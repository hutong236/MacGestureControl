import AppKit
import ApplicationServices
import Foundation

/// 使用 macOS 公开 Core Graphics API 注入鼠标与像素级滚动事件。
///
/// V0.5 延续“虚拟指针”累积：摄像头每次产生的亚像素位移不会因为系统坐标回读/量化而丢失，
/// 同时如果用户真实触控板/鼠标把光标移动到别处，会自动重新同步，不抢夺外部输入。
final class TrackpadController {
    private let lock = NSLock()
    private var fractionalScrollX = 0.0
    private var fractionalScrollY = 0.0
    private var leftButtonDown = false
    private var virtualPointer: CGPoint?
    private var lastExternalPointerProbeTime: TimeInterval = 0

    func movePointer(deltaX: Double, deltaY: Double) {
        guard deltaX.isFinite, deltaY.isFinite else { return }

        let now = ProcessInfo.processInfo.systemUptime
        var shouldProbe = false
        var base: CGPoint?
        var dragging = false

        lock.lock()
        shouldProbe = virtualPointer == nil || now - lastExternalPointerProbeTime >= 0.060
        base = virtualPointer
        dragging = leftButtonDown
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
        let target = CGPoint(x: currentBase.x + deltaX, y: currentBase.y + deltaY)
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
        guard let probe = CGEvent(source: nil) else { return }
        let location = probe.location
        let type: CGEventType = down ? .leftMouseDown : .leftMouseUp

        lock.lock()
        leftButtonDown = down
        virtualPointer = location
        lock.unlock()

        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: location,
            mouseButton: .left
        ) else { return }

        event.post(tap: .cghidEventTap)
    }

    func rightClick() {
        guard let probe = CGEvent(source: nil) else { return }
        let location = probe.location
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

        lock.lock()
        fractionalScrollX += deltaX
        fractionalScrollY += deltaY

        let horizontal = Int32(fractionalScrollX.rounded(.towardZero))
        let vertical = Int32(fractionalScrollY.rounded(.towardZero))
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
