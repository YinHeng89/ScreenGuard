import CoreGraphics
import Foundation

/// 第五层：把特征综合成风险评分，并驱动六态状态机。
///
/// 设计原则：只有观察到手部尺度「持续变大」才允许报警。抬手、张手、静态悬停
/// 都不构成接近动作，由尺度增长门控统一拦下。速度因逐帧抖动大，只写入诊断
/// 数据、不参与评分。
final class RiskEvaluator {
    private(set) var state: DetectionState = .idle
    private(set) var assessment = RiskAssessment.empty

    // 状态机计数器：near 累积进入证据，away 累积退出证据，growth 累积连续增长，
    // alert 记录已锁定时长。全部只在 analyze 所在的 analysisQueue 上访问。
    private var nearFrames = 0
    private var awayFrames = 0
    private var growthFrames = 0
    private var alertFrames = 0
    private var latched = false

    /// 最近若干帧的瞬时风险，滑动平均抑制抖动。窗口未满时按实际帧数求均值，
    /// 因此首帧强信号不会被稀释。
    private var riskWindow: [CGFloat] = []
    /// 进入遮挡前最后一次可信的平滑风险，仅供无观测帧衰减，不写回窗口，
    /// 避免衰减值与窗口互相强化导致风险无法消退。
    private var lastObservedRisk: CGFloat = 0

    /// 输入特征、视觉置信度、遮挡保留系数，输出风险与状态。
    func evaluate(
        features: FeatureSet,
        visualConfidence: CGFloat,
        occlusionRetention: CGFloat,
        hasObservation: Bool
    ) -> RiskAssessment {
        let signals = SignalSettings.current
        let risk = smoothedRisk(
            features: features,
            signals: signals,
            visualConfidence: visualConfidence,
            occlusionRetention: occlusionRetention,
            hasObservation: hasObservation
        )
        let intent = intentScore(features: features, signals: signals)

        // 尺度增长门控：只有连续多帧达标才算「正在靠近」。
        growthFrames = features.growth >= DetectionConfig.growthGate ? growthFrames + 1 : 0
        // 用户关闭「正在靠近」时门控停用，改由区域/姿态独立判断。
        let gateOpen = signals.growth
            ? (features.growth >= DetectionConfig.growthGate
                && growthFrames >= DetectionConfig.growthFramesNeeded)
            : true

        let threshold = DetectionConfig.threshold
        let newState = nextState(
            features: features,
            signals: signals,
            risk: risk,
            threshold: threshold,
            gateOpen: gateOpen,
            visualConfidence: visualConfidence,
            occlusionRetention: occlusionRetention,
            hasObservation: hasObservation
        )

        state = newState
        assessment = RiskAssessment(
            risk: risk,
            state: newState,
            visualConfidence: visualConfidence,
            intentConfidence: intent,
            features: features,
            approachGateOpen: gateOpen,
            sustainedGrowthFrames: growthFrames
        )
        return assessment
    }

    func reset() {
        state = .idle
        assessment = .empty
        nearFrames = 0
        awayFrames = 0
        growthFrames = 0
        alertFrames = 0
        riskWindow.removeAll()
        lastObservedRisk = 0
        latched = false
    }

    // MARK: - 评分

    /// 意图分与风险分共用 FeatureSet 的同一加权口径，仅风险额外叠加置信度与遮挡衰减。
    /// 这样诊断数据里 intentConfidence 与 risk 可直接对照，不会因两套公式而矛盾。
    private func intentScore(features: FeatureSet, signals: SignalSettings) -> CGFloat {
        min(max(features.weightedScore(signals: signals), 0), 1)
    }

    private func smoothedRisk(
        features: FeatureSet,
        signals: SignalSettings,
        visualConfidence: CGFloat,
        occlusionRetention: CGFloat,
        hasObservation: Bool
    ) -> CGFloat {
        var raw = features.weightedScore(signals: signals)
        raw *= DetectionConfig.confidenceFloor + DetectionConfig.confidenceSlope * visualConfidence
        let instantaneous = min(max(raw, 0), 1)

        if hasObservation {
            riskWindow.append(instantaneous)
            if riskWindow.count > DetectionConfig.riskWindowSize { riskWindow.removeFirst() }
            let average = riskWindow.reduce(0, +) / CGFloat(riskWindow.count)
            lastObservedRisk = average
            return average
        }

        // 缺失观测：从最后一次可信风险按遮挡保留系数衰减，
        // 衰减值既不写回窗口也不更新基线，避免自引用锁死。
        return max(instantaneous, lastObservedRisk * occlusionRetention)
    }

    // MARK: - 状态机

    private func nextState(
        features: FeatureSet,
        signals: SignalSettings,
        risk: CGFloat,
        threshold: CGFloat,
        gateOpen: Bool,
        visualConfidence: CGFloat,
        occlusionRetention: CGFloat,
        hasObservation: Bool
    ) -> DetectionState {
        latched ? alertState(
            features: features, signals: signals, risk: risk, threshold: threshold,
            occlusionRetention: occlusionRetention, hasObservation: hasObservation
        ) : idleState(
            features: features, signals: signals, risk: risk, threshold: threshold,
            gateOpen: gateOpen, visualConfidence: visualConfidence,
            hasObservation: hasObservation
        )
    }

    /// 未锁定：累积接近证据，满足条件后进入 alert。
    private func idleState(
        features: FeatureSet,
        signals: SignalSettings,
        risk: CGFloat,
        threshold: CGFloat,
        gateOpen: Bool,
        visualConfidence: CGFloat,
        hasObservation: Bool
    ) -> DetectionState {
        let fast = DetectionConfig.FastApproach.self
        let strongApproach = signals.growth && hasObservation
            && features.growth >= fast.growth
            && features.zone >= fast.zone
            && visualConfidence >= fast.confidence

        if gateOpen && risk >= threshold && hasObservation {
            nearFrames += strongApproach ? fast.credit : 1
            awayFrames = 0
            if nearFrames >= DetectionConfig.enterFrames {
                latched = true
                alertFrames = 0
                return .alert
            }
            return .approaching
        }

        if gateOpen && risk >= threshold * DetectionConfig.observeFactor {
            // 略低于阈值：衰减一票，保留观察，不直接清零。
            nearFrames = max(0, nearFrames - 1)
            return .observing
        }

        // 没有持续变大的证据：抬手、张手、静态悬停都走这里。
        nearFrames = 0
        return hasObservation ? .idle : .occluded
    }

    /// 已锁定：维持提醒，直到手停住 / 远离 / 遮挡证据耗尽 / 超时。
    private func alertState(
        features: FeatureSet,
        signals: SignalSettings,
        risk: CGFloat,
        threshold: CGFloat,
        occlusionRetention: CGFloat,
        hasObservation: Bool
    ) -> DetectionState {
        alertFrames += 1

        let handSettled = signals.growth && hasObservation
            && features.growth < DetectionConfig.settledGrowth
        let noEvidence = !hasObservation
            && occlusionRetention <= DetectionConfig.Occlusion.exhausted
        let riskGone = hasObservation
            && risk <= threshold * DetectionConfig.riskGoneFactor
        let timedOut = alertFrames >= DetectionConfig.maxAlertFrames

        guard handSettled || noEvidence || riskGone || timedOut else {
            awayFrames = 0
            return .alert
        }

        awayFrames += 1
        let frames = DetectionConfig.ExitFrames.self
        let needed = timedOut ? 1
            : handSettled ? frames.settled
            : noEvidence ? frames.noEvidence
            : frames.riskGone
        guard awayFrames >= needed else { return .alert }

        latched = false
        nearFrames = 0
        awayFrames = 0
        growthFrames = 0
        alertFrames = 0
        return .recovery
    }
}
