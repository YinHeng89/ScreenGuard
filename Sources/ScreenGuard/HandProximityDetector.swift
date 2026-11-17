import AVFoundation
import Combine
import CoreVideo
import Vision

/// 单维度手部接近检测：手部在画面中的尺寸（包围盒对角线）达到阈值即报警。
/// 判定只有一条链路 —— 看得见手、且手足够大（足够近）；不再有增长、方向、
/// 姿态、区域、速度等多路评分。画面只在本机分析，不上传。
final class HandProximityDetector: NSObject, ObservableObject {
    static let shared = HandProximityDetector()

    // MARK: - 固定参数

    private enum Config {
        /// 灵敏度三档（保守 / 标准 / 灵敏）对应的尺寸阈值。
        static let thresholds: [CGFloat] = [0.62, 0.48, 0.36]
        /// 释放滞回系数：尺寸回落到阈值的该比例以下才允许下一轮报警。
        static let releaseFactor: CGFloat = 0.78
        /// 连续达标帧数（30fps 下约 100ms），抗单帧关键点抖动。
        static let confirmFrames = 3
        /// 帧处理最小间隔（纳秒），约 30fps。
        static let frameIntervalNanos: UInt64 = 33_000_000
        /// 手部关键点置信度下限与最少有效点数。
        static let jointConfidence: Float = 0.3
        static let minimumValidJoints = 6
    }

    // MARK: - 采集

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.screenguard.session", qos: .userInitiated)
    private let analysisQueue = DispatchQueue(label: "com.screenguard.analysis", qos: .userInitiated)
    private let visionHandler = VNSequenceRequestHandler()
    private lazy var handRequest: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 1
        return request
    }()

    // MARK: - 生命周期状态

    /// 跨线程读写（主线程写、sessionQueue/回调读），用锁保证原子性。
    private let lifecycleLock = NSLock()
    private var generation: UInt64 = 0
    private var desiredRunning = false

    /// 只在 analysisQueue 内读写：丢弃 stop/切相机后已入队的残留帧。
    private var analysisActive = false
    private var lastProcessedUp: UInt64 = 0

    // MARK: - 判定状态（只在 analysisQueue 内读写）

    private var nearFrames = 0
    private var awayFrames = 0
    private var latched = false
    private var lastTriggerUp: UInt64 = 0

    // 诊断快照缓存（只在 analysisQueue 内读写）
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastFrameMeta: [String: Any] = [:]

    // MARK: - 对外状态（只在主线程写）

    @Published private(set) var isMonitoring = false
    @Published private(set) var isClose = false
    @Published private(set) var detectionStrength: CGFloat = 0
    @Published private(set) var statusText = "未启动"
    @Published private(set) var stateText = "待机"

    /// 报警触发回调。弹窗显示时长由 OverlayManager 自己控制， detector 不再管隐藏。
    var onTrigger: ((CGFloat) -> Void)?

    private static func uptimeNanos() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    private static func seconds(_ nanos: UInt64) -> TimeInterval {
        TimeInterval(nanos) / 1_000_000_000
    }

    // MARK: - 用户设置

    private func currentThreshold() -> CGFloat {
        let raw = UserDefaults.standard.integer(forKey: "sensitivity")
        return Config.thresholds[min(max(raw, 0), Config.thresholds.count - 1)]
    }

    private func currentCooldownNanos() -> UInt64 {
        let seconds = max(UserDefaults.standard.integer(forKey: "cooldownSeconds"), 1)
        return UInt64(seconds) * 1_000_000_000
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
            self.isMonitoring = false
            self.isClose = false
            self.detectionStrength = 0
            self.stateText = "待机"
            self.statusText = "已暂停"
        }
    }

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
                // 先激活分析队列再放行 UI：与帧处理同队列，保证时序
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
        analysisQueue.async { [weak self] in
            guard let self else { return }
            self.analysisActive = false
            self.nearFrames = 0
            self.awayFrames = 0
            self.latched = false
            // 新一轮监测从零开始：否则切相机/重启后仍被上一轮的冷却压住，
            // 最长一个 cooldown 周期内不报警。
            self.lastTriggerUp = 0
            self.lastProcessedUp = 0
            self.lastPixelBuffer = nil
            self.lastFrameMeta = [:]
        }
    }

    // MARK: - 帧处理

    /// 从 Vision 结果里取手部关键点的包围盒对角线，作为唯一的尺度信号。
    private func measure(_ pixelBuffer: CVPixelBuffer) -> (span: CGFloat, confidence: Float, handCount: Int) {
        do {
            try visionHandler.perform([handRequest], on: pixelBuffer, orientation: .up)
        } catch {
            return (0, 0, 0)
        }

        var bestSpan: CGFloat = 0
        var bestConfidence: Float = 0
        var count = 0

        for hand in handRequest.results ?? [] {
            guard let points = try? hand.recognizedPoints(.all) else { continue }
            let valid = points.values.filter { $0.confidence > Config.jointConfidence }
            guard valid.count >= Config.minimumValidJoints else { continue }

            let xs = valid.map { CGFloat($0.location.x) }
            let ys = valid.map { CGFloat($0.location.y) }
            guard let minX = xs.min(), let maxX = xs.max(),
                  let minY = ys.min(), let maxY = ys.max() else { continue }

            let span = min(max(hypot(maxX - minX, maxY - minY), 0), 1.5)
            let confidence = valid.reduce(Float(0)) { $0 + $1.confidence } / Float(valid.count)
            count += 1
            if span > bestSpan {
                bestSpan = span
                bestConfidence = confidence
            }
        }

        return (bestSpan, bestConfidence, count)
    }

    /// 唯一的判定逻辑：尺寸达标连续 N 帧即报警，回落到释放线以下才解锁。
    private func evaluate(span: CGFloat, confidence: Float, handCount: Int) {
        let threshold = currentThreshold()
        let strength = min(max(span / threshold, 0), 1)
        let now = Self.uptimeNanos()

        var fired = false
        if !latched {
            if span >= threshold {
                nearFrames += 1
                awayFrames = 0
                if nearFrames >= Config.confirmFrames {
                    let cooldownOK = lastTriggerUp == 0
                        || now - lastTriggerUp >= currentCooldownNanos()
                    if cooldownOK {
                        latched = true
                        lastTriggerUp = now
                        fired = true
                    }
                }
            } else {
                nearFrames = 0
            }
        } else if span <= threshold * Config.releaseFactor {
            awayFrames += 1
            nearFrames = 0
            if awayFrames >= Config.confirmFrames {
                latched = false
                awayFrames = 0
            }
        } else {
            awayFrames = 0
        }

        let meta = snapshotMeta(
            span: span, threshold: threshold, strength: strength,
            confidence: confidence, handCount: handCount)
        lastFrameMeta = meta
        if fired {
            DiagnosticCapture.shared.save(
                png: lastPixelBuffer.flatMap { DiagnosticCapture.pngData(from: $0) },
                reason: "alert", metadata: meta)
        }

        let close = latched
        let state = latched ? "已提醒" : (span >= threshold ? "接近中" : "监测中")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.detectionStrength = strength
            self.isClose = close
            self.stateText = state
            if fired { self.onTrigger?(strength) }
        }
    }

    private func snapshotMeta(
        span: CGFloat, threshold: CGFloat, strength: CGFloat,
        confidence: Float, handCount: Int
    ) -> [String: Any] {
        [
            "algorithm": "single-span-v4",
            "span": span,
            "threshold": threshold,
            "strength": strength,
            "handCount": handCount,
            "confidence": confidence,
            "sensitivityLevel": UserDefaults.standard.integer(forKey: "sensitivity"),
            "latched": latched
        ]
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
        // 丢弃 stop/切相机后已入队的残留帧
        guard analysisActive else { return }

        let now = Self.uptimeNanos()
        if lastProcessedUp != 0 && now - lastProcessedUp < Config.frameIntervalNanos {
            return
        }
        lastProcessedUp = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastPixelBuffer = pixelBuffer

        let measured = measure(pixelBuffer)
        evaluate(span: measured.span, confidence: measured.confidence, handCount: measured.handCount)
    }
}
