import CoreGraphics
import Foundation

/// 综合特征输出风险评分，并维护风险状态机。
///
/// 核心原则：只有观察到手部尺度「持续变大」（由远及近）才允许报警。
/// 抬手、张手、静态悬停都不是接近动作，一律被尺度增长门控拦下。
///
/// 精简原则：评分只保留真正有判别力的信号。速度来自两帧关键点差分，抖动大，
/// 仅写入诊断数据而不参与评分；上肢特征在常见坐姿下恒为 0，整条分支已移除。
final class RiskEvaluator {
    private(set) var state: DetectionState = .idle
    private(set) var assessment = RiskAssessment.empty

    /// 评分权重，总和为 1。growth 占主导，zone 提供位置约束，其余仅弱辅助。
    private let weights = (
        growth: CGFloat(0.62),
        direction: CGFloat(0.08),
        gesture: CGFloat(0.12),
        zone: CGFloat(0.18)
    )

    /// 尺度增长门控：增长强度至少达到此值才认为手在靠近
    var growthGate: CGFloat = 0.22
    /// 连续增长帧数门槛（@30fps：2 帧约 66ms）
    var growthFramesNeeded = 2

    private var nearFrames = 0
    private var awayFrames = 0
    private var growthFrames = 0
    private var alertFrames = 0
    private var latched = false

    /// 最近若干帧的瞬时风险，用于滑动平均。窗口未满时按实际帧数求均值，
    /// 因此第一帧强信号不会被稀释；只有连续多帧的抖动才会被平滑掉。
    private var riskWindow: [CGFloat] = []
    private let riskWindowSize = 3
    /// 进入遮挡前最后一次可信的平滑风险，仅供无观测帧衰减使用，不参与平滑
    private var lastObservedRisk: CGFloat = 0

    /// alert 最长保持帧数（@30fps 约 3 秒）。正常退出都在 1 秒内完成，
    /// 这里只作为兜底：任何退出条件因边缘情况失效时，强制恢复，
    /// 避免状态永久卡在 alert 导致后续接近再也无法触发提醒。
    var maxAlertFrames = 90

    /// 输入特征、视觉置信度、遮挡保留系数，输出风险与状态
    func evaluate(
        features: FeatureSet,
        visualConfidence: CGFloat,
        occlusionRetention: CGFloat,
        hasObservation: Bool
    ) -> RiskAssessment {
        // 三路信号开关：关掉的通道权重为 0，其余通道按原比例归一化到总和 1。
        let signals = SignalSettings.current
        let activeGrowth = signals.growth ? weights.growth : 0
        let activeDirection = signals.growth ? weights.direction : 0
        let activeGesture = signals.gesture ? weights.gesture : 0
        let activeZone = signals.zone ? weights.zone : 0
        let activeTotal = activeGrowth + activeDirection + activeGesture + activeZone

        var raw = features.growth * activeGrowth
        raw += features.direction * activeDirection
        raw += features.gesture * activeGesture
        raw += features.zone * activeZone
        raw /= max(activeTotal, 0.0001)

        // 意图分与风险分共用同一套加权口径；区别仅在 risk 会叠加遮挡保留与视觉置信度。
        // 这样诊断数据里 intentConfidence / risk 可直接对照，不会因两套公式而矛盾。
        let intent = min(max(raw, 0), 1)

        // 视觉置信度只做温和压制：快速戳屏时 Vision 置信度会骤降，
        // 旧系数 0.45+0.55·vc 在 vc=0.2 时把风险压到 56%，实测会把本该触发的
        // 动作压到阈值以下；改为 0.7+0.3·vc，最差仍保留 70%，减少漏报。
        raw *= 0.7 + 0.3 * visualConfidence
        let instantaneous = min(max(raw, 0), 1)

        // 3 帧滑动平均：食指伸出是二值判定、关键点逐帧抖动，会让瞬时风险
        // 在阈值上下反复横跳。平滑后单帧尖峰不再触发，稳定接近仍能保持高分。
        // 窗口未满时按实际帧数求均值，保证第一帧强信号不被稀释。
        // 仅在有真实观测时更新窗口——遮挡期若把衰减值反复写回，会形成
        // 「历史高值 → 平滑 → 再保持 → 再平滑」的正反馈，拖慢风险衰减。
        var risk: CGFloat
        if hasObservation {
            riskWindow.append(instantaneous)
            if riskWindow.count > riskWindowSize { riskWindow.removeFirst() }
            risk = riskWindow.reduce(0, +) / CGFloat(riskWindow.count)
            lastObservedRisk = risk
        } else {
            // 缺失观测：从最后一次可信风险按遮挡保留系数衰减。
            // 衰减值既不写回窗口也不更新基线，避免「历史高值反复平滑自己」的锁死。
            risk = max(instantaneous, lastObservedRisk * occlusionRetention)
        }

        // === 尺度增长门控 ===
        // 连续增长才累积帧数；抬手/张手的一次性跳变会在下一帧被清零。
        if features.growth >= growthGate {
            growthFrames += 1
        } else {
            growthFrames = 0
        }
        // 「正在靠近」关掉时，门控随之停用；由用户显式选择只靠区域/姿态判断。
        let gateOpen = signals.growth
            ? (features.growth >= growthGate && growthFrames >= growthFramesNeeded)
            : true

        let threshold = currentThreshold()
        let newState: DetectionState

        // 快速通道同样以增长为核心，并额外要求进入危险区；不再依赖抖动大的速度/方向
        let strongApproach = signals.growth && hasObservation
            && features.growth >= 0.55
            && features.zone >= 0.4
            && visualConfidence >= 0.55

        if !latched {
            if gateOpen && risk >= threshold && hasObservation {
                nearFrames += strongApproach ? 2 : 1
                awayFrames = 0
                if nearFrames >= 2 {
                    latched = true
                    alertFrames = 0
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
            alertFrames += 1
            let handSettled = signals.growth && hasObservation && features.growth < 0.1
            let noEvidence = !hasObservation && occlusionRetention <= 0.25
            let riskGone = hasObservation && risk <= threshold * 0.35
            // 兜底：即使所有退出条件都因边缘情况失效，超过最长保持时间也强制恢复，
            // 避免状态永久卡在「已提醒」而阻断后续提醒。
            let timedOut = alertFrames >= maxAlertFrames
            if handSettled || noEvidence || riskGone || timedOut {
                awayFrames += 1
                // 手停住给较长时间（约 0.67s）避免提醒一闪而过；超时则一帧即恢复
                let needed = timedOut ? 1 : (handSettled ? 20 : (noEvidence ? 6 : 10))
                if awayFrames >= needed {
                    latched = false
                    nearFrames = 0
                    awayFrames = 0
                    growthFrames = 0
                    alertFrames = 0
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
        alertFrames = 0
        riskWindow.removeAll()
        lastObservedRisk = 0
        latched = false
    }

    private func currentThreshold() -> CGFloat {
        let levels: [CGFloat] = [0.62, 0.48, 0.36]
        let raw = UserDefaults.standard.integer(forKey: "sensitivity")
        return levels[min(max(raw, 0), levels.count - 1)]
    }
}
