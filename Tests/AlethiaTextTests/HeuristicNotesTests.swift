import XCTest
@testable import AlethiaText
import AlethiaCore

final class HeuristicNotesTests: XCTestCase {
    func testGeneratesSectionsAndCheckboxes() async {
        let meetingID = UUID()
        let utterances: [Utterance] = [
            Utterance(meetingID: meetingID, speakerLabel: "Sarah", startMs: 0, endMs: 4000,
                      text: "Good morning everyone, today we need to review the launch timeline and the remaining blockers on the payments work."),
            Utterance(meetingID: meetingID, speakerLabel: "You", startMs: 4000, endMs: 8000,
                      text: "I'll send the deck by Friday so the leadership team can review it before the customer call."),
            Utterance(meetingID: meetingID, speakerLabel: "Alex", startMs: 8000, endMs: 12000,
                      text: "We agreed to use PostgreSQL for the analytics store instead of keeping everything in the current warehouse."),
            Utterance(meetingID: meetingID, speakerLabel: "Sarah", startMs: 12000, endMs: 16000,
                      text: "What about the budget for the extra contractor we discussed last week?"),
            Utterance(meetingID: meetingID, speakerLabel: "Alex", startMs: 16000, endMs: 20000,
                      text: "We're going with the smaller vendor because they already finished the integration last quarter."),
            Utterance(meetingID: meetingID, speakerLabel: "Maya", startMs: 20000, endMs: 24000,
                      text: "The main problem is the checkout flow is still slow and users get frustrated on mobile during peak hours."),
            Utterance(meetingID: meetingID, speakerLabel: "You", startMs: 24000, endMs: 28000,
                      text: "We should follow up with legal by next week and let's schedule a working session tomorrow."),
            Utterance(meetingID: meetingID, speakerLabel: "Sarah", startMs: 28000, endMs: 32000,
                      text: "Can we ship the notifications experiment this sprint or is that blocked on design?"),
            Utterance(meetingID: meetingID, speakerLabel: "Maya", startMs: 32000, endMs: 36000,
                      text: "I will ping design this afternoon and we need to decide on the copy before Thursday."),
            Utterance(meetingID: meetingID, speakerLabel: "Alex", startMs: 36000, endMs: 40000,
                      text: "The plan is to launch quietly on Monday if the remaining tests look green overnight."),
        ]

        let meeting = Meeting(
            title: "Sprint planning",
            userNotes: "Focus on launch and budget.",
            attendees: ["Jordan"],
            utterances: utterances
        )

        let notes = HeuristicNotesGenerator().generate(meeting: meeting, template: .general)
        XCTAssertTrue(notes.contains("## Your Notes"))
        XCTAssertTrue(notes.contains("Focus on launch and budget."))
        XCTAssertTrue(notes.contains("## Summary"))
        XCTAssertTrue(notes.contains("## Action Items"))
        XCTAssertTrue(notes.contains("## Decisions"))
        XCTAssertTrue(notes.contains("## Open Questions"))
        XCTAssertTrue(notes.contains("- [ ]"))
        XCTAssertTrue(notes.contains("Sarah:") || notes.contains("I'll send") || notes.contains("send the deck"))
        XCTAssertTrue(notes.contains("?"))
        XCTAssertTrue(notes.lowercased().contains("postgresql") || notes.lowercased().contains("agreed") || notes.lowercased().contains("plan"))

        let summary = HeuristicNotesGenerator().summaryLine(for: meeting)
        XCTAssertLessThanOrEqual(summary.count, 140)

        let enhancer = NotesEnhancer(provider: nil)
        let result = await enhancer.enhance(meeting: meeting, template: .general)
        XCTAssertEqual(result.producedBy, "local-heuristics")
        XCTAssertTrue(result.notes.contains("## Summary"))
    }

    func testEmptyTranscriptPlaceholder() {
        let meeting = Meeting(title: "Empty")
        let notes = HeuristicNotesGenerator().generate(meeting: meeting, template: .general)
        XCTAssertTrue(
            notes.contains("_Nothing captured for this section._") || notes.contains("_Nothing captured._")
        )
        XCTAssertFalse(notes.contains("## Your Notes"))
    }

    func testPromptsContainHeadingsAndTranscript() {
        let meeting = Meeting(title: "Sync", userNotes: "Ship it")
        let req = Prompts.enhanceNotes(meeting: meeting, template: .general, transcript: "hello world")
        XCTAssertTrue(req.system.contains("## Summary"))
        XCTAssertTrue(req.user.contains("# User notes") || req.user.contains("USER NOTES:"))
        XCTAssertTrue(req.user.contains("# Transcript") || req.user.contains("TRANSCRIPT:"))
        XCTAssertTrue(req.user.contains("hello world"))

        let polish = Prompts.polishDictation("hello", style: .chat)
        XCTAssertTrue(polish.system.lowercased().contains("punctuation") || polish.system.lowercased().contains("chat"))
        XCTAssertEqual(polish.user, "hello")

        let title = Prompts.meetingTitle(transcriptExcerpt: "We discussed hiring")
        XCTAssertTrue(title.system.lowercased().contains("title"))

        let one = Prompts.oneLineSummary(notes: "## Summary\nGreat meeting")
        XCTAssertTrue(one.system.lowercased().contains("140"))
    }
}
