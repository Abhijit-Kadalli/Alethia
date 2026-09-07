#if canImport(AppKit)
import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation

public enum PermissionState: String, Sendable {
    case granted
    case denied
    case notDetermined
}

/// Central place for TCC permission checks and System Settings deep links.
@MainActor
public final class PermissionGate {
    public init() {}

    // MARK: Microphone

    public func microphoneState() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    public func requestMicrophone() async -> PermissionState {
        if microphoneState() == .granted { return .granted }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        return granted ? .granted : .denied
    }

    public func requireMicrophone() async throws {
        guard await requestMicrophone() == .granted else {
            throw AlethiaError.microphonePermissionDenied
        }
    }

    // MARK: Accessibility (typing into other apps, global hotkeys)

    public func accessibilityTrusted(prompt: Bool) -> Bool {
        if prompt {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
        return AXIsProcessTrusted()
    }

    // MARK: Screen Recording (system audio via ScreenCaptureKit)

    public func screenRecordingGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Shows the system prompt once; later calls only open System Settings.
    @discardableResult
    public func requestScreenRecording() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }

    // MARK: System Settings deep links

    public func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    public func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    public func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    public func openCalendarSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
    }

    private func open(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
#endif
