import Foundation

public enum AlethiaError: Error, LocalizedError, Sendable, Equatable {
    case microphonePermissionDenied
    case accessibilityPermissionDenied
    case screenRecordingPermissionDenied
    case modelsNotReady(String)
    case modelDownloadFailed(String)
    case recognitionFailed(String)
    case diarizationFailed(String)
    case audioEngine(String)
    case database(String)
    case languageModel(String)
    case notFound(String)
    case invalidInput(String)

    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone access is required. Enable Alethia in System Settings → Privacy & Security → Microphone."
        case .accessibilityPermissionDenied:
            return "Accessibility access is required to type dictated text into other apps. Enable Alethia in System Settings → Privacy & Security → Accessibility."
        case .screenRecordingPermissionDenied:
            return "Screen Recording access is required to capture system audio from calls. Enable Alethia in System Settings → Privacy & Security → Screen Recording."
        case .modelsNotReady(let detail):
            return "Speech models are not ready: \(detail)"
        case .modelDownloadFailed(let detail):
            return "Model download failed: \(detail)"
        case .recognitionFailed(let detail):
            return "Speech recognition failed: \(detail)"
        case .diarizationFailed(let detail):
            return "Speaker detection failed: \(detail)"
        case .audioEngine(let detail):
            return "Audio error: \(detail)"
        case .database(let detail):
            return "Storage error: \(detail)"
        case .languageModel(let detail):
            return "Language model error: \(detail)"
        case .notFound(let detail):
            return "Not found: \(detail)"
        case .invalidInput(let detail):
            return detail
        }
    }
}
