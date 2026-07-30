import Foundation
import AlethiaCore

/// Resolves local whisper.cpp CLI + GGML model paths for on-device ASR.
public struct WhisperCPPConfiguration: Sendable, Equatable {
    public var cliPath: URL
    public var modelPath: URL
    public var language: String?

    public init(cliPath: URL, modelPath: URL, language: String? = "en") {
        self.cliPath = cliPath
        self.modelPath = modelPath
        self.language = language
    }

    /// Environment overrides used by Darwin CI:
    /// `ALETHIA_WHISPER_CLI`, `ALETHIA_WHISPER_MODEL`
    public static func fromEnvironment(fileManager: FileManager = .default) -> WhisperCPPConfiguration? {
        let env = ProcessInfo.processInfo.environment
        guard
            let cli = env["ALETHIA_WHISPER_CLI"], !cli.isEmpty,
            let model = env["ALETHIA_WHISPER_MODEL"], !model.isEmpty
        else { return nil }
        let cliURL = URL(fileURLWithPath: cli)
        let modelURL = URL(fileURLWithPath: model)
        guard fileManager.isExecutableFile(atPath: cliURL.path),
              fileManager.fileExists(atPath: modelURL.path) else { return nil }
        return WhisperCPPConfiguration(cliPath: cliURL, modelPath: modelURL)
    }

    public static func defaultLocal(fileManager: FileManager = .default) -> WhisperCPPConfiguration? {
        if let env = fromEnvironment(fileManager: fileManager) { return env }
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let candidates: [(String, String)] = [
            (".tools/whisper.cpp/build/bin/whisper-cli", "Models/ggml-tiny.bin"),
            (".tools/whisper.cpp/build/bin/whisper-cli", "Models/ggml-large-v3-turbo-q5_0.bin"),
        ]
        for (cliRel, modelRel) in candidates {
            let cli = cwd.appendingPathComponent(cliRel)
            let model = cwd.appendingPathComponent(modelRel)
            if fileManager.isExecutableFile(atPath: cli.path), fileManager.fileExists(atPath: model.path) {
                return WhisperCPPConfiguration(cliPath: cli, modelPath: model)
            }
        }
        return nil
    }
}

/// On-device ASR via whisper.cpp CLI (Metal-enabled binary built by Scripts/setup-whisper-darwin.sh).
public struct WhisperCPPRecognizer: SpeechRecognizing {
    public let configuration: WhisperCPPConfiguration

    public init(configuration: WhisperCPPConfiguration) {
        self.configuration = configuration
    }

    public func transcribe(pcm: [Float], sampleRate: Double) async throws -> [TranscriptSegment] {
        guard !pcm.isEmpty else { return [] }
        let wav = try Self.writeTempWAV(pcm: pcm, sampleRate: sampleRate)
        defer { try? FileManager.default.removeItem(at: wav) }

        let output = try await runCLI(wav: wav)
        return Self.parseTranscript(output, fallbackDurationMs: Int(Double(pcm.count) / sampleRate * 1000))
    }

    private func runCLI(wav: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    process.executableURL = configuration.cliPath
                    var args = [
                        "-m", configuration.modelPath.path,
                        "-f", wav.path,
                        "-nt", // no timestamps in plain mode; we also try JSON if available
                        "-np"
                    ]
                    if let language = configuration.language {
                        args += ["-l", language]
                    }
                    process.arguments = args
                    let pipe = Pipe()
                    let err = Pipe()
                    process.standardOutput = pipe
                    process.standardError = err
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = err.fileHandleForReading.readDataToEndOfFile()
                    guard process.terminationStatus == 0 else {
                        let message = String(data: errData, encoding: .utf8) ?? "whisper-cli failed"
                        continuation.resume(throwing: AlethiaError.audioEngine(message))
                        return
                    }
                    continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public static func parseTranscript(_ raw: String, fallbackDurationMs: Int) -> [TranscriptSegment] {
        let cleaned = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { line in
                let lower = line.lowercased()
                if lower.hasPrefix("whisper_") || lower.hasPrefix("system_info") { return false }
                if lower.hasPrefix("main:") || lower.hasPrefix("ggml_") { return false }
                return true
            }
            .map { line in
                // Strip leading timestamp markers like [00:00:00.000 --> 00:00:01.000]
                if let end = line.firstIndex(of: "]") {
                    return String(line[line.index(after: end)...]).trimmingCharacters(in: .whitespaces)
                }
                return line
            }
            .filter { !$0.isEmpty }
        let text = cleaned.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return [TranscriptSegment(startMs: 0, endMs: max(fallbackDurationMs, 1), text: text)]
    }

    public static func writeTempWAV(pcm: [Float], sampleRate: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alethia-\(UUID().uuidString).wav")
        let data = try PCMWAVEncoder.encode(pcm: pcm, sampleRate: Int(sampleRate))
        try data.write(to: url)
        return url
    }
}

enum PCMWAVEncoder {
    static func encode(pcm: [Float], sampleRate: Int) throws -> Data {
        var data = Data()
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * bitsPerSample / 8
        var samples = Data(capacity: pcm.count * 2)
        for s in pcm {
            let clipped = max(-1.0, min(1.0, s))
            var value = Int16((clipped * Float(Int16.max)).rounded())
            samples.append(Data(bytes: &value, count: 2))
        }
        let dataSize = UInt32(samples.count)
        func appendASCII(_ string: String) { data.append(contentsOf: string.utf8) }
        func appendU16(_ v: UInt16) { var le = v.littleEndian; data.append(Data(bytes: &le, count: 2)) }
        func appendU32(_ v: UInt32) { var le = v.littleEndian; data.append(Data(bytes: &le, count: 4)) }

        appendASCII("RIFF")
        appendU32(36 + dataSize)
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendU32(16)
        appendU16(1) // PCM
        appendU16(channels)
        appendU32(UInt32(sampleRate))
        appendU32(byteRate)
        appendU16(blockAlign)
        appendU16(bitsPerSample)
        appendASCII("data")
        appendU32(dataSize)
        data.append(samples)
        return data
    }
}

public enum ASRFactory {
    /// Prefer whisper.cpp when CLI+model exist; otherwise stub (keeps unit tests offline).
    public static func makeDefault() -> any SpeechRecognizing {
        if let config = WhisperCPPConfiguration.defaultLocal() {
            return WhisperCPPRecognizer(configuration: config)
        }
        return WhisperStubRecognizer()
    }
}
