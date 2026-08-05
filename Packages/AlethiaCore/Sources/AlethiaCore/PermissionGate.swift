import AVFoundation
import AppKit
import ApplicationServices
import Foundation

public enum PermissionStatus: String, Sendable {
    case granted
    case denied
    case notDetermined
}

public final class PermissionGate: @unchecked Sendable {
    public init() {}

    public func microphoneStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    public func requestMicrophone() async -> PermissionStatus {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        return granted ? .granted : .denied
    }

    public func accessibilityTrusted(prompt: Bool = false) -> Bool {
        // Prefer the non-prompting check first; prompting every call spams the user.
        if AXIsProcessTrusted() { return true }
        guard prompt else { return false }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public func openAccessibilitySettings() {
        // macOS 13+ Settings deep link; fall back to legacy pane.
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }

    public func requireMicrophone() async throws {
        switch microphoneStatus() {
        case .granted:
            return
        case .notDetermined:
            let status = await requestMicrophone()
            guard status == .granted else { throw AlethiaError.microphonePermissionDenied }
        case .denied:
            throw AlethiaError.microphonePermissionDenied
        }
    }

    public func requireAccessibility(prompt: Bool = true) throws {
        if accessibilityTrusted(prompt: false) { return }
        if prompt {
            _ = accessibilityTrusted(prompt: true)
            openAccessibilitySettings()
        }
        throw AlethiaError.accessibilityPermissionDenied
    }
}
