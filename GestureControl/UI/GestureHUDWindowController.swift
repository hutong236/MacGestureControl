import AppKit
import Combine

private final class GestureHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Native AppKit content for the floating HUD.
///
/// Keep this runtime path out of SwiftUI hosting: the HUD is created while a menu-bar SwiftUI app
/// is already processing camera/Vision callbacks, and the extra NSHostingView/Material bridge proved
/// fragile on real hardware. NSVisualEffectView gives us the same translucent system appearance with
/// a much smaller lifecycle surface.
private final class GestureHUDContentView: NSVisualEffectView {
    private let iconView = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let actionLabel = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 15
        layer?.masksToBounds = true

        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = .labelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        actionLabel.font = .systemFont(ofSize: 13, weight: .medium)
        actionLabel.textColor = .labelColor
        actionLabel.lineBreakMode = .byTruncatingTail
        actionLabel.translatesAutoresizingMaskIntoConstraints = false

        progressIndicator.style = .bar
        progressIndicator.controlSize = .small
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.isHidden = true
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(statusLabel)
        addSubview(actionLabel)
        addSubview(progressIndicator)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),

            statusLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            statusLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),

            actionLabel.leadingAnchor.constraint(equalTo: statusLabel.leadingAnchor),
            actionLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 3),
            actionLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),

            progressIndicator.leadingAnchor.constraint(equalTo: statusLabel.leadingAnchor),
            progressIndicator.topAnchor.constraint(equalTo: actionLabel.bottomAnchor, constant: 5),
            progressIndicator.widthAnchor.constraint(equalToConstant: 230),
            progressIndicator.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14)
        ])
    }

    func update(with state: GestureHUDState) {
        let symbolName: String
        if state.isLocked {
            symbolName = "lock.fill"
        } else {
            switch state.mode {
            case .idle: symbolName = "hand.raised"
            case .active: symbolName = "hand.point.up.left"
            case .holdCandidate: symbolName = "hand.pinch"
            case .latched: symbolName = "lock.fill"
            }
        }

        iconView.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: state.actionText
        )
        statusLabel.stringValue = "\(state.leftHandText)    \(state.rightHandText)"
        actionLabel.stringValue = state.actionText
        actionLabel.font = .systemFont(ofSize: 13, weight: state.isLocked ? .semibold : .medium)

        if let progress = state.holdProgress, state.mode == .holdCandidate {
            progressIndicator.doubleValue = min(max(progress, 0), 1)
            progressIndicator.isHidden = false
        } else {
            progressIndicator.doubleValue = 0
            progressIndicator.isHidden = true
        }
    }
}

final class GestureHUDWindowController {
    static let shared = GestureHUDWindowController()

    private let defaultsKey = "gesture.hudEnabled.v1"
    private var panel: GestureHUDPanel?
    private var hudContentView: GestureHUDContentView?
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
        // Stay dormant until a real interaction exists; this also keeps window creation out of the
        // camera-start transition.
        switch state.mode {
        case .idle:
            panel?.orderOut(nil)
            return
        case .active, .holdCandidate, .latched:
            break
        }

        let panel = ensurePanel()
        hudContentView?.update(with: state)
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

        let contentView = GestureHUDContentView(frame: frame)
        contentView.update(with: state)
        panel.contentView = contentView

        self.hudContentView = contentView
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
