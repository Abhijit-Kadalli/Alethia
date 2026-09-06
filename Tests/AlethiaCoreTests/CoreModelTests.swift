import XCTest
@testable import AlethiaCore

final class CoreModelTests: XCTestCase {
    func testWAVRoundTrip() throws {
        let samples: [Float] = (0..<1600).map { sin(Float($0) * 0.05) * 0.5 }
        let data = WAVCodec.encode(pcm: samples, sampleRate: 16_000)
        XCTAssertEqual(data.count, WAVCodec.headerSize + samples.count * 2)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")

        let decoded = try WAVCodec.decode(data)
        XCTAssertEqual(decoded.sampleRate, 16_000)
        XCTAssertEqual(decoded.channels, 1)
        XCTAssertEqual(decoded.samples.count, samples.count)
        for (a, b) in zip(decoded.samples, samples) {
            XCTAssertEqual(a, b, accuracy: 1.0 / 16_000)
        }
    }

    func testWAVRejectsGarbage() {
        XCTAssertThrowsError(try WAVCodec.decode(Data(repeating: 0, count: 100)))
    }

    func testMeetingTranscriptText() {
        let id = UUID()
        let meeting = Meeting(
            id: id,
            title: "Sync",
            utterances: [
                Utterance(meetingID: id, speakerLabel: "You", startMs: 0, endMs: 1000, text: "Hello there."),
                Utterance(meetingID: id, speakerLabel: "Speaker 2", startMs: 61_000, endMs: 62_000, text: "Hi."),
            ]
        )
        XCTAssertEqual(meeting.transcriptText(), "You: Hello there.\nSpeaker 2: Hi.")
        XCTAssertEqual(meeting.transcriptText(includeTimestamps: true), "[0:00] You: Hello there.\n[1:01] Speaker 2: Hi.")
        XCTAssertEqual(meeting.speakerLabels, ["You", "Speaker 2"])
        XCTAssertEqual(Meeting.formatTimestamp(ms: 3_725_000), "1:02:05")
    }

    func testSpeakerNames() {
        XCTAssertTrue(Speaker.isProvisionalName("Speaker 3"))
        XCTAssertTrue(Speaker.isProvisionalName("Person 12"))
        XCTAssertFalse(Speaker.isProvisionalName("Ada Lovelace"))
        XCTAssertFalse(Speaker(displayName: "Speaker 1").isNamed)
        XCTAssertTrue(Speaker(displayName: "Grace").isNamed)
    }

    func testEmbeddingMath() {
        XCTAssertEqual(EmbeddingMath.cosineSimilarity([1, 0], [1, 0]), 1, accuracy: 1e-6)
        XCTAssertEqual(EmbeddingMath.cosineSimilarity([1, 0], [0, 1]), 0, accuracy: 1e-6)
        XCTAssertEqual(EmbeddingMath.cosineSimilarity([], []), 0)
        let mean = EmbeddingMath.updateMean([2, 2], count: 1, with: [4, 0])
        XCTAssertEqual(mean, [3, 1])
        XCTAssertEqual(EmbeddingMath.updateMean([], count: 0, with: [1, 2]), [1, 2])
    }

    func testSettingsRoundTripAndPartialDecode() throws {
        let suiteName = "alethia.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.load(), .default)

        _ = store.update { $0.dictation.hotkey = .rightOption; $0.didCompleteOnboarding = true }
        let fresh = SettingsStore(defaults: defaults)
        XCTAssertEqual(fresh.load().dictation.hotkey, .rightOption)
        XCTAssertTrue(fresh.load().didCompleteOnboarding)

        // Simulate an older/newer install with an unknown top-level shape but a valid section.
        let partial = """
        {"dictation": {"hotkey": "f5", "activation": "toggle"}, "didCompleteOnboarding": true, "bogus": 1}
        """
        defaults.set(Data(partial.utf8), forKey: SettingsStore.defaultsKey)
        let recovered = SettingsStore(defaults: defaults).load()
        XCTAssertTrue(recovered.didCompleteOnboarding)
        XCTAssertEqual(recovered.dictation.hotkey, .f5)
        XCTAssertEqual(recovered.dictation.activation, .toggle)
        XCTAssertEqual(recovered.dictation.removeFillers, DictationSettings().removeFillers)
        XCTAssertEqual(recovered.meetings, MeetingSettings())
    }

    func testAppPathsUseOverride() {
        let paths = AppPaths(root: URL(fileURLWithPath: "/tmp/alethia-test", isDirectory: true))
        let id = UUID()
        XCTAssertEqual(paths.relativeRecordingPath(for: id), "Recordings/\(id.uuidString).wav")
        XCTAssertEqual(paths.resolve(relativePath: paths.relativeRecordingPath(for: id)), paths.recordingURL(for: id))
    }
}
