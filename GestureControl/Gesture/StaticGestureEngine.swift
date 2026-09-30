import Foundation

/// 用户自定义静态手势识别器。
/// 只有同一组手指伸/屈状态持续稳定一段时间才触发，触发后必须先改变手势才能再次触发。
final class StaticGestureEngine {
    private let lock = NSLock()
    private var gestures: [CustomStaticGesture] = []
    private var currentPattern: FingerPattern?
    private var stableSince: TimeInterval = 0
    private var blockedPattern: FingerPattern?
    private let minimumHoldDuration: TimeInterval = 0.55
    private let minimumConfidence = 0.45

    var onGesture: ((CustomStaticGesture) -> Void)?

    func update(gestures newGestures: [CustomStaticGesture]) {
        lock.lock()
        gestures = newGestures
        lock.unlock()
    }

    func reset() {
        lock.lock()
        currentPattern = nil
        blockedPattern = nil
        stableSince = 0
        lock.unlock()
    }

    func process(pattern: FingerPattern?, timestamp: TimeInterval, confidence: Double) {
        var detected: CustomStaticGesture?

        lock.lock()
        defer { lock.unlock() }

        guard confidence >= minimumConfidence, let pattern else {
            currentPattern = nil
            stableSince = 0
            return
        }

        if currentPattern != pattern {
            currentPattern = pattern
            stableSince = timestamp
            if blockedPattern != pattern {
                blockedPattern = nil
            }
            return
        }

        guard blockedPattern != pattern,
              timestamp - stableSince >= minimumHoldDuration else {
            return
        }

        if let gesture = gestures.first(where: { $0.enabled && $0.pattern == pattern }) {
            blockedPattern = pattern
            detected = gesture
        }

        if let detected {
            DispatchQueue.main.async { [weak self] in
                self?.onGesture?(detected)
            }
        }
    }
}
