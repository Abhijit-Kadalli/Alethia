#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import AlethiaCore
@testable import AlethiaText

final class LanguageModelTests: XCTestCase {
    func testRequestInitDefaults() {
        let req = LanguageModelRequest(system: "s", user: "u")
        XCTAssertEqual(req.maxTokens, 1024)
        XCTAssertEqual(req.temperature, 0.2, accuracy: 0.0001)
    }

    func testChatCompletionsURLNormalization() {
        XCTAssertEqual(
            OpenAICompatibleProvider.chatCompletionsURL(from: URL(string: "http://localhost:11434")!),
            URL(string: "http://localhost:11434/v1/chat/completions")
        )
        XCTAssertEqual(
            OpenAICompatibleProvider.chatCompletionsURL(from: URL(string: "http://x/v1/")!),
            URL(string: "http://x/v1/chat/completions")
        )
        XCTAssertEqual(
            OpenAICompatibleProvider.chatCompletionsURL(from: URL(string: "http://x/v1")!),
            URL(string: "http://x/v1/chat/completions")
        )
    }

    func testModelsURL() {
        XCTAssertEqual(
            OpenAICompatibleProvider.modelsURL(from: URL(string: "http://localhost:11434")!),
            URL(string: "http://localhost:11434/v1/models")
        )
    }

    func testSuccessParse() throws {
        MockURLProtocol.install()
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.url?.absoluteString.hasSuffix("/v1/chat/completions") == true)
            let body = #"{"choices":[{"message":{"content":"Hello world"}}]}"#
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }
        let session = URLSession(configuration: MockURLProtocol.makeConfiguration())
        let provider = OpenAICompatibleProvider(
            baseURL: URL(string: "http://localhost:11434")!,
            apiKey: "k",
            model: "m",
            session: session
        )
        let result = try tryWait { try await provider.complete(LanguageModelRequest(system: "s", user: "u")) }
        XCTAssertEqual(result, "Hello world")
    }

    func testThinkStripping() throws {
        MockURLProtocol.install()
        MockURLProtocol.handler = { request in
            let body = #"{"choices":[{"message":{"content":"<think>reason</think>\nCleaned text"}}]}"#
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }
        let session = URLSession(configuration: MockURLProtocol.makeConfiguration())
        let provider = OpenAICompatibleProvider(
            baseURL: URL(string: "http://x/v1/")!,
            apiKey: nil,
            model: "qwen",
            session: session
        )
        let result = try tryWait { try await provider.complete(LanguageModelRequest(system: "s", user: "u")) }
        XCTAssertEqual(result, "Cleaned text")
    }

    func testHTTP500MapsToAlethiaError() {
        MockURLProtocol.install()
        MockURLProtocol.handler = { request in
            let body = String(repeating: "x", count: 400)
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }
        let session = URLSession(configuration: MockURLProtocol.makeConfiguration())
        let provider = OpenAICompatibleProvider(
            baseURL: URL(string: "http://localhost:11434")!,
            apiKey: nil,
            model: "m",
            session: session
        )
        XCTAssertThrowsError(try tryWait { try await provider.complete(LanguageModelRequest(system: "s", user: "u")) }) { error in
            guard let alethia = error as? AlethiaError, case .languageModel(let message) = alethia else {
                return XCTFail("wrong error \(error)")
            }
            XCTAssertTrue(message.contains("500"))
            XCTAssertTrue(message.contains(String(repeating: "x", count: 200)))
            XCTAssertFalse(message.contains(String(repeating: "x", count: 201)))
        }
    }

    func testIsAvailableSuccess() {
        MockURLProtocol.install()
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("{}".utf8))
        }
        let session = URLSession(configuration: MockURLProtocol.makeConfiguration())
        let provider = OpenAICompatibleProvider(
            baseURL: URL(string: "http://localhost:11434")!,
            apiKey: nil,
            model: "m",
            session: session
        )
        XCTAssertTrue(tryWait { await provider.isAvailable() })
    }

    func testDictationPolishPrompt() {
        let req = Prompts.dictationPolish(text: "um hello", style: .chat)
        XCTAssertTrue(req.system.lowercased().contains("dictation"))
        XCTAssertTrue(req.system.lowercased().contains("casual"))
        XCTAssertEqual(req.user, "um hello")
        XCTAssertTrue(req.system.lowercased().contains("do not add"))
    }

    func testMeetingNotesTruncationAndHeadings() {
        XCTAssertEqual(Prompts.maxTranscriptCharacters, 24_000)
        let long = String(repeating: "word ", count: 10_000)
        XCTAssertGreaterThan(long.count, Prompts.maxTranscriptCharacters)
        let meeting = Meeting(title: "Standup")
        let template = NotesTemplate(
            id: "std",
            name: "Std",
            description: "",
            sections: ["Summary", "Action Items", "Open Questions"],
            instructions: "Be brief."
        )
        let req = Prompts.meetingNotes(meeting: meeting, template: template, transcript: long, userNotes: "ship it")
        XCTAssertTrue(req.system.contains("## Summary"))
        XCTAssertTrue(req.system.contains("## Action Items"))
        XCTAssertTrue(req.system.contains("## Open Questions"))
        XCTAssertTrue(req.user.contains("[…]"))
        XCTAssertTrue(req.user.contains("USER NOTES:"))
        XCTAssertTrue(req.user.contains("TRANSCRIPT:"))
        XCTAssertTrue(req.user.contains("ship it"))
        XCTAssertTrue(req.user.contains("Be brief.") || req.system.contains("Be brief."))
        let transcriptPart = req.user.components(separatedBy: "TRANSCRIPT:").last ?? ""
        XCTAssertLessThan(transcriptPart.count, Prompts.maxTranscriptCharacters + 20)
    }

    func testMeetingTitlePrompt() {
        let req = Prompts.meetingTitle(transcript: "We discussed the Q3 budget.")
        XCTAssertTrue(req.system.contains("8"))
        XCTAssertTrue(req.system.lowercased().contains("quote"))
    }

    func testGuardrailsPass() {
        XCTAssertTrue(DictationPolisher.passesGuardrails(original: "Hello there world.", polished: "Hello there world."))
    }

    func testGuardrailsRejectPreamble() {
        XCTAssertFalse(DictationPolisher.passesGuardrails(original: "Hello there world.", polished: "Here is the cleaned text: Hello there world."))
        XCTAssertFalse(DictationPolisher.passesGuardrails(original: "Hello there world.", polished: "Sure, Hello there world."))
    }

    func testGuardrailsRejectQuotesAndEmpty() {
        XCTAssertFalse(DictationPolisher.passesGuardrails(original: "Hello there world.", polished: "   "))
        XCTAssertTrue(DictationPolisher.passesGuardrails(original: "Hello there world.", polished: "\"Hello there world.\""))
    }

    func testGuardrailsLengthRatio() {
        XCTAssertFalse(DictationPolisher.passesGuardrails(original: String(repeating: "hello ", count: 20), polished: "hi"))
        XCTAssertFalse(DictationPolisher.passesGuardrails(original: "hi there friend", polished: String(repeating: "hello ", count: 40)))
    }

    func testGuardrailsNewline() {
        XCTAssertFalse(DictationPolisher.passesGuardrails(original: "Hello there world.", polished: "Hello there\nworld."))
        XCTAssertTrue(DictationPolisher.passesGuardrails(original: "Hello\nthere world.", polished: "Hello\nthere world."))
    }

    func testGuardrailsMissingTokens() {
        XCTAssertFalse(DictationPolisher.passesGuardrails(
            original: "The budget for Q3 is forty five thousand dollars.",
            polished: "Yes I can help with that."
        ))
    }

    func testPolisherReturnsNilOnFailedGuardrails() {
        let stub = StubLanguageModel(id: "s", available: true, result: .success("Sure, here is an answer to your question about life."))
        let polisher = DictationPolisher(provider: stub)
        let out = tryWait { await polisher.polish("The budget for Q3 is forty five thousand dollars.", style: .standard) }
        XCTAssertNil(out)
    }

    func testPolisherReturnsText() {
        let stub = StubLanguageModel(id: "s", available: true, result: .success("The budget for Q3 is forty five thousand dollars."))
        let polisher = DictationPolisher(provider: stub)
        let out = tryWait { await polisher.polish("The budget for Q3 is forty five thousand dollars.", style: .standard) }
        XCTAssertEqual(out, "The budget for Q3 is forty five thousand dollars.")
    }

    func testPolisherUnavailable() {
        let stub = StubLanguageModel(id: "s", available: false, result: .success("x"))
        let polisher = DictationPolisher(provider: stub)
        let out = tryWait { await polisher.polish("Hello there friend.", style: .standard) }
        XCTAssertNil(out)
    }
}

final class NotesGeneratorTests: XCTestCase {
    func testHeuristicSummarizerOnSyntheticMeeting() {
        let meetingID = UUID()
        var utterances: [Utterance] = []
        let rows: [(String, String)] = [
            ("Sarah", "Good morning everyone, today we need to review the launch timeline."),
            ("You", "I'll send the deck by Friday so leadership can review it."),
            ("Alex", "We agreed to use PostgreSQL for the analytics store."),
            ("Sarah", "What about the budget for the extra contractor we discussed?"),
            ("Alex", "We're going with the smaller vendor because they finished the integration."),
            ("Maya", "The checkout flow is still slow and users get frustrated on mobile."),
            ("You", "We should follow up with legal by next week."),
            ("Sarah", "Can we ship the notifications experiment this sprint?"),
            ("Maya", "I will ping design this afternoon about the copy."),
            ("Alex", "The plan is to launch quietly on Monday if tests look green."),
            ("Jordan", "I'm blocked on the API credentials and waiting on security."),
            ("You", "Let's schedule a working session tomorrow to unblock Jordan."),
        ]
        var t = 0
        for (speaker, text) in rows {
            utterances.append(Utterance(meetingID: meetingID, speakerLabel: speaker, startMs: t, endMs: t + 4000, text: text))
            t += 4000
        }
        let meeting = Meeting(
            title: "Sprint planning",
            durationMs: 48_000,
            userNotes: "Focus on launch and budget.",
            attendees: ["Jordan"],
            utterances: utterances
        )
        let notes = HeuristicNotesSummarizer().summarize(meeting: meeting, template: .general)
        XCTAssertEqual(notes.producedBy, "local-heuristics")
        XCTAssertNil(notes.suggestedTitle)
        XCTAssertTrue(notes.markdown.contains("## Your Notes"))
        XCTAssertTrue(notes.markdown.contains("Focus on launch and budget."))
        XCTAssertTrue(notes.markdown.contains("## Summary"))
        XCTAssertTrue(notes.markdown.contains("## Key Points"))
        XCTAssertTrue(notes.markdown.contains("## Decisions"))
        XCTAssertTrue(notes.markdown.contains("## Action Items"))
        XCTAssertTrue(notes.markdown.contains("## Open Questions"))
        XCTAssertTrue(notes.markdown.contains("- [ ]"))
        XCTAssertTrue(notes.markdown.contains("?"))
        XCTAssertLessThanOrEqual(notes.summary.count, 160)
        XCTAssertFalse(notes.summary.isEmpty)
    }

    func testNotesGeneratorUsesStubMarkdown() {
        let markdown = """
        ## Summary
        We planned the launch.

        ## Key Points
        - Ship on Monday

        ## Decisions
        - Use PostgreSQL

        ## Action Items
        - [ ] Send the deck (You)

        ## Open Questions
        - Budget?
        """
        let stub = StubLanguageModel(id: "openai-compatible", available: true, result: .success(markdown))
        let meeting = Meeting(title: "Sync", utterances: [
            Utterance(meetingID: UUID(), speakerLabel: "You", startMs: 0, endMs: 1000, text: "Hello team we should ship Monday.")
        ])
        let out = tryWait { await NotesGenerator(provider: stub).generate(meeting: meeting, template: .general) }
        XCTAssertEqual(out.producedBy, "openai-compatible")
        XCTAssertTrue(out.markdown.contains("## Summary"))
        XCTAssertEqual(out.summary, "We planned the launch.")
    }

    func testNotesGeneratorFallsBackOnGarbage() {
        let stub = StubLanguageModel(id: "openai-compatible", available: true, result: .success("not notes at all"))
        let meeting = Meeting(title: "Sync", userNotes: "Keep this", utterances: [
            Utterance(meetingID: UUID(), speakerLabel: "You", startMs: 0, endMs: 1000, text: "I'll send the report tomorrow.")
        ])
        let out = tryWait { await NotesGenerator(provider: stub).generate(meeting: meeting, template: .general) }
        XCTAssertEqual(out.producedBy, "local-heuristics")
        XCTAssertTrue(out.markdown.contains("## Your Notes"))
        XCTAssertTrue(out.markdown.contains("## Summary"))
    }

    func testNotesGeneratorFallsBackOnError() {
        let stub = StubLanguageModel(id: "x", available: true, result: .failure(AlethiaError.languageModel("nope")))
        let meeting = Meeting(title: "Sync")
        let out = tryWait { await NotesGenerator(provider: stub).generate(meeting: meeting, template: .general) }
        XCTAssertEqual(out.producedBy, "local-heuristics")
    }
}

final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    private static var didRegister = false

    static func install() {
        if !didRegister {
            _ = URLProtocol.registerClass(MockURLProtocol.self)
            didRegister = true
        }
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return config
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

struct StubLanguageModel: LanguageModelProvider {
    let id: String
    let displayName: String = "Stub"
    var available: Bool
    var result: Result<String, Error>

    func isAvailable() async -> Bool { available }

    func complete(_ request: LanguageModelRequest) async throws -> String {
        switch result {
        case .success(let s): return s
        case .failure(let e): throw e
        }
    }
}

@discardableResult
func tryWait<T>(_ body: @escaping () async throws -> T) throws -> T {
    var value: T?
    var thrown: Error?
    let sem = DispatchSemaphore(value: 0)
    Task {
        do { value = try await body() } catch { thrown = error }
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 10)
    if let thrown { throw thrown }
    guard let value else { throw AlethiaError.languageModel("async timed out") }
    return value
}

@discardableResult
func tryWait<T>(_ body: @escaping () async -> T) -> T {
    var value: T?
    let sem = DispatchSemaphore(value: 0)
    Task {
        value = await body()
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 10)
    return value!
}
