import Foundation

/// Compiles and executes the actual production coordinator / Hold FSM with small model stubs.
/// This is a behavioral regression test, rather than a source-string-only smoke check.
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
require(hold.advance(leftPinchRatio: 0.2, timestamp: 3.41, latchableAction: nil) == .latch(scroll),
        "Expected second latch")
_ = hold.advance(leftPinchRatio: nil, timestamp: 3.5, latchableAction: nil)
require(hold.advance(leftPinchRatio: nil, timestamp: 3.76, latchableAction: nil) == .release,
        "Sustained left dropout failed to release")
hold.reset()
hold.reset()
require(hold.state == .idle, "Repeated reset is not idempotent")

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
