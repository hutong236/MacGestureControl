import ApplicationServices
import Foundation
import Darwin

final class KeyboardController {
    /// Serialize all synthetic key events off the main/Vision threads. The old synchronous 10ms
    /// key-up delay could visibly stall menu UI callbacks and gesture processing.
    private let eventQueue = DispatchQueue(label: "com.hutong.GestureControl.key-events", qos: .userInteractive)

    /// Event intents are generation-scoped. Stopping recognition or switching modes invalidates
    /// queued-but-not-yet-posted shortcuts so stale gestures cannot fire after the UI says "stopped".
    /// A key-up that belongs to a key-down already posted is always allowed to complete.
    private let stateLock = NSLock()
    private var eventGeneration: UInt64 = 0
    private var pendingZoomSteps = 0
    private var zoomDrainGeneration: UInt64?

    func send(_ action: KeyActionPreset) {
        send(keyCode: action.keyCode)
    }

    func send(keyCode: CGKeyCode, flags: CGEventFlags = []) {
        let generation = generationSnapshot()
        eventQueue.async { [weak self] in
            guard let self, self.isGenerationCurrent(generation) else { return }
            self.postKey(keyCode: keyCode, flags: flags)
        }
    }

    /// Invalidate queued input that has not started posting yet.
    ///
    /// If cancellation races with a key that is already down, postKey still emits its matching key-up
    /// before the queue observes the new generation. This avoids both stale actions and stuck modifiers.
    func cancelPendingEvents() {
        stateLock.lock()
        eventGeneration &+= 1
        pendingZoomSteps = 0
        zoomDrainGeneration = nil
        stateLock.unlock()
    }

    // macOS 默认触控板多指系统手势的键盘等价操作。
    func switchToNextSpace() {
        send(keyCode: 124, flags: .maskControl) // Control + Right
    }

    func switchToPreviousSpace() {
        send(keyCode: 123, flags: .maskControl) // Control + Left
    }

    func missionControl() {
        send(keyCode: 126, flags: .maskControl) // Control + Up
    }

    func appExpose() {
        send(keyCode: 125, flags: .maskControl) // Control + Down
    }

    func zoomIn() {
        zoom(steps: 1)
    }

    func zoomOut() {
        zoom(steps: -1)
    }

    /// Coalesce zoom pulses instead of enqueuing one closure per Vision frame.
    ///
    /// Opposite-direction updates cancel each other and the pending budget is deliberately bounded,
    /// preventing a burst of Command +/- events from continuing long after the user's fingers stop.
    func zoom(steps: Int) {
        guard steps != 0 else { return }
        // Clamp before arithmetic so Int.min can never overflow this utility path.
        let boundedSteps = min(max(steps, -3), 3)

        var generation: UInt64 = 0
        var shouldScheduleDrain = false

        stateLock.lock()
        generation = eventGeneration
        pendingZoomSteps = min(max(pendingZoomSteps + boundedSteps, -6), 6)
        if zoomDrainGeneration != generation {
            zoomDrainGeneration = generation
            shouldScheduleDrain = true
        }
        stateLock.unlock()

        guard shouldScheduleDrain else { return }
        eventQueue.async { [weak self] in
            self?.drainZoom(generation: generation)
        }
    }

    private func drainZoom(generation: UInt64) {
        while true {
            let step: Int

            stateLock.lock()
            guard eventGeneration == generation else {
                if zoomDrainGeneration == generation {
                    zoomDrainGeneration = nil
                }
                stateLock.unlock()
                return
            }

            guard pendingZoomSteps != 0 else {
                if zoomDrainGeneration == generation {
                    zoomDrainGeneration = nil
                }
                stateLock.unlock()
                return
            }

            step = pendingZoomSteps > 0 ? 1 : -1
            pendingZoomSteps -= step
            stateLock.unlock()

            let keyCode: CGKeyCode = step > 0 ? 24 : 27
            postKey(keyCode: keyCode, flags: .maskCommand, keyUpDelayUS: 6_000)
        }
    }

    private func generationSnapshot() -> UInt64 {
        stateLock.lock()
        let generation = eventGeneration
        stateLock.unlock()
        return generation
    }

    private func isGenerationCurrent(_ generation: UInt64) -> Bool {
        stateLock.lock()
        let current = eventGeneration == generation
        stateLock.unlock()
        return current
    }

    private func postKey(
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        keyUpDelayUS: useconds_t = 10_000
    ) {
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            return
        }

        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        usleep(keyUpDelayUS)
        keyUp.post(tap: .cghidEventTap)
    }
}
