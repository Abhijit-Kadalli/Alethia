import XCTest
@testable import AlethiaCore

final class TranscriptAlignerTests: XCTestCase {
    private let meetingID = UUID()

    private func words(_ spec: [(String, Int, Int)]) -> [TimedWord] {
        spec.map { TimedWord(text: $0.0, startMs: $0.1, endMs: $0.2) }
    }

    func testAssignsWordsToOverlappingSpeakersAndSplitsOnChange() {
        let segment = TranscriptSegment(
            startMs: 0, endMs: 4000, text: "Hello there. Hi, how are you?",
            words: words([("Hello", 0, 400), ("there.", 400, 800), ("Hi,", 2000, 2300), ("how", 2300, 2500), ("are", 2500, 2700), ("you?", 2700, 3000)])
        )
        let speakers = [
            SpeakerSegment(clusterID: "A", startMs: 0, endMs: 1000),
            SpeakerSegment(clusterID: "B", startMs: 1900, endMs: 3100),
        ]
        let out = TranscriptAligner().align(meetingID: meetingID, segments: [segment], speakers: speakers)
        XCTAssertEqual(out.utterances.count, 2)
        XCTAssertEqual(out.utterances[0].speakerLabel, "Speaker 1")
        XCTAssertEqual(out.utterances[0].text, "Hello there.")
        XCTAssertEqual(out.utterances[1].speakerLabel, "Speaker 2")
        XCTAssertEqual(out.utterances[1].text, "Hi, how are you?")
        XCTAssertEqual(out.utterances[1].startMs, 2000)
        XCTAssertEqual(out.utterances[1].endMs, 3000)
        XCTAssertEqual(out.clusterLabels, ["A": "Speaker 1", "B": "Speaker 2"])
    }

    func testSplitsOnLongPauseSameSpeaker() {
        let segment = TranscriptSegment(
            startMs: 0, endMs: 10_000, text: "One two. Three four.",
            words: words([("One", 0, 300), ("two.", 300, 600), ("Three", 5000, 5300), ("four.", 5300, 5600)])
        )
        let speakers = [SpeakerSegment(clusterID: "A", startMs: 0, endMs: 6000)]
        let out = TranscriptAligner(pauseSplitMs: 1500).align(meetingID: meetingID, segments: [segment], speakers: speakers)
        XCTAssertEqual(out.utterances.map(\.text), ["One two.", "Three four."])
        XCTAssertTrue(out.utterances.allSatisfy { $0.speakerLabel == "Speaker 1" })
    }

    func testFallsBackToEvenSpacingWithoutWordTimings() {
        let segments = [
            TranscriptSegment(startMs: 0, endMs: 2000, text: "alpha beta gamma delta"),
            TranscriptSegment(startMs: 2000, endMs: 4000, text: "epsilon zeta"),
        ]
        let speakers = [
            SpeakerSegment(clusterID: "x", startMs: 0, endMs: 2000),
            SpeakerSegment(clusterID: "y", startMs: 2000, endMs: 4000),
        ]
        let out = TranscriptAligner().align(meetingID: meetingID, segments: segments, speakers: speakers)
        XCTAssertEqual(out.utterances.count, 2)
        XCTAssertEqual(out.utterances[0].text, "alpha beta gamma delta")
        XCTAssertEqual(out.utterances[1].text, "epsilon zeta")
    }

    func testNoDiarizationProducesSingleSpeaker() {
        let segment = TranscriptSegment(startMs: 0, endMs: 1000, text: "Just me talking.", words: words([("Just", 0, 200), ("me", 200, 400), ("talking.", 400, 800)]))
        let out = TranscriptAligner().align(meetingID: meetingID, segments: [segment], speakers: [])
        XCTAssertEqual(out.utterances.count, 1)
        XCTAssertEqual(out.utterances[0].speakerLabel, "Speaker 1")
        XCTAssertNil(out.utterances[0].isLocalSpeaker)
    }

    func testDetectsLocalUserFromMicrophoneDominance() {
        let segment = TranscriptSegment(
            startMs: 0, endMs: 4000, text: "I think so. Yes agreed.",
            words: words([("I", 0, 200), ("think", 200, 500), ("so.", 500, 800), ("Yes", 2000, 2300), ("agreed.", 2300, 2800)])
        )
        let speakers = [
            SpeakerSegment(clusterID: "A", startMs: 0, endMs: 1000),
            SpeakerSegment(clusterID: "B", startMs: 1900, endMs: 3000),
        ]
        var loudness: [SourceLoudness] = []
        for t in stride(from: 0, to: 4000, by: 100) {
            let micLoud = t < 1000
            loudness.append(SourceLoudness(startMs: t, endMs: t + 100, microphoneRMS: micLoud ? 0.2 : 0.005, systemRMS: micLoud ? 0.01 : 0.2))
        }
        let out = TranscriptAligner().align(meetingID: meetingID, segments: [segment], speakers: speakers, loudness: loudness, hasSystemAudio: true)
        XCTAssertEqual(out.selfCluster, "A")
        XCTAssertEqual(out.utterances[0].speakerLabel, "You")
        XCTAssertEqual(out.utterances[0].isLocalSpeaker, true)
        XCTAssertEqual(out.utterances[1].speakerLabel, "Speaker 1")
        XCTAssertEqual(out.utterances[1].isLocalSpeaker, false)
    }

    func testJoinWordsHandlesPunctuation() {
        XCTAssertEqual(TranscriptAligner.joinWords(["Hello", ",", "world", "."]), "Hello, world.")
        XCTAssertEqual(TranscriptAligner.joinWords(["It", "costs", "$", "5", "."]), "It costs $5.")
        XCTAssertEqual(TranscriptAligner.joinWords(["(", "aside", ")"]), "(aside)")
    }

    func testSpeakerMatcherSuggestsAndAutoAccepts() {
        let grace = Speaker(displayName: "Grace", embedding: [1, 0, 0])
        let ada = Speaker(displayName: "Ada", embedding: [0, 1, 0])
        let unnamed = Speaker(displayName: "Speaker 4", embedding: [0, 0, 1])
        let clusters: [String: [Float]] = [
            "A": [0.95, 0.05, 0],     // ≈ Grace, high
            "B": [0.5, 0.7, 0],       // ≈ Ada (0.81), below auto-accept
            "C": [0, 0, 1],           // matches only the unnamed profile → ignored
        ]
        let matcher = SpeakerMatcher(suggestThreshold: 0.55, autoAcceptThreshold: 0.9)
        let matches = matcher.match(clusters: clusters, gallery: [grace, ada, unnamed])
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches[0].clusterID, "A")
        XCTAssertEqual(matches[0].speaker.displayName, "Grace")
        XCTAssertTrue(matches[0].autoAccepted)
        XCTAssertEqual(matches[1].clusterID, "B")
        XCTAssertFalse(matches[1].autoAccepted)

        var utterances = [
            Utterance(meetingID: meetingID, speakerLabel: "Speaker 1", startMs: 0, endMs: 1, text: "a"),
            Utterance(meetingID: meetingID, speakerLabel: "Speaker 2", startMs: 1, endMs: 2, text: "b"),
            Utterance(meetingID: meetingID, speakerLabel: "Speaker 3", startMs: 2, endMs: 3, text: "c"),
        ]
        matcher.apply(matches, to: &utterances, clusterLabels: ["A": "Speaker 1", "B": "Speaker 2", "C": "Speaker 3"])
        XCTAssertEqual(utterances[0].speakerLabel, "Grace")
        XCTAssertEqual(utterances[0].speakerID, grace.id)
        XCTAssertEqual(utterances[1].speakerLabel, "Speaker 2")
        XCTAssertEqual(utterances[1].suggestedSpeakerName, "Ada")
        XCTAssertNil(utterances[2].suggestedSpeakerName)
    }

    func testEachGallerySpeakerUsedOnce() {
        let grace = Speaker(displayName: "Grace", embedding: [1, 0])
        let clusters: [String: [Float]] = ["A": [0.9, 0.1], "B": [0.8, 0.2]]
        let matches = SpeakerMatcher(suggestThreshold: 0.5, autoAcceptThreshold: 0.99).match(clusters: clusters, gallery: [grace])
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].clusterID, "A")
    }
}
