import CoreGraphics
import Foundation

/// 屏幕危险区域的归一化坐标模型。
/// 基于视觉经验的近似区域，不是精确的三维相机外参标定；参数集中在 DetectionConfig。
enum ScreenGeometry {

    /// 点进入危险区的程度 [0,1]。y 小于危险区起点视为进入接近区。
    static func zoneScore(for point: CGPoint) -> CGFloat {
        let z = DetectionConfig.Zone.self
        let vertical = min(max(
            (DetectionConfig.dangerZoneTop + z.verticalOffset - point.y) / z.verticalSpan, 0), 1)
        // 画面左右边缘的接近动作也算高风险
        let horizontal = min(max(
            (abs(point.x - 0.5) - z.horizontalCenter) / z.horizontalSpan, 0), 1)
        return min(max(vertical + horizontal * DetectionConfig.horizontalTolerance * z.horizontalWeight, 0), 1)
    }

    /// 运动方向是否朝向屏幕区域：向下运动，或朝画面边缘的斜向运动。
    static func directionScore(velocity: CGPoint, at point: CGPoint) -> CGFloat {
        let d = DetectionConfig.Direction.self
        guard velocity.length > d.minimumSpeed else { return 0 }

        // 向下（y 减小）为主
        let downward = min(max(-velocity.y / d.downwardSpan, 0), 1)
        // 侧向接近：朝最近的画面边缘移动
        let towardEdge = point.x < 0.5 ? -velocity.x : velocity.x
        let lateral = min(max(towardEdge / d.lateralSpan, 0), 1) * d.lateralWeight
        return min(max(downward + lateral, 0), 1)
    }
}
