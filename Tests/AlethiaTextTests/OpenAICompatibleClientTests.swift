import XCTest
@testable import AlethiaText
import AlethiaCore

final class OpenAICompatibleClientTests: XCTestCase {
    func testMakeRequestBodyShape() throws {
        let request = LanguageModelRequest(system: "sys", user: "usr", maxTokens: 64, temperature: 0.5)
        let data = OpenAICompatibleClient.makeRequestBody(model: "qwen3:4b", request: request)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["model"] as? String, "qwen3:4b")
        XCTAssertEqual(obj["max_tokens"] as? Int, 64)
        XCTAssertEqual(obj["temperature"] as? Double, 0.5)
        XCTAssertEqual(obj["stream"] as? Bool, false)
        let messages = try XCTUnwrap(obj["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, "sys")
        XCTAssertEqual(messages[1]["role"] as? String, "user")
        XCTAssertEqual(messages[1]["content"] as? String, "usr")
    }

    func testParseCompletionStripsThink() throws {
        let json = """
        {"choices":[{"message":{"content":"<think>reason later</think> Hello world"}}]}
        """
        let text = try OpenAICompatibleClient.parseCompletion(Data(json.utf8))
        XCTAssertEqual(text, "Hello world")
        XCTAssertFalse(text.contains("think"))
    }

    func testParseCompletionErrorJSON() {
        let json = """
        {"error":{"message":"invalid_api_key","type":"auth"}}
        """
        XCTAssertThrowsError(try OpenAICompatibleClient.parseCompletion(Data(json.utf8))) { error in
            let alethia = error as? AlethiaError
            guard case .languageModel(let detail)? = alethia else {
                return XCTFail("expected languageModel, got \(error)")
            }
            XCTAssertTrue(detail.contains("invalid_api_key"))
        }
    }

    func testParseCompletionMissingContent() {
        let json = """
        {"choices":[]}
        """
        XCTAssertThrowsError(try OpenAICompatibleClient.parseCompletion(Data(json.utf8))) { error in
            XCTAssertTrue(error is AlethiaError)
        }
    }

    func testClientID() {
        let client = OpenAICompatibleClient(baseURL: URL(string: "http://localhost:11434/v1")!, model: "qwen3:4b")
        XCTAssertTrue(client.id.hasPrefix("openai-compatible"))
    }
}
