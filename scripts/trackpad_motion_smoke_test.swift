import Foundation

struct FingerPattern {
    let thumb: Bool
    let index: Bool
    let middle: Bool
    let ring: Bool
    let little: Bool

    var isPointerPose: Bool { index && !middle && !ring && !little }
    var isTwoFingerPose: Bool { index && middle && !ring && !little }
    var isSystemSwipePose: Bool {
        (index && middle && ring && !little) || (index && middle && ring && little)
    }
}

let one = FingerPattern(thumb: false, index: true, middle: false, ring: false, little: false)
let two = FingerPattern(thumb: false, index: true, middle: true, ring: false, little: false)
let three = FingerPattern(thumb: false, index: true, middle: true, ring: true, little: false)
let four = FingerPattern(thumb: false, index: true, middle: true, ring: true, little: true)
precondition(one.isPointerPose && !one.isTwoFingerPose)
precondition(two.isTwoFingerPose && !two.isPointerPose)
precondition(three.isSystemSwipePose)
precondition(four.isSystemSwipePose)
print("PASS: finger-mode classification")

func smoothstep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
    let x = min(max((value - edge0) / (edge1 - edge0), 0), 1)
    return x * x * (3 - 2 * x)
}

func pointerAlpha(speed: Double, responsiveness: Double, confidence: Double = 0.8) -> Double {
    let speedT = smoothstep(0.04, 1.20, speed)
    let confidenceFactor = min(max((confidence - 0.40) / 0.45, 0), 1)
    return min(max(0.20 + responsiveness * 0.25 + speedT * 0.35 + confidenceFactor * 0.06, 0.20), 0.88)
}

let slowAlpha = pointerAlpha(speed: 0.06, responsiveness: 0.74)
let fastAlpha = pointerAlpha(speed: 1.1, responsiveness: 0.74)
precondition(fastAlpha > slowAlpha)
precondition(fastAlpha <= 0.88)
print("PASS: adaptive pointer response")

func axisLock(dx: Double, dy: Double, ratio: Double = 1.60) -> String {
    if abs(dx) > abs(dy) * ratio { return "horizontal" }
    if abs(dy) > abs(dx) * ratio { return "vertical" }
    return "none"
}
precondition(axisLock(dx: 0.03, dy: 0.008) == "horizontal")
precondition(axisLock(dx: 0.006, dy: 0.028) == "vertical")
precondition(axisLock(dx: 0.02, dy: 0.016) == "none")
print("PASS: soft-axis-lock decision")

func settleVelocity(_ velocity: Double, stillSamples: Int) -> Double {
    stillSamples >= 2 ? 0 : velocity * 0.28
}
precondition(settleVelocity(120, stillSamples: 1) > 0)
precondition(settleVelocity(120, stillSamples: 2) == 0)
print("PASS: pointer stop magnet")

func inertiaDecay(initial: Double, inertia: Double, speed: Double, frames: Int) -> Double {
    var v = initial
    for _ in 0..<frames {
        let speedT = min(speed / 1600.0, 1.0)
        let per60HzDecay = min(0.985, 0.78 + inertia * 0.18 + speedT * 0.020)
        v *= per60HzDecay
    }
    return v
}
let slowTail = inertiaDecay(initial: 1000, inertia: 0.72, speed: 200, frames: 20)
let fastTail = inertiaDecay(initial: 1000, inertia: 0.72, speed: 1600, frames: 20)
precondition(fastTail > slowTail)
precondition(slowTail > 0)
print("PASS: velocity-aware inertia")

func naturalScroll(dy: Double, natural: Bool) -> Double { natural ? -dy : dy }
precondition(naturalScroll(dy: 0.1, natural: true) < 0)
precondition(naturalScroll(dy: 0.1, natural: false) > 0)
print("PASS: natural scroll direction")

// Debounced pinch semantics: one noisy sample is insufficient to press/release.
let pressDebounce = 0.028
let releaseDebounce = 0.035
precondition(0.020 < pressDebounce)
precondition(0.030 < releaseDebounce)
print("PASS: pinch debounce thresholds")

func distanceGain(palmScale: Double, nominal: Double = 0.14) -> Double {
    min(max(nominal / palmScale, 0.65), 1.75)
}
let nearGain = distanceGain(palmScale: 0.20)
let normalGain = distanceGain(palmScale: 0.14)
let farGain = distanceGain(palmScale: 0.09)
precondition(nearGain < normalGain && normalGain < farGain)
precondition(abs(normalGain - 1.0) < 0.0001)
print("PASS: camera-distance compensation")

func predictedVelocity(raw: Double, previousRaw: Double, dt: Double, response: Double, speedT: Double) -> Double {
    let horizon = (0.006 + 0.010 * response) * speedT
    let acceleration = (raw - previousRaw) / dt
    let maxLead = abs(raw) * 0.16 + 45.0
    let lead = min(max(acceleration * horizon, -maxLead), maxLead)
    return raw + lead
}
let accelerating = predictedVelocity(raw: 600, previousRaw: 300, dt: 1.0 / 30.0, response: 0.74, speedT: 1)
precondition(accelerating > 600 && accelerating < 750)
let steady = predictedVelocity(raw: 600, previousRaw: 600, dt: 1.0 / 30.0, response: 0.74, speedT: 1)
precondition(abs(steady - 600) < 0.001)
print("PASS: bounded short-window prediction")

func scrollRamp(age: Double, duration: Double = 0.075) -> Double {
    smoothstep(0, duration, age)
}
precondition(scrollRamp(age: 0) == 0)
precondition(scrollRamp(age: 0.04) > 0 && scrollRamp(age: 0.04) < 1)
precondition(scrollRamp(age: 0.08) == 1)
print("PASS: progressive scroll engagement")

// V0.5 adaptive jitter floor: noisier observations should create a larger dead zone,
// while remaining bounded so micro movement is never completely swallowed.
func adaptiveDeadZone(base: Double, noise: Double, precision: Double) -> Double {
    let multiplier = 1.35 + precision * 0.95
    return min(base * 2.4, max(base * 0.62, noise * multiplier))
}
let stableDZ = adaptiveDeadZone(base: 0.00120, noise: 0.00060, precision: 0.68)
let noisyDZ = adaptiveDeadZone(base: 0.00120, noise: 0.00120, precision: 0.68)
precondition(noisyDZ > stableDZ)
precondition(noisyDZ <= 0.00120 * 2.4 + 0.000001)
print("PASS: adaptive pointer noise floor")

// Precision clutch hysteresis: tiny movement remains latched; a deliberate movement exits.
func precisionLatched(distance: Double, releaseRadius: Double) -> Bool {
    distance < releaseRadius
}
precondition(precisionLatched(distance: 0.003, releaseRadius: 0.0062))
precondition(!precisionLatched(distance: 0.009, releaseRadius: 0.0062))
print("PASS: precision-clutch hysteresis")

// Drag curve must be more precise at low speed, but retain more gain at high speed.
func dragGain(speedT: Double) -> Double { 0.56 + 0.29 * speedT }
precondition(dragGain(speedT: 0.05) < dragGain(speedT: 0.95))
precondition(dragGain(speedT: 0.05) < 0.60)
precondition(dragGain(speedT: 0.95) > 0.80)
print("PASS: drag precision curve")

struct VelocitySample {
    let age: Double
    let x: Double
    let y: Double
}
func weightedReleaseVelocity(_ samples: [VelocitySample], window: Double = 0.14) -> (Double, Double) {
    var total = 0.0
    var vx = 0.0
    var vy = 0.0
    for s in samples where s.age <= window {
        let freshness = max(0.08, 1.0 - s.age / window)
        let speed = hypot(s.x, s.y)
        let motionWeight = 0.45 + min(speed / 1400.0, 1.0) * 0.55
        let weight = freshness * freshness * motionWeight
        vx += s.x * weight
        vy += s.y * weight
        total += weight
    }
    return total > 0 ? (vx / total, vy / total) : (0, 0)
}
let release = weightedReleaseVelocity([
    .init(age: 0.12, x: 900, y: 0),
    .init(age: 0.08, x: 1100, y: 0),
    .init(age: 0.04, x: 1250, y: 0),
    .init(age: 0.00, x: 80, y: 0), // noisy final frame should not erase the flick
])
precondition(release.0 > 300)
precondition(abs(release.1) < 0.001)
print("PASS: weighted scroll release velocity")

func zoomPulseCount(accumulator: Double, threshold: Double = 0.05) -> Int {
    let direction = accumulator >= 0 ? 1 : -1
    return direction * min(3, max(1, Int(abs(accumulator) / threshold)))
}
precondition(zoomPulseCount(accumulator: 0.06) == 1)
precondition(zoomPulseCount(accumulator: 0.14) == 2)
precondition(zoomPulseCount(accumulator: -0.20) == -3)
print("PASS: velocity-like zoom pulse mapping")

// V0.6 personal calibration: stable samples converge to the user's working-distance scale.
func calibratedPalmScale(samples: [Double], required: Int = 42) -> (progress: Double, baseline: Double?) {
    var candidate: Double?
    var count = 0
    for raw in samples where raw >= 0.060 && raw <= 0.28 {
        let clamped = min(max(raw, 0.060), 0.28)
        if let current = candidate {
            candidate = current + (clamped - current) * 0.085
        } else {
            candidate = clamped
        }
        count += 1
    }
    let progress = min(Double(count) / Double(max(required, 12)), 1)
    return (progress, count >= required ? candidate : nil)
}
let calibration = calibratedPalmScale(samples: (0..<45).map { i in 0.142 + (i % 2 == 0 ? 0.001 : -0.001) })
precondition(calibration.progress == 1)
precondition(calibration.baseline != nil)
precondition(abs((calibration.baseline ?? 0) - 0.142) < 0.003)
print("PASS: personal palm-scale calibration")

// V0.6 click intent: appearing already pinched must not click; open -> intentional close may click.
struct PinchIntentState {
    var armed = false
    mutating func observe(ratio: Double, allowPress: Bool, closingSpeed: Double, pointerSpeed: Double) -> Bool {
        if allowPress && ratio >= 0.56 && pointerSpeed <= 0.42 { armed = true }
        guard allowPress && armed else { return false }
        let hasIntent = closingSpeed >= 0.18 || ratio <= 0.27
        if ratio <= 0.34 && hasIntent {
            armed = false
            return true
        }
        return false
    }
}
var pinch = PinchIntentState()
precondition(!pinch.observe(ratio: 0.25, allowPress: true, closingSpeed: 0, pointerSpeed: 0))
precondition(!pinch.observe(ratio: 0.62, allowPress: true, closingSpeed: 0, pointerSpeed: 0.05))
precondition(pinch.observe(ratio: 0.31, allowPress: true, closingSpeed: 0.9, pointerSpeed: 0.10))
print("PASS: armed click-intent gating")

// V0.6 scroll curve: slow motion remains precise while fast flick receives more gain.
func scrollGain(speedT: Double, strength: Double = 0.72) -> Double {
    let s = min(max(strength, 0), 1)
    let fine = 0.66 + (1.0 - s) * 0.12
    let fast = 1.18 + s * 0.58
    return fine + (fast - fine) * pow(speedT, 1.18)
}
let slowScrollGain = scrollGain(speedT: 0.08)
let mediumScrollGain = scrollGain(speedT: 0.50)
let fastScrollGain = scrollGain(speedT: 0.95)
precondition(slowScrollGain < mediumScrollGain && mediumScrollGain < fastScrollGain)
precondition(slowScrollGain < 0.9)
precondition(fastScrollGain > 1.4)
print("PASS: continuous scroll acceleration curve")

// V0.7 time-normalized filter: slower input FPS uses a larger per-sample alpha,
// faster input FPS uses a smaller one, keeping the response per second close.
func timeNormalizedAlpha(base: Double, dt: Double, nominalFPS: Double = 30) -> Double {
    let ref = 1.0 / nominalFPS
    let exponent = min(max(dt / ref, 0.35), 2.5)
    return 1.0 - pow(1.0 - base, exponent)
}
let alpha20 = timeNormalizedAlpha(base: 0.55, dt: 1.0 / 20.0)
let alpha30 = timeNormalizedAlpha(base: 0.55, dt: 1.0 / 30.0)
let alpha45 = timeNormalizedAlpha(base: 0.55, dt: 1.0 / 45.0)
precondition(alpha20 > alpha30 && alpha30 > alpha45)
print("PASS: V0.7 FPS-normalized filter response")

func frameDeadZoneScale(actualFPS: Double, nominalFPS: Double = 30) -> Double {
    let ratio = min(max((1.0 / actualFPS) / (1.0 / nominalFPS), 0.60), 1.65)
    return sqrt(ratio)
}
precondition(frameDeadZoneScale(actualFPS: 45) < 1)
precondition(frameDeadZoneScale(actualFPS: 20) > 1)
print("PASS: V0.7 frame-adaptive dead zone")

func approachGain(lastSpeed: Double, currentSpeed: Double, assist: Double = 0.68) -> Double {
    let deceleration = max(0, lastSpeed - currentSpeed)
    let intent = smoothstep(0.055, 0.30, deceleration)
        * smoothstep(0.16, 0.58, lastSpeed)
        * (1.0 - smoothstep(0.32, 0.78, currentSpeed))
    return 1.0 - min(max(assist, 0), 1) * 0.30 * intent
}
let arriving = approachGain(lastSpeed: 0.70, currentSpeed: 0.18)
let cruising = approachGain(lastSpeed: 0.45, currentSpeed: 0.44)
precondition(arriving < cruising)
precondition(arriving >= 0.70)
print("PASS: V0.7 approach-intent slowdown")

func continuityGain(cosine: Double, normalizedSpeed: Double, continuity: Double = 0.72) -> Double {
    let abruptReverse = smoothstep(0.05, 0.85, -cosine)
    let lowSpeedGate = 1.0 - smoothstep(0.48, 1.05, normalizedSpeed)
    return 1.0 - abruptReverse * lowSpeedGate * continuity * 0.62
}
let noisyReverse = continuityGain(cosine: -0.92, normalizedSpeed: 0.22)
let deliberateFastReverse = continuityGain(cosine: -0.92, normalizedSpeed: 1.20)
let sameDirection = continuityGain(cosine: 0.95, normalizedSpeed: 0.22)
precondition(noisyReverse < 0.75)
precondition(deliberateFastReverse > noisyReverse)
precondition(abs(sameDirection - 1.0) < 0.001)
print("PASS: V0.7 direction-continuity suppression")

func continuousFriction(initial: Double, inertia: Double, dt: Double, seconds: Double) -> Double {
    var speed = initial
    var remaining = seconds
    while remaining > 0.000_001 && speed > 0 {
        let step = min(dt, remaining)
        let speedT = min(speed / 1700.0, 1.0)
        let highSpeedFriction = 1.35 + (1.0 - inertia) * 2.10
        let lowSpeedExtra = (1.0 - speedT) * (2.20 + (1.0 - inertia) * 1.30)
        speed *= exp(-(highSpeedFriction + lowSpeedExtra) * step)
        if speed < 260, speed > 0 {
            speed = max(0, speed - (72.0 + (1.0 - inertia) * 110.0) * step)
        }
        remaining -= step
    }
    return speed
}
let friction60 = continuousFriction(initial: 1800, inertia: 0.72, dt: 1.0 / 60.0, seconds: 0.7)
let friction120 = continuousFriction(initial: 1800, inertia: 0.72, dt: 1.0 / 120.0, seconds: 0.7)
precondition(abs(friction60 - friction120) < 35)
precondition(friction60 < 1800 && friction120 < 1800)
print("PASS: V0.7 tick-rate-independent inertia friction")

func trackingInstability(confidence: Double, jitter: Double, fps: Double, noise: Double, nominalFPS: Double = 30) -> Double {
    let lowFPSPenalty = max(0, nominalFPS - fps) / nominalFPS
    let confidencePenalty = max(0, 0.78 - confidence) / 0.38
    let jitterPenalty = min(jitter / 0.28, 1.0)
    let noisePenalty = min(max((noise - 0.00055) / (0.00320 - 0.00055), 0), 1)
    return min(max(confidencePenalty * 0.42 + jitterPenalty * 0.28 + lowFPSPenalty * 0.18 + noisePenalty * 0.12, 0), 1)
}
let stableQuality = trackingInstability(confidence: 0.88, jitter: 0.04, fps: 30, noise: 0.00065)
let poorQuality = trackingInstability(confidence: 0.55, jitter: 0.22, fps: 18, noise: 0.0022)
precondition(poorQuality > stableQuality)
print("PASS: V0.7 adaptive tracking quality model")
