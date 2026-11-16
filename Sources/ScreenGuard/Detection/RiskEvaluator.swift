import CoreGraphics
import Foundation

/// 综合六类特征输出风险评分，并维护风险状态机。
///
/// 核心原则：只有观察到手部尺度「持续变大」（由远及近）才允许报警。
/// 抬手、张手、静态悬停都不是接近动作，一律被尺度增长门控拦下。
final class RiskEvaluator {
    private(set) var state: DetectionState = .idle
    private(set) var assessment = RiskAssessment.empty

    /// 权重，总和为 1。growth 是核心信号，静态 zone 刻意压低。
    private let weights = (
        growth: CGFloat(0.32),
        direction: CGFloat(0.20),
        velocity: CGFloat(0.14),
        gesture: CGFloat(0.14),
        zone: CGFloat(0.08),
        arm: CGFloat(0.12)
    )

    /// 尺度增长门控：增长强度至少达到此值才认为手在靠近
    var growthGate: CGFloat = 0.22
    /// 连续增长帧数门槛（@30fps：2 帧约 66ms）
    var growthFramesNeeded = 2

    private var nearFrames = 0
    private var awayFrames = 0
    private var growthFrames = 0
    private var latched = false

    /// 输入特征、视觉置信度、遮挡保留系数，输出风险与状态
    func evaluate(
        features: FeatureSet,
        visualConfidence: CGFloat,
        occlusionRetention: CGFloat,
        hasObservation: Bool
    ) -> RiskAssessment {
        var raw = features.growth * weights.growth
        raw += features.direction * weights.direction
        raw += features.velocity * weights.velocity
        raw += features.gesture * weights.gesture
        raw += features.zone * weights.zone
        raw += features.armExtension * weights.arm

        // 上肢特征不可用时（前置摄像头只拍到半身），其权重按比例还给可靠特征
        let armUsable = features.armExtension > 0.01
        if !armUsable { raw /= (1.0 - weights.arm) }

        // 缺失观测不直接归零，而是按遮挡保留系数衰减
        if !hasObservation {
            raw = max(raw, assessment.risk * occlusionRetention)
        }

        // 视觉置信度低时风险上限受限，但不完全忽略历史证据
        raw *= 0.45 + 0.55 * visualConfidence
        let risk = min(max(raw, 0), 1)

        let intent = min(max(
            features.growth * 0.35 + features.direction * 0.25
                + features.velocity * 0.2 + features.gesture * 0.2,
            0
        ), 1)

        // === 尺度增长门控 ===
        // 连续增长才累积帧数；抬手/张手的一次性跳变会在下一帧被清零。
        if features.growth >= growthGate {
            growthFrames += 1
        } else {
            growthFrames = 0
        }
        let gateOpen = features.growth >= growthGate && growthFrames >= growthFramesNeeded

        let threshold = currentThreshold()
        let newState: DetectionState

        // 速度直通也必须过增长门控：光是快不算靠近，得在变大
        let strongApproach = hasObservation
            && features.velocity >= 0.85
            && features.direction >= 0.8
            && features.growth >= 0.3
            && visualConfidence >= 0.55

        if !latched {
            if gateOpen && risk >= threshold && hasObservation {
                nearFrames += strongApproach ? 2 : 1
                awayFrames = 0
                if nearFrames >= 3 {
                    latched = true
                    newState = .alert
                } else {
                    newState = .approaching
                }
            } else if gateOpen && risk >= threshold * 0.6 {
                // 门控开着但风险略低：衰减一票，保留观察，不直接清零
                nearFrames = max(0, nearFrames - 1)
                newState = .observing
            } else {
                // 没有持续变大证据：一律清零。抬手/张手/静态悬停都走这里。
                nearFrames = 0
                newState = hasObservation ? .idle : .occluded
            }
        } else {
            // 已报警：维持提醒，直到手明确停住 / 远离 / 失去遮挡证据
            let handSettled = hasObservation && features.growth < 0.1
            let noEvidence = !hasObservation && occlusionRetention <= 0.25
            let riskGone = hasObservation && risk <= threshold * 0.35
            if handSettled || noEvidence || riskGone {
                awayFrames += 1
                // 手停住给较长时间（约 0.67s）避免提醒一闪而过
                let needed = handSettled ? 20 : (noEvidence ? 6 : 10)
                if awayFrames >= needed {
                    latched = false
                    nearFrames = 0
                    awayFrames = 0
                    growthFrames = 0
                    newState = .recovery
                } else {
                    newState = .alert
                }
            } else {
                awayFrames = 0
                newState = .alert
            }
        }

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
        latched = false
    }

    private func currentThreshold() -> CGFloat {
        let levels: [CGFloat] = [0.62, 0.48, 0.36]
        let raw = UserDefaults.standard.integer(forKey: "sensitivity")
        return levels[min(max(raw, 0), levels.count - 1)]
    }
}
