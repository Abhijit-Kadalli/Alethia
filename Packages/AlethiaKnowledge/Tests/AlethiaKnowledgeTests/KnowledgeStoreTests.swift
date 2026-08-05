import XCTest
@testable import AlethiaKnowledge
import AlethiaCore

final class KnowledgeStoreTests: XCTestCase {
    func testSaveSessionDictationSearchAndRename() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("alethia-test-\(UUID().uuidString)")
        let store = try KnowledgeStore(directory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let speaker = SpeakerProfile(displayName: "Speaker 1", embedding: [0.1, 0.2, 0.3])
        try store.upsertSpeaker(speaker)

        let utterance = Utterance(
            speakerID: speaker.id,
            speakerLabel: speaker.displayName,
            startMs: 0,
            endMs: 1200,
            text: "shipping the alethia roadmap next week"
        )
        let session = ConversationSession(
            title: "Planning",
            source: .meeting,
            utterances: [utterance]
        )
        try store.saveSession(session)

        let dictation = DictationEvent(text: "draft the alethia release notes")
        try store.saveDictation(dictation)

        let hits = try store.search(query: "alethia")
        XCTAssertGreaterThanOrEqual(hits.count, 1)

        try store.renameSpeaker(id: speaker.id, to: "Alex")
        let speakers = try store.allSpeakers()
        XCTAssertEqual(speakers.first?.displayName, "Alex")

        let recent = try store.recentSessions(limit: 5)
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent.first?.title, "Planning")
        XCTAssertEqual(recent.first?.utterances.count, 1)
        XCTAssertEqual(recent.first?.utterances.first?.text, "shipping the alethia roadmap next week")

        let dictations = try store.recentDictations(limit: 5)
        XCTAssertEqual(dictations.count, 1)
    }

    func testDeleteSessionCleansFTSAndNullifiesDictations() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("alethia-test-\(UUID().uuidString)")
        let store = try KnowledgeStore(directory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let utterance = Utterance(
            speakerLabel: "Speaker 1",
            startMs: 0,
            endMs: 800,
            text: "uniquephrase about deleting meetings"
        )
        let session = ConversationSession(
            title: "To Delete",
            source: .meeting,
            utterances: [utterance]
        )
        try store.saveSession(session)

        let dictation = DictationEvent(
            text: "keep this dictation",
            sessionID: session.id
        )
        try store.saveDictation(dictation)

        XCTAssertEqual(try store.sessionID(forUtteranceID: utterance.id), session.id)
        XCTAssertGreaterThanOrEqual(try store.search(query: "uniquephrase").count, 1)

        try store.deleteSession(id: session.id)

        XCTAssertNil(try store.session(id: session.id))
        XCTAssertTrue(try store.recentSessions().isEmpty)
        XCTAssertNil(try store.sessionID(forUtteranceID: utterance.id))
        XCTAssertTrue(try store.search(query: "uniquephrase").isEmpty)

        let remaining = try store.recentDictations()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.text, "keep this dictation")
        XCTAssertNil(remaining.first?.sessionID)
    }
}
