import CoreGraphics
import Foundation

/// 第三/四层：遮挡期间的风险维持与衰减。
/// 设计原则：手消失不等于危险解除，而是观测暂时丢失，需根据历史证据重新评估。
final class OcclusionPredictor {
    private var lastEvidenceAt: TimeInterval = 0
    private var hadApproachEvidence = false

    /// 记录一次有效观测及其风险。
    func observe(risk: CGFloat, approaching: Bool, at time: TimeInterval) {
        lastEvidenceAt = time
        if approaching {
            hadApproachEvidence = true
        } else if risk < DetectionConfig.Occlusion.evidenceClearRisk {
            hadApproachEvidence = false
        }
    }

    /// 无观测时返回衰减后的风险保留系数 [0,1]。
    func retainedRisk(at time: TimeInterval) -> CGFloat {
        let elapsed = time - lastEvidenceAt
        guard elapsed > 0 else { return 1 }

        // 没有接近证据时快速衰减，避免把普通离场误判为威胁
        let o = DetectionConfig.Occlusion.self
        guard hadApproachEvidence else {
            return max(0, 1 - elapsed / o.noEvidenceFade)
        }

        if elapsed <= o.window { return max(o.holdFloor, 1 - elapsed * o.holdSlope) }
        return max(0, exp(-o.decayRate * (elapsed - o.window)))
    }

    func reset() {
        lastEvidenceAt = 0
        hadApproachEvidence = false
    }
}
