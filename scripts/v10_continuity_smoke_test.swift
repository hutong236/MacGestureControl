import Foundation

func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
    guard e1 > e0 else { return x >= e1 ? 1 : 0 }
    let t = min(max((x - e0) / (e1 - e0), 0), 1)
    return t * t * (3 - 2 * t)
}

func softConfidence(_ c: Double, minimum: Double = 0.18, full: Double = 0.70) -> Double {
    smoothstep(minimum, full, c)
}

func isHolding(lastValid: Double, now: Double, interval: Double = 1.0/30.0, hold: Double = 0.20) -> Bool {
    let adaptive = min(max(hold, interval * 3.8), 0.24)
    return now - lastValid <= adaptive
}

func pointerModePersists(classificationMissing: Bool, lastExplicit: Double, now: Double, grace: Double = 0.18) -> Bool {
    classificationMissing && now - lastExplicit <= grace
}

func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
    if !condition() {
        fputs("FAIL: \(name)\n", stderr)
        exit(1)
    }
    print("PASS: \(name)")
}

expect(isHolding(lastValid: 10.0, now: 10.033), "V1.0 single-frame dropout remains connected")
expect(isHolding(lastValid: 10.0, now: 10.100), "V1.0 ~3-frame dropout remains connected")
expect(!isHolding(lastValid: 10.0, now: 10.260), "V1.0 prolonged loss ends tracking")

let belowOldGate = softConfidence(0.40)
let aboveOldGate = softConfidence(0.44)
expect(belowOldGate > 0, "V1.0 confidence below old 0.42 gate still contributes")
expect(aboveOldGate > belowOldGate, "V1.0 confidence weighting is monotonic")
expect(abs(aboveOldGate - belowOldGate) < 0.20, "V1.0 no hard confidence cliff around 0.42")

expect(pointerModePersists(classificationMissing: true, lastExplicit: 5.0, now: 5.10), "V1.0 missing classification keeps pointer mode")
expect(!pointerModePersists(classificationMissing: false, lastExplicit: 5.0, now: 5.10), "V1.0 explicit different classification breaks grace")
expect(!pointerModePersists(classificationMissing: true, lastExplicit: 5.0, now: 5.25), "V1.0 classification grace cannot stick forever")

let earlyFade = smoothstep(0.055, 0.20, 0.070)
let lateFade = smoothstep(0.055, 0.20, 0.170)
expect(earlyFade < lateFade, "V1.0 prediction hold brakes progressively")

print("PASS: V1.0 continuity-first smoke suite")
