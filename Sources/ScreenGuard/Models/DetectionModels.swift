import CoreGraphics
import Foundation

/// 单个手部目标的连续追踪记录。所有坐标均为 Vision 归一化图像坐标（原点左下）。
struct HandTrack {
    let id: UUID
    var boundingBox: CGRect
    var wrist: CGPoint
    var palm: CGPoint
    var indexTip: CGPoint?
    var velocity: CGPoint
    var acceleration: CGPoint
    var confidence: Float
    var lastObservedAt: TimeInterval

    /// 连续未被观测到的帧数，用于遮挡预测
    var missedFrames: Int = 0

    /// 最近若干帧的手部包围盒面积（归一化坐标），用于判断尺度是否持续增长。
    /// 手由远及近时面积持续变大；张手/抬手只是一次性跳变，不会连续增长。
    var scaleHistory: [CGFloat] = []

    init(
        id: UUID = UUID(),
        boundingBox: CGRect,
        wrist: CGPoint,
        palm: CGPoint,
        indexTip: CGPoint?,
        velocity: CGPoint = .zero,
        acceleration: CGPoint = .zero,
        confidence: Float,
        lastObservedAt: TimeInterval
    ) {
        self.id = id
        self.boundingBox = boundingBox
        self.wrist = wrist
        self.palm = palm
        self.indexTip = indexTip
        self.velocity = velocity
        self.acceleration = acceleration
        self.confidence = confidence
        self.lastObservedAt = lastObservedAt
    }

    /// 用于与目标关联的代表点：优先手掌，其次手腕
    var anchor: CGPoint { palm }
}

/// 风险状态机的六个状态
enum DetectionState: String {
    case idle = "待机"
    case observing = "观察中"
    case approaching = "接近中"
    case occluded = "目标遮挡"
    case alert = "已提醒"
    case recovery = "恢复中"
}

/// 单次风险评估结果。
/// visualConfidence 与 intentConfidence 刻意分离：看得清不等于有接触意图。
struct RiskAssessment {
    let risk: CGFloat
    let state: DetectionState
    let visualConfidence: CGFloat
    let intentConfidence: CGFloat
    let features: FeatureSet
    /// 尺度增长门控是否打开——进入 alert 的必要条件
    let approachGateOpen: Bool
    /// 连续观测到尺度增长的帧数
    let sustainedGrowthFrames: Int

    static let empty = RiskAssessment(
        risk: 0,
        state: .idle,
        visualConfidence: 0,
        intentConfidence: 0,
        features: .empty,
        approachGateOpen: false,
        sustainedGrowthFrames: 0
    )
}

/// 参与风险评分的归一化特征。
/// growth（尺度持续增长）是核心前提：只有手正在变大/靠近才应报警。
/// velocity 仍会采集并写入诊断 JSON，但不再参与评分——关键点差分在 30fps 下抖动过大。
struct FeatureSet {
    /// 运动方向与目标屏幕区域的匹配程度（弱辅助，避免把抖动当成意图）
    var direction: CGFloat = 0
    /// 接近运动的速度（仅诊断展示，不参与评分）
    var velocity: CGFloat = 0
    /// 手部姿态与触碰动作的匹配程度（辅助）
    var gesture: CGFloat = 0
    /// 与屏幕危险区域的空间关系
    var zone: CGFloat = 0
    /// 手部尺度的持续增长趋势：越大表示越靠近，报警的必要前提
    var growth: CGFloat = 0

    static let empty = FeatureSet()
}

/// 三路可开关的信号。关掉某一路后，它的权重按比例分给其余开启项。
/// 开关状态存 UserDefaults，菜单里点击即时生效。
struct SignalSettings {
    /// 正在靠近（尺度增长 + 运动方向）。关闭后不再要求手持续变大，误报会上升。
    var growth: Bool
    /// 食指伸出 / 张开手掌
    var gesture: Bool
    /// 是否进入画面危险区
    var zone: Bool

    static var current: SignalSettings {
        let defaults = UserDefaults.standard
        return SignalSettings(
            growth: defaults.object(forKey: "signalGrowthEnabled") as? Bool ?? true,
            gesture: defaults.object(forKey: "signalGestureEnabled") as? Bool ?? true,
            zone: defaults.object(forKey: "signalZoneEnabled") as? Bool ?? true
        )
    }
}

// MARK: - CGPoint 便捷运算

extension CGPoint {
    static func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
        CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
    }

    static func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
        CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }

    static func * (point: CGPoint, scalar: CGFloat) -> CGPoint {
        CGPoint(x: point.x * scalar, y: point.y * scalar)
    }

    var length: CGFloat { hypot(x, y) }
}
