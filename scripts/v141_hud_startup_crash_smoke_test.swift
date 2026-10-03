import Foundation

private func read(_ path: String) -> String {
    guard let data = FileManager.default.contents(atPath: path),
          let text = String(data: data, encoding: .utf8) else {
        fatalError("Unable to read \(path)")
    }
    return text
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

let hud = read("GestureControl/UI/GestureHUDWindowController.swift")

// Starting gesture control publishes isRunning=true before the first camera frame arrives.
// Idle HUD state must therefore not create/show an AppKit panel at that moment.
require(
    hud.contains("case .idle:\n            panel?.orderOut(nil)\n            return"),
    "Idle running state must not create/show the HUD panel"
)

// A defensive main-thread hop is safer than terminating the whole app if a future caller
// reaches presentation from a non-main queue.
require(!hud.contains("precondition(Thread.isMainThread)"), "HUD presentation must not crash on a thread precondition")
require(hud.contains("guard Thread.isMainThread else"), "HUD must defensively hop to the main queue")

print("V1.4.1 HUD startup crash regression smoke test OK")
