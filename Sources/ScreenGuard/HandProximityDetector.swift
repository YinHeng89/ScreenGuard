import AVFoundation
import Combine
import CoreVideo
import Vision

/// 检测系统协调者。
/// 对外保持 @Published 状态与回调接口，内部编排采集、追踪、分析、遮挡预测与风险决策。
/// 所有检测模块只在 analysisQueue 上访问；对外状态只在主线程写入。
final class HandProximityDetector: NSObject, ObservableObject {
    static let shared = HandProximityDetector()

    // MARK: - 采集

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.screenguard.session", qos: .userInitiated)
    private let analysisQueue = DispatchQueue(label: "com.screenguard.analysis", qos: .userInitiated)

    private let visionHandler = VNSequenceRequestHandler()
    private lazy var handRequest: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        return request
    }()

    // MARK: - 检测模块

    private let tracker = HandTrackingEngine()
    private let occlusion = OcclusionPredictor()
    private let evaluator = RiskEvaluator()

    // MARK: - 生命周期状态

    /// 跨线程读写（主线程写、sessionQueue/回调读），用锁保证原子性。
    private let lifecycleLock = NSLock()
    private var generation: UInt64 = 0
    private var desiredRunning = false

    /// 只在 analysisQueue 内读写：start 后放行、stop/reset 时关闭，
    /// 用于丢弃已入队的残留帧，避免切摄像头后的幽灵报警。
    private var analysisActive = false
    private var lastProcessedUp: UInt64 = 0
    private var lastTriggerUp: UInt64 = 0
    /// Vision 连续异常计数，累计到阈值时提示一次，恢复识别后清零。
    private var consecutiveErrors = 0

    /// 本轮接近是否已真正上报提醒。仅存在于 analysisQueue，
    /// UI 状态由它派生，不反向读取主线程的 @Published 值。
    private var reportIssued = false

    // 诊断快照：最近一帧的像素缓冲与元数据，仅在 analysisQueue 读写
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastFrameMeta: [String: Any] = [:]

    // MARK: - 对外状态

    @Published private(set) var isMonitoring = false
    @Published private(set) var isClose = false
    @Published private(set) var detectionStrength: CGFloat = 0
    @Published private(set) var indexExtended = false
    @Published private(set) var approaching = false
    @Published private(set) var zoneStrength: CGFloat = 0
    @Published private(set) var stateText = "待机"
    @Published private(set) var statusText = "未启动"

    var onTrigger: ((CGFloat) -> Void)?
    var onClear: (() -> Void)?

    private static func uptimeNanos() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    private static func seconds(_ nanos: UInt64) -> TimeInterval {
        TimeInterval(nanos) / 1_000_000_000
    }

    // MARK: - 生命周期

    func start(deviceID: String) {
        let token = beginTransition(desiredRunning: true)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrent(token) else { return }
            self.statusText = "正在启动"
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession(deviceID: deviceID, token: token)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                DispatchQueue.main.async {
                    guard self.isCurrent(token) else { return }
                    if !granted {
                        self.statusText = "相机权限未开启"
                        return
                    }
                    self.configureSession(deviceID: deviceID, token: token)
                }
            }
        default:
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrent(token) else { return }
                self.statusText = "相机权限被拒绝"
            }
        }
    }

    func stop() {
        _ = beginTransition(desiredRunning: false)
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
        resetState()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.statusText = "已暂停"
            self.onClear?()
        }
    }

    /// 原子递增 generation 并更新运行意图，返回新 token。
    private func beginTransition(desiredRunning: Bool) -> UInt64 {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        generation += 1
        self.desiredRunning = desiredRunning
        return generation
    }

    private func isCurrent(_ token: UInt64) -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return token == generation && desiredRunning
    }

    private func configureSession(deviceID: String, token: UInt64) {
        sessionQueue.async { [weak self] in
            guard let self, self.isCurrent(token) else { return }
            if self.session.isRunning { self.session.stopRunning() }

            self.session.beginConfiguration()
            for input in self.session.inputs { self.session.removeInput(input) }

            guard let device = self.resolveDevice(preferredID: deviceID),
                  let input = try? AVCaptureDeviceInput(device: device),
                  self.session.canAddInput(input) else {
                self.session.commitConfiguration()
                DispatchQueue.main.async {
                    guard self.isCurrent(token) else { return }
                    self.statusText = "摄像头不可用"
                }
                return
            }
            self.session.addInput(input)

            if !self.session.outputs.contains(self.videoOutput) {
                self.videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                self.videoOutput.alwaysDiscardsLateVideoFrames = true
                self.videoOutput.setSampleBufferDelegate(self, queue: self.analysisQueue)
                if self.session.canAddOutput(self.videoOutput) {
                    self.session.addOutput(self.videoOutput)
                }
            }

            self.session.commitConfiguration()
            self.session.startRunning()

            DispatchQueue.main.async {
                guard self.isCurrent(token) else {
                    self.sessionQueue.async {
                        if self.session.isRunning { self.session.stopRunning() }
                    }
                    return
                }
                // 先激活分析队列再放行 UI：与帧处理同一队列，保证时序
                self.analysisQueue.async { self.analysisActive = true }
                self.isMonitoring = true
                self.statusText = "监测中"
            }
        }
    }

    private func resolveDevice(preferredID: String) -> AVCaptureDevice? {
        if !preferredID.isEmpty, let device = AVCaptureDevice(uniqueID: preferredID) {
            return device
        }
        if let builtIn = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) {
            return builtIn
        }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.first ?? AVCaptureDevice.default(for: .video)
    }

    private func resetState() {
        // 检测模块与诊断缓存全部只在 analysisQueue 内访问，复位必须串行到该队列。
        analysisQueue.async { [weak self] in
            guard let self else { return }
            self.analysisActive = false
            self.tracker.clear()
            self.occlusion.reset()
            self.evaluator.reset()
            self.reportIssued = false
            self.lastPixelBuffer = nil
            self.lastFrameMeta = [:]
            self.consecutiveErrors = 0
        }
        // @Published 状态统一回主线程写
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isMonitoring = false
            self.isClose = false
            self.detectionStrength = 0
            self.indexExtended = false
            self.approaching = false
            self.zoneStrength = 0
            self.stateText = "待机"
        }
    }

    // MARK: - 帧处理流水线

    private func processFrame(_ pixelBuffer: CVPixelBuffer, at time: TimeInterval) {
        // 第一层：视觉感知
        let observation = perceive(pixelBuffer)

        // 第二层：多目标追踪
        let tracks = tracker.update(with: observation.hands, at: time)
        let hasObservation = tracker.hasLiveObservation(
            at: time, tolerance: DetectionConfig.Matching.observationTolerance)
        let primary = tracks.max {
            tracker.confidence(for: $0, at: time) < tracker.confidence(for: $1, at: time)
        }
        // 视觉置信度来自主目标轨迹：遮挡帧会按丢失时长指数衰减，而非感知层原始值。
        let visualConfidence = primary.map { tracker.confidence(for: $0, at: time) } ?? 0

        // 第三层：运动意图特征
        let features = extractFeatures(primary: primary, observation: observation, time: time)

        // 第四层：遮挡置信度。只在真实观测到手时刷新证据时间戳——
        // 无观测帧若也刷新，保留系数会恒为 1，导致状态永久卡在 alert。
        if hasObservation {
            let signals = SignalSettings.current
            occlusion.observe(
                risk: features.weightedScore(signals: signals),
                approaching: features.approaching,
                at: time
            )
        }
        let retention = occlusion.retainedRisk(at: time)

        // 第五层：风险决策
        let assessment = evaluator.evaluate(
            features: features,
            visualConfidence: visualConfidence,
            occlusionRetention: retention,
            hasObservation: hasObservation
        )

        publish(
            assessment: assessment,
            features: features,
            observation: observation,
            primary: primary,
            retention: retention,
            pixelBuffer: pixelBuffer,
            time: time
        )
    }

    /// 第一层：用 Vision 提取手部关键点与姿态。
    private func perceive(_ pixelBuffer: CVPixelBuffer) -> Perception {
        var hands: [HandObservation] = []
        var indexExtended = false
        var palmOpen = false

        do {
            try visionHandler.perform([handRequest], on: pixelBuffer, orientation: .up)
            for hand in handRequest.results ?? [] {
                guard let analyzed = HandPoseAnalyzer.analyze(hand) else { continue }
                hands.append(analyzed.observation)
                indexExtended = indexExtended || analyzed.indexExtended
                palmOpen = palmOpen || analyzed.palmOpen
            }
            consecutiveErrors = 0
        } catch {
            // 单帧识别失败无需中断监测，下一帧会重试；持续异常才提示用户。
            consecutiveErrors += 1
            if consecutiveErrors >= DetectionConfig.errorNoticeThreshold {
                consecutiveErrors = 0
                DispatchQueue.main.async { [weak self] in
                    self?.statusText = "识别暂时中断"
                }
            }
        }

        return Perception(
            hands: hands,
            indexExtended: indexExtended,
            palmOpen: palmOpen
        )
    }

    /// 第三层：从主目标轨迹计算评分特征。
    private func extractFeatures(
        primary: HandTrack?,
        observation: Perception,
        time: TimeInterval
    ) -> FeatureSet {
        guard let track = primary else { return FeatureSet() }

        let anchor = track.indexTip ?? track.palm
        let speed = track.velocity.length
        let gesture = DetectionConfig.GestureScore.self
        var features = FeatureSet()
        features.direction = ScreenGeometry.directionScore(velocity: track.velocity, at: anchor)
        // 速度来自关键点差分、抖动大，只写入诊断数据不参与评分
        features.velocity = min(max(speed / DetectionConfig.velocityNormalizer, 0), 1)
        features.gesture = (observation.indexExtended ? gesture.indexExtended : 0)
            + (observation.palmOpen ? gesture.palmOpen : 0)
        features.zone = ScreenGeometry.zoneScore(for: anchor)
        features.growth = tracker.scaleGrowth(for: track)
        return features
    }

    /// 把本帧结果转换为触发判定、诊断快照与主线程 UI 更新。
    private func publish(
        assessment: RiskAssessment,
        features: FeatureSet,
        observation: Perception,
        primary: HandTrack?,
        retention: CGFloat,
        pixelBuffer: CVPixelBuffer,
        time: TimeInterval
    ) {
        let strength = min(max(assessment.risk / DetectionConfig.threshold, 0), 1)
        let inAlert = assessment.state == .alert
        // 先捕获「上一帧是否已上报」：退出 alert 时靠它决定是否收起提醒。
        let wasIssued = reportIssued

        let now = Self.uptimeNanos()
        let cooldownOK = lastTriggerUp == 0
            || now - lastTriggerUp >= DetectionConfig.cooldownNanos
        let fired = inAlert && !wasIssued && cooldownOK
        if fired {
            lastTriggerUp = now
            reportIssued = true
        } else if !inAlert {
            // 已退出 alert，允许下一轮接近再次上报
            reportIssued = false
        }

        // 只有真正上报过才算「已提醒」；冷却期压住的 alert 显示「接近中」。
        let announced = inAlert && reportIssued
        let displayState = inAlert && !announced ? "接近中" : assessment.state.rawValue

        let meta = Self.snapshotMeta(
            assessment: assessment, strength: strength, time: time,
            observation: observation, features: features,
            approaching: features.approaching, retention: retention, primary: primary)
        if fired {
            DiagnosticCapture.shared.save(
                png: DiagnosticCapture.pngData(from: pixelBuffer), reason: "alert", metadata: meta)
        }
        // 缓存最近一帧供「手动记录」使用（漏报分析）
        lastPixelBuffer = pixelBuffer
        lastFrameMeta = meta

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.detectionStrength = strength
            self.indexExtended = observation.indexExtended
            self.approaching = features.approaching
            self.zoneStrength = features.zone
            self.isClose = announced
            self.stateText = displayState

            if fired {
                self.onTrigger?(assessment.risk)
            } else if !inAlert && wasIssued {
                self.onClear?()
            }
        }
    }

    /// 本帧视觉感知结果。
    private struct Perception {
        var hands: [HandObservation] = []
        var indexExtended = false
        var palmOpen = false
    }

    /// 组装诊断快照的结构化数据，便于事后对照画面分析误报 / 漏报。
    private static func snapshotMeta(
        assessment: RiskAssessment,
        strength: CGFloat,
        time: TimeInterval,
        observation: Perception,
        features: FeatureSet,
        approaching: Bool,
        retention: CGFloat,
        primary: HandTrack?
    ) -> [String: Any] {
        let signals = SignalSettings.current
        var meta: [String: Any] = [
            "algorithm": "growth-first-v3",
            "signals": ["growth": signals.growth, "gesture": signals.gesture, "zone": signals.zone],
            "uptimeSec": time,
            "state": assessment.state.rawValue,
            "risk": assessment.risk,
            "strength": strength,
            "sensitivityLevel": UserDefaults.standard.integer(forKey: "sensitivity"),
            "threshold": DetectionConfig.threshold,
            "visualConfidence": assessment.visualConfidence,
            "intentConfidence": assessment.intentConfidence,
            "occlusionRetention": retention,
            "feature_direction": features.direction,
            "feature_velocity": features.velocity,
            "feature_gesture": features.gesture,
            "feature_zone": features.zone,
            "feature_growth": features.growth,
            "gateOpen": assessment.approachGateOpen,
            "growthFrames": assessment.sustainedGrowthFrames,
            "indexExtended": observation.indexExtended,
            "palmOpen": observation.palmOpen,
            "approaching": approaching,
            "hasTrack": primary != nil
        ]
        if let t = primary {
            meta["track"] = [
                "velocity": [t.velocity.x, t.velocity.y],
                "indexTip": t.indexTip.map { [$0.x, $0.y] } ?? NSNull(),
                "palm": [t.palm.x, t.palm.y],
                "missedFrames": t.missedFrames,
                "confidence": t.confidence,
                "scaleHistory": t.scaleHistory
            ] as [String: Any]
        }
        return meta
    }

    /// 手动记录当前画面（用于分析漏报：手确实戳了但没触发报警）。
    func captureManualSnapshot() {
        analysisQueue.async { [weak self] in
            guard let self else { return }
            let hasFrame = self.lastPixelBuffer != nil
            let png = self.lastPixelBuffer.flatMap { DiagnosticCapture.pngData(from: $0) }
            var meta = self.lastFrameMeta
            meta["note"] = hasFrame
                ? "手动记录（可能用于漏报分析）"
                : "手动记录时无摄像头画面：监测未启动或相机未授权"
            meta["hasImage"] = hasFrame
            DiagnosticCapture.shared.save(png: png, reason: "manual", metadata: meta)
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension HandProximityDetector: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // 丢弃 stop/切相机后已入队的残留帧：这些帧会用被清空的状态误判。
        // analysisActive 与本回调同在 analysisQueue，无数据竞争。
        guard analysisActive else { return }

        let now = Self.uptimeNanos()
        if lastProcessedUp != 0 && now - lastProcessedUp < DetectionConfig.frameIntervalNanos {
            return
        }
        lastProcessedUp = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        processFrame(pixelBuffer, at: Self.seconds(now))
    }
}
