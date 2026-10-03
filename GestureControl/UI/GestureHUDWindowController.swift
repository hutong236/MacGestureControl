import AppKit
import Combine
import SwiftUI

private final class GestureHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class GestureHUDWindowController {
    static let shared = GestureHUDWindowController()

    private let defaultsKey = "gesture.hudEnabled.v1"
    private var panel: GestureHUDPanel?
    private var hostingView: NSHostingView<GestureHUDView>?
    private var cancellables = Set<AnyCancellable>()
    private var hideWorkItem: DispatchWorkItem?
    private var enabled = true
    private var running = false
    private var state = GestureHUDState(
        mode: .idle,
        leftHandText: "Left: Ready",
        rightHandText: "Right: Ready",
        actionText: "Gesture Ready",
        holdProgress: nil,
        isLocked: false
    )

    private init() {}

    func bind(to controller: AppController) {
        cancellables.removeAll()
        enabled = UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
        running = controller.isRunning
        state = controller.hudState

        controller.$hudState
            .combineLatest(controller.$isRunning)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state, running in
                guard let self else { return }
                self.state = state
                self.running = running
                self.refreshPresentation()
            }
            .store(in: &cancellables)

        DispatchQueue.main.async { [weak self] in
            self?.refreshPresentation()
        }
    }

    func setEnabled(_ enabled: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.enabled = enabled
            self.refreshPresentation()
        }
    }

    func update(state: GestureHUDState) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.state = state
            self.refreshPresentation()
        }
    }

    func setRunning(_ running: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.running = running
            self.refreshPresentation()
        }
    }

    func hide() {
        DispatchQueue.main.async { [weak self] in
            self?.hideWorkItem?.cancel()
            self?.hideWorkItem = nil
            self?.panel?.orderOut(nil)
        }
    }

    private func refreshPresentation() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.refreshPresentation()
            }
            return
        }

        hideWorkItem?.cancel()
        hideWorkItem = nil

        guard enabled, running else {
            panel?.orderOut(nil)
            return
        }

        // Starting gesture control publishes `isRunning = true` before the first camera frame.
        // Do not allocate/order an AppKit panel for that idle transition. The HUD is created lazily
        // only after a real gesture becomes active, which also avoids startup-time window reentrancy.
        switch state.mode {
        case .idle:
            panel?.orderOut(nil)
            return
        case .active, .holdCandidate, .latched:
            break
        }

        let panel = ensurePanel()
        hostingView?.rootView = GestureHUDView(state: state)
        position(panel)
        panel.orderFrontRegardless()
    }

    private func ensurePanel() -> GestureHUDPanel {
        if let panel { return panel }

        let frame = NSRect(x: 0, y: 0, width: 360, height: 78)
        let panel = GestureHUDPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let hostingView = NSHostingView(rootView: GestureHUDView(state: state))
        hostingView.frame = frame
        panel.contentView = hostingView

        self.hostingView = hostingView
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let origin = NSPoint(
            x: visibleFrame.midX - size.width * 0.5,
            y: visibleFrame.maxY - size.height - 24
        )
        panel.setFrameOrigin(origin)
    }
}
