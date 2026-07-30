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
            source: .ambient,
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
    }
}
