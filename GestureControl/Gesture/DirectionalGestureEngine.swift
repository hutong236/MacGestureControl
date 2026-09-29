import Foundation

/// 纯几何轨迹识别器：不依赖网络或第三方 AI。
///
/// V1.2 增加“单次笔画 + 回程抑制”：一次方向手势触发后，原路收手不会再被识别成
/// 反方向动作。只有手势被明确释放/重置，或检测到回程后停稳，才重新武装。
final class DirectionalGestureEngine {
    struct Configuration: Equatable {
        var minimumDistance: Double = 0.18
        var minimumVelocity: Double = 0.36
        var dominanceRatio: Double = 1.35
        var maximumGestureDuration: TimeInterval = 0.85
        var minimumGestureDuration: TimeInterval = 0.10
        var historyDuration: TimeInterval = 0.95
        var cooldown: TimeInterval = 0.85
        var minimumConfidence: Double = 0.45
        var returnSuppressionEnabled: Bool = true
        var returnDeltaThreshold: Double = 0.0025
        var returnNeutralSpeed: Double = 0.055
        var returnNeutralHold: TimeInterval = 0.085
    }

    private let lock = NSLock()
    private var samples: [HandSample] = []
    private var lastTriggerTime: TimeInterval = -.infinity
    private var configuration = Configuration()

    // V1.2 return-path latch.
    private var blockedDirection: GestureDirection?
    private var returnMotionSeen = false
    private var neutralSince: TimeInterval?
    private var lastBlockedSample: HandSample?

    var onGesture: ((GestureDirection) -> Void)?

    func update(configuration newConfiguration: Configuration) {
        lock.lock()
        configuration = newConfiguration
        lock.unlock()
    }

    func reset() {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        blockedDirection = nil
        returnMotionSeen = false
        neutralSince = nil
        lastBlockedSample = nil
        lock.unlock()
    }

    func process(_ sample: HandSample) {
        var detected: GestureDirection?

        lock.lock()
        defer { lock.unlock() }

        guard sample.confidence >= configuration.minimumConfidence else {
            // Losing the hand/pose is equivalent to lifting from a real trackpad: fully re-arm.
            samples.removeAll(keepingCapacity: true)
            blockedDirection = nil
            returnMotionSeen = false
            neutralSince = nil
            lastBlockedSample = nil
            return
        }

        if configuration.returnSuppressionEnabled,
           let blocked = blockedDirection {
            processBlockedReturn(sample, triggeredDirection: blocked)
            return
        }

        samples.append(sample)
        let cutoff = sample.timestamp - configuration.historyDuration
        samples.removeAll { $0.timestamp < cutoff }

        guard sample.timestamp - lastTriggerTime >= configuration.cooldown else {
            return
        }

        guard let start = bestStartSample(relativeTo: sample) else { return }

        let dt = sample.timestamp - start.timestamp
        guard dt >= configuration.minimumGestureDuration,
              dt <= configuration.maximumGestureDuration else { return }

        let dx = sample.x - start.x
        let dy = sample.y - start.y
        let absX = abs(dx)
        let absY = abs(dy)
        let distance = hypot(dx, dy)
        let velocity = distance / max(dt, 0.001)

        guard distance >= configuration.minimumDistance,
              velocity >= configuration.minimumVelocity else { return }

        if absX >= configuration.minimumDistance,
           absX > absY * configuration.dominanceRatio {
            detected = dx > 0 ? .right : .left
        } else if absY >= configuration.minimumDistance,
                  absY > absX * configuration.dominanceRatio {
            detected = dy > 0 ? .up : .down
        }

        if let detected {
            lastTriggerTime = sample.timestamp
            samples.removeAll(keepingCapacity: true)
            if configuration.returnSuppressionEnabled {
                blockedDirection = detected
                returnMotionSeen = false
                neutralSince = nil
                lastBlockedSample = sample
            }
            DispatchQueue.main.async { [weak self] in
                self?.onGesture?(detected)
            }
        }
    }

    private func processBlockedReturn(_ sample: HandSample, triggeredDirection: GestureDirection) {
        guard let previous = lastBlockedSample else {
            lastBlockedSample = sample
            return
        }
        let dt = sample.timestamp - previous.timestamp
        lastBlockedSample = sample
        guard dt > 0.008, dt < 0.25 else { return }

        let dx = sample.x - previous.x
        let dy = sample.y - previous.y
        let speed = hypot(dx, dy) / dt
        let threshold = max(configuration.returnDeltaThreshold, 0.0015)

        let returning: Bool
        switch triggeredDirection {
        case .right: returning = dx < -threshold
        case .left: returning = dx > threshold
        case .up: returning = dy < -threshold
        case .down: returning = dy > threshold
        }

        if returning {
            returnMotionSeen = true
            neutralSince = nil
            return
        }

        // Once a return/recenter motion has happened, wait only for a short stable pause. The new
        // stroke then starts from the current hand position and may go in either direction.
        if returnMotionSeen, speed <= max(configuration.returnNeutralSpeed, 0.025) {
            if neutralSince == nil { neutralSince = sample.timestamp }
            if let neutralSince,
               sample.timestamp - neutralSince >= max(configuration.returnNeutralHold, 0.05) {
                blockedDirection = nil
                returnMotionSeen = false
                self.neutralSince = nil
                lastBlockedSample = nil
                samples.removeAll(keepingCapacity: true)
                samples.append(sample)
            }
        } else if speed > configuration.returnNeutralSpeed {
            neutralSince = nil
        }
    }

    /// 不直接使用 history 中最老的点。选取 0.12~0.85 秒范围内距离当前点最远的候选起点，
    /// 对轻微手抖更稳定，也能兼容快挥和慢挥。
    private func bestStartSample(relativeTo current: HandSample) -> HandSample? {
        let minAge = configuration.minimumGestureDuration
        let maxAge = configuration.maximumGestureDuration

        let candidates = samples.filter {
            let age = current.timestamp - $0.timestamp
            return age >= minAge && age <= maxAge
        }

        return candidates.max { lhs, rhs in
            let lhsDistance = hypot(current.x - lhs.x, current.y - lhs.y)
            let rhsDistance = hypot(current.x - rhs.x, current.y - rhs.y)
            return lhsDistance < rhsDistance
        }
    }
}
