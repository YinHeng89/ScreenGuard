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

/// 第二层：多目标跨帧关联与轨迹平滑。
/// 核心原则：丢失关键点不等于丢失目标。
final class HandTrackingEngine {
    private(set) var tracks: [HandTrack] = []

    func clear() { tracks.removeAll() }

    /// 用本帧观测更新轨迹，返回所有活跃轨迹（含遮挡预测中的）。
    func update(with observations: [HandObservation], at time: TimeInterval) -> [HandTrack] {
        var remaining = observations
        var updated: [HandTrack] = []

        // 1. 已有轨迹优先匹配最近的观测
        for var track in tracks {
            if let matchIndex = nearestObservation(for: track, in: remaining, at: time) {
                let observation = remaining.remove(at: matchIndex)
                track = apply(observation: observation, to: track, at: time)
            } else {
                // 未匹配到观测，转入遮挡预测（不写尺度历史，避免预测值污染趋势）
                track.missedFrames += 1
                if track.missedFrames <= DetectionConfig.maxMissedFrames {
                    track = predict(track: track, elapsed: time - track.lastObservedAt)
                }
            }

            if track.missedFrames <= DetectionConfig.maxMissedFrames {
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

    /// 本帧是否仍有真实观测（而非纯预测）。
    func hasLiveObservation(at time: TimeInterval, tolerance: TimeInterval) -> Bool {
        tracks.contains { $0.missedFrames == 0 && time - $0.lastObservedAt <= tolerance }
    }

    /// 置信度随遮挡时间指数衰减：C(Δt) = C₀·e^(-λΔt)。
    func confidence(for track: HandTrack, at time: TimeInterval) -> CGFloat {
        guard track.missedFrames > 0 else { return CGFloat(track.confidence) }
        let elapsed = time - track.lastObservedAt
        return CGFloat(track.confidence) * exp(-DetectionConfig.confidenceDecay * elapsed)
    }

    /// 尺度增长强度 [0,1]：手部包围盒面积是否连续多帧变大。
    ///
    /// 区分「手正在靠近」与「抬手/张手一次跳变」的关键：
    /// 靠近时面积在连续多帧里单调增长；抬手停住或张开手掌只是一次跳变后稳定，
    /// 连续性很低；手远离则为负增长。两种情况都返回 0。
    func scaleGrowth(for track: HandTrack) -> CGFloat {
        let history = track.scaleHistory
        let g = DetectionConfig.Growth.self
        guard history.count >= g.minimumHistory,
              let first = history.first,
              let last = history.last else { return 0 }

        let baseline = max(first, g.baselineFloor)
        // 绝对增量门槛排除关键点抖动造成的假性百分比增长
        guard last - baseline >= g.minimumAbsoluteGain else { return 0 }
        let relative = (last - baseline) / baseline
        guard relative > g.minimumRelativeGain else { return 0 }

        var growthSteps = 0
        for i in 1..<history.count where history[i] > history[i - 1] * g.stepFactor {
            growthSteps += 1
        }
        let continuity = CGFloat(growthSteps) / CGFloat(history.count - 1)
        guard continuity >= g.minimumContinuity else { return 0 }

        return min(max(relative / g.normalizer, 0), 1) * continuity
    }

    // MARK: - 私有

    private static func area(of rect: CGRect) -> CGFloat {
        max(rect.width * rect.height, 0)
    }

    /// 关联时用速度外推的预测位置作锚点，而非上一帧的静止位置。
    /// 快速移动时位移大，用旧位置匹配会超过阈值被误判为跟丢，进而新建轨迹、
    /// 速度归零——越快越检测不到。预测锚点朝运动方向匹配可解此问题。
    private func nearestObservation(
        for track: HandTrack,
        in observations: [HandObservation],
        at time: TimeInterval
    ) -> Int? {
        let m = DetectionConfig.Matching.self
        let dt = min(max(time - track.lastObservedAt, 0), m.maxDeltaTime)
        let predicted = track.palm + track.velocity * CGFloat(dt)
        // 阈值按速度适度放宽：静止时收紧防误关联，高速时放宽防断链
        let threshold: CGFloat = m.base + min(track.velocity.length * m.velocityFactor, m.velocityCap)
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
        let s = DetectionConfig.Smoothing.self
        let dt = max(time - track.lastObservedAt, s.minimumDeltaTime)
        let newVelocity = (observation.palm - track.palm) * (1.0 / dt)
        let newAcceleration = (newVelocity - track.velocity) * (1.0 / dt)

        // 首帧直接用真实速度，否则快速动作要等数帧速度才爬起来、触发时早已错过。
        let isFirstSample = time - track.lastObservedAt > s.firstSampleDelta
        let alpha: CGFloat = isFirstSample ? 1.0 : s.velocity
        let smoothedVelocity = track.velocity * (1 - alpha) + newVelocity * alpha

        var result = track
        result.boundingBox = observation.boundingBox
        result.wrist = observation.wrist
        result.palm = observation.palm
        result.indexTip = observation.indexTip
        result.velocity = smoothedVelocity
        result.acceleration = newAcceleration * s.acceleration
            + track.acceleration * (1 - s.acceleration)
        result.confidence = observation.confidence
        result.lastObservedAt = time
        result.missedFrames = 0

        result.scaleHistory.append(Self.area(of: observation.boundingBox))
        if result.scaleHistory.count > DetectionConfig.scaleWindow {
            result.scaleHistory.removeFirst()
        }
        return result
    }

    /// 短时匀速 + 部分加速度预测，不更新尺度历史，避免预测面积伪造增长趋势。
    private func predict(track: HandTrack, elapsed: TimeInterval) -> HandTrack {
        let dt = CGFloat(elapsed)
        var result = track
        result.palm = track.palm + track.velocity * dt + track.acceleration * (0.5 * dt * dt)
        result.wrist = track.wrist + track.velocity * dt
        if let tip = track.indexTip { result.indexTip = tip + track.velocity * dt }
        result.boundingBox = track.boundingBox.offsetBy(
            dx: track.velocity.x * dt,
            dy: track.velocity.y * dt
        )
        return result
    }
}
