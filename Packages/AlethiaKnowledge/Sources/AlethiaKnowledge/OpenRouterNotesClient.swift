import Foundation
import AlethiaCore

/// Generates meeting summary notes via OpenRouter (`openai/gpt-5.6-luna`).
public struct OpenRouterNotesClient: Sendable {
    public static let modelID = "openai/gpt-5.6-luna"
    public static let baseURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    public var apiKey: String
    public var model: String
    public var siteURL: String
    public var appName: String

    public init(
        apiKey: String,
        model: String = OpenRouterNotesClient.modelID,
        siteURL: String = "https://alethia.local",
        appName: String = "Alethia"
    ) {
        self.apiKey = apiKey
        self.model = model
        self.siteURL = siteURL
        self.appName = appName
    }

    public func generateNotes(
        title: String?,
        startedAt: Date,
        utterances: [Utterance],
        verbatim: Bool = true
    ) async throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw AlethiaError.modelMissing("OpenRouter API key is missing. Add it in Hub → Settings.")
        }
        guard !utterances.isEmpty else {
            throw AlethiaError.audioEngine("No transcript available to summarize.")
        }

        let transcript = utterances.map { u in
            let stamp = Self.formatMs(u.startMs)
            let body = u.displayText(verbatim: verbatim)
            return "[\(stamp)] \(u.speakerLabel): \(body)"
        }.joined(separator: "\n")

        let meetingTitle = title?.nilIfEmptyTrimmed ?? "Meeting"
        let dateLine = startedAt.formatted(date: .abbreviated, time: .shortened)
        let system = """
        You are Alethia’s meeting notes assistant. Write clear, concise Markdown notes for a local macOS app.
        Structure:
        # \(meetingTitle)
        ## Summary
        ## Key Points
        ## Decisions
        ## Action Items
        ## Open Questions
        Keep names as given (Person 1 / labeled speakers). Prefer bullets. No preamble.
        """
        let user = """
        Meeting: \(meetingTitle)
        When: \(dateLine)

        Transcript:
        \(transcript)
        """

        let body: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: Self.baseURL)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(siteURL, forHTTPHeaderField: "HTTP-Referer")
        request.setValue(appName, forHTTPHeaderField: "X-Title")
        request.timeoutInterval = 120

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AlethiaError.modelMissing("OpenRouter returned an invalid response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: responseData, encoding: .utf8) ?? ""
            throw AlethiaError.modelMissing("OpenRouter error \(http.statusCode): \(detail.prefix(280))")
        }

        guard
            let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw AlethiaError.modelMissing("OpenRouter response missing note content.")
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AlethiaError.modelMissing("OpenRouter returned empty notes.")
        }
        return trimmed
    }

    private static func formatMs(_ ms: Int) -> String {
        let total = max(ms, 0) / 1000
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private extension String {
    var nilIfEmptyTrimmed: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
