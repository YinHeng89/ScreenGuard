import AVFoundation
import Combine
import Vision

/// 检测系统协调者。
/// 对外保持原有 @Published 状态与回调接口，内部编排采集、追踪、分析、遮挡预测与风险决策。
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
    private var geometry = ScreenGeometry()

    // MARK: - 状态

    private var desiredRunning = false
    private var generation: UInt64 = 0
    private var lastProcessedUp: UInt64 = 0
    private var lastTriggerUp: UInt64 = 0
    private var consecutiveErrors = 0

    // 诊断快照：最近一帧的像素缓冲与元数据，仅在 analysisQueue 读写
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastFrameMeta: [String: Any] = [:]
    /// 判定用的本地状态镜像，避免跨线程读取主线程 @Published 值
    private var localIsClose = false

    @Published private(set) var isMonitoring = false
    @Published private(set) var isClose = false
    @Published private(set) var detectionStrength: CGFloat = 0
    @Published private(set) var indexExtended = false
    @Published private(set) var approaching = false
    @Published private(set) var zoneStrength: CGFloat = 0
    @Published private(set) var stateText = "待机"
    @Published private(set) var statusText = "未启动"

    /// 兼容旧接口：检测强度别名
    var currentSpan: CGFloat { detectionStrength }

    var onTrigger: ((CGFloat) -> Void)?
    var onClear: (() -> Void)?

    private static func uptimeNanos() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    private static func seconds(_ nanos: UInt64) -> TimeInterval {
        TimeInterval(nanos) / 1_000_000_000
    }

    // MARK: - 生命周期

    override init() {
        super.init()
        geometry.load()
    }

    func start(deviceID: String) {
        generation += 1
        let token = generation
        desiredRunning = true
        statusText = "正在启动"

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession(deviceID: deviceID, token: token)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                DispatchQueue.main.async {
                    guard self.isCurrent(token), granted else {
                        if !granted { self.statusText = "相机权限未开启" }
                        return
                    }
                    self.configureSession(deviceID: deviceID, token: token)
                }
            }
        default:
            statusText = "相机权限被拒绝"
        }
    }

    func stop() {
        generation += 1
        desiredRunning = false
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
        resetState()
        statusText = "已暂停"
        onClear?()
    }

    private func isCurrent(_ token: UInt64) -> Bool {
        token == generation && desiredRunning
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
        tracker.clear()
        occlusion.reset()
        evaluator.reset()
        isMonitoring = false
        isClose = false
        detectionStrength = 0
        indexExtended = false
        approaching = false
        zoneStrength = 0
        stateText = "待机"
        consecutiveErrors = 0
        // 诊断缓存与判定镜像都在 analysisQueue 内访问，清理也送回该队列
        analysisQueue.async { [weak self] in
            guard let self else { return }
            self.localIsClose = false
            self.lastPixelBuffer = nil
            self.lastFrameMeta = [:]
        }
    }

    // MARK: - 帧处理流水线

    private func cooldownNanos() -> UInt64 {
        UInt64(max(UserDefaults.standard.integer(forKey: "cooldownSeconds"), 1)) * 1_000_000_000
    }

    private func processFrame(_ pixelBuffer: CVPixelBuffer, at time: TimeInterval) {
        // Layer 1：视觉感知
        var handObservations: [HandObservation] = []
        var indexExtended = false
        var palmOpen = false

        do {
            try visionHandler.perform([handRequest], on: pixelBuffer, orientation: .up)
            for hand in handRequest.results ?? [] {
                guard let analyzed = HandPoseAnalyzer.analyze(hand) else { continue }
                handObservations.append(analyzed.observation)
                indexExtended = indexExtended || analyzed.indexExtended
                palmOpen = palmOpen || analyzed.palmOpen
            }
        } catch {
            consecutiveErrors += 1
            if consecutiveErrors >= 20 {
                consecutiveErrors = 0
                DispatchQueue.main.async { [weak self] in self?.statusText = "识别暂时中断" }
            }
        }
        if (handRequest.results?.isEmpty ?? true) == false { consecutiveErrors = 0 }

        // Layer 2：多目标追踪
        let tracks = tracker.update(with: handObservations, at: time)
        let hasObservation = tracker.hasLiveObservation(at: time)

        // Layer 3 & 4：运动意图 + 遮挡置信度
        let primary = tracks.max {
            tracker.confidence(for: $0, at: time) < tracker.confidence(for: $1, at: time)
        }

        var features = FeatureSet()
        var visualConfidence: CGFloat = 0
        var riskHint: CGFloat = 0

        if let track = primary {
            let confidence = tracker.confidence(for: track, at: time)
            visualConfidence = confidence
            let velocity = track.velocity
            let anchor = track.indexTip ?? track.palm
            let speed = velocity.length

            features.direction = geometry.directionScore(velocity: velocity, at: anchor)
            // 速度仅作诊断展示，不参与评分
            features.velocity = min(max(speed / 0.45, 0), 1)
            features.gesture = (indexExtended ? 0.65 : 0) + (palmOpen ? 0.35 : 0)
            features.zone = geometry.zoneScore(for: anchor)
            features.growth = tracker.scaleGrowth(for: track)

            // 遮挡期证据同样遵循信号开关，并按开启项重新归一化
            let signals = SignalSettings.current
            let hintTotal: CGFloat = (signals.growth ? 0.7 : 0)
                + (signals.zone ? 0.2 : 0) + (signals.gesture ? 0.1 : 0)
            riskHint = ((signals.growth ? features.growth * 0.7 : 0)
                + (signals.zone ? features.zone * 0.2 : 0)
                + (signals.gesture ? features.gesture * 0.1 : 0))
                / max(hintTotal, 0.0001)
        } else {
            // 无观测时不伪造风险，交给遮挡保留系数衰减
            riskHint = 0
        }

        // 接近意图以「尺度持续变大」为核心；单纯速度快/方向对都不算接近
        let approaching = features.growth >= 0.2 && features.direction > 0.3
        occlusion.observe(risk: riskHint, approaching: approaching, at: time)
        let retention = occlusion.retainedRisk(at: time)

        // Layer 5：风险决策
        let assessment = evaluator.evaluate(
            features: features,
            visualConfidence: visualConfidence,
            occlusionRetention: retention,
            hasObservation: hasObservation
        )

        let strength = min(max(assessment.risk / currentThreshold(), 0), 1)
        let wasClose = localIsClose
        let now = Self.uptimeNanos()
        let fired = assessment.state == .alert && !wasClose
            && (lastTriggerUp == 0 || now - lastTriggerUp >= cooldownNanos())

        if fired { lastTriggerUp = now }
        localIsClose = assessment.state == .alert

        // 诊断快照：在 analysisQueue 内、pixelBuffer 仍有效时转换并落盘
        if fired {
            let png = DiagnosticCapture.pngData(from: pixelBuffer)
            let meta = Self.snapshotMeta(
                assessment: assessment, strength: strength, time: time,
                indexExtended: indexExtended, palmOpen: palmOpen,
                approaching: approaching, visualConfidence: visualConfidence,
                retention: retention, primary: primary
            )
            DiagnosticCapture.shared.save(png: png, reason: "alert", metadata: meta)
        }

        // 同时缓存最近一帧数据，供「手动记录」使用（漏报分析）
        lastPixelBuffer = pixelBuffer
        lastFrameMeta = Self.snapshotMeta(
            assessment: assessment, strength: strength, time: time,
            indexExtended: indexExtended, palmOpen: palmOpen,
            approaching: approaching, visualConfidence: visualConfidence,
            retention: retention, primary: primary
        )

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.detectionStrength = strength
            self.indexExtended = indexExtended
            self.approaching = approaching
            self.zoneStrength = features.zone
            self.stateText = assessment.state.rawValue
            self.isClose = assessment.state == .alert

            if fired {
                self.onTrigger?(assessment.risk)
            } else if assessment.state == .recovery && wasClose {
                self.onClear?()
            }
        }
    }

    /// 组装诊断快照的结构化数据，便于事后对照画面分析误报 / 漏报
    private static func snapshotMeta(
        assessment: RiskAssessment,
        strength: CGFloat,
        time: TimeInterval,
        indexExtended: Bool,
        palmOpen: Bool,
        approaching: Bool,
        visualConfidence: CGFloat,
        retention: CGFloat,
        primary: HandTrack?
    ) -> [String: Any] {
        let f = assessment.features
        var meta: [String: Any] = [
            "algorithm": "growth-first-v3",
            "signals": [
                "growth": SignalSettings.current.growth,
                "gesture": SignalSettings.current.gesture,
                "zone": SignalSettings.current.zone
            ],
            "uptimeSec": time,
            "state": assessment.state.rawValue,
            "risk": assessment.risk,
            "strength": strength,
            "sensitivityLevel": UserDefaults.standard.integer(forKey: "sensitivity"),
            "threshold": Self.thresholdValue(),
            "visualConfidence": visualConfidence,
            "intentConfidence": assessment.intentConfidence,
            "occlusionRetention": retention,
            "feature_direction": f.direction,
            "feature_velocity": f.velocity,
            "feature_gesture": f.gesture,
            "feature_zone": f.zone,
            "feature_growth": f.growth,
            "gateOpen": assessment.approachGateOpen,
            "growthFrames": assessment.sustainedGrowthFrames,
            "indexExtended": indexExtended,
            "palmOpen": palmOpen,
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

    /// 手动记录当前画面（用于分析漏报：手确实戳了但没触发报警）
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

    private static func thresholdValue() -> CGFloat {
        let levels: [CGFloat] = [0.62, 0.48, 0.36]
        let raw = UserDefaults.standard.integer(forKey: "sensitivity")
        return levels[min(max(raw, 0), levels.count - 1)]
    }

    private func currentThreshold() -> CGFloat { Self.thresholdValue() }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension HandProximityDetector: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = Self.uptimeNanos()
        // 采样提到 ~30fps：3 帧确认窗口从 200ms 缩到 100ms，覆盖快速戳屏动作
        if lastProcessedUp != 0 && now - lastProcessedUp < 33_000_000 { return }
        lastProcessedUp = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        processFrame(pixelBuffer, at: Self.seconds(now))
    }
}
