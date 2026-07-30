import XCTest
@testable import AlethiaASR

final class WhisperBridgeTests: XCTestCase {
    func testWAVEncoderProducesRIFFHeader() throws {
        let pcm = (0..<1600).map { i in sin(Float(i) / 20) * 0.1 }
        let data = try PCMWAVEncoder.encode(pcm: pcm, sampleRate: 16_000)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data.subdata(in: 8..<12), encoding: .ascii), "WAVE")
    }

    func testParseTranscriptStripsTimestamps() {
        let raw = """
        [00:00:00.000 --> 00:00:01.200]  hello world
        whisper_print_timings unused
        """
        let segs = WhisperCPPRecognizer.parseTranscript(raw, fallbackDurationMs: 1200)
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].text, "hello world")
    }

    func testStubRecognizerReturnsPlaceholder() async throws {
        let stub = WhisperStubRecognizer()
        let segs = try await stub.transcribe(pcm: [Float](repeating: 0.1, count: 8_000), sampleRate: 16_000)
        XCTAssertEqual(segs.count, 1)
        XCTAssertTrue(segs[0].text.contains("whisper"))
    }

    func testWhisperCLISmokeWhenConfigured() async throws {
        guard let config = WhisperCPPConfiguration.fromEnvironment() else {
            throw XCTSkip("ALETHIA_WHISPER_CLI/MODEL not set — Darwin CI provides these")
        }
        let recognizer = WhisperCPPRecognizer(configuration: config)
        // Use bundled fixture if present; otherwise synthesize
        let pcm: [Float]
        if let url = Bundle.module.url(forResource: "speech_short", withExtension: "wav", subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "speech_short", withExtension: "wav") {
            pcm = try loadMonoPCM(wav: url)
        } else {
            pcm = (0..<24_000).map { i in sin(Float(i) / 18) * 0.2 }
        }
        let segs = try await recognizer.transcribe(pcm: pcm, sampleRate: 16_000)
        // Tiny model on tones may yield empty; success is non-throwing CLI path.
        _ = segs
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
