import XCTest
@testable import AlethiaASR

final class CrisperBridgeTests: XCTestCase {
    func testWAVEncoderProducesRIFFHeader() throws {
        let pcm = (0..<1600).map { i in sin(Float(i) / 20) * 0.1 }
        let data = try PCMWAVEncoder.encode(pcm: pcm, sampleRate: 16_000)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data.subdata(in: 8..<12), encoding: .ascii), "WAVE")
    }

    func testParseResponseSegments() throws {
        let json = """
        {"text":"hello world","segments":[{"start_ms":0,"end_ms":1200,"text":"hello world"}]}
        """.data(using: .utf8)!
        let segs = try CrisperWhisperRecognizer.parseResponse(json, fallbackDurationMs: 1200)
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].text, "hello world")
        XCTAssertEqual(segs[0].endMs, 1200)
    }

    func testParseResponseRejectsStubUnlessAllowed() {
        let json = """
        {"text":"stub transcript","stub":true,"segments":[{"start_ms":0,"end_ms":1000,"text":"stub transcript"}]}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try CrisperWhisperRecognizer.parseResponse(json, fallbackDurationMs: 1000))
    }

    func testStubRecognizerReturnsPlaceholder() async throws {
        let stub = WhisperStubRecognizer()
        let segs = try await stub.transcribe(pcm: [Float](repeating: 0.1, count: 8_000), sampleRate: 16_000)
        XCTAssertEqual(segs.count, 1)
        XCTAssertTrue(segs[0].text.contains("crisperwhisper"))
    }

    func testSidecarSmokeWhenConfigured() async throws {
        let config = CrisperWhisperConfiguration.fromEnvironment() ?? .defaultLocal()
        guard await CrisperWhisperRecognizer.isHealthy(baseURL: config.baseURL) else {
            throw XCTSkip("CrisperWhisper sidecar not running — Darwin CI starts it in stub mode")
        }
        let recognizer = CrisperWhisperRecognizer(configuration: config)
        let pcm: [Float]
        if let url = Bundle.module.url(forResource: "speech_short", withExtension: "wav", subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "speech_short", withExtension: "wav") {
            pcm = try loadMonoPCM(wav: url)
        } else {
            pcm = (0..<24_000).map { i in sin(Float(i) / 18) * 0.2 }
        }
        let segs = try await recognizer.transcribe(pcm: pcm, sampleRate: 16_000, mode: .intended)
        XCTAssertFalse(segs.isEmpty)
    }
}

private func loadMonoPCM(wav url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)
    guard data.count > 44 else { return [] }
    let pcmData = data.subdata(in: 44..<data.count)
    var samples: [Float] = []
    samples.reserveCapacity(pcmData.count / 2)
    pcmData.withUnsafeBytes { raw in
        let ints = raw.bindMemory(to: Int16.self)
        for v in ints {
            samples.append(Float(v) / Float(Int16.max))
        }
    }
    return samples
}
