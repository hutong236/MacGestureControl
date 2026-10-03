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

private func occurrences(of needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var cursor = haystack.startIndex
    while let range = haystack.range(of: needle, range: cursor..<haystack.endIndex) {
        count += 1
        cursor = range.upperBound
    }
    return count
}

let models = read("GestureControl/Models/GestureModels.swift")
let detector = read("GestureControl/Vision/HandPoseDetector.swift")

require(models.contains("enum Handedness: Equatable"), "Handedness model missing")
require(models.contains("case left, right, unknown"), "Handedness cases missing")
require(models.contains("enum LatchedAction: Equatable"), "LatchedAction model missing")
require(models.contains("enum LeftHoldState: Equatable"), "LeftHoldState model missing")
require(models.contains("enum GestureHUDMode: Equatable"), "GestureHUDMode model missing")
require(models.contains("struct GestureHUDState: Equatable"), "GestureHUDState model missing")
require(models.contains("var holdProgress: Double?"), "HUD hold progress missing")
require(models.contains("var isLocked: Bool"), "HUD locked state missing")
require(detector.contains("let handedness: Handedness"), "HandPoseResult handedness missing")
require(detector.contains("observation.chirality"), "Vision chirality mapping missing")
require(detector.contains("case .left"), "Left chirality mapping missing")
require(detector.contains("case .right"), "Right chirality mapping missing")
require(!detector.contains("centerX < 0.5") && !detector.contains("centerX > 0.5"), "Handedness must not be inferred from x-position")
print("PASS: V1.4 handedness and HUD models")

let coordinatorPath = "GestureControl/Gesture/BimanualLatchCoordinator.swift"
let coordinator = read(coordinatorPath)
require(coordinator.contains("final class BimanualLatchCoordinator"), "Latch coordinator missing")
require(coordinator.contains("func currentLatchableAction(timestamp: TimeInterval, zoomEnabled: Bool) -> LatchedAction?"), "Non-mutating latch candidate query missing")
require(coordinator.contains("func latchCurrentAction(timestamp: TimeInterval, zoomEnabled: Bool) -> Bool"), "Latch activation API missing")
require(coordinator.contains("let maximumSourceDelta = 22.0"), "Scroll source clamp missing")
require(coordinator.contains("1.0 / 60.0"), "60 Hz latched scroll cadence missing")
require(coordinator.contains("0.20"), "200 ms action freshness bound missing")
require(coordinator.contains("zoomRepeatInterval"), "Bounded zoom repeat interval missing")
require(coordinator.contains("onLeftButton?(false)"), "Latched drag final mouse-up missing")
require(coordinator.contains("guard let button = lastLeftButton, button.down else { return nil }"), "Ongoing drag must remain latchable after its initial mouseDown ages past 200 ms")
require(
    occurrences(of: "currentLatchedAction == .drag", in: coordinator) >= 3,
    "Latched drag must suppress conflicting mouse-up, scroll, and zoom output"
)
print("PASS: V1.4 latch coordinator source invariants")

let app = read("GestureControl/AppController.swift")
require(app.contains("let leftHoldDuration: TimeInterval = 0.30"), "300 ms left Hold threshold missing")
require(app.contains("let leftReleaseDebounce: TimeInterval = 0.08"), "80 ms Hold release debounce missing")
require(app.contains("let leftMissingReleaseDelay: TimeInterval = 0.25"), "250 ms missing-left safety release missing")
require(app.contains("ratio >= 0.58"), "Left Hold arm threshold missing")
require(app.contains("ratio <= 0.32"), "Left Hold close threshold missing")
require(app.contains("ratio >= 0.48"), "Left Hold release threshold missing")
require(app.contains("pose.handedness == .right"), "Physical right-hand primary routing missing")
require(app.contains("pose.handedness == .left"), "Physical left-hand modifier routing missing")
require(app.contains("latchCoordinator.observeScroll"), "Scroll output is not routed through latch coordinator")
require(app.contains("latchCoordinator.observeLeftButton"), "Drag output is not routed through latch coordinator")
require(app.contains("latchCoordinator.observeZoomStep"), "Zoom output is not routed through latch coordinator")
require(app.contains("latchCoordinator.reset()"), "Latch cleanup missing")
require(app.contains("updateBimanualAssist(secondaryPose, timestamp: processedTimestamp)"), "Hold/latch timing must share the system-uptime clock used by output snapshots")
require(!app.contains("updateBimanualAssist(secondaryPose, timestamp: timestamp)"), "Capture timestamps must not be compared with output callback timestamps")
require(app.contains("leftHandMissingSince = nil\n            leftHoldArmed = false\n            return"), "Idle left-hand loss must clear Hold arming before re-entry")
require(!app.contains("辅助手张开"), "Retired open-palm clutch mapping still present")
require(!app.contains("辅助手捏合 → 右键"), "Retired secondary-pinch right-click mapping still present")
require(!app.contains("trackpad.rightClick()"), "Secondary pinch must no longer post right click")
require(!app.contains("trackpadEngine.setExternalClutch"), "AppController still calls retired external clutch")
print("PASS: V1.4 left Hold orchestration invariants")

let hudView = read("GestureControl/UI/GestureHUDView.swift")
let hudWindow = read("GestureControl/UI/GestureHUDWindowController.swift")
let appRoot = read("GestureControl/GestureControlApp.swift")
let menu = read("GestureControl/UI/MenuBarPanel.swift")
let project = read("GestureControl.xcodeproj/project.pbxproj")
require(hudWindow.contains("isOpaque = false"), "HUD outer window must be transparent")
require(hudWindow.contains("backgroundColor = .clear"), "HUD clear window background missing")
require(hudWindow.contains("ignoresMouseEvents = true"), "HUD must be click-through")
require(hudWindow.contains(".nonactivatingPanel"), "HUD must use a non-activating panel")
require(hudWindow.contains("canBecomeKey: Bool { false }"), "HUD must not become key")
require(hudWindow.contains("canBecomeMain: Bool { false }"), "HUD must not become main")
require(hudWindow.contains(".canJoinAllSpaces"), "HUD must join all Spaces")
require(hudWindow.contains(".fullScreenAuxiliary"), "HUD must support full-screen auxiliary display")
require(hudView.contains("ultraThinMaterial"), "HUD translucent material missing")
require(appRoot.contains("GestureHUDWindowController.shared.bind"), "App root does not bind HUD to controller state")
require(menu.contains("gesture.hudEnabled.v1"), "Persisted HUD setting missing")
require(menu.contains("双手联动（左手 Hold 锁定）"), "New bimanual setting label missing")
require(menu.contains("显示透明 HUD"), "HUD toggle label missing")
require(project.contains("BimanualLatchCoordinator.swift in Sources"), "Latch coordinator not registered in Xcode project")
require(project.contains("GestureHUDView.swift in Sources"), "HUD view not registered in Xcode project")
require(project.contains("GestureHUDWindowController.swift in Sources"), "HUD window controller not registered in Xcode project")
print("PASS: V1.4 transparent HUD and project integration invariants")
