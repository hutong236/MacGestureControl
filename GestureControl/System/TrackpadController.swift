import AppKit
import ApplicationServices
import Foundation

/// Filters duplicate/rebound click transitions at the final system-event boundary.
///
/// The Vision gesture engine already performs pinch arming/debounce. This second, deliberately tiny
/// state gate protects against release-shape rebound producing an immediate second mouseDown while
/// preserving the first click and normal drag latency.
struct SelectionGestureGate {
    let minimumRearmInterval: TimeInterval

    private var lastAcceptedTimestamp: TimeInterval = -.infinity
    private var lastReleaseTime: TimeInterval = -.infinity
    private var suppressingBounce = false

    init(minimumRearmInterval: TimeInterval = 0.090) {
        self.minimumRearmInterval = max(minimumRearmInterval, 0)
    }

    /// Returns the button state that should actually be emitted, or nil when the transition should
    /// be ignored. `actualDown` is supplied by TrackpadController so event-allocation failures do not
    /// make this pure intent gate drift away from the real Core Graphics state.
    mutating func filter(
        requestedDown: Bool,
        actualDown: Bool,
        timestamp: TimeInterval
    ) -> Bool? {
        guard timestamp.isFinite, timestamp >= lastAcceptedTimestamp else { return nil }
        lastAcceptedTimestamp = timestamp

        if requestedDown {
            guard !actualDown else { return nil }
            guard !suppressingBounce else { return nil }

            let elapsed = timestamp - lastReleaseTime
            if elapsed + 1e-9 < minimumRearmInterval {
                suppressingBounce = true
                return nil
            }
            return true
        }

        if suppressingBounce {
            suppressingBounce = false
            return nil
        }
        guard actualDown else { return nil }
        return false
    }

    mutating func markEmitted(down: Bool, at timestamp: TimeInterval) {
        guard timestamp.isFinite else { return }
        suppressingBounce = false
        if !down {
            lastReleaseTime = timestamp
        }
    }
}

/// 使用 macOS 公开 Core Graphics API 注入鼠标与像素级滚动事件。
///
/// V0.5 延续“虚拟指针”累积：摄像头每次产生的亚像素位移不会因为系统坐标回读/量化而丢失，
/// 同时如果用户真实触控板/鼠标把光标移动到别处，会自动重新同步，不抢夺外部输入。
final class TrackpadController {
    private let lock = NSLock()
    private var fractionalScrollX = 0.0
    private var fractionalScrollY = 0.0
    private var leftButtonDown = false
    private var selectionGestureGate = SelectionGestureGate()
    private var virtualPointer: CGPoint?
    private var lastExternalPointerProbeTime: TimeInterval = 0

    func movePointer(deltaX: Double, deltaY: Double) {
        guard deltaX.isFinite, deltaY.isFinite else { return }

        // The gesture engine normally caps 120Hz deltas near 21 px, but the system-event boundary
        // must remain safe even if a future caller bypasses that invariant with a huge finite value.
        let maximumPointerDelta = 240.0
        let safeDeltaX = min(max(deltaX, -maximumPointerDelta), maximumPointerDelta)
        let safeDeltaY = min(max(deltaY, -maximumPointerDelta), maximumPointerDelta)

        let now = ProcessInfo.processInfo.systemUptime
        var shouldProbe = false
        var base: CGPoint?
        var dragging = false

        lock.lock()
        shouldProbe = virtualPointer == nil || now - lastExternalPointerProbeTime >= 0.060
        base = virtualPointer
        lock.unlock()

        // Reading current CG cursor position used to allocate a probe CGEvent on every 120Hz tick.
        // V1.2 checks external mouse/trackpad takeover at ~16Hz instead, while virtual sub-pixel
        // integration remains 120Hz. This removes a synchronous hot-path operation without making
        // physical-pointer takeover feel slow.
        var actual: CGPoint?
        if shouldProbe, let probe = CGEvent(source: nil) {
            actual = probe.location
        }

        lock.lock()
        if let actual {
            lastExternalPointerProbeTime = now
            if let virtualPointer {
                if hypot(actual.x - virtualPointer.x, actual.y - virtualPointer.y) > 18.0 {
                    self.virtualPointer = actual
                }
            } else {
                virtualPointer = actual
            }
        }

        guard let currentBase = virtualPointer ?? base ?? actual else {
            lock.unlock()
            return
        }
        let target = CGPoint(x: currentBase.x + safeDeltaX, y: currentBase.y + safeDeltaY)
        guard target.x.isFinite, target.y.isFinite else {
            virtualPointer = nil
            lock.unlock()
            return
        }
        virtualPointer = target
        dragging = leftButtonDown
        lock.unlock()

        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: dragging ? .leftMouseDragged : .mouseMoved,
            mouseCursorPosition: target,
            mouseButton: .left
        ) else { return }

        event.post(tap: .cghidEventTap)
    }

    func setLeftButton(down: Bool) {
        let now = ProcessInfo.processInfo.systemUptime

        // Keep the gate and actual button state under the same lock. In particular, a suppressed
        // rebound mouseDown still needs to see the following mouseUp so the suppression latch clears.
        lock.lock()
        let filteredDown = selectionGestureGate.filter(
            requestedDown: down,
            actualDown: leftButtonDown,
            timestamp: now
        )
        lock.unlock()
        guard let filteredDown else { return }

        guard let probe = CGEvent(source: nil) else { return }
        let location = probe.location
        guard location.x.isFinite, location.y.isFinite else { return }
        let type: CGEventType = filteredDown ? .leftMouseDown : .leftMouseUp
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: location,
            mouseButton: .left
        ) else { return }

        lock.lock()
        guard leftButtonDown != filteredDown else {
            lock.unlock()
            return
        }
        leftButtonDown = filteredDown
        selectionGestureGate.markEmitted(down: filteredDown, at: now)
        virtualPointer = location
        lock.unlock()

        event.post(tap: .cghidEventTap)
    }

    func rightClick() {
        guard let probe = CGEvent(source: nil) else { return }
        let location = probe.location
        guard location.x.isFinite, location.y.isFinite else { return }
        guard let down = CGEvent(
            mouseEventSource: nil,
            mouseType: .rightMouseDown,
            mouseCursorPosition: location,
            mouseButton: .right
        ), let up = CGEvent(
            mouseEventSource: nil,
            mouseType: .rightMouseUp,
            mouseCursorPosition: location,
            mouseButton: .right
        ) else { return }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    func scroll(deltaX: Double, deltaY: Double) {
        guard deltaX.isFinite, deltaY.isFinite else { return }

        // Keep malformed/outlier upstream values from overflowing Int32 conversion. Normal gesture
        // deltas are orders of magnitude smaller; this is a safety rail, not a sensitivity clamp.
        let maximumEventDelta = 32_000.0
        let safeDeltaX = min(max(deltaX, -maximumEventDelta), maximumEventDelta)
        let safeDeltaY = min(max(deltaY, -maximumEventDelta), maximumEventDelta)

        lock.lock()
        fractionalScrollX += safeDeltaX
        fractionalScrollY += safeDeltaY

        let wholeX = min(max(fractionalScrollX.rounded(.towardZero), -maximumEventDelta), maximumEventDelta)
        let wholeY = min(max(fractionalScrollY.rounded(.towardZero), -maximumEventDelta), maximumEventDelta)
        let horizontal = Int32(wholeX)
        let vertical = Int32(wholeY)
        fractionalScrollX -= Double(horizontal)
        fractionalScrollY -= Double(vertical)
        lock.unlock()

        guard horizontal != 0 || vertical != 0 else { return }

        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: vertical,
            wheel2: horizontal,
            wheel3: 0
        ) else { return }

        // 明确标记为连续/像素级滚动，让支持触控板滚动的 App 采用更平滑的路径。
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.post(tap: .cghidEventTap)
    }

    func resetMotionState() {
        lock.lock()
        fractionalScrollX = 0
        fractionalScrollY = 0
        virtualPointer = nil
        lastExternalPointerProbeTime = 0
        lock.unlock()
    }

    func resetScrollRemainder() {
        lock.lock()
        fractionalScrollX = 0
        fractionalScrollY = 0
        lock.unlock()
    }
}
