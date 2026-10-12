import Foundation

/// Compiles and executes the actual production coordinator / Hold FSM with small model stubs.
/// This is a behavioral regression test, rather than a source-string-only smoke check.
// Verify the real AppController wiring, keyboard event dispatch, and user toggle.
let appText = try String(contentsOfFile: "GestureControl/AppController.swift", encoding: .utf8)
let menuText = try String(contentsOfFile: "GestureControl/UI/MenuBarPanel.swift", encoding: .utf8)
guard appText.contains("processBimanualShortcut(pose, timestamp: timestamp, generation: generation)"),
      appText.contains("keyboard.send(keyCode: 8, flags: .maskCommand)"),
      appText.contains("keyboard.send(keyCode: 9, flags: .maskCommand)"),
      appText.contains("rightPose.handedness == .right"),
      appText.contains("trackpad.bimanualShortcutsEnabled.v1"),
      menuText.contains("双手复制 / 粘贴快捷手势") else {
    fatalError("Bimanual shortcut integration wiring incomplete")
}

let sourcePath = "GestureControl/Gesture/BimanualLatchCoordinator.swift"
guard let coordinatorSource = try? String(contentsOfFile: sourcePath, encoding: .utf8) else {
    fatalError("Missing \(sourcePath)")
}
let fixture = """
import Foundation

enum TrackpadInteraction: Equatable {
    case idle, pointer, dragging, scrolling, zooming, systemSwipe
}
enum LatchedAction: Equatable {
    case scroll(deltaX: Double, deltaY: Double)
    case drag
    case zoom(step: Int)
}
enum LeftHoldState: Equatable {
    case idle
    case candidate(progress: Double)
    case latched(LatchedAction)
}
struct FingerPattern: Equatable {
    let thumb: Bool
    let index: Bool
    let middle: Bool
    let ring: Bool
    let little: Bool
    var isPointerPose: Bool { index && !middle && !ring && !little }
    var isFistPose: Bool { !thumb && !index && !middle && !ring && !little }
    var isOpenPalmPose: Bool { index && middle && ring && little }
}

\(coordinatorSource)

func require(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}

let scroll = LatchedAction.scroll(deltaX: 0, deltaY: 3)
var hold = LeftHoldGestureStateMachine()
require(hold.advance(leftPinchRatio: 0.2, timestamp: 1.0, latchableAction: scroll) == .none,
        "Closing unarmed left hand must not start Hold")
require(hold.state == .idle, "Unarmed Hold entered candidate state")
_ = hold.advance(leftPinchRatio: 0.65, timestamp: 1.1, latchableAction: nil)
_ = hold.advance(leftPinchRatio: 0.25, timestamp: 1.2, latchableAction: scroll)
require(hold.isEngaged && hold.pendingAction == scroll, "Hold did not capture the scroll snapshot")
_ = hold.advance(leftPinchRatio: 0.2, timestamp: 1.3, latchableAction: .zoom(step: 1))
require(hold.pendingAction == scroll, "Right-hand switch replaced pending snapshot")
_ = hold.advance(leftPinchRatio: nil, timestamp: 1.35, latchableAction: nil)
_ = hold.advance(leftPinchRatio: 0.2, timestamp: 1.41, latchableAction: nil)
require(hold.advance(leftPinchRatio: 0.2, timestamp: 1.52, latchableAction: nil) == .none,
        "Dropout incorrectly counted as uninterrupted Hold")
require(hold.advance(leftPinchRatio: 0.2, timestamp: 1.57, latchableAction: nil) == .latch(scroll),
        "300 ms continuous Hold did not latch original action")
require(hold.state == .latched(scroll), "Latched state does not preserve scroll direction")
_ = hold.advance(leftPinchRatio: 0.51, timestamp: 1.6, latchableAction: nil)
require(hold.advance(leftPinchRatio: 0.51, timestamp: 1.69, latchableAction: nil) == .release,
        "80 ms release debounce did not release")
require(hold.state == .idle, "Hold remained latched after release")
_ = hold.advance(leftPinchRatio: 0.2, timestamp: 1.8, latchableAction: scroll)
require(hold.state == .idle, "Still-closed fingers immediately relatched without rearming")
_ = hold.advance(leftPinchRatio: 0.60, timestamp: 2.0, latchableAction: nil)
_ = hold.advance(leftPinchRatio: 0.20, timestamp: 2.1, latchableAction: scroll)
_ = hold.advance(leftPinchRatio: nil, timestamp: 2.2, latchableAction: nil)
_ = hold.advance(leftPinchRatio: nil, timestamp: 2.46, latchableAction: nil)
require(hold.state == .idle, "Missing left hand did not reset candidate")
require(hold.advance(leftPinchRatio: 0.2, timestamp: 2.47, latchableAction: scroll) == .none,
        "Re-entry without open-arm incorrectly started Hold")
require(hold.state == .idle, "Re-entry became candidate without open-arm")

hold.reset()
_ = hold.advance(leftPinchRatio: 0.62, timestamp: 3.0, latchableAction: nil)
_ = hold.advance(leftPinchRatio: 0.2, timestamp: 3.1, latchableAction: scroll)
_ = hold.advance(leftPinchRatio: 0.2, timestamp: 3.24, latchableAction: nil)
require(hold.advance(leftPinchRatio: 0.2, timestamp: 3.41, latchableAction: nil) == .latch(scroll),
        "Expected second latch")
_ = hold.advance(leftPinchRatio: nil, timestamp: 3.5, latchableAction: nil)
require(hold.advance(leftPinchRatio: nil, timestamp: 3.76, latchableAction: nil) == .release,
        "Sustained left dropout failed to release")
hold.reset()
hold.reset()
require(hold.state == .idle, "Repeated reset is not idempotent")

let pointer = FingerPattern(thumb: false, index: true, middle: false, ring: false, little: false)
let fist = FingerPattern(thumb: false, index: false, middle: false, ring: false, little: false)
let palm = FingerPattern(thumb: true, index: true, middle: true, ring: true, little: true)
var shortcuts = BimanualShortcutRecognizer()
func observe(_ pose: FingerPattern?, _ at: Double,
             enabled: Bool = true, right: Bool = true,
             latched: LatchedAction? = .scroll(deltaX: 0, deltaY: 3),
             dragging: Bool = false) -> BimanualShortcut? {
    shortcuts.advance(rightPattern: pose, timestamp: at, enabled: enabled,
                      latchedAction: latched, rightHandConfirmed: right, rightDragging: dragging)
}
require(observe(pointer, 0.0, enabled: false) == nil, "Disabled shortcuts fired")
require(observe(fist, 0.1) == nil, "Fist must require explicit neutral rearm")
require(observe(pointer, 0.2) == nil, "Neutral arming must not issue shortcut")
require(observe(pointer, 0.42) == nil, "Neutral arming must not issue shortcut")
require(observe(fist, 0.5) == nil, "Copy fired before confirmation")
require(observe(fist, 0.6) == nil, "Copy fired before 500ms")
require(observe(fist, 0.7) == nil, "Copy fired before 500ms")
require(observe(fist, 0.8) == nil, "Copy fired before 500ms")
require(observe(fist, 0.9) == nil, "Copy fired before 500ms")
require(observe(fist, 1.02) == .copy, "500ms fist did not copy")
require(observe(fist, 1.10) == nil, "Held fist repeated Command-C")
require(observe(palm, 1.20) == nil, "Direct fist to palm must not paste")
require(observe(palm, 1.30) == nil, "Direct fist to palm must stay disarmed")
require(observe(pointer, 1.40) == nil, "Return pointer must not paste")
require(observe(pointer, 1.61) == nil, "Rearm dwell must not paste")
require(observe(palm, 1.72) == nil, "Paste candidate begins")
require(observe(palm, 1.82) == nil, "Premature paste")
require(observe(palm, 1.92) == nil, "Premature paste")
require(observe(palm, 2.02) == nil, "Premature paste")
require(observe(palm, 2.13) == nil, "Premature paste")
require(observe(palm, 2.24) == .paste, "500ms palm did not paste")
require(observe(palm, 2.34) == nil, "Held palm repeated Paste")

shortcuts.reset()
require(observe(pointer, 3.0) == nil, "Reset must require neutral")
require(observe(pointer, 3.21) == nil, "Neutral completed")
require(observe(fist, 3.30) == nil, "Candidate started")
require(observe(fist, 3.42) == nil, "Premature candidate")
require(observe(nil, 3.52) == nil, "Missing pattern cannot copy")
require(observe(fist, 3.61) == nil, "Occlusion should reset candidate")
require(observe(fist, 3.72) == nil, "Occlusion should not accumulate")
require(observe(fist, 3.84) == nil, "Occlusion should not accumulate")
require(observe(fist, 4.02) == nil, "Occlusion should not accumulate")
require(observe(fist, 4.13) == .copy, "Reacquired fist should require new dwell")

shortcuts.reset()
require(observe(pointer, 5.0, right: false) == nil, "Unknown right hand must be rejected")
require(observe(fist, 5.15, right: false) == nil, "Unknown right hand must never issue copy")
require(observe(pointer, 5.30) == nil, "Arming restart")
require(observe(pointer, 5.52) == nil, "Arming restart")
require(observe(fist, 5.60, latched: .drag) == nil, "Latched drag cannot send clipboard keys")
require(observe(fist, 5.70, dragging: true) == nil, "Active right mouse drag cannot copy")
require(observe(fist, 5.80, latched: nil) == nil, "No left Hold cannot issue keys")
shortcuts.reset()
print("PASS: V1.5 shortcut dwell/rearm, anti-repeat, missing-hand and drag gate")

let coordinator = BimanualLatchCoordinator()
let callbackLock = NSLock()
var scrollOutput = [(Double, Double)]()
var buttonOutput = [Bool]()
coordinator.onScrollDelta = { dx, dy in
    callbackLock.lock()
    scrollOutput.append((dx, dy))
    callbackLock.unlock()
}
coordinator.onLeftButton = { down in
    callbackLock.lock()
    buttonOutput.append(down)
    callbackLock.unlock()
}

coordinator.observeInteraction(.scrolling)
coordinator.observeScroll(deltaX: 0, deltaY: 3, timestamp: 10)
require(coordinator.currentLatchableAction(timestamp: 10.25, zoomEnabled: false) == nil,
        "Stale motion must never become a new latch candidate")
require(coordinator.currentLatchableAction(timestamp: 10.1, zoomEnabled: false) == scroll,
        "Fresh scroll candidate lost")
require(coordinator.latch(scroll, timestamp: 10.4, zoomEnabled: false),
        "Captured scroll snapshot should latch despite right-hand pose switching")
coordinator.observeInteraction(.pointer)
coordinator.observeScroll(deltaX: 0, deltaY: -12, timestamp: 10.5)
require(coordinator.latchedAction == scroll, "Right-hand motion changed frozen scroll direction")
coordinator.observeHoldHeartbeat(timestamp: ProcessInfo.processInfo.systemUptime)
Thread.sleep(forTimeInterval: 0.065)
callbackLock.lock()
let hadPositiveRepeat = scrollOutput.contains { $0.1 > 0 }
let leakedReverseScroll = scrollOutput.contains { $0.1 < 0 }
callbackLock.unlock()
require(hadPositiveRepeat, "Latched scroll did not repeat")
require(!leakedReverseScroll, "Right-hand scroll leaked against frozen scroll")
coordinator.release(timestamp: 11)
require(coordinator.latchedAction == nil, "Scroll release failed")

require(!coordinator.latch(.zoom(step: 1), timestamp: 11.1, zoomEnabled: false),
        "Zoom latched while user setting disabled")
require(!coordinator.latch(.scroll(deltaX: .nan, deltaY: 1), timestamp: 11.2, zoomEnabled: true),
        "Nonfinite source output was accepted")

coordinator.observeInteraction(.dragging)
coordinator.observeLeftButton(true, timestamp: 12)
require(coordinator.latch(.drag, timestamp: 12.1, zoomEnabled: false), "Drag lock failed")
coordinator.observeLeftButton(false, timestamp: 12.2)
callbackLock.lock()
let prematureUp = buttonOutput.last == false
callbackLock.unlock()
require(!prematureUp, "Right hand released a left-hand-latched drag")
Thread.sleep(forTimeInterval: 0.47)
require(coordinator.latchedAction == nil, "Camera-stall watchdog did not cancel drag")
callbackLock.lock()
let finalUp = buttonOutput.last == false
callbackLock.unlock()
require(finalUp, "Watchdog did not send the mandatory mouseUp")
coordinator.reset()
coordinator.reset()
print("PASS: V1.5 bimanual Hold FSM, snapshot locking, missing-hand safety, drag watchdog")
"""

let workingDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("bimanual-hold-regression-" + UUID().uuidString, isDirectory: true)
try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: workingDirectory) }
let mainFile = workingDirectory.appendingPathComponent("main.swift")
let binary = workingDirectory.appendingPathComponent("hold-regression")
try fixture.write(to: mainFile, atomically: true, encoding: .utf8)

func run(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    // Forward output directly so a compiler diagnostic is visible even on CI failures.
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        FileHandle.standardError.write(Data("Nested regression process failed: \(process.terminationStatus)\n".utf8))
        exit(1)
    }
}

let compiler = FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun")
    ? ["xcrun", "swiftc"] : ["swiftc"]
try run(compiler + [mainFile.path, "-o", binary.path])
try run([binary.path])
