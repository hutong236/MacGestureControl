import Foundation

struct RetractionArbiter {
    enum Axis { case none, horizontal, vertical }

    var enabled = true
    var originX = 0.0
    var originY = 0.0
    var axis: Axis = .vertical
    var direction = 0.0
    var peak = 0.0
    var suppressed = false
    var candidateFrames = 0
    var neutralSince: Double?
    var reverseFrames = 0

    let armTravel = 0.014
    let oppositeDelta = 0.00085
    let confirmFrames = 2
    let neutralSpeed = 0.060
    let neutralHold = 0.090
    let reverseTravel = 0.011
    let reverseConfirmFrames = 3
    let deadZone = 0.00105

    mutating func observe(x: Double, y: Double, dx: Double, dy: Double, dt: Double, t: Double) -> Bool {
        guard enabled, dt > 0 else { return false }
        let displacement: Double
        let primaryDelta: Double
        switch axis {
        case .horizontal:
            displacement = x - originX
            primaryDelta = dx
        case .vertical:
            displacement = y - originY
            primaryDelta = dy
        case .none:
            return false
        }

        if direction == 0, abs(displacement) >= armTravel {
            direction = displacement >= 0 ? 1 : -1
            peak = abs(displacement)
            return false
        }
        guard direction != 0 else { return false }

        let directedDisplacement = displacement * direction
        peak = max(peak, directedDisplacement)
        let directedDelta = primaryDelta * direction
        let threshold = max(oppositeDelta, deadZone * 0.75)
        let clearlyReturning = directedDelta < -threshold
            && directedDisplacement < peak - max(threshold * 0.8, 0.0008)

        if !suppressed, peak >= armTravel {
            if clearlyReturning {
                candidateFrames += 1
                if candidateFrames >= confirmFrames {
                    suppressed = true
                    neutralSince = nil
                    reverseFrames = 0
                }
                return true
            } else {
                candidateFrames = 0
            }
        }

        guard suppressed else { return false }

        let speed = hypot(dx, dy) / max(dt, 0.001)
        if speed <= neutralSpeed {
            if neutralSince == nil { neutralSince = t }
            if let neutralSince, t - neutralSince >= neutralHold {
                originX = x
                originY = y
                axis = .vertical
                direction = 0
                peak = 0
                suppressed = false
                candidateFrames = 0
                self.neutralSince = nil
                reverseFrames = 0
                return true
            }
        } else {
            neutralSince = nil
        }

        let explicitReverse = directedDisplacement <= -max(reverseTravel, armTravel * 0.65)
            && directedDelta < -threshold
        if explicitReverse { reverseFrames += 1 } else { reverseFrames = 0 }
        if reverseFrames >= reverseConfirmFrames {
            originX = x
            originY = y
            direction = -direction
            peak = 0
            suppressed = false
            candidateFrames = 0
            neutralSince = nil
            reverseFrames = 0
            return true
        }
        return true
    }
}

// Downward primary stroke, then upward hand retraction: all reverse-return frames must be swallowed.
var down = RetractionArbiter()
var t = 0.0
var y = 0.0
for _ in 0..<8 {
    let dy = 0.004
    y += dy; t += 1.0/30.0
    _ = down.observe(x: 0, y: y, dx: 0, dy: dy, dt: 1.0/30.0, t: t)
}
precondition(down.direction == 1)
var reverseLeaked = false
for _ in 0..<6 {
    let dy = -0.0035
    y += dy; t += 1.0/30.0
    if !down.observe(x: 0, y: y, dx: 0, dy: dy, dt: 1.0/30.0, t: t) {
        reverseLeaked = true
    }
}
precondition(!reverseLeaked)
precondition(down.suppressed)
print("PASS: V1.1.2 downward stroke suppresses upward retraction")

// Upward primary stroke, then downward hand retraction: symmetric behavior.
var up = RetractionArbiter()
t = 0; y = 0
for _ in 0..<8 {
    let dy = -0.004
    y += dy; t += 1.0/30.0
    _ = up.observe(x: 0, y: y, dx: 0, dy: dy, dt: 1.0/30.0, t: t)
}
precondition(up.direction == -1)
reverseLeaked = false
for _ in 0..<6 {
    let dy = 0.0035
    y += dy; t += 1.0/30.0
    if !up.observe(x: 0, y: y, dx: 0, dy: dy, dt: 1.0/30.0, t: t) {
        reverseLeaked = true
    }
}
precondition(!reverseLeaked)
precondition(up.suppressed)
print("PASS: V1.1.2 upward stroke suppresses downward retraction")

// A single opposite jitter frame is swallowed but must not latch suppression permanently.
var jitter = RetractionArbiter()
t = 0; y = 0
for _ in 0..<7 {
    let dy = 0.004
    y += dy; t += 1.0/30.0
    _ = jitter.observe(x: 0, y: y, dx: 0, dy: dy, dt: 1.0/30.0, t: t)
}
y -= 0.0012; t += 1.0/30.0
precondition(jitter.observe(x: 0, y: y, dx: 0, dy: -0.0012, dt: 1.0/30.0, t: t))
precondition(!jitter.suppressed)
y += 0.003; t += 1.0/30.0
precondition(!jitter.observe(x: 0, y: y, dx: 0, dy: 0.003, dt: 1.0/30.0, t: t))
print("PASS: V1.1.2 one-frame reverse jitter does not latch")

// After retraction, a short still period rearms the next gesture.
var settle = down
for _ in 0..<4 {
    t += 0.035
    _ = settle.observe(x: 0, y: y, dx: 0, dy: 0, dt: 0.035, t: t)
}
precondition(!settle.suppressed)
precondition(settle.direction == 0)
print("PASS: V1.1.2 neutral hold rearms scrolling")

print("PASS: V1.1.2 scroll retraction smoke suite")

// A deliberate continuous reversal that travels beyond the original neutral point for >= 3 frames
// must eventually be accepted as a new opposite stroke, so suppression cannot permanently "lock" scrolling.
var reverseIntent = RetractionArbiter()
t = 0; y = 0
for _ in 0..<8 {
    let dy = 0.004
    y += dy; t += 1.0/30.0
    _ = reverseIntent.observe(x: 0, y: y, dx: 0, dy: dy, dt: 1.0/30.0, t: t)
}
for _ in 0..<14 {
    let dy = -0.004
    y += dy; t += 1.0/30.0
    _ = reverseIntent.observe(x: 0, y: y, dx: 0, dy: dy, dt: 1.0/30.0, t: t)
}
precondition(!reverseIntent.suppressed)
precondition(reverseIntent.direction == -1)
print("PASS: V1.1.2 deliberate sustained reverse can take over")
