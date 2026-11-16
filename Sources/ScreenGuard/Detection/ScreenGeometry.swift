import CoreGraphics
import Foundation

/// 屏幕危险区域的归一化坐标模型。
/// 注意：这是基于视觉经验的近似区域，不是精确的三维相机外参标定。
/// 用户可通过校准调整危险区的高度起点，以适配不同坐姿与摄像头视角。
struct ScreenGeometry {
    /// 危险区起点（Vision 坐标 y，原点左下）。y 小于此值视为进入接近区
    var dangerZoneTop: CGFloat

    /// 横向放宽系数：左右方向接近时适当扩大危险区
    var horizontalTolerance: CGFloat = 0.55

    init(dangerZoneTop: CGFloat = 0.42) {
        self.dangerZoneTop = dangerZoneTop
    }

    /// 点进入危险区的程度 [0,1]
    func zoneScore(for point: CGPoint) -> CGFloat {
        let vertical = min(max((dangerZoneTop + 0.12 - point.y) / 0.34, 0), 1)
        // 画面左右边缘的接近动作也算高风险
        let horizontal = min(max((abs(point.x - 0.5) - 0.25) / 0.25, 0), 1)
        return min(max(vertical + horizontal * horizontalTolerance * 0.3, 0), 1)
    }

    /// 运动方向是否朝向屏幕区域：向下运动，或朝画面边缘的斜向运动
    func directionScore(velocity: CGPoint, at point: CGPoint) -> CGFloat {
        let speed = velocity.length
        guard speed > 0.02 else { return 0 }

        // 向下（y 减小）为主score
        let downward = min(max(-velocity.y / 0.35, 0), 1)

        // 侧向接近：朝最近的画面边缘移动
        let towardEdge = point.x < 0.5 ? -velocity.x : velocity.x
        let lateral = min(max(towardEdge / 0.30, 0), 1) * 0.6

        return min(max(downward + lateral, 0), 1)
    }

    mutating func load() {
        if let saved = UserDefaults.standard.object(forKey: "dangerZoneTop") as? Double {
            dangerZoneTop = CGFloat(saved)
        }
    }

    func save() {
        UserDefaults.standard.set(Double(dangerZoneTop), forKey: "dangerZoneTop")
    }
}
