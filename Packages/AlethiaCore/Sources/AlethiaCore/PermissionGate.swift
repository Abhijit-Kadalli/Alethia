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
    /// Prevents the system AX dialog + Settings jump from firing on every failed paste.
    private let promptLock = NSLock()
    private var didPromptAccessibilityThisLaunch = false

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
        if AXIsProcessTrusted() { return true }
        guard prompt else { return false }
        promptLock.lock()
        let already = didPromptAccessibilityThisLaunch
        if !already { didPromptAccessibilityThisLaunch = true }
        promptLock.unlock()
        guard !already else { return false }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// One Settings jump per launch max (call after an explicit user action or first AX miss).
    public func openAccessibilitySettingsIfNeeded() {
        promptLock.lock()
        let already = didPromptAccessibilityThisLaunch
        if !already { didPromptAccessibilityThisLaunch = true }
        promptLock.unlock()
        // Always allow an explicit menu-button open; only gate the auto-jump via accessibilityTrusted(prompt:).
        openAccessibilitySettings()
    }

    public func openAccessibilitySettings() {
        openSystemSettings([
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        ])
    }

    public func openMicrophoneSettings() {
        openSystemSettings([
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone"
        ])
    }

    private func openSystemSettings(_ candidates: [String]) {
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
            // Only open Settings on the first miss this launch.
            promptLock.lock()
            let first = didPromptAccessibilityThisLaunch
            promptLock.unlock()
            if first {
                openAccessibilitySettings()
            }
        }
        throw AlethiaError.accessibilityPermissionDenied
    }

    /// Clear copy for the menu-bar status line when AX is off after a rebuild.
    public static let accessibilityRepairHint =
        "AX off for this build — System Settings → Privacy → Accessibility: remove Alethia, then add ~/Applications/Alethia.app and toggle ON"
}
