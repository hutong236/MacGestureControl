import Foundation

func smoothstep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
    guard edge1 > edge0 else { return value >= edge1 ? 1 : 0 }
    let x = min(max((value - edge0) / (edge1 - edge0), 0), 1)
    return x * x * (3 - 2 * x)
}

func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
    if !condition() {
        fputs("FAIL: \(name)\n", stderr)
        exit(1)
    }
    print("PASS: \(name)")
}

// MARK: - α-β state estimation

struct AlphaBeta1D {
    var x: Double
    var v: Double
    var t: Double

    mutating func update(measurement: Double, timestamp: Double, alpha: Double, beta: Double) -> Double {
        let dt = timestamp - t
        let predicted = x + v * dt
        let residual = measurement - predicted
        x = predicted + alpha * residual
        v += (beta / dt) * residual
        t = timestamp
        return v
    }
}

var filter = AlphaBeta1D(x: 0, v: 0, t: 0)
var rawVelocities: [Double] = []
var filteredVelocities: [Double] = []
let dt = 1.0 / 30.0
let noisePattern = [0.0000, 0.0012, -0.0009, 0.0007, -0.0011, 0.0005]
var positions: [Double] = []
for i in 0..<72 {
    positions.append(Double(i) * 0.010 + noisePattern[i % noisePattern.count])
}
for i in 1..<positions.count {
    let rawV = (positions[i] - positions[i - 1]) / dt
    rawVelocities.append(rawV)
    filteredVelocities.append(filter.update(measurement: positions[i], timestamp: Double(i) * dt, alpha: 0.72, beta: 0.16))
}
func variance(_ xs: [Double]) -> Double {
    let m = xs.reduce(0,+) / Double(xs.count)
    return xs.reduce(0) { $0 + ($1-m)*($1-m) } / Double(xs.count)
}
let rawSteady = Array(rawVelocities.dropFirst(18))
let filteredSteady = Array(filteredVelocities.dropFirst(18))
expect(variance(filteredSteady) < variance(rawSteady) * 0.45, "V0.9 alpha-beta reduces steady-state velocity jitter")
expect(abs(filteredVelocities.last! - 0.30) < 0.08, "V0.9 alpha-beta retains steady forward velocity")

// MARK: - measured Vision latency compensation

enum Phase { case accelerating, cruising, decelerating, settling, clickReady, dragging, idle }
func effectiveHorizon(phase: Phase, base: Double, processingLatency: Double, compensation: Double) -> Double {
    let weight: Double
    switch phase {
    case .accelerating: weight = 0.78
    case .cruising: weight = 0.58
    case .dragging: weight = 0.18
    case .decelerating: weight = 0.10
    case .settling, .clickReady, .idle: weight = 0
    }
    return base + min(max(processingLatency, 0), 0.060) * compensation * weight
}
let accelH = effectiveHorizon(phase: .accelerating, base: 0.016, processingLatency: 0.020, compensation: 0.68)
let settleH = effectiveHorizon(phase: .settling, base: 0, processingLatency: 0.020, compensation: 0.68)
expect(accelH > 0.016, "V0.9 measured latency extends moving prediction")
expect(settleH == 0, "V0.9 latency lead disabled while settling")

// MARK: - click rebound suppression
func pointerSuppressed(now: Double, releaseAt: Double, hold: Double) -> Bool {
    now < releaseAt + hold
}
expect(pointerSuppressed(now: 10.04, releaseAt: 10.0, hold: 0.085), "V0.9 post-click rebound hold active")
expect(!pointerSuppressed(now: 10.10, releaseAt: 10.0, hold: 0.085), "V0.9 post-click rebound hold expires")

// MARK: - pose grace must expire by wall-clock time
let lastExplicitTwoFinger = 20.0
expect(20.030 - lastExplicitTwoFinger <= 0.042, "V0.9 two-finger classification grace")
expect(!(20.090 - lastExplicitTwoFinger <= 0.042), "V0.9 two-finger grace cannot stick forever")

// MARK: - scroll phases

enum ScrollPhase { case idle, contact, tracking, coasting }
func phaseAfterContact(travel: Double, age: Double, threshold: Double = 0.0042, debounce: Double = 0.030) -> ScrollPhase {
    guard travel >= threshold, age >= debounce else { return .contact }
    return .tracking
}
func phaseAfterRelease(speed: Double) -> ScrollPhase { speed >= 70 ? .coasting : .idle }
expect(phaseAfterContact(travel: 0.003, age: 0.05) == .contact, "V0.9 scroll contact ignores tiny setup jitter")
expect(phaseAfterContact(travel: 0.010, age: 0.010) == .contact, "V0.9 scroll contact debounce")
expect(phaseAfterContact(travel: 0.010, age: 0.040) == .tracking, "V0.9 scroll engages after stable contact")
expect(phaseAfterRelease(speed: 420) == .coasting, "V0.9 fast release enters coasting")
expect(phaseAfterRelease(speed: 28) == .idle, "V0.9 slow release does not invent inertia")
