import Foundation

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

    private var currentInteraction: TrackpadInteraction = .idle
    private var lastScroll: (deltaX: Double, deltaY: Double, timestamp: TimeInterval)?
    private var lastLeftButton: (down: Bool, timestamp: TimeInterval)?
    private var lastZoom: (step: Int, timestamp: TimeInterval)?
    private var currentLatchedAction: LatchedAction?
    private var outputTimer: DispatchSourceTimer?

    var latchedAction: LatchedAction? {
        lock.lock()
        let action = currentLatchedAction
        lock.unlock()
        return action
    }

    func observeInteraction(_ interaction: TrackpadInteraction) {
        lock.lock()
        currentInteraction = interaction
        lock.unlock()
    }

    func observeScroll(deltaX: Double, deltaY: Double, timestamp: TimeInterval) {
        guard deltaX.isFinite, deltaY.isFinite, timestamp.isFinite else { return }
        let safeX = min(max(deltaX, -maximumSourceDelta), maximumSourceDelta)
        let safeY = min(max(deltaY, -maximumSourceDelta), maximumSourceDelta)
        var forwardLive = true

        lock.lock()
        lastScroll = (safeX, safeY, timestamp)
        if case .scroll = currentLatchedAction {
            currentLatchedAction = .scroll(deltaX: safeX, deltaY: safeY)
            forwardLive = false
        }
        lock.unlock()

        if forwardLive {
            onScrollDelta?(deltaX, deltaY)
        }
    }

    func observeLeftButton(_ down: Bool, timestamp: TimeInterval) {
        guard timestamp.isFinite else { return }
        var forwardLive = true

        lock.lock()
        lastLeftButton = (down, timestamp)
        if currentLatchedAction == .drag {
            forwardLive = false
        }
        lock.unlock()

        if forwardLive {
            onLeftButton?(down)
        }
    }

    func observeZoomStep(_ step: Int, timestamp: TimeInterval) {
        guard step != 0, timestamp.isFinite else { return }
        let normalizedStep = step > 0 ? 1 : -1
        var forwardLive = true

        lock.lock()
        lastZoom = (normalizedStep, timestamp)
        if case .zoom = currentLatchedAction {
            currentLatchedAction = .zoom(step: normalizedStep)
            forwardLive = false
        }
        lock.unlock()

        if forwardLive {
            onZoomStep?(step)
        }
    }

    func currentLatchableAction(timestamp: TimeInterval, zoomEnabled: Bool) -> LatchedAction? {
        guard timestamp.isFinite else { return nil }
        lock.lock()
        let action = currentLatchableActionLocked(timestamp: timestamp, zoomEnabled: zoomEnabled)
        lock.unlock()
        return action
    }

    @discardableResult
    func latchCurrentAction(timestamp: TimeInterval, zoomEnabled: Bool) -> Bool {
        guard timestamp.isFinite else { return false }
        let action: LatchedAction

        lock.lock()
        if currentLatchedAction != nil {
            lock.unlock()
            return true
        }
        guard let candidate = currentLatchableActionLocked(timestamp: timestamp, zoomEnabled: zoomEnabled) else {
            lock.unlock()
            return false
        }
        currentLatchedAction = candidate
        action = candidate
        lock.unlock()

        startTimerIfNeeded(for: action)
        onStateChanged?(action)
        return true
    }

    func release(timestamp: TimeInterval) {
        guard timestamp.isFinite else { return }
        let oldAction: LatchedAction?
        let timer: DispatchSourceTimer?

        lock.lock()
        oldAction = currentLatchedAction
        currentLatchedAction = nil
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

    private func currentLatchableActionLocked(timestamp: TimeInterval, zoomEnabled: Bool) -> LatchedAction? {
        switch currentInteraction {
        case .scrolling:
            guard let sample = lastScroll,
                  isFresh(sample.timestamp, relativeTo: timestamp),
                  abs(sample.deltaX) >= 0.010 || abs(sample.deltaY) >= 0.010 else { return nil }
            return .scroll(deltaX: sample.deltaX, deltaY: sample.deltaY)

        case .dragging:
            guard let button = lastLeftButton,
                  button.down,
                  isFresh(button.timestamp, relativeTo: timestamp) else { return nil }
            return .drag

        case .zooming:
            guard zoomEnabled,
                  let zoom = lastZoom,
                  isFresh(zoom.timestamp, relativeTo: timestamp) else { return nil }
            return .zoom(step: zoom.step)

        case .idle, .pointer, .systemSwipe:
            return nil
        }
    }

    private func isFresh(_ sampleTimestamp: TimeInterval, relativeTo timestamp: TimeInterval) -> Bool {
        let age = timestamp - sampleTimestamp
        return age >= 0 && age <= actionFreshness
    }

    private func startTimerIfNeeded(for action: LatchedAction) {
        let interval: TimeInterval
        switch action {
        case .scroll:
            interval = scrollRepeatInterval
        case .zoom:
            interval = zoomRepeatInterval
        case .drag:
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: outputQueue)
        let nanoseconds = max(Int(interval * 1_000_000_000), 1)
        timer.schedule(
            deadline: .now() + .nanoseconds(nanoseconds),
            repeating: .nanoseconds(nanoseconds),
            leeway: .milliseconds(1)
        )
        timer.setEventHandler { [weak self] in
            self?.emitLatchedOutput()
        }

        lock.lock()
        let oldTimer = outputTimer
        outputTimer = timer
        lock.unlock()
        oldTimer?.setEventHandler {}
        oldTimer?.cancel()
        timer.resume()
    }

    private func emitLatchedOutput() {
        let action: LatchedAction?
        lock.lock()
        action = currentLatchedAction
        lock.unlock()

        switch action {
        case let .scroll(deltaX, deltaY):
            // Engine scroll deltas arrive at 120 Hz. Repeating at 60 Hz doubles each captured delta
            // to preserve the same approximate pixels/second while remaining inside the source envelope.
            onScrollDelta?(deltaX * 2.0, deltaY * 2.0)
        case let .zoom(step):
            onZoomStep?(step)
        case .drag, .none:
            break
        }
    }
}
