import Foundation

struct ZoomArbiter {
    var enabled = false
    var accumulator = 0.0
    var suppressed = false
    var active = false
    var direction = 0
    var frames = 0
    var centerTravel = 0.0

    let stepThreshold = 0.050
    let centerMovementLimit = 0.010
    let maxCenterTravelBeforeLock = 0.018
    let minimumSpanDelta = 0.010
    let confirmFrames = 3

    mutating func observe(spanDelta: Double, centerMovement: Double, scrollEngaged: Bool) -> Int? {
        guard enabled else {
            accumulator = 0
            active = false
            direction = 0
            frames = 0
            return nil
        }

        centerTravel += centerMovement
        if scrollEngaged || centerMovement > centerMovementLimit || centerTravel > maxCenterTravelBeforeLock {
            suppressed = true
            active = false
            direction = 0
            frames = 0
            accumulator = 0
        }

        if !suppressed, abs(spanDelta) >= minimumSpanDelta {
            let d = spanDelta > 0 ? 1 : -1
            if direction == d {
                frames += 1
            } else {
                direction = d
                frames = 1
                accumulator = 0
            }
            accumulator += spanDelta
            if frames >= confirmFrames, abs(accumulator) >= stepThreshold {
                active = true
                return d
            }
        } else if !active {
            accumulator *= 0.45
            frames = max(frames - 1, 0)
            if frames == 0 { direction = 0 }
        }
        return nil
    }
}

// Default setting: zoom is disabled, so scroll jitter can never emit Command +/-.
var defaultArbiter = ZoomArbiter(enabled: false)
for i in 0..<12 {
    let noisySpan = i % 2 == 0 ? 0.022 : -0.020
    precondition(defaultArbiter.observe(spanDelta: noisySpan, centerMovement: 0.006, scrollEngaged: i > 1) == nil)
}
print("PASS: V1.1.1 zoom disabled by default")

// Even when experimental zoom is enabled, meaningful vertical translation locks the contact to scroll.
var scrollArbiter = ZoomArbiter(enabled: true)
var accidentalZoom = false
for i in 0..<10 {
    let noisySpan = i % 3 == 0 ? 0.021 : (i % 3 == 1 ? 0.016 : -0.014)
    if scrollArbiter.observe(spanDelta: noisySpan, centerMovement: 0.007, scrollEngaged: i >= 2) != nil {
        accidentalZoom = true
    }
}
precondition(!accidentalZoom)
precondition(scrollArbiter.suppressed)
print("PASS: V1.1.1 two-finger scroll suppresses zoom for the contact")

// Deliberate pinch: center stays nearly fixed and span changes consistently for >= 3 frames.
var pinchArbiter = ZoomArbiter(enabled: true)
var gotZoom = false
for _ in 0..<4 {
    if pinchArbiter.observe(spanDelta: 0.018, centerMovement: 0.002, scrollEngaged: false) != nil {
        gotZoom = true
        break
    }
}
precondition(gotZoom)
precondition(pinchArbiter.active)
print("PASS: V1.1.1 deliberate stationary pinch can still zoom when enabled")
