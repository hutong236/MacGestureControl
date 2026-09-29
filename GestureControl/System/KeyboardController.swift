import ApplicationServices
import Foundation
import Darwin

final class KeyboardController {
    private let zoomQueue = DispatchQueue(label: "com.hutong.GestureControl.zoom-keys", qos: .userInteractive)

    func send(_ action: KeyActionPreset) {
        send(keyCode: action.keyCode)
    }

    func send(keyCode: CGKeyCode, flags: CGEventFlags = []) {
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            return
        }

        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        usleep(10_000)
        keyUp.post(tap: .cghidEventTap)
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

    /// V0.5: 按双指张合速度连续发出有限数量的缩放脉冲。放到独立队列，
    /// 避免键盘事件间隔阻塞 Vision 帧处理。公开 API 无法全局注入真正的 magnify event，
    /// 因此这里仍使用应用普遍支持的 Command +/-，但速率更接近连续张合。
    func zoom(steps: Int) {
        guard steps != 0 else { return }
        let count = min(abs(steps), 3)
        let keyCode: CGKeyCode = steps > 0 ? 24 : 27
        zoomQueue.async { [weak self] in
            guard let self else { return }
            for _ in 0..<count {
                self.send(keyCode: keyCode, flags: .maskCommand)
                usleep(6_000)
            }
        }
    }
}
