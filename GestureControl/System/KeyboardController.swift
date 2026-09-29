import ApplicationServices
import Foundation
import Darwin

final class KeyboardController {
    /// Serialize all synthetic key events off the main/Vision threads. The old synchronous 10ms
    /// key-up delay could visibly stall menu UI callbacks and gesture processing.
    private let eventQueue = DispatchQueue(label: "com.hutong.GestureControl.key-events", qos: .userInteractive)

    func send(_ action: KeyActionPreset) {
        send(keyCode: action.keyCode)
    }

    func send(keyCode: CGKeyCode, flags: CGEventFlags = []) {
        eventQueue.async { [weak self] in
            self?.postKey(keyCode: keyCode, flags: flags)
        }
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
        send(keyCode: 24, flags: .maskCommand) // Command + =
    }

    func zoomOut() {
        send(keyCode: 27, flags: .maskCommand) // Command + -
    }

    /// V1.2.1: 缩放脉冲和其它键盘事件共用一个串行队列，保证事件顺序稳定，
    /// 同时不再让 6~10ms 的 key-up 间隔阻塞调用线程。
    func zoom(steps: Int) {
        guard steps != 0 else { return }
        let count = min(abs(steps), 3)
        let keyCode: CGKeyCode = steps > 0 ? 24 : 27
        eventQueue.async { [weak self] in
            guard let self else { return }
            for _ in 0..<count {
                self.postKey(keyCode: keyCode, flags: .maskCommand, keyUpDelayUS: 6_000)
            }
        }
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
