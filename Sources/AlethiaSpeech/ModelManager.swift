#if os(macOS)
import Combine
import CoreML
import FluidAudio
import Foundation
import AlethiaCore

/// A downloadable on-device model.
public enum ModelComponent: String, CaseIterable, Sendable, Identifiable, Hashable {
    case parakeetV2
    case parakeetV3
    case vad
    case diarizer

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .parakeetV2: return "Parakeet TDT 0.6B v2 · English"
        case .parakeetV3: return "Parakeet TDT 0.6B v3 · 25 languages"
        case .vad: return "Silero voice activity detector"
        case .diarizer: return "Speaker diarization (pyannote)"
        }
    }

    public var detail: String {
        switch self {
        case .parakeetV2: return "Speech recognition, highest English accuracy. ~600 MB."
        case .parakeetV3: return "Speech recognition with automatic language detection. ~600 MB."
        case .vad: return "Finds speech in audio so silence is skipped. ~2 MB."
        case .diarizer: return "Tells speakers apart in meetings. ~30 MB."
        }
    }

    public var approximateBytes: Int64 {
        switch self {
        case .parakeetV2, .parakeetV3: return 620 * 1024 * 1024
        case .vad: return 2 * 1024 * 1024
        case .diarizer: return 32 * 1024 * 1024
        }
    }

    public var license: String {
        switch self {
        case .parakeetV2, .parakeetV3: return "NVIDIA · CC-BY-4.0"
        case .vad: return "Silero · MIT"
        case .diarizer: return "pyannote · CC-BY-4.0 (wespeaker embeddings)"
        }
    }

    public static func asr(for variant: SpeechModelVariant) -> ModelComponent {
        variant == .parakeetV2English ? .parakeetV2 : .parakeetV3
    }

    public static func required(for variant: SpeechModelVariant) -> [ModelComponent] {
        [asr(for: variant), .vad, .diarizer]
    }
}

public enum ModelInstallState: Equatable, Sendable {
    case notInstalled
    case downloading(fraction: Double, phase: String)
    case installed
    case failed(String)

    public var isInstalled: Bool { self == .installed }
    public var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }
}

/// Tracks which models are on disk and downloads missing ones with progress.
///
/// Models live in FluidAudio's cache (`~/Library/Application Support/FluidAudio/Models`) so
/// other FluidAudio-based apps on the Mac share the same 600 MB download.
@MainActor
public final class ModelManager: ObservableObject {
    @Published public private(set) var states: [ModelComponent: ModelInstallState] = [:]
    @Published public private(set) var activeDownloads = 0

    private var tasks: [ModelComponent: Task<Void, Error>] = [:]
    private let log = Log("Models")

    public init() {
        refresh()
    }

    public var modelsDirectory: URL {
        MLModelConfigurationUtils.defaultModelsDirectory()
    }

    public func state(of component: ModelComponent) -> ModelInstallState {
        states[component] ?? .notInstalled
    }

    public func allInstalled(for variant: SpeechModelVariant) -> Bool {
        ModelComponent.required(for: variant).allSatisfy { state(of: $0).isInstalled }
    }

    /// Only the recognizer is strictly required to dictate; VAD and diarizer improve meetings.
    public func recognizerInstalled(for variant: SpeechModelVariant) -> Bool {
        state(of: ModelComponent.asr(for: variant)).isInstalled
    }

    /// Combined 0…1 progress across the components required for `variant`.
    public func overallProgress(for variant: SpeechModelVariant) -> Double {
        let required = ModelComponent.required(for: variant)
        let weights = required.map { Double($0.approximateBytes) }
        let total = weights.reduce(0, +)
        var done: Double = 0
        for (component, weight) in zip(required, weights) {
            switch state(of: component) {
            case .installed: done += weight
            case .downloading(let fraction, _): done += weight * fraction
            default: break
            }
        }
        return total > 0 ? done / total : 0
    }

    public func refresh() {
        for component in ModelComponent.allCases where !(states[component]?.isDownloading ?? false) {
            states[component] = isInstalled(component) ? .installed : .notInstalled
        }
    }

    private func isInstalled(_ component: ModelComponent) -> Bool {
        switch component {
        case .parakeetV2:
            return AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v2), version: .v2)
        case .parakeetV3:
            return AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
        case .vad:
            return Self.containsCompiledModel(modelsDirectory.appendingPathComponent("silero-vad"))
        case .diarizer:
            let dir = DiarizerModels.defaultModelsDirectory()
            return FileManager.default.fileExists(atPath: dir.appendingPathComponent("pyannote_segmentation.mlmodelc").path)
                && FileManager.default.fileExists(atPath: dir.appendingPathComponent("wespeaker_v2.mlmodelc").path)
        }
    }

    private static func containsCompiledModel(_ directory: URL) -> Bool {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return false }
        return items.contains { $0.hasSuffix(".mlmodelc") }
    }

    public func installedBytes(_ component: ModelComponent) -> Int64 {
        let directory: URL
        switch component {
        case .parakeetV2: directory = AsrModels.defaultCacheDirectory(for: .v2)
        case .parakeetV3: directory = AsrModels.defaultCacheDirectory(for: .v3)
        case .vad: directory = modelsDirectory.appendingPathComponent("silero-vad")
        case .diarizer: directory = DiarizerModels.defaultModelsDirectory()
        }
        return Self.directorySize(directory)
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    // MARK: Downloads

    /// Download everything `variant` needs. Throws the first failure after all attempts finish.
    public func downloadRequired(for variant: SpeechModelVariant) async throws {
        var firstError: Error?
        for component in ModelComponent.required(for: variant) where !state(of: component).isInstalled {
            do {
                try await download(component)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    public func download(_ component: ModelComponent) async throws {
        if let existing = tasks[component] {
            return try await existing.value
        }
        states[component] = .downloading(fraction: 0, phase: "Starting…")
        activeDownloads += 1
        let handler: ProgressHandler = { [weak self] progress in
            let phase: String
            switch progress.phase {
            case .listing: phase = "Preparing…"
            case .downloading(let done, let total): phase = "Downloading \(done + 1) of \(total)"
            case .compiling(let name): phase = "Optimizing \(name) for this Mac…"
            }
            let fraction = progress.fractionCompleted
            Task { @MainActor in
                guard let self, case .downloading = self.state(of: component) else { return }
                self.states[component] = .downloading(fraction: fraction, phase: phase)
            }
        }
        let task = Task<Void, Error> {
            switch component {
            case .parakeetV2:
                _ = try await AsrModels.download(version: .v2, progressHandler: handler)
            case .parakeetV3:
                _ = try await AsrModels.download(version: .v3, progressHandler: handler)
            case .vad:
                _ = try await VadManager(progressHandler: handler)
            case .diarizer:
                _ = try await DiarizerModels.download(progressHandler: handler)
            }
        }
        tasks[component] = task
        defer {
            tasks[component] = nil
            activeDownloads -= 1
        }
        do {
            try await task.value
            states[component] = isInstalled(component) ? .installed : .failed("Download finished but files are missing.")
            log.info("installed \(component.rawValue)")
        } catch is CancellationError {
            states[component] = isInstalled(component) ? .installed : .notInstalled
            throw CancellationError()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            states[component] = .failed(message)
            log.error("download \(component.rawValue) failed: \(message)")
            throw AlethiaError.modelDownloadFailed(message)
        }
    }

    public func cancelDownload(_ component: ModelComponent) {
        tasks[component]?.cancel()
    }

    public func delete(_ component: ModelComponent) throws {
        let directory: URL
        switch component {
        case .parakeetV2: directory = AsrModels.defaultCacheDirectory(for: .v2)
        case .parakeetV3: directory = AsrModels.defaultCacheDirectory(for: .v3)
        case .vad: directory = modelsDirectory.appendingPathComponent("silero-vad")
        case .diarizer: directory = DiarizerModels.defaultModelsDirectory()
        }
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        refresh()
    }
}
#endif
