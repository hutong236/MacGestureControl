import AVFoundation
import AppKit
import Combine
import Foundation

private func storedFiniteDouble(
    _ defaults: UserDefaults,
    key: String,
    default defaultValue: Double,
    range: ClosedRange<Double>
) -> Double {
    guard let value = defaults.object(forKey: key) as? Double, value.isFinite else {
        return defaultValue
    }
    return min(max(value, range.lowerBound), range.upperBound)
}

final class AppController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var handDetected = false
    @Published private(set) var handConfidence = 0.0
    @Published private(set) var lastGesture: GestureDirection?
    @Published private(set) var lastActionText = ""
    @Published private(set) var currentFingerPattern: FingerPattern?
    @Published private(set) var trackpadInteraction: TrackpadInteraction = .idle
    @Published private(set) var calibrationProgress = 0.0
    @Published private(set) var personalPalmScale: Double?
    @Published private(set) var visionFPS = 0.0
    @Published private(set) var trackingStability = 1.0
    @Published private(set) var distanceGain = 1.0
    @Published private(set) var visionLatencyMS = 0.0
    @Published private(set) var pointerMotionPhase: PointerMotionPhase = .idle
    @Published private(set) var scrollMotionPhase: ScrollMotionPhase = .idle
    @Published private(set) var trackingContinuity = 1.0
    @Published private(set) var droppedObservationCount = 0
    @Published private(set) var predictionHoldMS = 0.0
    @Published private(set) var lastRecoveryFrames = 0
    @Published private(set) var detectedHandCount = 0
    @Published private(set) var secondaryHandDetected = false
    // Retained for source/UI compatibility; under V1.4 this means a continuous action is latched.
    @Published private(set) var bimanualClutchActive = false
    @Published private(set) var leftHoldState: LeftHoldState = .idle
    @Published private(set) var hudState = GestureHUDState(
        mode: .idle,
        leftHandText: "Left: Ready",
        rightHandText: "Right: Ready",
        actionText: "Gesture Ready",
        holdProgress: nil,
        isLocked: false
    )

    @Published var customGestures: [CustomStaticGesture] {
        didSet {
            saveCustomGestures()
            staticGestureEngine.update(gestures: customGestures)
        }
    }

    @Published private(set) var cameraPermission = PermissionManager.cameraAuthorized
    @Published private(set) var accessibilityPermission = PermissionManager.postEventAuthorized
    @Published private(set) var accessibilityTrusted = PermissionManager.accessibilityTrusted
    @Published private(set) var inputControlState = PermissionManager.inputControlState
    @Published var lastError: String?

    @Published var controlMode: ControlMode {
        didSet {
            defaults.set(controlMode.rawValue, forKey: Keys.controlMode)
            resetRecognitionState()
        }
    }

    @Published var sensitivity: Double {
        didSet {
            defaults.set(sensitivity, forKey: Keys.sensitivity)
            applyPageGestureConfiguration()
        }
    }

    @Published var cooldown: Double {
        didSet {
            defaults.set(cooldown, forKey: Keys.cooldown)
            applyPageGestureConfiguration()
        }
    }

    @Published var pointerSensitivity: Double {
        didSet {
            defaults.set(pointerSensitivity, forKey: Keys.pointerSensitivity)
            applyTrackpadConfiguration()
        }
    }

    @Published var scrollSensitivity: Double {
        didSet {
            defaults.set(scrollSensitivity, forKey: Keys.scrollSensitivity)
            applyTrackpadConfiguration()
        }
    }

    @Published var scrollInertia: Double {
        didSet {
            defaults.set(scrollInertia, forKey: Keys.scrollInertia)
            applyTrackpadConfiguration()
        }
    }

    @Published var twoFingerZoomEnabled: Bool {
        didSet {
            defaults.set(twoFingerZoomEnabled, forKey: Keys.twoFingerZoomEnabled)
            applyTrackpadConfiguration()
        }
    }

    @Published var scrollRetractionSuppressionEnabled: Bool {
        didSet {
            defaults.set(scrollRetractionSuppressionEnabled, forKey: Keys.scrollRetractionSuppressionEnabled)
            applyTrackpadConfiguration()
        }
    }

    @Published var bimanualAssistEnabled: Bool {
        didSet {
            defaults.set(bimanualAssistEnabled, forKey: Keys.bimanualAssistEnabled)
            detector.setMaximumHandCount(bimanualAssistEnabled ? 2 : 1)
            if !bimanualAssistEnabled {
                latchCoordinator.reset()
                clearLeftHoldTrackingState()
                leftHoldState = .idle
                bimanualClutchActive = false
                updateHUDForInteraction(trackpadInteraction)
            }
        }
    }

    @Published var naturalScrolling: Bool {
        didSet {
            defaults.set(naturalScrolling, forKey: Keys.naturalScrolling)
            applyTrackpadConfiguration()
        }
    }

    @Published var trackingResponsiveness: Double {
        didSet {
            defaults.set(trackingResponsiveness, forKey: Keys.trackingResponsiveness)
            applyTrackpadConfiguration()
        }
    }

    @Published var precisionAssist: Double {
        didSet {
            defaults.set(precisionAssist, forKey: Keys.precisionAssist)
            applyTrackpadConfiguration()
        }
    }

    @Published var bindings: GestureBindings {
        didSet { saveBindings() }
    }

    let camera = CameraManager()

    private let detector = HandPoseDetector()
    private let gestureEngine = DirectionalGestureEngine()
    private let staticGestureEngine = StaticGestureEngine()
    private let trackpadEngine = TrackpadGestureEngine()
    private let latchCoordinator = BimanualLatchCoordinator()
    private let keyboard = KeyboardController()
    private let trackpad = TrackpadController()
    private let defaults = UserDefaults.standard
    private var lastUIUpdate: TimeInterval = 0
    /// Monotonic intent token. Camera permission callbacks are asynchronous and must not revive
    /// a run that the user already stopped while the prompt was in flight.
    private var runIntentGeneration: UInt64 = 0
    private let processingStateLock = NSLock()
    private var processingGeneration: UInt64 = 0
    private var processingEnabled = false
    private var hasRequestedAccessibilityThisLaunch = false
    private var activationObserver: NSObjectProtocol?

    // V1.4 physical two-hand roles. Right = operation hand; left = Hold modifier when both exist.
    private var primaryHandCenter: (x: Double, y: Double, timestamp: TimeInterval)?
    private var secondaryHandCenter: (x: Double, y: Double, timestamp: TimeInterval)?
    private let leftHoldDuration: TimeInterval = 0.30
    private let leftReleaseDebounce: TimeInterval = 0.08
    private let leftMissingReleaseDelay: TimeInterval = 0.25
    private var leftHoldArmed = false
    private var leftHoldCandidateSince: TimeInterval?
    private var leftHoldReleaseSince: TimeInterval?
    private var leftHandMissingSince: TimeInterval?
    private var leftHoldCandidateAction: LatchedAction?
    private var leftHoldStateInternal: LeftHoldState = .idle

    init() {
        let storedDefaults = UserDefaults.standard

        if let raw = storedDefaults.string(forKey: Keys.controlMode),
           let storedMode = ControlMode(rawValue: raw) {
            controlMode = storedMode
        } else {
            // 空中触控板仍是默认模式。
            controlMode = .trackpad
        }

        sensitivity = storedFiniteDouble(storedDefaults, key: Keys.sensitivity, default: 0.55, range: 0...1)
        cooldown = storedFiniteDouble(storedDefaults, key: Keys.cooldown, default: 0.85, range: 0.20...2.50)
        pointerSensitivity = storedFiniteDouble(storedDefaults, key: Keys.pointerSensitivity, default: 1.0, range: 0.35...2.50)
        scrollSensitivity = storedFiniteDouble(storedDefaults, key: Keys.scrollSensitivity, default: 1.0, range: 0.35...2.50)
        scrollInertia = storedFiniteDouble(storedDefaults, key: Keys.scrollInertia, default: 0.72, range: 0...1)
        // V1.1.1: 默认关闭键盘模拟缩放，避免双指滚动误触 Command +/-。
        twoFingerZoomEnabled = storedDefaults.object(forKey: Keys.twoFingerZoomEnabled) as? Bool ?? false
        // V1.1.2: 默认开启滚动回收抑制，避免主运动结束后收手被识别为反向滚动。
        scrollRetractionSuppressionEnabled = storedDefaults.object(forKey: Keys.scrollRetractionSuppressionEnabled) as? Bool ?? true
        // V1.4 keeps the persisted V1.2 key but changes the semantic to left-hand Pinch Hold latching.
        bimanualAssistEnabled = storedDefaults.object(forKey: Keys.bimanualAssistEnabled) as? Bool ?? false
        naturalScrolling = storedDefaults.object(forKey: Keys.naturalScrolling) as? Bool ?? true
        trackingResponsiveness = storedFiniteDouble(
            storedDefaults,
            key: Keys.trackingResponsiveness,
            default: 0.74,
            range: 0...1
        )
        precisionAssist = storedFiniteDouble(
            storedDefaults,
            key: Keys.precisionAssist,
            default: 0.68,
            range: 0...1
        )
        let rawPalmScale = storedDefaults.object(forKey: Keys.personalPalmScale) as? Double
        let storedPalmScale = rawPalmScale.flatMap { value in
            value.isFinite && value > 0.001 ? value : nil
        }
        personalPalmScale = storedPalmScale
        calibrationProgress = storedPalmScale == nil ? 0 : 1

        if let data = storedDefaults.data(forKey: Keys.bindings),
           let decoded = try? JSONDecoder().decode(GestureBindings.self, from: data) {
            bindings = decoded
        } else {
            bindings = GestureBindings()
        }

        if let data = storedDefaults.data(forKey: Keys.customGestures),
           let decoded = try? JSONDecoder().decode([CustomStaticGesture].self, from: data) {
            customGestures = decoded
        } else {
            customGestures = []
        }

        camera.frameHandler = { [weak self] sampleBuffer, capturedAt in
            guard let self, let generation = self.activeProcessingGeneration() else { return }
            self.process(sampleBuffer, capturedAt: capturedAt, generation: generation)
        }
        camera.errorHandler = { [weak self] message in
            guard let self else { return }
            self.endProcessingSession()
            self.keyboard.cancelPendingEvents()
            self.latchCoordinator.reset()
            self.trackpadEngine.reset()
            self.trackpad.setLeftButton(down: false)
            self.trackpad.resetMotionState()
            DispatchQueue.main.async {
                self.lastError = message
                self.isRunning = false
                self.resetPublishedTrackingState()
                self.resetHandAssignmentState()
            }
        }

        gestureEngine.onGesture = { [weak self] direction in
            self?.handlePageGesture(direction)
        }

        staticGestureEngine.onGesture = { [weak self] gesture in
            self?.handleStaticGesture(gesture)
        }
        staticGestureEngine.update(gestures: customGestures)

        latchCoordinator.onScrollDelta = { [weak self] dx, dy in
            guard let self, self.isProcessingActive() else { return }
            self.trackpad.scroll(deltaX: dx, deltaY: dy)
        }
        latchCoordinator.onLeftButton = { [weak self] down in
            guard let self else { return }
            guard !down || self.isProcessingActive() else { return }
            self.trackpad.setLeftButton(down: down)
        }
        latchCoordinator.onZoomStep = { [weak self] step in
            self?.handleZoom(step)
        }
        latchCoordinator.onStateChanged = { [weak self] action in
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.isProcessingActive() || action == nil else { return }
                self.bimanualClutchActive = action != nil
                if let action {
                    self.lastActionText = "🔒 \(self.displayName(for: action))"
                }
            }
        }

        // Hot path: do not call CGPreflightPostEventAccess at 120Hz. Permission is checked when
        // enabling/refreshing the app; posting without permission is harmlessly ignored by macOS.
        trackpadEngine.onPointerDelta = { [weak self] dx, dy in
            guard let self, self.isProcessingActive() else { return }
            self.trackpad.movePointer(deltaX: dx, deltaY: dy)
        }
        trackpadEngine.onLeftButton = { [weak self] down in
            guard let self else { return }
            guard !down || self.isProcessingActive() else { return }
            self.latchCoordinator.observeLeftButton(
                down,
                timestamp: ProcessInfo.processInfo.systemUptime
            )
        }
        trackpadEngine.onScrollDelta = { [weak self] dx, dy in
            guard let self, self.isProcessingActive() else { return }
            self.latchCoordinator.observeScroll(
                deltaX: dx,
                deltaY: dy,
                timestamp: ProcessInfo.processInfo.systemUptime
            )
        }
        trackpadEngine.onSystemSwipe = { [weak self] direction in
            self?.handleSystemSwipe(direction)
        }
        trackpadEngine.onZoomStep = { [weak self] step in
            guard let self, self.isProcessingActive() else { return }
            self.latchCoordinator.observeZoomStep(
                step,
                timestamp: ProcessInfo.processInfo.systemUptime
            )
        }
        trackpadEngine.onCalibrationChanged = { [weak self] progress, baseline in
            guard let self else { return }
            self.calibrationProgress = min(max(progress, 0), 1)
            if let baseline {
                self.personalPalmScale = baseline
                self.defaults.set(baseline, forKey: Keys.personalPalmScale)
            }
        }
        trackpadEngine.onTrackingTelemetry = { [weak self] fps, stability, gain, latency in
            guard let self, self.isProcessingActive() else { return }
            self.visionFPS = fps
            self.trackingStability = stability
            self.distanceGain = gain
            self.visionLatencyMS = latency * 1000
        }
        trackpadEngine.onPointerMotionPhaseChanged = { [weak self] phase in
            guard let self, self.isProcessingActive() else { return }
            self.pointerMotionPhase = phase
        }
        trackpadEngine.onScrollMotionPhaseChanged = { [weak self] phase in
            guard let self, self.isProcessingActive() else { return }
            self.scrollMotionPhase = phase
        }
        trackpadEngine.onContinuityTelemetry = { [weak self] continuity, dropped, hold, recoveryFrames in
            guard let self, self.isProcessingActive() else { return }
            self.trackingContinuity = continuity
            self.droppedObservationCount = dropped
            self.predictionHoldMS = hold * 1000
            self.lastRecoveryFrames = recoveryFrames
        }
        trackpadEngine.onInteractionChanged = { [weak self] interaction in
            guard let self else { return }
            guard self.isProcessingActive() || interaction == .idle else { return }
            self.latchCoordinator.observeInteraction(interaction)
            self.trackpadInteraction = interaction
            switch interaction {
            case .idle:
                if self.controlMode == .trackpad { self.lastActionText = "等待触控板手势" }
            case .pointer:
                self.lastActionText = "☝️ 一指移动指针"
            case .dragging:
                self.lastActionText = "🤏 捏合按下 / 拖拽"
            case .scrolling:
                self.lastActionText = "✌️ 双指连续滚动"
            case .zooming:
                self.lastActionText = "✌️ 双指张合缩放"
            case .systemSwipe:
                self.lastActionText = "多指系统手势"
            }
            self.updateHUDForInteraction(interaction)
        }

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshPermissions()
        }

        detector.setMaximumHandCount(bimanualAssistEnabled ? 2 : 1)
        applyPageGestureConfiguration()
        applyTrackpadConfiguration()
    }

    deinit {
        latchCoordinator.reset()
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    func toggleRunning(_ enabled: Bool) {
        enabled ? start() : stop()
    }

    func start() {
        guard !isRunning else { return }
        runIntentGeneration &+= 1
        let generation = runIntentGeneration
        lastError = nil
        refreshPermissions()

        PermissionManager.requestCamera { [weak self] granted in
            guard let self else { return }
            DispatchQueue.main.async {
                guard generation == self.runIntentGeneration else { return }
                self.cameraPermission = granted

                guard granted else {
                    self.isRunning = false
                    self.lastError = "需要摄像头权限才能识别手势。"
                    return
                }

                if !PermissionManager.postEventAuthorized && !self.hasRequestedAccessibilityThisLaunch {
                    self.hasRequestedAccessibilityThisLaunch = true
                    _ = PermissionManager.requestInputControl()
                }
                self.refreshPermissions()
                self.resetRecognitionState()
                self.beginProcessingSession()
                self.camera.start()
                self.isRunning = true
            }
        }
    }

    func stop() {
        runIntentGeneration &+= 1
        endProcessingSession()
        keyboard.cancelPendingEvents()
        camera.stop()
        gestureEngine.reset()
        staticGestureEngine.reset()
        latchCoordinator.reset()
        trackpadEngine.reset()
        trackpad.setLeftButton(down: false)
        trackpad.resetMotionState()
        isRunning = false
        resetPublishedTrackingState()
        resetHandAssignmentState()
    }

    func refreshPermissions() {
        cameraPermission = PermissionManager.cameraAuthorized
        accessibilityPermission = PermissionManager.postEventAuthorized
        accessibilityTrusted = PermissionManager.accessibilityTrusted
        inputControlState = PermissionManager.inputControlState
    }

    func requestAccessibility() {
        hasRequestedAccessibilityThisLaunch = true
        _ = PermissionManager.requestInputControl()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.refreshPermissions()
        }
    }

    func relaunchForPermission() {
        let appURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    self.lastError = "重新启动失败：\(error.localizedDescription)"
                    return
                }
                NSApplication.shared.terminate(nil)
            }
        }
    }

    func openCameraSettings() {
        PermissionManager.openCameraPrivacySettings()
    }

    func openAccessibilitySettings() {
        PermissionManager.openAccessibilityPrivacySettings()
    }

    func setBinding(_ action: KeyActionPreset, for direction: GestureDirection) {
        bindings[direction] = action
    }

    @discardableResult
    func addCurrentStaticGesture(name: String, action: KeyActionPreset) -> Bool {
        guard let pattern = currentFingerPattern, handDetected else {
            lastError = "没有稳定识别到手势，请把手保持在摄像头画面中再捕获。"
            return false
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "请先输入手势名称。"
            return false
        }
        guard !customGestures.contains(where: { $0.pattern == pattern }) else {
            lastError = "这个手指组合已经存在，请先删除或修改已有手势。"
            return false
        }
        customGestures.append(CustomStaticGesture(name: trimmed, pattern: pattern, action: action))
        lastError = nil
        return true
    }

    func deleteCustomGesture(_ id: UUID) {
        customGestures.removeAll { $0.id == id }
    }

    func setCustomGestureEnabled(_ id: UUID, enabled: Bool) {
        guard let index = customGestures.firstIndex(where: { $0.id == id }) else { return }
        customGestures[index].enabled = enabled
    }

    func setCustomGestureAction(_ id: UUID, action: KeyActionPreset) {
        guard let index = customGestures.firstIndex(where: { $0.id == id }) else { return }
        customGestures[index].action = action
    }

    func resetPersonalCalibration() {
        defaults.removeObject(forKey: Keys.personalPalmScale)
        personalPalmScale = nil
        calibrationProgress = 0
        trackpadEngine.resetPersonalCalibration()
        applyTrackpadConfiguration()
        lastActionText = "个人标定已重置，请自然伸出一根食指并保持约 1~2 秒"
    }

    func quit() {
        stop()
        NSApplication.shared.terminate(nil)
    }

    @discardableResult
    private func beginProcessingSession() -> UInt64 {
        processingStateLock.lock()
        processingGeneration &+= 1
        processingEnabled = true
        let generation = processingGeneration
        processingStateLock.unlock()
        return generation
    }

    private func endProcessingSession() {
        processingStateLock.lock()
        processingGeneration &+= 1
        processingEnabled = false
        processingStateLock.unlock()
    }

    private func activeProcessingGeneration() -> UInt64? {
        processingStateLock.lock()
        let generation = processingEnabled ? processingGeneration : nil
        processingStateLock.unlock()
        return generation
    }

    private func isProcessingGenerationCurrent(_ generation: UInt64) -> Bool {
        processingStateLock.lock()
        let current = processingEnabled && processingGeneration == generation
        processingStateLock.unlock()
        return current
    }

    private func isProcessingActive() -> Bool {
        processingStateLock.lock()
        let active = processingEnabled
        processingStateLock.unlock()
        return active
    }

    private func process(
        _ sampleBuffer: CMSampleBuffer,
        capturedAt: TimeInterval,
        generation: UInt64
    ) {
        guard isProcessingGenerationCurrent(generation) else { return }

        // V1.2: use camera-delivery time as the observation timestamp. Vision runs on another queue,
        // so using “Vision start time” would hide mailbox waiting and distort velocity when inference
        // duration varies. processingLatency now measures capture-delivery -> completed pose result.
        let poses = detector.detectHands(in: sampleBuffer)
        guard isProcessingGenerationCurrent(generation) else { return }

        let processedTimestamp = ProcessInfo.processInfo.systemUptime
        let processingLatency = max(0, processedTimestamp - capturedAt)
        let timestamp = capturedAt

        let assigned = assignHands(poses, timestamp: timestamp)
        let primaryPose = assigned.primary
        let secondaryPose = assigned.secondary
        guard isProcessingGenerationCurrent(generation) else { return }

        if controlMode == .trackpad {
            updateBimanualAssist(secondaryPose, timestamp: timestamp)
        } else {
            latchCoordinator.reset()
            clearLeftHoldTrackingState()
        }
        guard isProcessingGenerationCurrent(generation) else { return }

        guard let pose = primaryPose else {
            let continuityHolding: Bool
            if controlMode == .trackpad {
                continuityHolding = trackpadEngine.observationMissed(timestamp: timestamp)
            } else {
                continuityHolding = false
                gestureEngine.reset()
                staticGestureEngine.process(pattern: nil, timestamp: timestamp, confidence: 0)
            }

            if timestamp - lastUIUpdate > 0.10 {
                lastUIUpdate = timestamp
                let handCount = poses.count
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isProcessingGenerationCurrent(generation) else { return }
                    self.detectedHandCount = handCount
                    self.secondaryHandDetected = secondaryPose != nil
                    self.handDetected = continuityHolding
                    if continuityHolding {
                        self.handConfidence *= 0.88
                    } else {
                        self.handConfidence = 0
                        self.currentFingerPattern = nil
                    }
                }
            }
            return
        }

        switch controlMode {
        case .page:
            gestureEngine.process(
                HandSample(
                    x: pose.centerX,
                    y: pose.centerY,
                    timestamp: timestamp,
                    confidence: pose.confidence
                )
            )
            staticGestureEngine.process(
                pattern: pose.fingerPattern,
                timestamp: timestamp,
                confidence: pose.confidence
            )

        case .trackpad:
            trackpadEngine.process(
                TrackpadSample(
                    centerX: pose.centerX,
                    centerY: pose.centerY,
                    pointerX: pose.pointerX,
                    pointerY: pose.pointerY,
                    scrollX: pose.scrollX,
                    scrollY: pose.scrollY,
                    pointerObservationConfidence: pose.pointerObservationConfidence,
                    scrollObservationConfidence: pose.scrollObservationConfidence,
                    palmScale: pose.palmScale,
                    pinchRatio: pose.pinchRatio,
                    twoFingerSpan: pose.twoFingerSpan,
                    fingerPattern: pose.fingerPattern,
                    timestamp: timestamp,
                    processingLatency: processingLatency,
                    confidence: pose.confidence
                )
            )
        }

        if timestamp - lastUIUpdate > 0.10 {
            lastUIUpdate = timestamp
            let handCount = poses.count
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isProcessingGenerationCurrent(generation) else { return }
                self.detectedHandCount = handCount
                self.secondaryHandDetected = secondaryPose != nil
                self.handDetected = true
                self.handConfidence = pose.confidence
                self.currentFingerPattern = pose.fingerPattern
            }
        }
    }

    // MARK: - V1.4 two-hand assignment / left Pinch Hold

    private func assignHands(
        _ poses: [HandPoseResult],
        timestamp: TimeInterval
    ) -> (primary: HandPoseResult?, secondary: HandPoseResult?) {
        guard !poses.isEmpty else { return (nil, nil) }

        func distance(_ pose: HandPoseResult, _ track: (x: Double, y: Double, timestamp: TimeInterval)?) -> Double {
            guard let track else { return .infinity }
            return hypot(pose.centerX - track.x, pose.centerY - track.y)
        }

        let recentWindow = 0.45
        let primaryRecent = primaryHandCenter.map { timestamp - $0.timestamp <= recentWindow } ?? false
        let secondaryRecent = secondaryHandCenter.map { timestamp - $0.timestamp <= recentWindow } ?? false
        var primary: HandPoseResult?
        var secondary: HandPoseResult?

        if poses.count >= 2, bimanualAssistEnabled {
            let right = poses.first { pose in pose.handedness == .right }
            let left = poses.first { pose in pose.handedness == .left }

            if let right, let left, right.centerX != left.centerX || right.centerY != left.centerY {
                primary = right
                secondary = left
            } else if let right {
                primary = right
                secondary = poses.first { $0.centerX != right.centerX || $0.centerY != right.centerY }
            } else if let left {
                secondary = left
                primary = poses.first { $0.centerX != left.centerX || $0.centerY != left.centerY }
            }
        }

        if primary == nil, secondary == nil, poses.count >= 2 {
            let a = poses[0]
            let b = poses[1]
            if primaryRecent, secondaryRecent {
                let direct = distance(a, primaryHandCenter) + distance(b, secondaryHandCenter)
                let swapped = distance(b, primaryHandCenter) + distance(a, secondaryHandCenter)
                if direct <= swapped {
                    primary = a; secondary = b
                } else {
                    primary = b; secondary = a
                }
            } else if primaryRecent {
                if distance(a, primaryHandCenter) <= distance(b, primaryHandCenter) {
                    primary = a; secondary = b
                } else {
                    primary = b; secondary = a
                }
            } else {
                let scoreA = a.confidence + max(a.pointerObservationConfidence, a.scrollObservationConfidence) * 0.65
                let scoreB = b.confidence + max(b.pointerObservationConfidence, b.scrollObservationConfidence) * 0.65
                if scoreA >= scoreB { primary = a; secondary = b } else { primary = b; secondary = a }
            }
        } else if poses.count == 1, let only = poses.first {
            if bimanualAssistEnabled,
               only.handedness == .left,
               primaryRecent {
                secondary = only
            } else if bimanualAssistEnabled, primaryRecent, secondaryRecent {
                let dp = distance(only, primaryHandCenter)
                let ds = distance(only, secondaryHandCenter)
                if ds + 0.045 < dp {
                    secondary = only
                } else {
                    primary = only
                }
            } else {
                primary = only
            }
        }

        if let primary {
            primaryHandCenter = (primary.centerX, primary.centerY, timestamp)
        } else if let track = primaryHandCenter, timestamp - track.timestamp > recentWindow {
            primaryHandCenter = nil
        }

        if let secondary {
            secondaryHandCenter = (secondary.centerX, secondary.centerY, timestamp)
        } else if let track = secondaryHandCenter, timestamp - track.timestamp > recentWindow {
            secondaryHandCenter = nil
        }

        return (primary, secondary)
    }

    private func updateBimanualAssist(_ secondary: HandPoseResult?, timestamp: TimeInterval) {
        guard bimanualAssistEnabled else {
            latchCoordinator.reset()
            clearLeftHoldTrackingState()
            publishLeftHoldState(.idle, candidateAction: nil)
            return
        }

        guard let secondary,
              secondary.handedness == .left,
              secondary.confidence >= 0.38,
              let ratio = secondary.pinchRatio,
              ratio.isFinite else {
            handleMissingLeftHand(timestamp: timestamp)
            return
        }

        leftHandMissingSince = nil

        if ratio >= 0.58 {
            leftHoldArmed = true
        }

        switch leftHoldStateInternal {
        case .idle:
            leftHoldReleaseSince = nil
            guard leftHoldArmed, ratio <= 0.32,
                  let candidate = latchCoordinator.currentLatchableAction(
                    timestamp: timestamp,
                    zoomEnabled: twoFingerZoomEnabled
                  ) else {
                return
            }
            leftHoldCandidateSince = timestamp
            leftHoldCandidateAction = candidate
            publishLeftHoldState(.candidate(progress: 0), candidateAction: candidate)

        case .candidate:
            if ratio >= 0.48 {
                cancelLeftHoldCandidate(rearm: ratio >= 0.58)
                return
            }
            guard let since = leftHoldCandidateSince else {
                cancelLeftHoldCandidate(rearm: false)
                return
            }
            let progress = min(max((timestamp - since) / leftHoldDuration, 0), 1)
            publishLeftHoldState(.candidate(progress: progress), candidateAction: leftHoldCandidateAction)
            guard timestamp - since >= leftHoldDuration else { return }

            if latchCoordinator.latchCurrentAction(timestamp: timestamp, zoomEnabled: twoFingerZoomEnabled),
               let action = latchCoordinator.latchedAction {
                leftHoldArmed = false
                leftHoldCandidateSince = nil
                leftHoldCandidateAction = nil
                publishLeftHoldState(.latched(action), candidateAction: nil)
            } else {
                cancelLeftHoldCandidate(rearm: false)
            }

        case .latched:
            if ratio >= 0.48 {
                if leftHoldReleaseSince == nil { leftHoldReleaseSince = timestamp }
                if let since = leftHoldReleaseSince,
                   timestamp - since >= leftReleaseDebounce {
                    latchCoordinator.release(timestamp: timestamp)
                    clearLeftHoldTrackingState()
                    leftHoldArmed = ratio >= 0.58
                    publishLeftHoldState(.idle, candidateAction: nil)
                }
            } else {
                leftHoldReleaseSince = nil
            }
        }
    }

    private func handleMissingLeftHand(timestamp: TimeInterval) {
        guard leftHoldStateInternal != .idle else {
            leftHandMissingSince = nil
            return
        }
        if leftHandMissingSince == nil { leftHandMissingSince = timestamp }
        guard let since = leftHandMissingSince,
              timestamp - since >= leftMissingReleaseDelay else { return }
        latchCoordinator.release(timestamp: timestamp)
        clearLeftHoldTrackingState()
        publishLeftHoldState(.idle, candidateAction: nil)
    }

    private func cancelLeftHoldCandidate(rearm: Bool) {
        leftHoldCandidateSince = nil
        leftHoldCandidateAction = nil
        leftHoldReleaseSince = nil
        leftHoldArmed = rearm
        publishLeftHoldState(.idle, candidateAction: nil)
    }

    private func clearLeftHoldTrackingState() {
        leftHoldArmed = false
        leftHoldCandidateSince = nil
        leftHoldReleaseSince = nil
        leftHandMissingSince = nil
        leftHoldCandidateAction = nil
        leftHoldStateInternal = .idle
    }

    private func publishLeftHoldState(_ state: LeftHoldState, candidateAction: LatchedAction?) {
        leftHoldStateInternal = state
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.leftHoldState = state
            switch state {
            case .idle:
                self.bimanualClutchActive = false
                self.updateHUDForInteraction(self.trackpadInteraction)
            case let .candidate(progress):
                let actionName = candidateAction.map(self.displayName(for:)) ?? self.trackpadInteraction.displayName
                self.hudState = GestureHUDState(
                    mode: .holdCandidate,
                    leftHandText: "Left: HOLD \(Int(progress * 100))%",
                    rightHandText: "Right: Active",
                    actionText: "Locking \(actionName)",
                    holdProgress: progress,
                    isLocked: false
                )
            case let .latched(action):
                self.bimanualClutchActive = true
                self.hudState = GestureHUDState(
                    mode: .latched,
                    leftHandText: "Left: HOLD",
                    rightHandText: "Right: FREE",
                    actionText: self.displayName(for: action),
                    holdProgress: 1,
                    isLocked: true
                )
            }
        }
    }

    private func resetHandAssignmentState() {
        primaryHandCenter = nil
        secondaryHandCenter = nil
        clearLeftHoldTrackingState()
    }

    private func handlePageGesture(_ direction: GestureDirection) {
        // DirectionalGestureEngine fires from the Vision queue. Keep ObservableObject mutations and
        // binding reads on main so SwiftUI never receives background publications or races an edit.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isProcessingActive() else { return }
            self.lastGesture = direction
            let action = self.bindings[direction]
            self.lastActionText = action.displayName

            self.refreshPermissions()
            guard self.accessibilityPermission else {
                self.lastError = "已识别手势，但当前进程尚未获得“辅助功能”权限。若刚刚开启，请重新启动 GestureControl。"
                return
            }
            self.keyboard.send(action)
        }
    }

    private func handleStaticGesture(_ gesture: CustomStaticGesture) {
        // StaticGestureEngine also runs on the Vision path. Serialize UI state and configuration
        // access through main, and re-check processing state after the queue hop before posting input.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isProcessingActive() else { return }
            self.lastGesture = nil
            self.lastActionText = "\(gesture.name) → \(gesture.action.displayName)"
            self.gestureEngine.reset()

            self.refreshPermissions()
            guard self.accessibilityPermission else {
                self.lastError = "已识别自定义手势，但当前进程尚未获得“辅助功能”权限。"
                return
            }
            self.keyboard.send(gesture.action)
        }
    }

    private func handleSystemSwipe(_ direction: GestureDirection) {
        guard latchCoordinator.latchedAction == nil else { return }
        guard isProcessingActive(), PermissionManager.postEventAuthorized else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isProcessingActive() else { return }
            self.lastGesture = direction
            switch direction {
            case .left:
                self.lastActionText = "三/四指左滑 → 下一个桌面"
                self.keyboard.switchToNextSpace()
            case .right:
                self.lastActionText = "三/四指右滑 → 上一个桌面"
                self.keyboard.switchToPreviousSpace()
            case .up:
                self.lastActionText = "三/四指上滑 → Mission Control"
                self.keyboard.missionControl()
            case .down:
                self.lastActionText = "三/四指下滑 → App Exposé"
                self.keyboard.appExpose()
            }
        }
    }

    private func handleZoom(_ step: Int) {
        guard isProcessingActive(), PermissionManager.postEventAuthorized else { return }
        keyboard.zoom(steps: step)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isProcessingActive() else { return }
            self.lastActionText = step > 0 ? "双指张开 → 连续放大" : "双指合拢 → 连续缩小"
        }
    }

    private func updateHUDForInteraction(_ interaction: TrackpadInteraction) {
        switch leftHoldState {
        case .candidate, .latched:
            return
        case .idle:
            break
        }
        let mode: GestureHUDMode = interaction == .idle ? .idle : .active
        hudState = GestureHUDState(
            mode: mode,
            leftHandText: bimanualAssistEnabled ? "Left: Ready" : "Left: Off",
            rightHandText: interaction == .idle ? "Right: Ready" : "Right: Active",
            actionText: interaction.displayName,
            holdProgress: nil,
            isLocked: false
        )
    }

    private func displayName(for action: LatchedAction) -> String {
        switch action {
        case let .scroll(dx, dy):
            if abs(dy) >= abs(dx) { return dy >= 0 ? "Scroll Down" : "Scroll Up" }
            return dx >= 0 ? "Scroll Right" : "Scroll Left"
        case .drag:
            return "Drag"
        case let .zoom(step):
            return step > 0 ? "Zoom In" : "Zoom Out"
        }
    }

    private func resetPublishedTrackingState() {
        handDetected = false
        handConfidence = 0
        currentFingerPattern = nil
        trackpadInteraction = .idle
        visionFPS = 0
        trackingStability = 1
        distanceGain = 1
        visionLatencyMS = 0
        pointerMotionPhase = .idle
        scrollMotionPhase = .idle
        trackingContinuity = 1
        droppedObservationCount = 0
        predictionHoldMS = 0
        lastRecoveryFrames = 0
        detectedHandCount = 0
        secondaryHandDetected = false
        bimanualClutchActive = false
        leftHoldState = .idle
        hudState = GestureHUDState(
            mode: .idle,
            leftHandText: "Left: Ready",
            rightHandText: "Right: Ready",
            actionText: "Gesture Ready",
            holdProgress: nil,
            isLocked: false
        )
    }

    private func resetRecognitionState() {
        // Mode switches and restarts invalidate queued shortcuts from the previous recognition epoch.
        keyboard.cancelPendingEvents()
        gestureEngine.reset()
        staticGestureEngine.reset()
        latchCoordinator.reset()
        trackpadEngine.reset()
        trackpad.setLeftButton(down: false)
        trackpad.resetMotionState()
        lastGesture = nil
        lastActionText = controlMode == .trackpad ? "等待触控板手势" : "等待翻页手势"
        resetPublishedTrackingState()
        resetHandAssignmentState()
    }

    private func applyPageGestureConfiguration() {
        let clampedSensitivity = min(max(sensitivity, 0), 1)
        let minimumDistance = 0.29 - (0.17 * clampedSensitivity)
        let minimumVelocity = 0.48 - (0.18 * clampedSensitivity)

        var config = DirectionalGestureEngine.Configuration()
        config.minimumDistance = minimumDistance
        config.minimumVelocity = minimumVelocity
        config.cooldown = cooldown
        gestureEngine.update(configuration: config)
    }

    private func applyTrackpadConfiguration() {
        var config = TrackpadGestureEngine.Configuration()
        config.pointerSensitivity = min(max(pointerSensitivity, 0.35), 2.5)
        config.scrollSensitivity = min(max(scrollSensitivity, 0.35), 2.5)
        config.inertia = min(max(scrollInertia, 0), 1)
        config.responsiveness = min(max(trackingResponsiveness, 0), 1)
        config.precisionAssist = min(max(precisionAssist, 0), 1)
        config.naturalScrolling = naturalScrolling
        config.twoFingerZoomEnabled = twoFingerZoomEnabled
        config.scrollRetractionSuppressionEnabled = scrollRetractionSuppressionEnabled
        config.personalPalmScale = personalPalmScale
        trackpadEngine.update(configuration: config)
    }

    private func saveBindings() {
        if let data = try? JSONEncoder().encode(bindings) {
            defaults.set(data, forKey: Keys.bindings)
        }
    }

    private func saveCustomGestures() {
        if let data = try? JSONEncoder().encode(customGestures) {
            defaults.set(data, forKey: Keys.customGestures)
        }
    }

    private enum Keys {
        static let controlMode = "gesture.controlMode"
        static let sensitivity = "gesture.sensitivity"
        static let cooldown = "gesture.cooldown"
        static let pointerSensitivity = "trackpad.pointerSensitivity"
        static let scrollSensitivity = "trackpad.scrollSensitivity"
        static let scrollInertia = "trackpad.scrollInertia"
        static let naturalScrolling = "trackpad.naturalScrolling"
        static let twoFingerZoomEnabled = "trackpad.twoFingerZoomEnabled.v1"
        static let scrollRetractionSuppressionEnabled = "trackpad.scrollRetractionSuppression.v1"
        static let bimanualAssistEnabled = "trackpad.bimanualAssistEnabled.v1"
        static let trackingResponsiveness = "trackpad.trackingResponsiveness"
        static let precisionAssist = "trackpad.precisionAssist"
        static let personalPalmScale = "trackpad.personalPalmScale.v1"
        static let bindings = "gesture.bindings"
        static let customGestures = "gesture.customStaticGestures"
    }
}
