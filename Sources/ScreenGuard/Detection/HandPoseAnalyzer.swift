import CoreGraphics
import Vision

/// 从 Vision 手部关键点提取姿态与观测数据。
enum HandPoseAnalyzer {
    typealias Joint = VNHumanHandPoseObservation.JointName

    static let minimumConfidence: Float = 0.3

    /// 从手部观测中提取用于追踪与评分的特征
    static func analyze(_ observation: VNHumanHandPoseObservation) -> (
        observation: HandObservation,
        indexExtended: Bool,
        palmOpen: Bool
    )? {
        let points = (try? observation.recognizedPoints(.all)) ?? [:]
        let valid = points.filter { $0.value.confidence > minimumConfidence }
        guard valid.count >= 6 else { return nil }

        func point(_ joint: Joint) -> CGPoint? {
            guard let p = points[joint], p.confidence > minimumConfidence else { return nil }
            return CGPoint(x: p.location.x, y: p.location.y)
        }

        guard let wrist = point(.wrist),
              let indexTip = point(.indexTip),
              let middleMCP = point(.middleMCP),
              let ringMCP = point(.ringMCP),
              let littleMCP = point(.littleMCP) else { return nil }

        let palm = CGPoint(
            x: (middleMCP.x + ringMCP.x + littleMCP.x) / 3,
            y: (middleMCP.y + ringMCP.y + littleMCP.y) / 3
        )

        let xs = valid.values.map { $0.location.x }
        let ys = valid.values.map { $0.location.y }
        let box = CGRect(
            x: xs.min() ?? 0,
            y: ys.min() ?? 0,
            width: (xs.max() ?? 0) - (xs.min() ?? 0),
            height: (ys.max() ?? 0) - (ys.min() ?? 0)
        )

        // 食指伸出：食指长度显著超过其他指尖到手腕的平均距离
        let indexLength = hypot(indexTip.x - wrist.x, indexTip.y - wrist.y)
        let otherTips: [Joint] = [.middleTip, .ringTip, .littleTip]
        let otherLengths = otherTips.compactMap { joint -> CGFloat? in
            guard let p = point(joint) else { return nil }
            return hypot(p.x - wrist.x, p.y - wrist.y)
        }
        let indexExtended: Bool
        if otherLengths.isEmpty {
            indexExtended = indexLength > 0.12
        } else {
            let average = otherLengths.reduce(0, +) / CGFloat(otherLengths.count)
            indexExtended = indexLength > average * 1.12 && indexLength > 0.12
        }

        // 手掌张开：MCP 三点间距较大
        let spread1 = hypot(middleMCP.x - ringMCP.x, middleMCP.y - ringMCP.y)
        let spread2 = hypot(ringMCP.x - littleMCP.x, ringMCP.y - littleMCP.y)
        let palmOpen = (spread1 + spread2) > 0.16

        let handObservation = HandObservation(
            boundingBox: box,
            wrist: wrist,
            palm: palm,
            indexTip: indexTip,
            confidence: valid.values.map { $0.confidence }.reduce(0, +) / Float(valid.count)
        )

        return (handObservation, indexExtended, palmOpen)
    }
}
