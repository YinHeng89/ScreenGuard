import CoreGraphics
import Foundation

/// 遮挡期间的风险维持与衰减。
/// 设计原则：手消失不等于危险解除，而是观测暂时丢失，需根据历史证据重新评估。
final class OcclusionPredictor {
    /// 短时预测窗口（秒），可由实测标定
    var predictionWindow: TimeInterval = 0.5

    /// 判定目标确实离开所需的无观测时间
    var releaseDelay: TimeInterval = 0.8

    private var lastEvidenceAt: TimeInterval = 0
    private var hadApproachEvidence = false
    private var riskAtLoss: CGFloat = 0

    /// 记录一次有效观测及其风险
    func observe(risk: CGFloat, approaching: Bool, at time: TimeInterval) {
        lastEvidenceAt = time
        riskAtLoss = risk
        if approaching {
            hadApproachEvidence = true
        } else if risk < 0.25 {
            hadApproachEvidence = false
        }
    }

    /// 无观测时调用，返回衰减后的风险保留系数 [0,1]
    func retainedRisk(at time: TimeInterval) -> CGFloat {
        let elapsed = time - lastEvidenceAt
        guard elapsed > 0 else { return 1 }

        // 没有接近证据时快速衰减，避免误把普通离场当作威胁
        guard hadApproachEvidence else {
            return max(0, 1 - elapsed / 0.25)
        }

        // 有接近证据时，在预测窗口内保持较高风险
        if elapsed <= predictionWindow {
            return max(0.65, 1 - elapsed * 0.35)
        }

        // 超出窗口后逐渐放弃预测
        let decay = exp(-3.0 * (elapsed - predictionWindow))
        return max(0, decay)
    }

    /// 是否仍应维持风险状态
    func shouldHoldRisk(at time: TimeInterval) -> Bool {
        time - lastEvidenceAt < releaseDelay && retainedRisk(at: time) > 0.2
    }

    /// 记录的风险基线，供决策层参考
    var baselineRisk: CGFloat { riskAtLoss }

    func reset() {
        lastEvidenceAt = 0
        hadApproachEvidence = false
        riskAtLoss = 0
    }
}
