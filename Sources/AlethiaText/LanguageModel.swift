import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import AlethiaCore

/// A chat-completions style request sent to a `LanguageModelProvider`.
public struct LanguageModelRequest: Sendable, Hashable {
    public var system: String
    public var user: String
    public var maxTokens: Int
    public var temperature: Double

    public init(system: String, user: String, maxTokens: Int = 1024, temperature: Double = 0.2) {
        self.system = system
        self.user = user
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}

/// Pluggable text-generation backend used for dictation polish and meeting notes.
public protocol LanguageModelProvider: Sendable {
    /// Stable identifier recorded on outputs, e.g. "openai-compatible:qwen3:4b".
    var id: String { get }
    func isAvailable() async -> Bool
    func complete(_ request: LanguageModelRequest) async throws -> String
}

extension LanguageModelProvider {
    public var displayName: String { id }
}

/// OpenAI-compatible HTTP chat completions client (`/v1/chat/completions`).
public final class OpenAICompatibleClient: LanguageModelProvider, @unchecked Sendable {
    private let baseURL: URL
    private let apiKey: String?
    private let model: String
    private let session: URLSession
    private let timeout: TimeInterval

    public init(
        baseURL: URL,
        apiKey: String?,
        model: String,
        session: URLSession = .shared,
        timeout: TimeInterval = 120
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.session = session
        self.timeout = timeout
    }

    /// Contract initializer (`model` before `apiKey`).
    public init(
        baseURL: URL,
        model: String,
        apiKey: String? = nil,
        session: URLSession = .shared,
        timeout: TimeInterval = 120
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.session = session
        self.timeout = timeout
    }

    public var id: String { "openai-compatible" }
    public var displayName: String { id }

    public func isAvailable() async -> Bool {
        var request = URLRequest(url: Self.modelsURL(from: baseURL))
        request.httpMethod = "GET"
        request.timeoutInterval = 3
        applyAuth(&request)
        do {
            let (_, response) = try await data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            if (200..<300).contains(http.statusCode) { return true }
            // Server exists but the key is missing/wrong.
            if http.statusCode == 401 || http.statusCode == 403 { return false }
            return false
        } catch {
            return false
        }
    }

    public func listModels() async throws -> [String] {
        var request = URLRequest(url: Self.modelsURL(from: baseURL))
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        applyAuth(&request)
        let (data, response) = try await data(for: request)
        try throwIfFailed(response, data: data)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["data"] as? [[String: Any]] else {
            throw AlethiaError.languageModel("Unexpected models list JSON")
        }
        return arr.compactMap { $0["id"] as? String }
    }

    public func complete(_ request: LanguageModelRequest) async throws -> String {
        var urlRequest = URLRequest(url: Self.chatCompletionsURL(from: baseURL))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&urlRequest)
        urlRequest.httpBody = Self.makeRequestBody(model: model, request: request)
        let (data, response) = try await data(for: urlRequest)
        try throwIfFailed(response, data: data)
        return try Self.parseCompletion(data)
    }

    /// Normalizes `baseURL` (with or without trailing slash / `/v1`) to `.../v1/chat/completions`.
    public static func chatCompletionsURL(from url: URL) -> URL {
        apiRoot(url).appendingPathComponent("chat").appendingPathComponent("completions")
    }

    /// Normalizes `baseURL` to `.../v1/models`.
    public static func modelsURL(from url: URL) -> URL {
        apiRoot(url).appendingPathComponent("models")
    }

    static func apiRoot(_ url: URL) -> URL {
        var s = url.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/chat/completions") {
            s = String(s.dropLast("/chat/completions".count))
            while s.hasSuffix("/") { s.removeLast() }
        }
        if s.hasSuffix("/models") {
            s = String(s.dropLast("/models".count))
            while s.hasSuffix("/") { s.removeLast() }
        }
        if !s.lowercased().hasSuffix("/v1") {
            s += "/v1"
        }
        return URL(string: s) ?? url.appendingPathComponent("v1")
    }

    public static func makeRequestBody(model: String, request: LanguageModelRequest) -> Data {
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": request.system],
                ["role": "user", "content": request.user],
            ],
            "max_tokens": request.maxTokens,
            "temperature": request.temperature,
            "stream": false,
        ]
        return (try? JSONSerialization.data(withJSONObject: body, options: [])) ?? Data()
    }

    public static func parseCompletion(_ data: Data) throws -> String {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AlethiaError.languageModel("Invalid completion JSON")
        }
        if let error = obj["error"] {
            let excerpt: String
            if let dict = error as? [String: Any], let message = dict["message"] as? String {
                excerpt = message
            } else {
                excerpt = String(describing: error)
            }
            throw AlethiaError.languageModel(excerpt)
        }
        guard let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AlethiaError.languageModel("Missing completion content")
        }
        let stripped = CachedRegex.thinkBlock.replace(content, with: "")
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func applyAuth(_ request: inout URLRequest) {
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
    }

    private func throwIfFailed(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AlethiaError.languageModel("Invalid HTTP response")
        }
        if (200..<300).contains(http.statusCode) { return }
        let body = String(data: data, encoding: .utf8) ?? ""
        let excerpt = body.count > 200 ? String(body.prefix(200)) : body
        throw AlethiaError.languageModel("HTTP \(http.statusCode): \(excerpt)")
    }

    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data = data, let response = response else {
                    continuation.resume(throwing: AlethiaError.languageModel("Empty response"))
                    return
                }
                continuation.resume(returning: (data, response))
            }
            task.resume()
        }
    }
}

/// Compatibility alias used by older call sites.
public typealias OpenAICompatibleProvider = OpenAICompatibleClient
