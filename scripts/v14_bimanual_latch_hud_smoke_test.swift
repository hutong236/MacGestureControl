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

print("PASS: V1.4 latch coordinator source invariants")
