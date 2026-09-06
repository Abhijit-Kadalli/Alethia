import XCTest
import AlethiaCore
import AlethiaSpeech
@testable import AlethiaMeetings

final class MeetingPipelineTests: XCTestCase {
    @MainActor
    func testClusterEmbeddingsAveragesAndNormalizes() {
        let segments = [
            SpeakerSegment(clusterID: "A", startMs: 0, endMs: 1000, embedding: [1, 0, 0, 0]),
            SpeakerSegment(clusterID: "A", startMs: 1000, endMs: 2000, embedding: [0, 1, 0, 0]),
            SpeakerSegment(clusterID: "B", startMs: 2000, endMs: 3000, embedding: [0, 0, 2, 0]),
            SpeakerSegment(clusterID: "C", startMs: 3000, endMs: 4000, embedding: nil),
        ]
        let result = MeetingProcessor.clusterEmbeddings(segments)
        XCTAssertEqual(Set(result.keys), ["A", "B"])
        let a = result["A"]!
        XCTAssertEqual(a[0], a[1], accuracy: 1e-6)
        XCTAssertEqual(a.map { $0 * $0 }.reduce(0, +), 1, accuracy: 1e-5)
        XCTAssertEqual(result["B"]!, [0, 0, 1, 0])
    }

    @MainActor
    func testGenericTitles() {
        XCTAssertTrue(MeetingProcessor.isGenericTitle("Meeting · Monday 9:00 AM"))
        XCTAssertTrue(MeetingProcessor.isGenericTitle("Zoom call"))
        XCTAssertFalse(MeetingProcessor.isGenericTitle("Q3 planning"))
    }

    @MainActor
    func testProvisionalUtterancesFromLiveTranscript() {
        let id = UUID()
        let update = LiveTranscriptUpdate(
            committed: [
                TranscriptSegment(startMs: 0, endMs: 3000, text: "Hello everyone."),
                TranscriptSegment(startMs: 3200, endMs: 6000, text: ""),
            ],
            volatile: "Let's get",
            volatileStartMs: 6500
        )
        let utterances = MeetingRecorder.provisionalUtterances(from: update, meetingID: id)
        XCTAssertEqual(utterances.count, 2)
        XCTAssertEqual(utterances[0].text, "Hello everyone.")
        XCTAssertEqual(utterances[0].meetingID, id)
        XCTAssertEqual(utterances[1].startMs, 6500)
        XCTAssertEqual(utterances[1].text, "Let's get")
    }

    @MainActor
    func testDefaultTitleMentionsWeekday() {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 7
        components.hour = 9
        let date = Calendar(identifier: .gregorian).date(from: components)!
        let title = MeetingRecorder.defaultTitle(for: date)
        XCTAssertTrue(title.hasPrefix("Meeting · "))
        XCTAssertTrue(title.contains("9:00"))
    }
}
