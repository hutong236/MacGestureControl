import Foundation

struct HandSample {
    let x: Double
    let y: Double
    let timestamp: TimeInterval
    let confidence: Double
}

enum GestureDirection: String { case left, right, up, down }

final class Engine {
    var samples: [HandSample] = []
    var minimumDistance = 0.18
    var minimumVelocity = 0.36
    var dominanceRatio = 1.35

    func process(_ sample: HandSample) -> GestureDirection? {
        samples.append(sample)
        guard let start = samples.first else { return nil }
        let dt = sample.timestamp - start.timestamp
        guard dt >= 0.10 else { return nil }
        let dx = sample.x - start.x
        let dy = sample.y - start.y
        let ax = abs(dx), ay = abs(dy)
        let distance = hypot(dx, dy)
        guard distance >= minimumDistance, distance / dt >= minimumVelocity else { return nil }
        if ax > ay * dominanceRatio { return dx > 0 ? .right : .left }
        if ay > ax * dominanceRatio { return dy > 0 ? .up : .down }
        return nil
    }
}

func assertDirection(_ expected: GestureDirection, points: [(Double, Double)]) {
    let engine = Engine()
    var result: GestureDirection?
    for (index, point) in points.enumerated() {
        result = engine.process(HandSample(x: point.0, y: point.1, timestamp: Double(index) * 0.08, confidence: 1)) ?? result
    }
    precondition(result == expected, "expected \(expected.rawValue), got \(String(describing: result))")
    print("PASS: \(expected.rawValue)")
}

assertDirection(.right, points: [(0.2,0.5),(0.28,0.51),(0.40,0.50),(0.55,0.49),(0.70,0.50)])
assertDirection(.left, points: [(0.8,0.5),(0.71,0.49),(0.59,0.50),(0.44,0.51),(0.28,0.50)])
assertDirection(.up, points: [(0.5,0.2),(0.51,0.29),(0.49,0.41),(0.50,0.56),(0.50,0.72)])
assertDirection(.down, points: [(0.5,0.8),(0.49,0.72),(0.51,0.60),(0.50,0.45),(0.50,0.28)])
