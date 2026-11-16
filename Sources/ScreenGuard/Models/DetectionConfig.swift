import CoreGraphics
import Foundation

/// 检测算法全部可调参数的唯一来源。
///
/// 重构前这些数字散落在五个文件里，同一档阈值甚至写了两份，调参时极易改漏。
/// 现在按「采集 / 评分 / 状态机 / 遮挡 / 追踪 / 几何 / 姿态」分组集中，
/// 每项注明作用与量纲，算法模块只引用此处的语义常量，不再出现裸数字。
enum DetectionConfig {

    // MARK: - 采集

    /// 帧处理最小间隔（纳秒）。约 30fps，让 3 帧确认窗口压到 100ms 以内。
    static let frameIntervalNanos: UInt64 = 33_000_000

    /// 灵敏度三档对应的风险阈值（保守 / 标准 / 灵敏）。
    static let sensitivityLevels: [CGFloat] = [0.62, 0.48, 0.36]

    /// 当前灵敏度档位的风险阈值。
    static var threshold: CGFloat {
        let raw = UserDefaults.standard.integer(forKey: "sensitivity")
        return sensitivityLevels[min(max(raw, 0), sensitivityLevels.count - 1)]
    }

    /// 两次报警之间的最小间隔（纳秒）。用户设置低于下限时长时按下限处理。
    static var cooldownNanos: UInt64 {
        let seconds = max(UserDefaults.standard.integer(forKey: "cooldownSeconds"), 1)
        return UInt64(seconds) * 1_000_000_000
    }

    // MARK: - 评分

    /// 各信号权重，总和为 1。尺度增长主导，区域提供位置约束，其余弱辅助。
    /// direction 随 growth 开关一起启停（共用「正在靠近」一个用户开关）。
    struct Weights {
        static let growth: CGFloat = 0.62
        static let direction: CGFloat = 0.08
        static let gesture: CGFloat = 0.12
        static let zone: CGFloat = 0.18
    }

    /// 视觉置信度对风险的压制系数：risk × (floor + slope × confidence)。
    /// 保留下限是为了快速戳屏时置信度骤降仍不把有效动作压到阈值以下。
    static let confidenceFloor: CGFloat = 0.7
    static let confidenceSlope: CGFloat = 0.3

    /// 风险滑动平均窗口长度，抑制逐帧关键点抖动造成的阈值横跳。
    static let riskWindowSize = 3

    // MARK: - 尺度增长门控

    /// 判定「手正在靠近」所需的增长强度下限。
    static let growthGate: CGFloat = 0.22
    /// 连续满足增长门控的帧数下限（约 66ms）。
    static let growthFramesNeeded = 2

    /// 快速通道：强增长 + 进入危险区 + 高置信度时，单帧直接计入确认。
    struct FastApproach {
        static let growth: CGFloat = 0.55
        static let zone: CGFloat = 0.4
        static let confidence: CGFloat = 0.55
        /// 快速通道单帧等效的确认帧数。
        static let credit: Int = 2
    }

    // MARK: - 状态机

    /// 连续满足进入条件多少帧后锁定报警。
    static let enterFrames = 2
    /// 略低于阈值时的「观察」下限系数：介于其与阈值之间只衰减、不清零。
    static let observeFactor: CGFloat = 0.6
    /// 判定「手已停住」的增长上限。
    static let settledGrowth: CGFloat = 0.1
    /// 判定「风险消失」的阈值系数。
    static let riskGoneFactor: CGFloat = 0.35
    /// 判定「正在接近」意图的增长与方向下限。
    static let approachingGrowth: CGFloat = 0.2
    static let approachingDirection: CGFloat = 0.3

    /// 特征归一化：速度除以该值截断到 [0,1]（仅诊断展示，不参与评分）。
    static let velocityNormalizer: CGFloat = 0.45
    /// 姿态分：食指伸出与手掌张开的占比，两者加权和为 1。
    struct GestureScore {
        static let indexExtended: CGFloat = 0.65
        static let palmOpen: CGFloat = 0.35
    }

    /// 各退出条件成立多少帧后真正解锁。
    struct ExitFrames {
        /// 手停住：给较长时间，避免提醒一闪而过。
        static let settled = 20
        /// 遮挡证据耗尽。
        static let noEvidence = 6
        /// 风险回落。
        static let riskGone = 10
    }

    /// alert 最长保持帧数（约 3 秒）。仅作兜底：任何退出条件失效时强制恢复，
    /// 防止状态卡死阻断后续提醒；超时后一帧即恢复。
    static let maxAlertFrames = 90

    // MARK: - 遮挡保持

    /// 有接近证据时，风险在窗口内保持较高水平，之后指数衰减。
    struct Occlusion {
        static let window: TimeInterval = 0.5
        static let holdFloor: CGFloat = 0.65
        static let holdSlope: CGFloat = 0.35
        static let decayRate: Double = 3.0
        /// 无接近证据时的快速衰减时长（秒）。
        static let noEvidenceFade: TimeInterval = 0.25
        /// 风险低于此值时清除「曾有接近证据」的标记。
        static let evidenceClearRisk: CGFloat = 0.25
        /// 证据耗尽的保留系数，低于此值视为目标确实离开。
        static let exhausted: CGFloat = 0.25
    }

    // MARK: - 追踪

    /// 目标丢失后仍参与预测的最大帧数（约 0.27 秒）。
    static let maxMissedFrames = 8
    /// 尺度增长计算的历史窗口长度。
    static let scaleWindow = 8
    /// 置信度随遮挡时间指数衰减的系数。
    static let confidenceDecay: Double = 4.0

    /// 数据关联阈值：静止时收紧防误关联，高速时按速度放宽防断链。
    struct Matching {
        static let base: CGFloat = 0.30
        static let velocityFactor: CGFloat = 0.25
        static let velocityCap: CGFloat = 0.20
        /// 位移预测的时间上限（秒）。
        static let maxDeltaTime: TimeInterval = 0.1
        /// 判定「本帧仍有真实观测」的时间容差。
        static let observationTolerance: TimeInterval = 0.05
    }

    /// 速度/加速度的指数平滑系数，以及首帧直接采样的判定时长。
    struct Smoothing {
        static let velocity: CGFloat = 0.55
        static let acceleration: CGFloat = 0.3
        static let firstSampleDelta: TimeInterval = 0.1
        static let minimumDeltaTime: TimeInterval = 1.0 / 60.0
    }

    // MARK: - 尺度增长计算

    /// 手部面积增长的判定参数：排除关键点抖动造成的假性百分比增长，
    /// 只接受绝对增量与相对增幅都达标、且连续多帧单调变大的趋势。
    struct Growth {
        static let baselineFloor: CGFloat = 0.006
        static let minimumAbsoluteGain: CGFloat = 0.004
        static let minimumRelativeGain: CGFloat = 0.06
        static let stepFactor: CGFloat = 1.008
        static let minimumContinuity: CGFloat = 0.55
        static let normalizer: CGFloat = 0.8
        static let minimumHistory = 3
    }

    // MARK: - 几何

    /// 危险区起点（Vision 坐标 y，原点左下）。基于视觉经验的近似值，非相机标定。
    static let dangerZoneTop: CGFloat = 0.42
    /// 左右边缘接近动作的横向放宽系数。
    static let horizontalTolerance: CGFloat = 0.55

    struct Zone {
        static let verticalOffset: CGFloat = 0.12
        static let verticalSpan: CGFloat = 0.34
        static let horizontalCenter: CGFloat = 0.25
        static let horizontalSpan: CGFloat = 0.25
        static let horizontalWeight: CGFloat = 0.3
    }

    struct Direction {
        static let minimumSpeed: CGFloat = 0.02
        static let downwardSpan: CGFloat = 0.35
        static let lateralSpan: CGFloat = 0.30
        static let lateralWeight: CGFloat = 0.6
    }

    // MARK: - 姿态

    /// 手部关键点置信度下限与最少有效点数。
    static let jointConfidence: Float = 0.3
    static let minimumValidJoints = 6
    /// Vision 连续异常多少次后提示「识别暂时中断」。
    static let errorNoticeThreshold = 20

    struct Gesture {
        /// 食指显著长于其他指尖的比例，以及绝对长度下限。
        static let indexRatio: CGFloat = 1.12
        static let indexLength: CGFloat = 0.12
        /// 手掌张开时相邻 MCP 间距之和下限。
        static let palmSpread: CGFloat = 0.16
    }

    // MARK: - 诊断

    /// 快照记录的最近帧数（约 0.4 秒 @30fps）。
    /// 只用于事后对照「擦手持续高速」与「戳屏接近后停驻」，不参与任何评分或状态判定。
    enum Diagnostics {
        static let historyLength = 12
    }
}
