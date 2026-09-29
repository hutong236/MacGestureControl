import Foundation

enum Mode: Equatable { case idle, pointer, drag, scroll, systemSwipe }

func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
    guard e1 > e0 else { return x >= e1 ? 1 : 0 }
    let t = min(max((x - e0) / (e1 - e0), 0), 1)
    return t * t * (3 - 2 * t)
}

struct SemanticHysteresis {
    var candidate: Mode?
    var frames = 0

    mutating func resolve(requested: Mode, previous: Mode, required: Int = 2) -> Mode {
        let previousSemantic: Mode = previous == .drag ? .pointer : previous
        if requested == previousSemantic {
            candidate = nil
            frames = 0
            return requested
        }
        if previousSemantic == .idle {
            candidate = nil
            frames = 0
            return requested
        }
        if candidate != requested {
            candidate = requested
            frames = 1
        } else {
            frames += 1
        }
        if frames >= max(required, 1) {
            candidate = nil
            frames = 0
            return requested
        }
        return previousSemantic
    }
}

func recoveryTrust(remaining: Int, total: Int, floor: Double = 0.38) -> Double {
    guard remaining > 0, total > 0 else { return 1 }
    let completed = total - remaining
    let progress = Double(completed + 1) / Double(total)
    return floor + (1 - floor) * smoothstep(0, 1, progress)
}

func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
    guard condition() else {
        fputs("FAIL: \(name)\n", stderr)
        exit(1)
    }
    print("PASS: \(name)")
}

var h = SemanticHysteresis()
expect(h.resolve(requested: .scroll, previous: .pointer) == .pointer, "V1.1 one-frame pointer->scroll flicker is rejected")
expect(h.resolve(requested: .pointer, previous: .pointer) == .pointer, "V1.1 returning to pointer cancels false switch")
expect(h.resolve(requested: .scroll, previous: .pointer) == .pointer, "V1.1 first confirmed scroll frame still holds pointer")
expect(h.resolve(requested: .scroll, previous: .pointer) == .scroll, "V1.1 second confirmed scroll frame switches mode")

var h2 = SemanticHysteresis()
expect(h2.resolve(requested: .pointer, previous: .idle) == .pointer, "V1.1 idle->pointer remains immediate")

let r1 = recoveryTrust(remaining: 3, total: 3)
let r2 = recoveryTrust(remaining: 2, total: 3)
let r3 = recoveryTrust(remaining: 1, total: 3)
expect(r1 >= 0.38 && r1 < r2, "V1.1 recovery trust starts above floor")
expect(r2 < r3 && r3 <= 1.0, "V1.1 recovery trust ramps monotonically")
expect(recoveryTrust(remaining: 0, total: 0) == 1.0, "V1.1 normal tracking uses full trust")

let oldVelocity = 900.0
let firstRecoveryTarget = 300.0
let blended = oldVelocity + (firstRecoveryTarget - oldVelocity) * r1
expect(blended > firstRecoveryTarget && blended < oldVelocity, "V1.1 first recovery frame cannot hard-snap velocity")

print("PASS: V1.1 recovery fusion + semantic hysteresis suite")
