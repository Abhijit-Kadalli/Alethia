import AVFoundation
import ApplicationServices
import Foundation

public enum PermissionStatus: String, Sendable {
    case granted
    case denied
    case notDetermined
}

@MainActor
public final class PermissionGate {
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
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
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
        guard accessibilityTrusted(prompt: prompt) else {
            throw AlethiaError.accessibilityPermissionDenied
        }
    }
}
