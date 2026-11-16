import CoreGraphics
import Vision

/// 从人体姿态中提取上肢伸展特征。
/// 当手指或手掌被遮挡时，肘部与肩部仍可能提供接近证据。
enum BodyPoseAnalyzer {
    typealias Joint = VNHumanBodyPoseObservation.JointName

    /// 上肢伸展评分 [0,1]：值越大表示手臂越朝向画面上方/前方伸展
    static func armExtension(from observation: VNHumanBodyPoseObservation) -> CGFloat {
        let points = (try? observation.recognizedPoints(.all)) ?? [:]

        func point(_ joint: Joint) -> CGPoint? {
            guard let p = points[joint], p.confidence > 0.3 else { return nil }
            return CGPoint(x: p.location.x, y: p.location.y)
        }

        // 优先左右两侧中置信度更高、伸展更明显的一只手臂
        let candidates: [(Joint, Joint, Joint)] = [
            (.rightShoulder, .rightElbow, .rightWrist),
            (.leftShoulder, .leftElbow, .leftWrist)
        ]

        var best: CGFloat = 0
        for (shoulderJoint, elbowJoint, wristJoint) in candidates {
            guard let shoulder = point(shoulderJoint),
                  let elbow = point(elbowJoint),
                  let wrist = point(wristJoint) else { continue }

            let upperArm = hypot(elbow.x - shoulder.x, elbow.y - shoulder.y)
            let forearm = hypot(wrist.x - elbow.x, wrist.y - elbow.y)
            guard upperArm > 0.02, forearm > 0.02 else { continue }

            // 手臂伸直程度：肩—肘—腕夹角接近 180° 时伸展度最高
            let v1 = CGPoint(x: elbow.x - shoulder.x, y: elbow.y - shoulder.y)
            let v2 = CGPoint(x: wrist.x - elbow.x, y: wrist.y - elbow.y)
            let dot = (v1.x * v2.x + v1.y * v2.y) / (upperArm * forearm)
            let straightness = min(max((dot + 1) / 2, 0), 1)

            // 手腕高于肩部（Vision y 向上）视为向屏幕方向抬升
            let elevation = min(max((wrist.y - shoulder.y) / 0.35, 0), 1)

            let score = straightness * 0.6 + elevation * 0.4
            best = max(best, score)
        }
        return best
    }
}
