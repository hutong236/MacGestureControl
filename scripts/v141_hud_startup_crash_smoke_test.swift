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

// V1.4.2: the crash persists when the HUD actually becomes visible. Keep the floating window,
// but remove the SwiftUI/AppKit hosting bridge from this critical runtime path. The HUD content
// should be native AppKit so first presentation cannot fail inside NSHostingView/Material setup.
require(!hud.contains("NSHostingView<GestureHUDView>"), "HUD runtime must not retain NSHostingView storage")
require(!hud.contains("NSHostingView(rootView:"), "HUD runtime must not construct NSHostingView")
require(hud.contains("NSVisualEffectView"), "HUD must retain a native translucent AppKit surface")
require(hud.contains("NSTextField"), "HUD native labels missing")
require(hud.contains("NSProgressIndicator"), "HUD native Hold progress missing")

print("V1.4.2 HUD presentation crash regression smoke test OK")
