import AVFoundation
import Vision
import ImageIO

struct HandPoseResult {
    let centerX: Double
    let centerY: Double
    let pointerX: Double
    let pointerY: Double
    let scrollX: Double
    let scrollY: Double
    let pointerObservationConfidence: Double
    let scrollObservationConfidence: Double
    let palmScale: Double?
    let confidence: Double
    let fingerPattern: FingerPattern?
    let pinchRatio: Double?
    let twoFingerSpan: Double?
}

final class HandPoseDetector {
    private let request: VNDetectHumanHandPoseRequest
    private let requestLock = NSLock()

    init() {
        request = VNDetectHumanHandPoseRequest()
        // Performance-first default. AppController enables two-hand detection only when requested.
        request.maximumHandCount = 1
    }

    func setMaximumHandCount(_ count: Int) {
        requestLock.lock()
        request.maximumHandCount = min(max(count, 1), 2)
        requestLock.unlock()
    }

    /// Compatibility helper for callers that only need one hand.
    func detect(in sampleBuffer: CMSampleBuffer) -> HandPoseResult? {
        detectHands(in: sampleBuffer).first
    }

    /// Detect up to two hands from the same Vision request.
    /// Ordering from Vision is not treated as identity; AppController performs temporal assignment.
    func detectHands(in sampleBuffer: CMSampleBuffer) -> [HandPoseResult] {
        let handler = VNImageRequestHandler(
            cmSampleBuffer: sampleBuffer,
            orientation: .upMirrored,
            options: [:]
        )

        requestLock.lock()
        defer { requestLock.unlock() }
        do {
            try handler.perform([request])
            guard let observations = request.results, !observations.isEmpty else { return [] }
            return observations.compactMap(makeResult)
        } catch {
            return []
        }
    }

    private func makeResult(_ observation: VNHumanHandPoseObservation) -> HandPoseResult? {
        // Pull the full joint dictionary once per observation. Repeated recognizedPoint(_:) calls
        // add avoidable overhead in the camera/Vision hot path.
        guard let points = try? observation.recognizedPoints(.all) else { return nil }

        let palmJoints: [VNHumanHandPoseObservation.JointName] = [
            .wrist,
            .indexMCP,
            .middleMCP,
            .ringMCP,
            .littleMCP,
            .thumbCMC
        ]

        var palmPoints: [VNRecognizedPoint] = []
        for joint in palmJoints {
            if let point = points[joint], point.confidence >= 0.20 {
                palmPoints.append(point)
            }
        }

        // Two reliable palm points are enough to preserve short-term tracking.
        guard palmPoints.count >= 2 else { return nil }

        let centerX = palmPoints.reduce(0.0) { $0 + Double($1.location.x) } / Double(palmPoints.count)
        let centerY = palmPoints.reduce(0.0) { $0 + Double($1.location.y) } / Double(palmPoints.count)
        let confidence = palmPoints.reduce(0.0) { $0 + Double($1.confidence) } / Double(palmPoints.count)

        let wrist = recognized(.wrist, in: points, minimumConfidence: 0.20)
        let middleMCP = recognized(.middleMCP, in: points, minimumConfidence: 0.20)
        let indexTip = recognized(.indexTip, in: points, minimumConfidence: 0.25)
        let indexDIP = recognized(.indexDIP, in: points, minimumConfidence: 0.22)
        let middleTip = recognized(.middleTip, in: points, minimumConfidence: 0.25)
        let middleDIP = recognized(.middleDIP, in: points, minimumConfidence: 0.22)
        let thumbTip = recognized(.thumbTip, in: points, minimumConfidence: 0.25)

        // Tip + DIP same-frame fusion reduces jitter without temporal lag.
        let pointerX: Double
        let pointerY: Double
        let pointerObservationConfidence: Double
        if let indexTip, let indexDIP {
            pointerX = Double(indexTip.location.x) * 0.76 + Double(indexDIP.location.x) * 0.24
            pointerY = Double(indexTip.location.y) * 0.76 + Double(indexDIP.location.y) * 0.24
            pointerObservationConfidence = min(Double(indexTip.confidence), Double(indexDIP.confidence))
        } else if let indexTip {
            pointerX = Double(indexTip.location.x)
            pointerY = Double(indexTip.location.y)
            pointerObservationConfidence = Double(indexTip.confidence)
        } else if let indexDIP {
            pointerX = Double(indexDIP.location.x)
            pointerY = Double(indexDIP.location.y)
            pointerObservationConfidence = Double(indexDIP.confidence) * 0.85
        } else {
            // Keep a placeholder coordinate but mark it unusable. Palm center must never masquerade as pointer input.
            pointerX = centerX
            pointerY = centerY
            pointerObservationConfidence = 0
        }

        var scrollX = centerX
        var scrollY = centerY
        var scrollObservationConfidence = 0.0
        if let indexTip, let middleTip {
            let tipX = (Double(indexTip.location.x) + Double(middleTip.location.x)) * 0.5
            let tipY = (Double(indexTip.location.y) + Double(middleTip.location.y)) * 0.5
            if let indexDIP, let middleDIP {
                let dipX = (Double(indexDIP.location.x) + Double(middleDIP.location.x)) * 0.5
                let dipY = (Double(indexDIP.location.y) + Double(middleDIP.location.y)) * 0.5
                scrollX = tipX * 0.72 + dipX * 0.28
                scrollY = tipY * 0.72 + dipY * 0.28
                scrollObservationConfidence = min(
                    min(Double(indexTip.confidence), Double(middleTip.confidence)),
                    min(Double(indexDIP.confidence), Double(middleDIP.confidence))
                )
            } else {
                scrollX = tipX
                scrollY = tipY
                scrollObservationConfidence = min(Double(indexTip.confidence), Double(middleTip.confidence))
            }
        }

        var palmScale: Double?
        var pinchRatio: Double?
        var twoFingerSpan: Double?

        if let wrist, let middleMCP {
            let scale = max(distance(wrist, middleMCP), 0.001)
            palmScale = scale

            if let thumbTip, let indexTip {
                pinchRatio = distance(thumbTip, indexTip) / scale
            }
            if let indexTip, let middleTip {
                twoFingerSpan = distance(indexTip, middleTip) / scale
            }
        }

        let pattern = makeFingerPattern(points)

        return HandPoseResult(
            centerX: centerX,
            centerY: centerY,
            pointerX: pointerX,
            pointerY: pointerY,
            scrollX: scrollX,
            scrollY: scrollY,
            pointerObservationConfidence: pointerObservationConfidence,
            scrollObservationConfidence: scrollObservationConfidence,
            palmScale: palmScale,
            confidence: confidence,
            fingerPattern: pattern,
            pinchRatio: pinchRatio,
            twoFingerSpan: twoFingerSpan
        )
    }

    private func recognized(
        _ joint: VNHumanHandPoseObservation.JointName,
        in points: [VNHumanHandPoseObservation.JointName: VNRecognizedPoint],
        minimumConfidence: VNConfidence
    ) -> VNRecognizedPoint? {
        guard let point = points[joint],
              point.confidence >= minimumConfidence else {
            return nil
        }
        return point
    }

    private func distance(_ a: VNRecognizedPoint, _ b: VNRecognizedPoint) -> Double {
        hypot(Double(a.location.x - b.location.x), Double(a.location.y - b.location.y))
    }

    private func makeFingerPattern(
        _ points: [VNHumanHandPoseObservation.JointName: VNRecognizedPoint]
    ) -> FingerPattern? {
        let joints: [VNHumanHandPoseObservation.JointName] = [
            .wrist, .thumbTip, .thumbIP, .indexTip, .indexPIP,
            .middleTip, .middlePIP, .ringTip, .ringPIP, .littleTip, .littlePIP
        ]
        guard joints.allSatisfy({ points[$0]?.confidence ?? 0 >= 0.30 }),
              let wrist = points[.wrist],
              let thumbTip = points[.thumbTip],
              let thumbIP = points[.thumbIP],
              let indexTip = points[.indexTip],
              let indexPIP = points[.indexPIP],
              let middleTip = points[.middleTip],
              let middlePIP = points[.middlePIP],
              let ringTip = points[.ringTip],
              let ringPIP = points[.ringPIP],
              let littleTip = points[.littleTip],
              let littlePIP = points[.littlePIP] else {
            return nil
        }

        func extended(tip: VNRecognizedPoint, bend: VNRecognizedPoint, ratio: Double = 1.10) -> Bool {
            distance(tip, wrist) > distance(bend, wrist) * ratio
        }

        return FingerPattern(
            thumb: extended(tip: thumbTip, bend: thumbIP, ratio: 1.08),
            index: extended(tip: indexTip, bend: indexPIP),
            middle: extended(tip: middleTip, bend: middlePIP),
            ring: extended(tip: ringTip, bend: ringPIP),
            little: extended(tip: littleTip, bend: littlePIP)
        )
    }
}
