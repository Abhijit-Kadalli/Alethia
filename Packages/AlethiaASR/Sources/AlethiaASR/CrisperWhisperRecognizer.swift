import Foundation
import AlethiaCore

public enum ASRMode: String, Sendable, Equatable {
    case intended
    case verbatim
}

/// Resolves CrisperWhisper sidecar base URL.
public struct CrisperWhisperConfiguration: Sendable, Equatable {
    public var baseURL: URL
    public var language: String
    public var defaultMode: ASRMode

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:8765")!,
        language: String = "en",
        defaultMode: ASRMode = .intended
    ) {
        self.baseURL = baseURL
        self.language = language
        self.defaultMode = defaultMode
    }

    /// `ALETHIA_CRISPER_URL` (e.g. http://127.0.0.1:8765)
    public static func fromEnvironment() -> CrisperWhisperConfiguration? {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["ALETHIA_CRISPER_URL"], !raw.isEmpty,
              let url = URL(string: raw) else { return nil }
        return CrisperWhisperConfiguration(baseURL: url)
    }

    public static func defaultLocal() -> CrisperWhisperConfiguration {
        fromEnvironment() ?? CrisperWhisperConfiguration()
    }
}

/// On-device ASR via the local CrisperWhisper Python sidecar.
public struct CrisperWhisperRecognizer: SpeechRecognizing {
    public let configuration: CrisperWhisperConfiguration

    public init(configuration: CrisperWhisperConfiguration = .defaultLocal()) {
        self.configuration = configuration
    }

    public func transcribe(pcm: [Float], sampleRate: Double) async throws -> [TranscriptSegment] {
        try await transcribe(pcm: pcm, sampleRate: sampleRate, mode: configuration.defaultMode)
    }

    public func transcribe(pcm: [Float], sampleRate: Double, mode: ASRMode) async throws -> [TranscriptSegment] {
        guard !pcm.isEmpty else { return [] }
        let wav = try PCMWAVEncoder.encode(pcm: pcm, sampleRate: Int(sampleRate))
        let fallbackMs = Int(Double(pcm.count) / sampleRate * 1000)

        var components = URLComponents(url: configuration.baseURL.appendingPathComponent("transcribe"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "mode", value: mode.rawValue),
            URLQueryItem(name: "language", value: configuration.language),
            URLQueryItem(name: "word_timestamps", value: "0")
        ]
        guard let url = components.url else {
            throw AlethiaError.audioEngine("Invalid CrisperWhisper URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        let boundary = "alethia-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipartBody(boundary: boundary, fieldName: "audio", filename: "audio.wav", data: wav)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AlethiaError.modelMissing(
                "CrisperWhisper sidecar unreachable at \(configuration.baseURL.absoluteString). Run ./Scripts/setup-crisperwhisper.sh && ./Scripts/start-crisper-sidecar.sh"
            )
        }

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AlethiaError.audioEngine("CrisperWhisper sidecar error: \(body)")
        }

        return try Self.parseResponse(data, fallbackDurationMs: max(fallbackMs, 1))
    }

    public static func isHealthy(baseURL: URL = CrisperWhisperConfiguration.defaultLocal().baseURL) async -> Bool {
        let url = baseURL.appendingPathComponent("health")
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ok = obj["ok"] as? Bool {
                return ok
            }
            return true
        } catch {
            return false
        }
    }

    public static func parseResponse(_ data: Data, fallbackDurationMs: Int) throws -> [TranscriptSegment] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AlethiaError.audioEngine("Invalid CrisperWhisper JSON")
        }
        if let stub = obj["stub"] as? Bool, stub {
            let allow = ProcessInfo.processInfo.environment["ALETHIA_CRISPER_ALLOW_STUB"]
                .map { ["1", "true", "yes"].contains($0.lowercased()) } ?? false
            if !allow {
                throw AlethiaError.modelMissing(
                    "CrisperWhisper sidecar is in STUB mode. Run ./Scripts/setup-crisperwhisper.sh (without ALETHIA_CRISPER_STUB) then ./Scripts/run-app.sh"
                )
            }
        }
        if let segments = obj["segments"] as? [[String: Any]], !segments.isEmpty {
            return segments.compactMap { item in
                guard let text = item["text"] as? String else { return nil }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                let start = item["start_ms"] as? Int ?? 0
                let end = item["end_ms"] as? Int ?? fallbackDurationMs
                return TranscriptSegment(startMs: start, endMs: max(end, start + 1), text: trimmed)
            }
        }
        let text = (obj["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return [TranscriptSegment(startMs: 0, endMs: max(fallbackDurationMs, 1), text: text)]
    }

    private func multipartBody(boundary: String, fieldName: String, filename: String, data: Data) -> Data {
        var body = Data()
        func append(_ string: String) { body.append(contentsOf: string.utf8) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")
        return body
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

/// Best-effort launcher for the local Python sidecar process.
public enum CrisperSidecarLauncher {
    /// Returns true if health check succeeds (starts process if needed and waits briefly).
    @discardableResult
    public static func ensureRunning(
        configuration: CrisperWhisperConfiguration = .defaultLocal(),
        fileManager: FileManager = .default
    ) async -> Bool {
        if await CrisperWhisperRecognizer.isHealthy(baseURL: configuration.baseURL) {
            return true
        }
        guard let script = resolveStartScript(fileManager: fileManager) else {
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if await CrisperWhisperRecognizer.isHealthy(baseURL: configuration.baseURL) {
                return true
            }
        }
        return false
    }

    private static func resolveStartScript(fileManager: FileManager) -> URL? {
        let env = ProcessInfo.processInfo.environment
        var roots: [URL] = []
        if let root = env["ALETHIA_ROOT"], !root.isEmpty {
            roots.append(URL(fileURLWithPath: root))
        }
        if let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let marker = support.appendingPathComponent("Alethia/repo_root.txt")
            if let data = try? Data(contentsOf: marker),
               let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                roots.append(URL(fileURLWithPath: path))
            }
        }
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        roots.append(cwd)
        var current = cwd
        for _ in 0..<8 {
            if fileManager.fileExists(atPath: current.appendingPathComponent("Package.swift").path) {
                roots.append(current)
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        for root in roots {
            let script = root.appendingPathComponent("Scripts/start-crisper-sidecar.sh")
            if fileManager.isExecutableFile(atPath: script.path) || fileManager.fileExists(atPath: script.path) {
                return script
            }
        }
        return nil
    }
}

public enum ASRFactory {
    /// Prefer CrisperWhisper sidecar when healthy; otherwise stub (keeps unit tests offline).
    public static func makeDefault() -> any SpeechRecognizing {
        CrisperWhisperRecognizer(configuration: .defaultLocal())
    }
}
