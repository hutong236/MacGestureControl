import Foundation
import CoreGraphics

struct HandSample: Equatable {
    let x: Double
    let y: Double
    let timestamp: TimeInterval
    let confidence: Double
}

enum ControlMode: String, CaseIterable, Codable, Identifiable {
    case trackpad
    case page

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .trackpad: return "空中触控板"
        case .page: return "翻页"
        }
    }
}

enum TrackpadInteraction: String, Equatable {
    case idle
    case pointer
    case dragging
    case scrolling
    case zooming
    case systemSwipe

    var displayName: String {
        switch self {
        case .idle: return "等待手势"
        case .pointer: return "指针移动"
        case .dragging: return "捏合拖拽"
        case .scrolling: return "双指滚动"
        case .zooming: return "双指缩放"
        case .systemSwipe: return "多指系统手势"
        }
    }
}

/// V0.9 双指滚动相位。用于区分接触、直接操控和惯性滑行，避免起步/抬手瞬间跳变。
enum ScrollMotionPhase: String, Equatable {
    case idle
    case contact
    case tracking
    case coasting

    var displayName: String {
        switch self {
        case .idle: return "等待"
        case .contact: return "接触"
        case .tracking: return "滚动"
        case .coasting: return "惯性"
        }
    }
}

/// 指针意图状态。它不是新的用户手势，而是对最近几帧轨迹的运动阶段判断。
enum PointerMotionPhase: String, Equatable {
    case idle
    case accelerating
    case cruising
    case decelerating
    case settling
    case clickReady
    case dragging

    var displayName: String {
        switch self {
        case .idle: return "等待"
        case .accelerating: return "加速"
        case .cruising: return "移动"
        case .decelerating: return "减速"
        case .settling: return "停驻"
        case .clickReady: return "准备点击"
        case .dragging: return "拖拽"
        }
    }
}

struct TrackpadSample: Equatable {
    /// Palm center: used by three/four-finger system swipes.
    let centerX: Double
    let centerY: Double
    /// Stabilized index-finger point: used by pointer / drag.
    let pointerX: Double
    let pointerY: Double
    /// Stabilized midpoint of index + middle fingers: used by two-finger scroll.
    let scrollX: Double
    let scrollY: Double
    /// Pointer / scroll landmarks have their own confidence. A valid palm observation must not
    /// masquerade as a valid fingertip observation.
    let pointerObservationConfidence: Double
    let scrollObservationConfidence: Double
    /// Wrist -> middle MCP distance in normalized Vision coordinates.
    /// Used to compensate for the hand moving closer to / farther from the camera.
    let palmScale: Double?
    let pinchRatio: Double?
    let twoFingerSpan: Double?
    let fingerPattern: FingerPattern?
    /// 这帧代表的观测时间（在 Vision 推理开始前记录）。
    let timestamp: TimeInterval
    /// 从收到摄像头帧到 Vision 推理完成的本机处理延迟。
    let processingLatency: TimeInterval
    let confidence: Double
}

enum GestureDirection: String, CaseIterable, Codable, Identifiable {
    case left
    case right
    case up
    case down

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .left: return "向左挥"
        case .right: return "向右挥"
        case .up: return "向上挥"
        case .down: return "向下挥"
        }
    }

    var symbolName: String {
        switch self {
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        case .up: return "arrow.up"
        case .down: return "arrow.down"
        }
    }
}

enum KeyActionPreset: String, CaseIterable, Codable, Identifiable {
    case leftArrow
    case rightArrow
    case upArrow
    case downArrow
    case pageUp
    case pageDown
    case space
    case escape
    case returnKey
    case home
    case end

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .leftArrow: return "← 左方向键"
        case .rightArrow: return "→ 右方向键"
        case .upArrow: return "↑ 上方向键"
        case .downArrow: return "↓ 下方向键"
        case .pageUp: return "Page Up"
        case .pageDown: return "Page Down"
        case .space: return "Space"
        case .escape: return "Esc"
        case .returnKey: return "Return"
        case .home: return "Home"
        case .end: return "End"
        }
    }

    var keyCode: CGKeyCode {
        switch self {
        case .leftArrow: return 123
        case .rightArrow: return 124
        case .downArrow: return 125
        case .upArrow: return 126
        case .pageUp: return 116
        case .pageDown: return 121
        case .space: return 49
        case .escape: return 53
        case .returnKey: return 36
        case .home: return 115
        case .end: return 119
        }
    }
}

struct GestureBindings: Codable, Equatable {
    var left: KeyActionPreset = .leftArrow
    var right: KeyActionPreset = .rightArrow
    var up: KeyActionPreset = .upArrow
    var down: KeyActionPreset = .downArrow

    subscript(direction: GestureDirection) -> KeyActionPreset {
        get {
            switch direction {
            case .left: return left
            case .right: return right
            case .up: return up
            case .down: return down
            }
        }
        set {
            switch direction {
            case .left: left = newValue
            case .right: right = newValue
            case .up: up = newValue
            case .down: down = newValue
            }
        }
    }
}

struct FingerPattern: Codable, Equatable, Hashable {
    let thumb: Bool
    let index: Bool
    let middle: Bool
    let ring: Bool
    let little: Bool

    var displayName: String {
        let states = [thumb, index, middle, ring, little].map { $0 ? "●" : "○" }.joined()
        return "拇食中无小 \(states)"
    }

    var shortDescription: String {
        let names = ["拇", "食", "中", "无", "小"]
        let states = [thumb, index, middle, ring, little]
        let extended = zip(names, states).compactMap { $0.1 ? $0.0 : nil }
        return extended.isEmpty ? "握拳" : "伸展：\(extended.joined(separator: "、"))"
    }

    var extendedCount: Int {
        [thumb, index, middle, ring, little].filter { $0 }.count
    }

    /// 类似触控板“一指”：允许拇指检测有少量抖动，但要求其余三指收起。
    var isPointerPose: Bool {
        index && !middle && !ring && !little
    }

    /// 类似触控板“双指滚动”：拇指状态不参与判定，降低 Vision 抖动影响。
    var isTwoFingerPose: Bool {
        index && middle && !ring && !little
    }

    /// V1.2 双手辅助：辅助手张开作为“离合/重定位”，拇指状态不参与，降低识别抖动。
    var isOpenPalmPose: Bool {
        index && middle && ring && little
    }

    /// 保守的握拳识别，可作为未来辅助手动作扩展。
    var isFistPose: Bool {
        !thumb && !index && !middle && !ring && !little
    }

    /// 三指或四指作为系统级滑动手势。
    var isSystemSwipePose: Bool {
        if index && middle && ring && !little { return true }
        if index && middle && ring && little { return true }
        return false
    }
}

struct CustomStaticGesture: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var pattern: FingerPattern
    var action: KeyActionPreset
    var enabled: Bool

    init(
        id: UUID = UUID(),
        name: String,
        pattern: FingerPattern,
        action: KeyActionPreset,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.action = action
        self.enabled = enabled
    }
}
