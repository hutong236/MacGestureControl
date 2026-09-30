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

// Lock the production hardening hooks in place so the stress model cannot silently drift away.
let detectorSource = read("GestureControl/Vision/HandPoseDetector.swift")
let trackpadSource = read("GestureControl/Gesture/TrackpadGestureEngine.swift")
let directionalSource = read("GestureControl/Gesture/DirectionalGestureEngine.swift")
let staticSource = read("GestureControl/Gesture/StaticGestureEngine.swift")

require(detectorSource.contains("isUsable(point, minimumConfidence:"), "Vision landmark finite-value guard missing")
require(trackpadSource.contains("isNumericallySafe(_ sample: TrackpadSample)"), "Trackpad numeric quarantine missing")
require(trackpadSource.contains("claimInputTimestampLocked"), "Trackpad monotonic timestamp gate missing")
require(directionalSource.contains("lastAcceptedTimestamp"), "Directional timestamp gate missing")
require(directionalSource.contains("samples.count > 120"), "Directional history bound missing")
require(directionalSource.contains("lastTriggerTime = -.infinity"), "Directional reset must clear cooldown")
require(staticSource.contains("lastAcceptedTimestamp"), "Static gesture timestamp gate missing")
require(staticSource.contains("currentPattern = nil"), "Static gesture edits must restart hold timing")

struct StressSample {
    var centerX: Double
    var centerY: Double
    var pointerX: Double
    var pointerY: Double
    var scrollX: Double
    var scrollY: Double
    var pointerConfidence: Double
    var scrollConfidence: Double
    var palmScale: Double?
    var pinchRatio: Double?
    var span: Double?
    var timestamp: Double
    var latency: Double
    var confidence: Double
}

enum Decision: Equatable {
    case accepted
    case missed
    case ignored
}

struct IngressGate {
    var lastTimestamp = -Double.infinity
    let minimumConfidence = 0.18

    mutating func process(_ sample: StressSample) -> Decision {
        guard sample.timestamp.isFinite, sample.timestamp >= 0 else { return .ignored }
        guard sample.timestamp > lastTimestamp else { return .ignored }
        lastTimestamp = sample.timestamp

        let finiteRequired = [
            sample.centerX, sample.centerY,
            sample.pointerX, sample.pointerY,
            sample.scrollX, sample.scrollY,
            sample.pointerConfidence, sample.scrollConfidence,
            sample.latency, sample.confidence
        ].allSatisfy { $0.isFinite }

        guard finiteRequired, sample.latency >= 0 else { return .missed }
        if let value = sample.palmScale, !value.isFinite || value <= 0 { return .missed }
        if let value = sample.pinchRatio, !value.isFinite || value < 0 { return .missed }
        if let value = sample.span, !value.isFinite || value < 0 { return .missed }
        guard sample.confidence >= minimumConfidence else { return .missed }
        return .accepted
    }
}

struct LCG {
    var state: UInt64 = 0x8f3d_9a61_4c27_b5e1

    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
}

var rng = LCG()
var gate = IngressGate()
var timestamp = 10.0
var accepted = 0
var missed = 0
var ignored = 0

for index in 0..<500 {
    timestamp += 1.0 / (18.0 + rng.next() * 102.0)

    var sample = StressSample(
        centerX: 0.15 + rng.next() * 0.70,
        centerY: 0.15 + rng.next() * 0.70,
        pointerX: 0.10 + rng.next() * 0.80,
        pointerY: 0.10 + rng.next() * 0.80,
        scrollX: 0.10 + rng.next() * 0.80,
        scrollY: 0.10 + rng.next() * 0.80,
        pointerConfidence: 0.2 + rng.next() * 0.8,
        scrollConfidence: 0.2 + rng.next() * 0.8,
        palmScale: 0.08 + rng.next() * 0.15,
        pinchRatio: rng.next(),
        span: rng.next(),
        timestamp: timestamp,
        latency: rng.next() * 0.09,
        confidence: 0.25 + rng.next() * 0.75
    )

    var expected: Decision = .accepted
    if index % 41 == 0 {
        sample.pointerX = .nan
        expected = .missed
    } else if index % 67 == 0 {
        sample.latency = .infinity
        expected = .missed
    } else if index % 53 == 0 {
        sample.confidence = 0.10
        expected = .missed
    } else if index % 89 == 0 {
        sample.palmScale = -0.1
        expected = .missed
    }

    let decision = gate.process(sample)
    switch decision {
    case .accepted: accepted += 1
    case .missed: missed += 1
    case .ignored: ignored += 1
    }
    require(String(describing: decision) == String(describing: expected), "Unexpected decision at case \(index)")

    // Probe duplicates/out-of-order delivery without counting them as one of the 500 primary cases.
    if index % 29 == 0 {
        var stale = sample
        stale.timestamp -= 0.0001
        require(gate.process(stale) == .ignored, "Out-of-order sample was not ignored at case \(index)")
    }
}

require(accepted + missed + ignored == 500, "Stress suite did not execute exactly 500 primary cases")
require(accepted > 430, "Too many healthy frames were rejected")
require(missed > 0, "Injected invalid frames were not quarantined")
require(ignored == 0, "Monotonic primary stream should not be ignored")

print("PASS: 500 deterministic realtime-ingress stress cases")
print("PASS: accepted=\(accepted), quarantined=\(missed), primaryIgnored=\(ignored)")
print("PASS: stale duplicate probes were ignored without corrupting the timestamp gate")
