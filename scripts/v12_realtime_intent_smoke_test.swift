import Foundation

// Platform-neutral mirror of V1.2's axial stroke latch.
struct StrokeLatch {
    var origin = 0.0
    var position = 0.0
    var direction = 0.0
    var peak = 0.0
    var suppressed = false
    var neutralSince: Double?
    let threshold = 0.00065
    let armTravel = 0.010
    let neutralSpeed = 0.050
    let neutralHold = 0.065

    mutating func observe(delta: Double, orthogonal: Double = 0, dt: Double, t: Double) -> Bool {
        position += delta
        let speed = hypot(delta, orthogonal) / max(dt, 0.001)
        let displacement = position - origin

        if direction == 0 {
            if abs(displacement) >= armTravel || abs(delta) >= threshold * 1.35 {
                direction = displacement != 0 ? (displacement >= 0 ? 1 : -1) : (delta >= 0 ? 1 : -1)
                peak = max(abs(displacement), armTravel)
            }
            return false
        }

        let directedDelta = delta * direction
        let directedDisplacement = displacement * direction
        peak = max(peak, directedDisplacement)

        if directedDelta < -threshold {
            suppressed = true
            neutralSince = nil
            return true
        }

        if suppressed {
            let rearmZone = max(0.006, peak * 0.30)
            let nearRecenter = directedDisplacement <= rearmZone
            if nearRecenter && speed <= neutralSpeed {
                if neutralSince == nil { neutralSince = t }
                if let neutralSince, t - neutralSince >= neutralHold {
                    origin = position
                    direction = 0
                    peak = 0
                    suppressed = false
                    self.neutralSince = nil
                }
            } else {
                neutralSince = nil
            }
            return true
        }

        // Important: a pause at the far endpoint does not re-arm.
        return false
    }
}

// Main stroke, pause at endpoint, then imperfect return. The pause must not re-arm the reverse path.
var latch = StrokeLatch()
var t = 0.0
for _ in 0..<7 {
    t += 1.0/30.0
    precondition(!latch.observe(delta: 0.0038, orthogonal: 0.0004, dt: 1.0/30.0, t: t))
}
precondition(latch.direction == 1)
for _ in 0..<5 {
    t += 0.035
    precondition(!latch.observe(delta: 0, dt: 0.035, t: t))
}
precondition(latch.direction == 1 && !latch.suppressed)
print("PASS: endpoint pause does not rearm return path")

// Return path has lateral error and does not exactly retrace the stroke; no reverse scroll may leak.
var reverseLeaked = false
for i in 0..<8 {
    t += 1.0/30.0
    let sideways = (i % 2 == 0) ? 0.0014 : -0.0011
    if !latch.observe(delta: -0.0030, orthogonal: sideways, dt: 1.0/30.0, t: t) {
        reverseLeaked = true
    }
}
precondition(!reverseLeaked && latch.suppressed)
print("PASS: imperfect return path cannot generate reverse scroll")

// Once near the original axial region, a brief stable pause re-arms from the new position.
for _ in 0..<3 {
    t += 0.035
    _ = latch.observe(delta: 0, dt: 0.035, t: t)
}
precondition(!latch.suppressed && latch.direction == 0)
t += 1.0/30.0
precondition(!latch.observe(delta: -0.0036, dt: 1.0/30.0, t: t))
precondition(latch.direction == -1)
print("PASS: near-origin neutral pause rearms a deliberate new stroke")

// Stop halfway through retraction: must remain suppressed, because this is still ambiguous return motion.
var half = StrokeLatch()
t = 0
for _ in 0..<8 { t += 1.0/30.0; _ = half.observe(delta: 0.004, dt: 1.0/30.0, t: t) }
for _ in 0..<3 { t += 1.0/30.0; _ = half.observe(delta: -0.004, dt: 1.0/30.0, t: t) }
precondition(half.suppressed)
for _ in 0..<5 { t += 0.035; _ = half.observe(delta: 0, dt: 0.035, t: t) }
precondition(half.suppressed)
print("PASS: mid-return pause cannot accidentally rearm")

// Symmetric opposite-direction behavior.
var opposite = StrokeLatch()
t = 0
for _ in 0..<6 { t += 1.0/30.0; _ = opposite.observe(delta: -0.004, dt: 1.0/30.0, t: t) }
precondition(opposite.direction == -1)
t += 1.0/30.0
precondition(opposite.observe(delta: 0.003, dt: 1.0/30.0, t: t))
print("PASS: direction latch is symmetric")

// Temporal hand assignment still preserves identity across Vision result ordering changes.
struct Hand { let x: Double; let y: Double; let score: Double }
func dist(_ h: Hand, _ p: (Double, Double)) -> Double { hypot(h.x-p.0, h.y-p.1) }
func assign(_ a: Hand, _ b: Hand, primary: (Double,Double), secondary: (Double,Double)) -> (Hand,Hand) {
    let direct = dist(a, primary) + dist(b, secondary)
    let swapped = dist(b, primary) + dist(a, secondary)
    return direct <= swapped ? (a,b) : (b,a)
}
let result = assign(
    Hand(x: 0.79,y:0.51,score:1), Hand(x:0.23,y:0.49,score:1),
    primary: (0.22, 0.50), secondary: (0.78, 0.52)
)
precondition(result.0.x < 0.5 && result.1.x > 0.5)
print("PASS: temporal hand identity survives Vision ordering changes")

// V1.4 supersedes the old open-palm clutch/right-click mapping with physical-left Pinch Hold.
func read(_ path: String) -> String {
    guard let data = FileManager.default.contents(atPath: path),
          let text = String(data: data, encoding: .utf8) else {
        fatalError("Unable to read \(path)")
    }
    return text
}
let appSource = read("GestureControl/AppController.swift")
precondition(appSource.contains("leftHoldDuration: TimeInterval = 0.30"))
precondition(appSource.contains("leftReleaseDebounce: TimeInterval = 0.08"))
precondition(appSource.contains("leftMissingReleaseDelay: TimeInterval = 0.25"))
precondition(!appSource.contains("trackpadEngine.setExternalClutch"))
precondition(!appSource.contains("trackpad.rightClick()"))
print("PASS: legacy bimanual clutch/right-click mapping is retired")

print("PASS: V1.2/V1.4 real-time intent smoke suite")
