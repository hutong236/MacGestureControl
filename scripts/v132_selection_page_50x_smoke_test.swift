import Foundation

struct CommandFailure: Error {
    let command: String
    let output: String
}

@discardableResult
func runXcrun(_ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = arguments

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(decoding: data, as: UTF8.self)
    guard process.terminationStatus == 0 else {
        throw CommandFailure(command: "xcrun \(arguments.joined(separator: " "))", output: output)
    }
    return output
}

func compileAndRun(name: String, sources: [String], harness: String) throws -> String {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("MacGestureControl-\(name)-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    let main = dir.appendingPathComponent("main.swift")
    let executable = dir.appendingPathComponent(name)
    try harness.write(to: main, atomically: true, encoding: .utf8)

    _ = try runXcrun(["swiftc"] + sources + [main.path, "-o", executable.path])
    let process = Process()
    process.executableURL = executable
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    guard process.terminationStatus == 0 else {
        throw CommandFailure(command: executable.path, output: output)
    }
    return output
}

let selectionHarness = #"""
import Foundation

var checks = 0
func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    checks += 1
    precondition(condition(), "selection case \(checks) failed: \(name)")
}

var gate = SelectionGestureGate(minimumRearmInterval: 0.090)
var actualDown = false

@discardableResult
func request(_ down: Bool, _ timestamp: TimeInterval) -> Bool? {
    let decision = gate.filter(requestedDown: down, actualDown: actualDown, timestamp: timestamp)
    if let decision {
        actualDown = decision
        gate.markEmitted(down: decision, at: timestamp)
    }
    return decision
}

check("first press passes", request(true, 1.000) == true)
check("duplicate press is ignored", request(true, 1.010) == nil)
check("release passes", request(false, 1.080) == false)
check("duplicate release is ignored", request(false, 1.090) == nil)
check("20ms rebound press is suppressed", request(true, 1.100) == nil)
check("suppressed rebound remains suppressed", request(true, 1.120) == nil)
check("release clears suppressed rebound", request(false, 1.130) == nil)
check("press after rearm interval passes", request(true, 1.180) == true)
check("normal release after rearm passes", request(false, 1.240) == false)
check("80ms rebound stays blocked", request(true, 1.320) == nil)
check("blocked rebound release emits nothing", request(false, 1.330) == nil)
check("exact 90ms boundary rearms", request(true, 1.330) == true)
check("release after boundary press passes", request(false, 1.400) == false)
check("stale timestamp is ignored", request(true, 1.390) == nil)
check("non-finite timestamp is ignored", request(true, .infinity) == nil)
check("state remains released after invalid timestamp", actualDown == false)
check("long-gap press passes", request(true, 2.000) == true)
check("drag hold duplicate press ignored", request(true, 2.400) == nil)
check("drag release passes", request(false, 2.500) == false)
check("fast chatter press suppressed", request(true, 2.520) == nil)
check("fast chatter release suppressed", request(false, 2.540) == nil)
check("later selection press passes", request(true, 2.620) == true)
check("later selection release passes", request(false, 2.700) == false)
check("second deliberate click after 120ms passes", request(true, 2.820) == true)
check("second deliberate click release passes", request(false, 2.900) == false)

precondition(checks == 25, "expected 25 selection scenarios, got \(checks)")
print("PASS: 25 selection gesture scenarios")
"""#

let pageHarness = #"""
import Foundation

var checks = 0
func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    checks += 1
    precondition(condition(), "page case \(checks) failed: \(name)")
}

func detect(
    _ points: [(Double, Double, Double, Double)],
    configure: ((inout DirectionalGestureEngine.Configuration) -> Void)? = nil
) -> [GestureDirection] {
    let engine = DirectionalGestureEngine()
    var config = DirectionalGestureEngine.Configuration()
    config.minimumDistance = 0.16
    config.minimumVelocity = 0.30
    config.maximumGestureDuration = 0.90
    config.minimumGestureDuration = 0.09
    config.cooldown = 0
    config.returnSuppressionEnabled = false
    config.minimumDirectionalConsistency = 0.68
    config.directionNoiseTolerance = 0.004
    config.minimumConsistentSegments = 2
    configure?(&config)
    engine.update(configuration: config)

    var result: [GestureDirection] = []
    engine.onGesture = { result.append($0) }
    for point in points {
        engine.process(HandSample(x: point.0, y: point.1, timestamp: point.2, confidence: point.3))
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.015))
    return result
}

func vertical(_ ys: [Double], x: Double = 0.5, start: Double = 10, dt: Double = 0.055, confidence: Double = 0.95) -> [(Double, Double, Double, Double)] {
    ys.enumerated().map { index, y in (x + (index.isMultiple(of: 2) ? 0.002 : -0.002), y, start + Double(index) * dt, confidence) }
}

check("clean up stroke", detect(vertical([0.20, 0.27, 0.35, 0.44, 0.55])).last == .up)
check("clean down stroke", detect(vertical([0.80, 0.72, 0.63, 0.53, 0.42])).last == .down)
check("fast up stroke", detect(vertical([0.22, 0.33, 0.48, 0.64], dt: 0.035)).last == .up)
check("fast down stroke", detect(vertical([0.78, 0.66, 0.51, 0.35], dt: 0.035)).last == .down)
check("slow up stroke", detect(vertical([0.18, 0.22, 0.27, 0.33, 0.40, 0.48, 0.57], dt: 0.09)).last == .up)
check("slow down stroke", detect(vertical([0.82, 0.78, 0.73, 0.67, 0.60, 0.52, 0.43], dt: 0.09)).last == .down)
check("minor up jitter tolerated", detect(vertical([0.20, 0.28, 0.276, 0.37, 0.46, 0.56])).last == .up)
check("minor down jitter tolerated", detect(vertical([0.80, 0.72, 0.724, 0.63, 0.54, 0.44])).last == .down)
check("up with x wobble remains vertical", detect([(0.50,0.20,10.00,0.95),(0.53,0.28,10.06,0.95),(0.47,0.38,10.12,0.95),(0.52,0.49,10.18,0.95),(0.49,0.60,10.24,0.95)]).last == .up)
check("down with x wobble remains vertical", detect([(0.50,0.80,10.00,0.95),(0.47,0.72,10.06,0.95),(0.53,0.62,10.12,0.95),(0.48,0.51,10.18,0.95),(0.51,0.40,10.24,0.95)]).last == .down)

check("large up-down-up oscillation rejected", detect(vertical([0.20, 0.44, 0.30, 0.57])).isEmpty)
check("large down-up-down oscillation rejected", detect(vertical([0.80, 0.56, 0.70, 0.43])).isEmpty)
check("two reversals up rejected", detect(vertical([0.18, 0.38, 0.27, 0.49, 0.36, 0.59])).isEmpty)
check("two reversals down rejected", detect(vertical([0.82, 0.62, 0.73, 0.51, 0.64, 0.41])).isEmpty)
check("sawtooth net-up rejected", detect(vertical([0.20, 0.37, 0.29, 0.46, 0.38, 0.56])).isEmpty)
check("sawtooth net-down rejected", detect(vertical([0.80, 0.63, 0.71, 0.54, 0.62, 0.44])).isEmpty)

check("diagonal up-right rejected", detect([(0.20,0.20,10.00,0.95),(0.30,0.30,10.06,0.95),(0.42,0.42,10.12,0.95),(0.54,0.54,10.18,0.95)]).isEmpty)
check("diagonal down-left rejected", detect([(0.80,0.80,10.00,0.95),(0.69,0.69,10.06,0.95),(0.57,0.57,10.12,0.95),(0.45,0.45,10.18,0.95)]).isEmpty)
check("short vertical travel rejected", detect(vertical([0.30, 0.34, 0.39, 0.44])).isEmpty)
check("low confidence interrupts stroke", detect([(0.5,0.20,10.00,0.95),(0.5,0.31,10.06,0.95),(0.5,0.40,10.12,0.20),(0.5,0.56,10.18,0.95)]).isEmpty)
check("out-of-order timestamp rejected safely", detect([(0.5,0.20,10.00,0.95),(0.5,0.32,10.08,0.95),(0.5,0.48,10.04,0.95)]).isEmpty)

let defaults = GestureBindings()
check("default up maps to Page Up", defaults.up == .pageUp)
check("default down maps to Page Down", defaults.down == .pageDown)
check("horizontal defaults remain arrows", defaults.left == .leftArrow && defaults.right == .rightArrow)
check("Page Up/Down key codes stay macOS standard", KeyActionPreset.pageUp.keyCode == 116 && KeyActionPreset.pageDown.keyCode == 121)

precondition(checks == 25, "expected 25 page scenarios, got \(checks)")
print("PASS: 25 vertical page gesture scenarios")
"""#

do {
    let selectionOutput = try compileAndRun(
        name: "selection-gesture-25x",
        sources: ["GestureControl/System/TrackpadController.swift"],
        harness: selectionHarness
    )
    print(selectionOutput, terminator: "")

    let pageOutput = try compileAndRun(
        name: "page-gesture-25x",
        sources: [
            "GestureControl/Models/GestureModels.swift",
            "GestureControl/Gesture/DirectionalGestureEngine.swift"
        ],
        harness: pageHarness
    )
    print(pageOutput, terminator: "")
    print("PASS: V1.3.2 selection + page gesture 50-scenario suite")
} catch let failure as CommandFailure {
    fputs("FAIL: \(failure.command)\n\(failure.output)\n", stderr)
    exit(1)
} catch {
    fputs("FAIL: \(error)\n", stderr)
    exit(1)
}
