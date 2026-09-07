import XCTest
@testable import AlethiaText
import AlethiaCore

final class MarkdownExportTests: XCTestCase {
    func testMeetingExportIncludesTranscriptAndNotes() {
        let meetingID = UUID()
        let meeting = Meeting(
            title: "Design review",
            durationMs: 125_000,
            userNotes: "Bring mockups",
            enhancedNotes: "## Summary\nLooked at the homepage.",
            summary: "Homepage review",
            attendees: ["Sam"],
            utterances: [
                Utterance(meetingID: meetingID, speakerLabel: "Sam", startMs: 0, endMs: 2000, text: "Let's start."),
            ]
        )
        let md = MarkdownExport.meeting(meeting, includeTranscript: true, includeTimestamps: true)
        XCTAssertTrue(md.contains("# Design review"))
        XCTAssertTrue(md.contains("Sam"))
        XCTAssertTrue(md.contains("Let's start."))
        XCTAssertTrue(md.contains("Bring mockups"))
        XCTAssertTrue(md.contains("Homepage review"))
        XCTAssertTrue(md.contains("[0:00]") || md.contains("0:00"))

        let noTranscript = MarkdownExport.meeting(meeting, includeTranscript: false, includeTimestamps: false)
        XCTAssertFalse(noTranscript.contains("Let's start."))
    }

    func testDictationsExport() {
        let d = Dictation(rawText: "hello", finalText: "Hello there.", targetAppName: "Slack")
        let md = MarkdownExport.dictations([d])
        XCTAssertTrue(md.contains("# Dictations"))
        XCTAssertTrue(md.contains("Hello there."))
        XCTAssertTrue(md.contains("Slack"))
    }

    func testEmptyDictations() {
        let md = MarkdownExport.dictations([])
        XCTAssertTrue(md.contains("Dictations"))
    }
}
