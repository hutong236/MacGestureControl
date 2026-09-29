import AVFoundation
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum InputControlPermissionState: Equatable {
    case ready
    case restartRequired
    case notGranted
}

struct PermissionManager {
    static var cameraAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    /// Accessibility pane status. This is useful for explaining what the user sees
    /// in System Settings, but it is not the final gate used by CGEvent posting.
    static var accessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// GestureControl sends keyboard input through CGEvent. The PostEvent preflight
    /// is the authoritative runtime gate for that operation on modern macOS.
    static var postEventAuthorized: Bool {
        if #available(macOS 10.15, *) {
            return CGPreflightPostEventAccess()
        }
        return AXIsProcessTrusted()
    }

    static var inputControlState: InputControlPermissionState {
        if postEventAuthorized {
            return .ready
        }
        if accessibilityTrusted {
            // TCC may keep the PostEvent decision frozen for the lifetime of the
            // current process. The Settings toggle can already be ON while this
            // running process still sees the old decision.
            return .restartRequired
        }
        return .notGranted
    }

    static func requestCamera(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    /// Call only from an explicit user action, or once on first enable.
    @discardableResult
    static func requestInputControl() -> Bool {
        if #available(macOS 10.15, *) {
            return CGRequestPostEventAccess()
        }

        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openCameraPrivacySettings() {
        openPrivacyPane("Privacy_Camera")
    }

    static func openAccessibilityPrivacySettings() {
        openPrivacyPane("Privacy_Accessibility")
    }

    private static func openPrivacyPane(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
