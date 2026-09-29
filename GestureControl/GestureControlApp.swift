import SwiftUI

@main
struct GestureControlApp: App {
    @StateObject private var controller = AppController()

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
