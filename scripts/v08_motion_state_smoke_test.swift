import Foundation

enum Phase: String {
    case idle, accelerating, cruising, decelerating, settling, clickReady, dragging
}

func smoothstep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
    let x = min(max((value - edge0) / (edge1 - edge0), 0), 1)
    return x * x * (3 - 2 * x)
}

func desiredPhase(previousSpeed: Double,
                  speed: Double,
                  pinchArmed: Bool = false,
                  pinchRatio: Double = 1,
                  pinchArmRatio: Double = 0.56,
                  pinchStartRatio: Double = 0.34,
                  closingSpeed: Double = 0,
                  dragging: Bool = false) -> Phase {
    let delta = speed - previousSpeed
    let clickReady = pinchArmed
        && pinchRatio < pinchArmRatio
        && pinchRatio > pinchStartRatio * 0.92
        && (closingSpeed > 0.055 || pinchRatio < pinchArmRatio * 0.90)
        && speed < 0.30

    if dragging { return .dragging }
    if clickReady { return .clickReady }
    if speed < 0.032 { return .settling }
    if delta > 0.075 && speed > 0.12 { return .accelerating }
    if -delta > 0.060 && previousSpeed > 0.15 { return .decelerating }
    return .cruising
}

func predictionHorizon(_ phase: Phase, response: Double = 0.74, speed: Double = 0.6) -> Double {
    let base: Double
    switch phase {
    case .accelerating: base = 0.010 + 0.008 * response
    case .cruising: base = 0.007 + 0.006 * response
    case .decelerating: base = 0.0025 + 0.0025 * response
    case .dragging: base = 0.0025
    case .settling, .clickReady, .idle: base = 0
    }
    return base * smoothstep(0.10, 0.92, speed)
}

func stateBrake(_ phase: Phase, dt: Double = 1.0/120.0, decel: Double = 0.72) -> Double {
    switch phase {
    case .clickReady: return exp(-20.0 * dt)
    case .settling: return exp(-15.0 * dt)
    case .decelerating: return exp(-3.6 * decel * dt)
    case .idle: return exp(-22.0 * dt)
    default: return 1
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
    if !condition() {
        fputs("FAIL: \(name)\n", stderr)
        exit(1)
    }
    print("PASS: \(name)")
}

expect(desiredPhase(previousSpeed: 0.04, speed: 0.22) == .accelerating, "V0.8 accelerating classification")
expect(desiredPhase(previousSpeed: 0.32, speed: 0.34) == .cruising, "V0.8 cruising classification")
expect(desiredPhase(previousSpeed: 0.48, speed: 0.20) == .decelerating, "V0.8 decelerating classification")
expect(desiredPhase(previousSpeed: 0.05, speed: 0.018) == .settling, "V0.8 settling classification")
expect(desiredPhase(previousSpeed: 0.12, speed: 0.08, pinchArmed: true, pinchRatio: 0.44, closingSpeed: 0.11) == .clickReady,
       "V0.8 click-ready intent classification")
expect(desiredPhase(previousSpeed: 0.12, speed: 0.08, dragging: true) == .dragging, "V0.8 dragging priority")

let accelH = predictionHorizon(.accelerating)
let cruiseH = predictionHorizon(.cruising)
let decelH = predictionHorizon(.decelerating)
expect(accelH > cruiseH && cruiseH > decelH, "V0.8 phase-aware prediction horizon ordering")
expect(predictionHorizon(.settling) == 0 && predictionHorizon(.clickReady) == 0,
       "V0.8 no prediction while settling/click-ready")
expect(stateBrake(.clickReady) < stateBrake(.decelerating), "V0.8 click-ready brakes harder than deceleration")
expect(stateBrake(.settling) < 1, "V0.8 settling removes residual velocity")
