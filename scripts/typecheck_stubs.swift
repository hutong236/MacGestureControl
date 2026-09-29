import Foundation

struct HandSample: Equatable {
    let x: Double
    let y: Double
    let timestamp: TimeInterval
    let confidence: Double
}

enum TrackpadInteraction: String, Equatable { case idle, pointer, dragging, scrolling, zooming, systemSwipe }
enum ScrollMotionPhase: String, Equatable { case idle, contact, tracking, coasting }
enum PointerMotionPhase: String, Equatable { case idle, accelerating, cruising, decelerating, settling, clickReady, dragging }

enum GestureDirection: String, CaseIterable, Codable, Identifiable {
    case left, right, up, down
    var id: String { rawValue }
}

struct FingerPattern: Codable, Equatable, Hashable {
    let thumb: Bool
    let index: Bool
    let middle: Bool
    let ring: Bool
    let little: Bool
    var isPointerPose: Bool { index && !middle && !ring && !little }
    var isTwoFingerPose: Bool { index && middle && !ring && !little }
    var isSystemSwipePose: Bool {
        if index && middle && ring && !little { return true }
        if index && middle && ring && little { return true }
        return false
    }
}

struct TrackpadSample: Equatable {
    let centerX: Double
    let centerY: Double
    let pointerX: Double
    let pointerY: Double
    let scrollX: Double
    let scrollY: Double
    let pointerObservationConfidence: Double
    let scrollObservationConfidence: Double
    let palmScale: Double?
    let pinchRatio: Double?
    let twoFingerSpan: Double?
    let fingerPattern: FingerPattern?
    let timestamp: TimeInterval
    let processingLatency: TimeInterval
    let confidence: Double
}
