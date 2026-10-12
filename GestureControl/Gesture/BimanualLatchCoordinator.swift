import Foundation

/// Pure, camera-frame-driven left-hand modifier state machine.
/// All timestamps are monotonic frame timestamps; actions are snapshots from the moment Hold begins.
struct LeftHoldGestureStateMachine {
    enum Transition: Equatable {
        case none
        case latch(LatchedAction)
        case release
    }

    private let leftHoldDuration: TimeInterval = 0.30
    private let leftReleaseDebounce: TimeInterval = 0.08
    private let leftMissingReleaseDelay: TimeInterval = 0.25

    private(set) var state: LeftHoldState = .idle
    private(set) var isArmed = false
    private var candidateSince: TimeInterval?
    private var candidateAction: LatchedAction?
    private var releaseSince: TimeInterval?
    private var missingSince: TimeInterval?
    private var previousTimestamp: TimeInterval?

    var pendingAction: LatchedAction? { candidateAction }

    var isEngaged: Bool {
        switch state {
        case .idle: return false
        case .candidate, .latched: return true
        }
    }

    mutating func reset() {
        state = .idle
        isArmed = false
        candidateSince = nil
        candidateAction = nil
        releaseSince = nil
        missingSince = nil
        previousTimestamp = nil
    }

    mutating func advance(
        leftPinchRatio ratio: Double?,
        timestamp: TimeInterval,
        latchableAction: LatchedAction?
    ) -> Transition {
        guard timestamp.isFinite else { return .none }
        if let previousTimestamp, timestamp < previousTimestamp { return .none }
        previousTimestamp = timestamp

        guard let ratio, ratio.isFinite else {
            return handleMissing(at: timestamp)
        }

        if let missingSince {
            // A short tracking dropout must not count toward an uninterrupted 300 ms Hold.
            if case .candidate = state, let candidateSince {
                self.candidateSince = candidateSince + max(0, timestamp - missingSince)
            }
            releaseSince = nil
        }
        missingSince = nil

        if ratio >= 0.58 { isArmed = true }

        switch state {
        case .idle:
            guard isArmed, ratio <= 0.32, let action = latchableAction else { return .none }
            candidateSince = timestamp
            candidateAction = action
            state = .candidate(progress: 0)
            return .none

        case .candidate:
            if ratio >= 0.48 {
                reset()
                isArmed = ratio >= 0.58
                return .none
            }
            guard let candidateSince, let candidateAction else {
                reset()
                return .none
            }
            let elapsed = max(0, timestamp - candidateSince)
            let progress = min(elapsed / leftHoldDuration, 1)
            if progress < 1 {
                state = .candidate(progress: progress)
                return .none
            }
            state = .latched(candidateAction)
            isArmed = false
            self.candidateSince = nil
            self.candidateAction = nil
            return .latch(candidateAction)

        case .latched:
            if ratio >= 0.48 {
                if releaseSince == nil { releaseSince = timestamp }
                if let releaseSince, timestamp - releaseSince >= leftReleaseDebounce {
                    reset()
                    isArmed = ratio >= 0.58
                    return .release
                }
            } else {
                releaseSince = nil
            }
            return .none
        }
    }

    private mutating func handleMissing(at timestamp: TimeInterval) -> Transition {
        guard isEngaged else {
            isArmed = false
            missingSince = nil
            return .none
        }
        if missingSince == nil { missingSince = timestamp }
        guard let missingSince, timestamp - missingSince >= leftMissingReleaseDelay else {
            return .none
        }
        let wasLatched: Bool
        if case .latched = state { wasLatched = true } else { wasLatched = false }
        reset()
        return wasLatched ? .release : .none
    }
}

/// Owns the latched continuous output only. Gesture recognition and Hold timing live elsewhere.
final class BimanualLatchCoordinator {
    var onScrollDelta: ((Double, Double) -> Void)?
    var onLeftButton: ((Bool) -> Void)?
    var onZoomStep: ((Int) -> Void)?
    var onStateChanged: ((LatchedAction?) -> Void)?

    private let lock = NSLock()
    private let outputQueue = DispatchQueue(label: "com.hutong.GestureControl.bimanual-latch", qos: .userInteractive)
    private let actionFreshness: TimeInterval = 0.20
    private let scrollRepeatInterval: TimeInterval = 1.0 / 60.0
    private let zoomRepeatInterval: TimeInterval = 0.050
    private let maximumSourceDelta = 22.0
    // Covers a camera stall: missing-frame debounce alone cannot run if frames stop arriving.
    private let holdHeartbeatTimeout: TimeInterval = 0.35

    private var currentInteraction: TrackpadInteraction = .idle
    private var lastScroll: (deltaX: Double, deltaY: Double, timestamp: TimeInterval)?
    private var lastLeftButton: (down: Bool, timestamp: TimeInterval)?
    private var lastZoom: (step: Int, timestamp: TimeInterval)?
    private var currentLatchedAction: LatchedAction?
    private var lastHoldHeartbeat: TimeInterval?
    private var outputTimer: DispatchSourceTimer?

    var latchedAction: LatchedAction? {
        lock.lock()
        defer { lock.unlock() }
        return currentLatchedAction
    }

    func observeInteraction(_ interaction: TrackpadInteraction) {
        lock.lock()
        currentInteraction = interaction
        lock.unlock()
    }

    func observeHoldHeartbeat(timestamp: TimeInterval) {
        guard timestamp.isFinite else { return }
        lock.lock()
        // Never allow out-of-order observations to prolong the watchdog deadline.
        lastHoldHeartbeat = max(lastHoldHeartbeat ?? timestamp, timestamp)
        lock.unlock()
    }

    func observeScroll(deltaX: Double, deltaY: Double, timestamp: TimeInterval) {
        guard deltaX.isFinite, deltaY.isFinite, timestamp.isFinite else { return }
        let safeX = min(max(deltaX, -maximumSourceDelta), maximumSourceDelta)
        let safeY = min(max(deltaY, -maximumSourceDelta), maximumSourceDelta)
        lock.lock()
        lastScroll = (safeX, safeY, timestamp)
        let action = currentLatchedAction
        lock.unlock()

        // A locked action is immutable: subsequent right-hand gestures cannot rewrite its direction.
        if case .scroll = action { return }
        if action == .drag { return }
        onScrollDelta?(safeX, safeY)
    }

    func observeLeftButton(_ down: Bool, timestamp: TimeInterval) {
        guard timestamp.isFinite else { return }
        lock.lock()
        lastLeftButton = (down, timestamp)
        let suppress = currentLatchedAction == .drag
        lock.unlock()
        if !suppress { onLeftButton?(down) }
    }

    func observeZoomStep(_ step: Int, timestamp: TimeInterval) {
        guard step != 0, timestamp.isFinite else { return }
        let safeStep = step > 0 ? 1 : -1
        lock.lock()
        lastZoom = (safeStep, timestamp)
        let action = currentLatchedAction
        lock.unlock()
        if case .zoom = action { return }
        if action == .drag { return }
        onZoomStep?(safeStep)
    }

    func currentLatchableAction(timestamp: TimeInterval, zoomEnabled: Bool) -> LatchedAction? {
        guard timestamp.isFinite else { return nil }
        lock.lock()
        defer { lock.unlock() }
        switch currentInteraction {
        case .scrolling:
            guard let sample = lastScroll,
                  isFresh(sample.timestamp, relativeTo: timestamp),
                  abs(sample.deltaX) >= 0.010 || abs(sample.deltaY) >= 0.010 else { return nil }
            return .scroll(deltaX: sample.deltaX, deltaY: sample.deltaY)
        case .dragging:
            // Drag is a persistent button state, not a fresh one-shot mouseDown sample.
            guard let button = lastLeftButton, button.down else { return nil }
            return .drag
        case .zooming:
            guard zoomEnabled, let zoom = lastZoom,
                  isFresh(zoom.timestamp, relativeTo: timestamp) else { return nil }
            return .zoom(step: zoom.step)
        case .idle, .pointer, .systemSwipe:
            return nil
        }
    }

    @discardableResult
    func latchCurrentAction(timestamp: TimeInterval, zoomEnabled: Bool) -> Bool {
        guard let action = currentLatchableAction(timestamp: timestamp, zoomEnabled: zoomEnabled) else {
            return false
        }
        return latch(action, timestamp: timestamp, zoomEnabled: zoomEnabled)
    }

    /// Commit the specific action captured when the left Hold candidate started.
    /// Deliberately do not refresh from the right hand after the 300 ms confirmation period.
    @discardableResult
    func latch(_ action: LatchedAction, timestamp: TimeInterval, zoomEnabled: Bool) -> Bool {
        guard timestamp.isFinite else { return false }
        let sanitized: LatchedAction
        switch action {
        case let .scroll(dx, dy):
            guard dx.isFinite, dy.isFinite,
                  abs(dx) >= 0.010 || abs(dy) >= 0.010 else { return false }
            sanitized = .scroll(
                deltaX: min(max(dx, -maximumSourceDelta), maximumSourceDelta),
                deltaY: min(max(dy, -maximumSourceDelta), maximumSourceDelta)
            )
        case .drag:
            sanitized = .drag
        case let .zoom(step):
            guard zoomEnabled, step != 0 else { return false }
            sanitized = .zoom(step: step > 0 ? 1 : -1)
        }

        lock.lock()
        if currentLatchedAction != nil {
            lock.unlock()
            return false
        }
        if sanitized == .drag {
            guard currentInteraction == .dragging,
                  let button = lastLeftButton, button.down else {
                lock.unlock()
                return false
            }
        }
        currentLatchedAction = sanitized
        lastHoldHeartbeat = ProcessInfo.processInfo.systemUptime
        lock.unlock()

        startTimerIfNeeded(for: sanitized)
        onStateChanged?(sanitized)
        return true
    }

    func release(timestamp: TimeInterval) {
        guard timestamp.isFinite else { return }
        let oldAction: LatchedAction?
        let timer: DispatchSourceTimer?
        lock.lock()
        oldAction = currentLatchedAction
        currentLatchedAction = nil
        lastHoldHeartbeat = nil
        timer = outputTimer
        outputTimer = nil
        lock.unlock()

        timer?.setEventHandler {}
        timer?.cancel()
        if oldAction == .drag {
            onLeftButton?(false)
        }
        if oldAction != nil {
            onStateChanged?(nil)
        }
    }

    func reset() {
        release(timestamp: ProcessInfo.processInfo.systemUptime)
        lock.lock()
        currentInteraction = .idle
        lastScroll = nil
        lastLeftButton = nil
        lastZoom = nil
        lastHoldHeartbeat = nil
        lock.unlock()
    }

    deinit {
        lock.lock()
        let timer = outputTimer
        outputTimer = nil
        lock.unlock()
        timer?.setEventHandler {}
        timer?.cancel()
    }

    private func isFresh(_ sampleTimestamp: TimeInterval, relativeTo timestamp: TimeInterval) -> Bool {
        // Capture and output clocks are monotonic but may differ by inference latency.
        let age = abs(timestamp - sampleTimestamp)
        return age <= actionFreshness
    }

    private func startTimerIfNeeded(for action: LatchedAction) {
        let interval: TimeInterval
        switch action {
        case .scroll: interval = scrollRepeatInterval
        case .zoom: interval = zoomRepeatInterval
        // A drag must have a watchdog as well or a frozen camera can leave mouseDown stuck.
        case .drag: interval = zoomRepeatInterval
        }

        let timer = DispatchSource.makeTimerSource(queue: outputQueue)
        let nanoseconds = max(Int(interval * 1_000_000_000), 1)
        timer.schedule(
            deadline: .now() + .nanoseconds(nanoseconds),
            repeating: .nanoseconds(nanoseconds),
            leeway: .milliseconds(1)
        )
        timer.setEventHandler { [weak self] in self?.emitLatchedOutput() }

        lock.lock()
        guard currentLatchedAction == action else {
            lock.unlock()
            timer.setEventHandler {}
            timer.resume()
            timer.cancel()
            return
        }
        let oldTimer = outputTimer
        outputTimer = timer
        lock.unlock()
        oldTimer?.setEventHandler {}
        oldTimer?.cancel()
        timer.resume()
    }

    private func emitLatchedOutput() {
        lock.lock()
        let action = currentLatchedAction
        let lastHeartbeat = lastHoldHeartbeat
        lock.unlock()

        guard let action else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if lastHeartbeat == nil || now - (lastHeartbeat ?? now) >= holdHeartbeatTimeout {
            release(timestamp: now)
            return
        }

        switch action {
        case let .scroll(dx, dy):
            // Engine runs at 120 Hz; repeating at 60 Hz preserves its approximate rate.
            onScrollDelta?(dx * 2.0, dy * 2.0)
        case let .zoom(step):
            onZoomStep?(step)
        case .drag:
            break
        }
    }
}
