import CoreGraphics
import Foundation

/// 观测到的一帧手部目标
struct HandObservation {
    let boundingBox: CGRect
    let wrist: CGPoint
    let palm: CGPoint
    let indexTip: CGPoint?
    let confidence: Float
}

/// 多目标跨帧关联与轨迹平滑。
/// 核心原则：丢失关键点不等于丢失目标。
final class HandTrackingEngine {
    private(set) var tracks: [HandTrack] = []
    /// 短时遮挡预测最多保留的帧数（约 0.27 秒 @30fps）
    var maxMissedFrames = 8
    /// 尺度增长计算所用的历史窗口长度（@30fps 约 0.27 秒）
    private let scaleWindow = 8

    func clear() { tracks.removeAll() }

    /// 用本帧观测更新轨迹，返回所有活跃轨迹（含遮挡预测中的）
    func update(with observations: [HandObservation], at time: TimeInterval) -> [HandTrack] {
        var remaining = observations
        var updated: [HandTrack] = []

        // 1. 已有轨迹优先匹配最近的观测
        for var track in tracks {
            if let matchIndex = nearestObservation(for: track, in: remaining, at: time) {
                let observation = remaining.remove(at: matchIndex)
                track = apply(observation: observation, to: track, at: time)
            } else {
                // 未匹配到观测，转入遮挡预测（不写入尺度历史，避免预测值污染趋势）
                track.missedFrames += 1
                if track.missedFrames <= maxMissedFrames {
                    track = predict(track: track, elapsed: time - track.lastObservedAt)
                }
            }

            if track.missedFrames <= maxMissedFrames {
                updated.append(track)
            }
        }

        // 2. 剩余观测创建新轨迹
        for observation in remaining {
            var track = HandTrack(
                boundingBox: observation.boundingBox,
                wrist: observation.wrist,
                palm: observation.palm,
                indexTip: observation.indexTip,
                confidence: observation.confidence,
                lastObservedAt: time
            )
            track.scaleHistory = [Self.area(of: observation.boundingBox)]
            updated.append(track)
        }

        tracks = updated
        return updated
    }

    /// 本帧是否仍有真实观测（而非纯预测）
    func hasLiveObservation(at time: TimeInterval, tolerance: TimeInterval = 0.05) -> Bool {
        tracks.contains { $0.missedFrames == 0 && time - $0.lastObservedAt <= tolerance }
    }

    /// 置信度随遮挡时间指数衰减：C(Δt) = C₀·e^(-λΔt)
    func confidence(for track: HandTrack, at time: TimeInterval) -> CGFloat {
        if track.missedFrames == 0 {
            return CGFloat(track.confidence)
        }
        let elapsed = time - track.lastObservedAt
        let lambda = 4.0
        return CGFloat(track.confidence) * exp(-lambda * elapsed)
    }

    /// 尺度增长强度 [0,1]：手部包围盒面积是否「连续多帧」变大。
    ///
    /// 这是区分「手正在靠近屏幕」与「抬手/张手一次跳变」的关键：
    /// - 靠近：面积在连续多帧里单调增长，continuity 接近 1
    /// - 抬手停住 / 张开手掌：面积一次跳变后稳定，continuity 很低 → 返回 0
    /// - 手远离：面积为负增长 → 返回 0
    func scaleGrowth(for track: HandTrack) -> CGFloat {
        let history = track.scaleHistory
        guard history.count >= 3,
              let first = history.first,
              let last = history.last else { return 0 }

        let baseline = max(first, 0.006)
        // 绝对增量门槛：排除关键点抖动造成的「百分比增长」
        guard last - baseline >= 0.004 else { return 0 }
        let relative = (last - baseline) / baseline
        guard relative > 0.06 else { return 0 }

        // 每步增长门槛与连续性比例原本偏严（1.2% / 65%）：快速戳屏时关键点
        // 抖动会让个别帧面积回落， continuity 掉破门槛导致漏报。温和放宽到
        // 0.8% / 55%，但保留上面的「绝对增量 + 相对增长」双门槛——抬手/张手
        // 的一次性跳变 continuity 仍很低，不会误报。
        var growthSteps = 0
        for i in 1..<history.count {
            if history[i] > history[i - 1] * 1.008 { growthSteps += 1 }
        }
        let continuity = CGFloat(growthSteps) / CGFloat(history.count - 1)
        guard continuity >= 0.55 else { return 0 }

        return min(max(relative / 0.8, 0), 1) * continuity
    }

    // MARK: - 私有

    private static func area(of rect: CGRect) -> CGFloat {
        max(rect.width * rect.height, 0)
    }

    /// 关联时用速度外推的预测位置作锚点，而非上一帧的静止位置。
    /// 快速移动时位移大，若仍用旧位置匹配会超过阈值被误判为跟丢，
    /// 进而新建轨迹、速度归零——越快越检测不到。预测锚点朝运动方向匹配可解此问题。
    private func nearestObservation(
        for track: HandTrack,
        in observations: [HandObservation],
        at time: TimeInterval
    ) -> Int? {
        let dt = min(max(time - track.lastObservedAt, 0), 0.1)
        let predicted = track.palm + track.velocity * CGFloat(dt)
        // 阈值按速度适度放宽：静止时收紧防误关联，高速时放宽防断链
        let threshold: CGFloat = 0.30 + min(track.velocity.length * 0.25, 0.20)
        var bestIndex: Int?
        var bestDistance: CGFloat = threshold

        for (index, observation) in observations.enumerated() {
            let distance = hypot(
                observation.palm.x - predicted.x,
                observation.palm.y - predicted.y
            )
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex
    }

    private func apply(
        observation: HandObservation,
        to track: HandTrack,
        at time: TimeInterval
    ) -> HandTrack {
        let dt = max(time - track.lastObservedAt, 1.0 / 60.0)
        let newVelocity = (observation.palm - track.palm) * (1.0 / dt)
        let newAcceleration = (newVelocity - track.velocity) * (1.0 / dt)

        // 指数平滑抑制抖动；但首帧（刚新建的轨迹）直接用真实速度，
        // 否则快速动作要等好几帧速度才爬起来，触发时早已错过
        let isFirstSample = time - track.lastObservedAt > 0.1
        let alpha: CGFloat = isFirstSample ? 1.0 : 0.55
        let smoothedVelocity = track.velocity * (1 - alpha) + newVelocity * alpha

        var result = track
        result.boundingBox = observation.boundingBox
        result.wrist = observation.wrist
        result.palm = observation.palm
        result.indexTip = observation.indexTip
        result.velocity = smoothedVelocity
        result.acceleration = newAcceleration * 0.3 + track.acceleration * 0.7
        result.confidence = observation.confidence
        result.lastObservedAt = time
        result.missedFrames = 0

        // 累积尺度历史，仅保留最近窗口
        result.scaleHistory.append(Self.area(of: observation.boundingBox))
        if result.scaleHistory.count > scaleWindow {
            result.scaleHistory.removeFirst()
        }
        return result
    }

    /// 短时匀速 + 部分加速度预测（不更新尺度历史，避免预测面积伪造增长趋势）
    private func predict(track: HandTrack, elapsed: TimeInterval) -> HandTrack {
        let dt = CGFloat(elapsed)
        var result = track
        result.palm = track.palm + track.velocity * dt + track.acceleration * (0.5 * dt * dt)
        result.wrist = track.wrist + track.velocity * dt
        if let tip = track.indexTip {
            result.indexTip = tip + track.velocity * dt
        }
        result.boundingBox = track.boundingBox.offsetBy(
            dx: track.velocity.x * dt,
            dy: track.velocity.y * dt
        )
        return result
    }
}
