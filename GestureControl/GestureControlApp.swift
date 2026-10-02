import SwiftUI

@main
struct GestureControlApp: App {
    @StateObject private var controller: AppController

    init() {
        let controller = AppController()
        _controller = StateObject(wrappedValue: controller)
        GestureHUDWindowController.shared.bind(to: controller)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel(controller: controller)
        } label: {
            Label(
                "Gesture Control",
                systemImage: controller.isRunning ? "hand.raised.fill" : "hand.raised"
            )
        }
        .menuBarExtraStyle(.window)
    }
}
