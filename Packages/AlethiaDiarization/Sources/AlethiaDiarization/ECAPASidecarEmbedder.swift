import Foundation
import AlethiaCore

/// Calls the local Crisper sidecar `POST /embed` (SpeechBrain ECAPA-TDNN → 192-d).
public struct ECAPASidecarEmbedder: SpeakerEmbeddingEngine, Sendable {
    public var baseURL: URL
    public var timeout: TimeInterval

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:8765")!,
        timeout: TimeInterval = 60
    ) {
        self.baseURL = baseURL
        self.timeout = timeout
    }

    public static func fromEnvironment() -> ECAPASidecarEmbedder {
        if let raw = ProcessInfo.processInfo.environment["ALETHIA_CRISPER_URL"],
           !raw.isEmpty,
           let url = URL(string: raw) {
            return ECAPASidecarEmbedder(baseURL: url)
        }
        return ECAPASidecarEmbedder()
    }

    public static func isAvailable(baseURL: URL = ECAPASidecarEmbedder.fromEnvironment().baseURL) -> Bool {
        let url = baseURL.appendingPathComponent("health")
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { sem.signal() }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ecapa = obj["ecapa"] as? [String: Any]
            else { return }
            if let loaded = ecapa["loaded"] as? Bool, loaded {
                ok = true
            } else if let enabled = ecapa["enabled"] as? Bool, enabled, ecapa["error"] == nil {
                // Enabled but not warmed yet — still try /embed (lazy load).
                ok = true
            }
        }.resume()
        _ = sem.wait(timeout: .now() + 2.5)
        return ok
    }

    public func embed(pcm: [Float], sampleRate: Double) throws -> [Float] {
        guard pcm.count > Int(sampleRate * 0.2) else {
            // Too short — return zeros (caller should skip / merge windows).
            return [Float](repeating: 0, count: 192)
        }
        let wav = try PCMWAVEncoder.encode(pcm: pcm, sampleRate: Int(sampleRate.rounded()))
        let url = baseURL.appendingPathComponent("embed")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        let boundary = "alethia-ecapa-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipart(boundary: boundary, wav: wav)

        let sem = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultError: Error?
        var status = 0
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { sem.signal() }
            resultError = error
            resultData = data
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        }.resume()
        let wait = sem.wait(timeout: .now() + timeout + 5)
        guard wait == .success else {
            throw AlethiaError.modelMissing("ECAPA sidecar timed out at \(baseURL.absoluteString)")
        }
        if let resultError {
            throw AlethiaError.modelMissing("ECAPA sidecar unreachable: \(resultError.localizedDescription)")
        }
        guard let resultData, (200..<300).contains(status) else {
            let body = resultData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            throw AlethiaError.modelMissing("ECAPA sidecar error \(status): \(body.prefix(200))")
        }
        guard
            let obj = try JSONSerialization.jsonObject(with: resultData) as? [String: Any],
            let arr = obj["embedding"] as? [Any]
        else {
            throw AlethiaError.modelMissing("ECAPA response missing embedding")
        }
        let emb = arr.compactMap { ($0 as? NSNumber)?.floatValue }
        guard emb.count >= 128 else {
            throw AlethiaError.modelMissing("ECAPA embedding dim \(emb.count) too small")
        }
        return EmbeddingMath.l2Normalize(emb)
    }

    private static func multipart(boundary: String, wav: Data) -> Data {
        var body = Data()
        func append(_ s: String) { body.append(contentsOf: s.utf8) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"audio\"; filename=\"clip.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(wav)
        append("\r\n--\(boundary)--\r\n")
        return body
    }
}
