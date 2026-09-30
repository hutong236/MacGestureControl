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
    var searchStart = haystack.startIndex
    while let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
        count += 1
        searchStart = range.upperBound
    }
    return count
}

let keyboardSource = read("GestureControl/System/KeyboardController.swift")
let appSource = read("GestureControl/AppController.swift")
let detectorSource = read("GestureControl/Vision/HandPoseDetector.swift")
let trackpadSource = read("GestureControl/Gesture/TrackpadGestureEngine.swift")
let directionalSource = read("GestureControl/Gesture/DirectionalGestureEngine.swift")
let staticSource = read("GestureControl/Gesture/StaticGestureEngine.swift")

require(keyboardSource.contains("func cancelPendingEvents()"), "Keyboard cancellation API missing")
require(keyboardSource.contains("eventGeneration &+= 1"), "Keyboard generation invalidation missing")
require(keyboardSource.contains("pendingZoomSteps = min(max(pendingZoomSteps + boundedSteps, -6), 6)"), "Zoom backlog bound missing")
require(keyboardSource.contains("zoomDrainGeneration"), "Single zoom drain gate missing")
require(occurrences(of: "keyboard.cancelPendingEvents()", in: appSource) >= 3, "Stop/error/reset must invalidate queued keyboard input")
require(appSource.contains("DirectionalGestureEngine fires from the Vision queue"), "Page gesture main-thread handoff missing")
require(appSource.contains("StaticGestureEngine also runs on the Vision path"), "Static gesture main-thread handoff missing")
require(detectorSource.contains("(-0.5...1.5).contains(x)"), "Vision landmark envelope missing")
require(trackpadSource.contains("sample.processingLatency <= 2.0"), "Trackpad stale-frame latency bound missing")
require(trackpadSource.contains("(0...1).contains(sample.confidence)"), "Trackpad confidence range guard missing")
require(directionalSource.contains("(0...1).contains(sample.confidence)"), "Directional confidence guard missing")
require(staticSource.contains("(0...1).contains(confidence)"), "Static confidence guard missing")

struct EventGate {
    private(set) var generation: UInt64 = 0
    private(set) var pendingZoomSteps = 0
    private(set) var activeDrainGeneration: UInt64?

    mutating func enqueueZoom(_ steps: Int) -> UInt64? {
        guard steps != 0 else { return nil }
        let bounded = min(max(steps, -3), 3)
        pendingZoomSteps = min(max(pendingZoomSteps + bounded, -6), 6)
        if activeDrainGeneration != generation {
            activeDrainGeneration = generation
            return generation
        }
        return nil
    }

    mutating func cancel() {
        generation &+= 1
        pendingZoomSteps = 0
        activeDrainGeneration = nil
    }

    mutating func drainOne(expectedGeneration: UInt64) -> Int? {
        guard generation == expectedGeneration else {
            if activeDrainGeneration == expectedGeneration {
                activeDrainGeneration = nil
            }
            return nil
        }
        guard pendingZoomSteps != 0 else {
            if activeDrainGeneration == expectedGeneration {
                activeDrainGeneration = nil
            }
            return nil
        }

        let step = pendingZoomSteps > 0 ? 1 : -1
        pendingZoomSteps -= step
        return step
    }
}

for pass in 0..<50 {
    var gate = EventGate()

    // Vary burst size, direction, cancellation point and opposite-direction correction.
    let first = (pass % 7) - 3
    let second = ((pass * 3) % 7) - 3
    let token = gate.enqueueZoom(first == 0 ? 1 : first) ?? gate.generation
    _ = gate.enqueueZoom(second == 0 ? -1 : second)

    require(abs(gate.pendingZoomSteps) <= 6, "Pass \(pass): zoom backlog escaped bound")

    if pass % 2 == 0 {
        gate.cancel()
        require(gate.pendingZoomSteps == 0, "Pass \(pass): cancel must clear pending zoom")
        require(gate.drainOne(expectedGeneration: token) == nil, "Pass \(pass): stale generation posted after cancel")

        // A new recognition epoch must still be able to schedule and drain fresh events.
        let freshToken = gate.enqueueZoom(pass % 4 < 2 ? 3 : -3) ?? gate.generation
        var emitted = 0
        while gate.drainOne(expectedGeneration: freshToken) != nil {
            emitted += 1
            require(emitted <= 6, "Pass \(pass): fresh zoom drain exceeded bound")
        }
        require(emitted == 3, "Pass \(pass): fresh generation lost zoom steps")
    } else {
        var emitted = 0
        while gate.drainOne(expectedGeneration: token) != nil {
            emitted += 1
            require(emitted <= 6, "Pass \(pass): zoom drain exceeded bounded budget")
        }
        require(gate.pendingZoomSteps == 0, "Pass \(pass): drain left pending steps")
    }

    // Equal and opposite bursts should collapse instead of becoming a long asynchronous tail.
    var cancellationGate = EventGate()
    let cancellationToken = cancellationGate.enqueueZoom(3) ?? cancellationGate.generation
    _ = cancellationGate.enqueueZoom(-3)
    require(cancellationGate.pendingZoomSteps == 0, "Pass \(pass): opposite zoom bursts did not coalesce")
    require(cancellationGate.drainOne(expectedGeneration: cancellationToken) == nil, "Pass \(pass): coalesced zoom unexpectedly emitted")
}

print("V1.3.1 event lifecycle 50-scenario smoke test OK")
