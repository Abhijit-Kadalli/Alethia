import XCTest
import Foundation
import AlethiaCore
@testable import AlethiaKnowledge

final class KnowledgeStoreSchemaTests: XCTestCase {
    func testFreshStoreReportsSchemaVersion1() throws {
        let store = try KnowledgeStore.inMemory()
        XCTAssertEqual(store.schemaVersion, 1)
        try store.migrate()
        XCTAssertEqual(store.schemaVersion, 1)
    }

    func testReopeningTheSameFileIsIdempotent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("alethia-schema-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("alethia.sqlite")

        do {
            let store = try KnowledgeStore(databaseURL: dbURL, paths: nil)
            XCTAssertEqual(store.schemaVersion, 1)
            try store.saveMeeting(Meeting(title: "First"))
        }

        do {
            let store = try KnowledgeStore(databaseURL: dbURL, paths: nil)
            XCTAssertEqual(store.schemaVersion, 1)
            XCTAssertEqual(try store.listMeetings().map(\.title), ["First"])
            try store.saveMeeting(Meeting(title: "Second"))
            XCTAssertEqual(try store.listMeetings().map(\.title), ["Second", "First"])
        }
    }
}

final class KnowledgeStoreMeetingTests: XCTestCase {
    func testMeetingSaveLoadRoundTripAndMetadataUpdates() throws {
        let store = try KnowledgeStore.inMemory()
        let meetingID = UUID()
        let words = [
            TimedWord(text: "Hello", startMs: 0, endMs: 400, confidence: 0.5),
            TimedWord(text: "world", startMs: 400, endMs: 800, confidence: 1.0),
        ]
        let utterances = [
            Utterance(
                meetingID: meetingID,
                speakerLabel: "You",
                startMs: 0,
                endMs: 800,
                text: "Hello world",
                words: words,
                isLocalSpeaker: true,
                matchConfidence: 0.91,
                suggestedSpeakerName: "Ada"
            ),
            Utterance(
                meetingID: meetingID,
                speakerLabel: "Speaker 2",
                startMs: 900,
                endMs: 1500,
                text: "Hi there",
                words: [],
                isLocalSpeaker: false
            ),
            Utterance(
                meetingID: meetingID,
                speakerLabel: "Speaker 2",
                startMs: 1600,
                endMs: 2000,
                text: "Let's begin",
                words: [
                    TimedWord(text: "Let's", startMs: 1600, endMs: 1800),
                    TimedWord(text: "begin", startMs: 1800, endMs: 2000),
                ],
                isLocalSpeaker: nil
            ),
        ]
        let meeting = Meeting(
            id: meetingID,
            title: "Q1 Planning",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_003_600),
            source: .microphone,
            status: .ready,
            audioPath: "Recordings/\(meetingID.uuidString).wav",
            durationMs: 3_600_000,
            language: "en",
            userNotes: "Bring slides",
            enhancedNotes: "## Summary\nGood meeting",
            enhancedNotesTemplateID: "general",
            enhancedAt: Date(timeIntervalSince1970: 1_700_004_000),
            enhancedBy: "local-heuristics",
            summary: "Planned Q1",
            calendarEventID: "cal-1",
            attendees: ["Ada", "Grace"],
            utterances: utterances,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_004_000)
        )

        try store.saveMeeting(meeting)
        let loaded = try store.meeting(id: meetingID)
        XCTAssertEqual(loaded, meeting)
        XCTAssertEqual(loaded?.utterances.count, 3)
        XCTAssertEqual(loaded?.utterances[0].words, words)
        XCTAssertEqual(loaded?.utterances[0].isLocalSpeaker, true)
        XCTAssertEqual(loaded?.utterances[1].isLocalSpeaker, false)
        XCTAssertNil(loaded?.utterances[2].isLocalSpeaker)
        XCTAssertEqual(loaded?.utterances[0].matchConfidence, Float(0.91))
        XCTAssertEqual(loaded?.utterances[0].suggestedSpeakerName, "Ada")

        let newestID = UUID()
        let older = Meeting(title: "Older", startedAt: Date(timeIntervalSince1970: 100))
        let newest = Meeting(
            id: newestID,
            title: "Newest",
            startedAt: Date(timeIntervalSince1970: 300),
            utterances: [
                Utterance(meetingID: newestID, speakerLabel: "A", startMs: 0, endMs: 10, text: "one"),
                Utterance(meetingID: newestID, speakerLabel: "B", startMs: 20, endMs: 30, text: "two"),
                Utterance(meetingID: newestID, speakerLabel: "C", startMs: 40, endMs: 50, text: "three"),
            ]
        )
        let middle = Meeting(title: "Middle", startedAt: Date(timeIntervalSince1970: 200))
        try store.saveMeeting(older)
        try store.saveMeeting(newest)
        try store.saveMeeting(middle)

        let listed = try store.listMeetings(includeUtterances: false)
        XCTAssertEqual(listed.map(\.title), ["Q1 Planning", "Newest", "Middle", "Older"])
        XCTAssertTrue(listed.allSatisfy { $0.utterances.isEmpty })

        let withUtterances = try store.listMeetings(includeUtterances: true)
        XCTAssertEqual(withUtterances.first?.title, "Q1 Planning")
        XCTAssertEqual(withUtterances.first(where: { $0.title == "Newest" })?.utterances.count, 3)

        try store.updateUserNotes(meetingID: meetingID, notes: "Updated notes")
        try store.updateEnhancedNotes(
            meetingID: meetingID,
            markdown: "Enhanced body",
            templateID: "standup",
            producedBy: "apple-intelligence",
            summary: "One line"
        )
        try store.updateStatus(meetingID: meetingID, status: .failed, error: "boom")
        try store.updateTitle(meetingID: meetingID, title: "Renamed")

        let updated = try store.meeting(id: meetingID)
        XCTAssertEqual(updated?.userNotes, "Updated notes")
        XCTAssertEqual(updated?.enhancedNotes, "Enhanced body")
        XCTAssertEqual(updated?.enhancedNotesTemplateID, "standup")
        XCTAssertEqual(updated?.enhancedBy, "apple-intelligence")
        XCTAssertEqual(updated?.summary, "One line")
        XCTAssertNotNil(updated?.enhancedAt)
        XCTAssertEqual(updated?.status, .failed)
        XCTAssertEqual(updated?.processingError, "boom")
        XCTAssertEqual(updated?.title, "Renamed")
        XCTAssertEqual(updated?.utterances.count, 3)

        guard var metadata = try store.meeting(id: meetingID) else {
            XCTFail("Expected meeting after metadata edits")
            return
        }
        metadata.title = "Metadata only"
        metadata.utterances = []
        try store.updateMeetingMetadata(metadata)
        let afterMeta = try store.meeting(id: meetingID)
        XCTAssertEqual(afterMeta?.title, "Metadata only")
        XCTAssertEqual(afterMeta?.utterances.count, 3)
    }

    func testReplaceUtterancesUpdateTextAndRelabelSpeaker() throws {
        let store = try KnowledgeStore.inMemory()
        let meetingID = UUID()
        let speaker = Speaker(displayName: "Ada")
        try store.upsertSpeaker(speaker)

        let first = Utterance(
            meetingID: meetingID,
            speakerLabel: "Speaker 1",
            startMs: 0,
            endMs: 500,
            text: "Alpha",
            matchConfidence: 0.4,
            suggestedSpeakerName: "Maybe Ada"
        )
        let second = Utterance(
            meetingID: meetingID,
            speakerLabel: "Speaker 2",
            startMs: 600,
            endMs: 900,
            text: "Beta"
        )
        let third = Utterance(
            meetingID: meetingID,
            speakerLabel: "Speaker 1",
            startMs: 1000,
            endMs: 1400,
            text: "Gamma",
            matchConfidence: 0.7,
            suggestedSpeakerName: "Ada?"
        )
        try store.saveMeeting(Meeting(id: meetingID, title: "Relabel", utterances: [first, second, third]))

        let replacement = Utterance(meetingID: meetingID, speakerLabel: "Narrator", startMs: 10, endMs: 20, text: "Only one")
        try store.replaceUtterances(meetingID: meetingID, [replacement])
        var loaded = try store.meeting(id: meetingID)
        XCTAssertEqual(loaded?.utterances.map(\.text), ["Only one"])

        try store.replaceUtterances(meetingID: meetingID, [first, second, third])
        try store.updateUtteranceText(id: first.id, text: "Alpha edited")
        loaded = try store.meeting(id: meetingID)
        XCTAssertEqual(loaded?.utterances.first(where: { $0.id == first.id })?.text, "Alpha edited")

        try store.relabelSpeaker(meetingID: meetingID, currentLabel: "Speaker 1", newLabel: "Ada", speakerID: speaker.id)
        loaded = try store.meeting(id: meetingID)
        let labeled = loaded?.utterances.filter { $0.speakerLabel == "Ada" } ?? []
        XCTAssertEqual(labeled.count, 2)
        XCTAssertTrue(labeled.allSatisfy { $0.speakerID == speaker.id })
        XCTAssertTrue(labeled.allSatisfy { $0.suggestedSpeakerName == nil })
        XCTAssertTrue(labeled.allSatisfy { $0.matchConfidence == nil })
        XCTAssertEqual(loaded?.utterances.first(where: { $0.id == second.id })?.speakerLabel, "Speaker 2")
        XCTAssertNil(loaded?.utterances.first(where: { $0.id == second.id })?.speakerID)
    }

    func testDeleteMeetingRemovesUtterancesFTSAndAudio() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alethia-audio-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        let store = try KnowledgeStore(paths: paths)

        let meetingID = UUID()
        let audioURL = paths.recordingURL(for: meetingID)
        try Data("wav".utf8).write(to: audioURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))

        let utterance = Utterance(meetingID: meetingID, speakerLabel: "You", startMs: 0, endMs: 100, text: "deletemeuniquetoken")
        try store.saveMeeting(Meeting(
            id: meetingID,
            title: "Delete title token",
            audioPath: paths.relativeRecordingPath(for: meetingID),
            utterances: [utterance]
        ))
        XCTAssertFalse(try store.search("deletemeuniquetoken").isEmpty)

        try store.deleteMeeting(id: meetingID)
        XCTAssertNil(try store.meeting(id: meetingID))
        XCTAssertTrue(try store.listMeetings().isEmpty)
        XCTAssertTrue(try store.search("deletemeuniquetoken").isEmpty)
        XCTAssertTrue(try store.search("Delete title token").isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
    }

    func testMeetingsInProgress() throws {
        let store = try KnowledgeStore.inMemory()
        try store.saveMeeting(Meeting(title: "Rec", status: .recording))
        try store.saveMeeting(Meeting(title: "Proc", status: .processing))
        try store.saveMeeting(Meeting(title: "Ready", status: .ready))
        let inProgress = try store.meetingsInProgress()
        XCTAssertEqual(Set(inProgress.map(\.title)), ["Rec", "Proc"])
    }
}

final class KnowledgeStoreSpeakerTests: XCTestCase {
    func testSpeakerUpsertListDeleteNullsUtteranceSpeakerID() throws {
        let store = try KnowledgeStore.inMemory()
        let stamp = Date(timeIntervalSince1970: 1_700_000_123)
        let speaker = Speaker(
            displayName: "Grace",
            embedding: [1, 0, 0],
            sampleCount: 2,
            isSelf: true,
            createdAt: stamp,
            updatedAt: stamp
        )
        try store.upsertSpeaker(speaker)
        XCTAssertEqual(try store.speaker(id: speaker.id), speaker)
        XCTAssertEqual(try store.speakers().map(\.displayName), ["Grace"])

        let meetingID = UUID()
        let utterance = Utterance(
            meetingID: meetingID,
            speakerID: speaker.id,
            speakerLabel: "Grace",
            startMs: 0,
            endMs: 100,
            text: "Hello"
        )
        try store.saveMeeting(Meeting(id: meetingID, title: "Call", utterances: [utterance]))
        try store.deleteSpeaker(id: speaker.id)
        XCTAssertNil(try store.speaker(id: speaker.id))
        XCTAssertNil(try store.meeting(id: meetingID)?.utterances.first?.speakerID)
        XCTAssertEqual(try store.meeting(id: meetingID)?.utterances.first?.speakerLabel, "Grace")
    }

    func testMergeSpeakersAveragesEmbeddingsAndRepointsUtterances() throws {
        let store = try KnowledgeStore.inMemory()
        let keep = Speaker(displayName: "Keep", embedding: [1, 1], sampleCount: 2)
        let remove = Speaker(displayName: "Remove", embedding: [4, 1], sampleCount: 1)
        try store.upsertSpeaker(keep)
        try store.upsertSpeaker(remove)

        let meetingID = UUID()
        let utterance = Utterance(
            meetingID: meetingID,
            speakerID: remove.id,
            speakerLabel: "Remove",
            startMs: 0,
            endMs: 50,
            text: "Hi"
        )
        try store.saveMeeting(Meeting(id: meetingID, title: "Merge", utterances: [utterance]))

        try store.mergeSpeakers(keep: keep.id, remove: remove.id)

        XCTAssertNil(try store.speaker(id: remove.id))
        let merged = try store.speaker(id: keep.id)
        XCTAssertEqual(merged?.sampleCount, 3)
        XCTAssertEqual(merged?.embedding.count, 2)
        XCTAssertEqual(merged?.embedding[0] ?? 0, 2, accuracy: 0.0001)
        XCTAssertEqual(merged?.embedding[1] ?? 0, 1, accuracy: 0.0001)
        XCTAssertEqual(try store.meeting(id: meetingID)?.utterances.first?.speakerID, keep.id)
        XCTAssertEqual(try store.speakers().count, 1)
    }
}

final class KnowledgeStoreDictationTests: XCTestCase {
    func testDictationSaveListEditDeleteAndDeleteAll() throws {
        let store = try KnowledgeStore.inMemory()
        let older = Dictation(
            createdAt: Date(timeIntervalSince1970: 10),
            rawText: "raw older",
            finalText: "older",
            targetBundleID: "com.apple.Notes",
            targetAppName: "Notes",
            durationMs: 1200,
            insertion: .paste,
            appliedStages: ["fillers"]
        )
        let newer = Dictation(
            createdAt: Date(timeIntervalSince1970: 20),
            rawText: "raw newer",
            finalText: "newer",
            insertion: .accessibility
        )
        try store.saveDictation(older)
        try store.saveDictation(newer)

        XCTAssertEqual(try store.listDictations().map(\.finalText), ["newer", "older"])
        XCTAssertEqual(try store.dictation(id: newer.id)?.finalText, "newer")
        XCTAssertNil(try store.dictation(id: UUID()))
        try store.updateDictationEdit(id: newer.id, editedText: "newer edited")
        XCTAssertEqual(try store.listDictations().first?.editedText, "newer edited")
        XCTAssertEqual(try store.listDictations().first?.displayText, "newer edited")
        XCTAssertEqual(try store.dictation(id: newer.id)?.editedText, "newer edited")

        try store.deleteDictation(id: older.id)
        XCTAssertEqual(try store.listDictations().map(\.id), [newer.id])

        try store.deleteAllDictations()
        XCTAssertTrue(try store.listDictations().isEmpty)
    }
}

final class KnowledgeStoreVocabularyTests: XCTestCase {
    func testDictionarySpokenConflictAndUseCounts() throws {
        let store = try KnowledgeStore.inMemory()
        let originalID = UUID()
        try store.upsertDictionaryEntry(DictionaryEntry(id: originalID, spoken: "k8s", written: "k8s", origin: .user))
        try store.upsertDictionaryEntry(DictionaryEntry(spoken: "K8S", written: "Kubernetes", origin: .learned))

        let entries = try store.dictionaryEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].id, originalID)
        XCTAssertEqual(entries[0].spoken, "k8s")
        XCTAssertEqual(entries[0].written, "Kubernetes")
        XCTAssertEqual(entries[0].origin, .learned)
        XCTAssertEqual(try store.dictionaryEntry(id: originalID)?.written, "Kubernetes")
        XCTAssertNil(try store.dictionaryEntry(id: UUID()))

        try store.recordDictionaryUse(ids: [originalID, originalID])
        XCTAssertEqual(try store.dictionaryEntries().first?.useCount, 2)

        try store.deleteDictionaryEntry(id: originalID)
        XCTAssertTrue(try store.dictionaryEntries().isEmpty)
    }

    func testSnippetTriggerConflictAndUseCounts() throws {
        let store = try KnowledgeStore.inMemory()
        let originalID = UUID()
        try store.upsertSnippet(Snippet(id: originalID, trigger: "sig", expansion: "old"))
        try store.upsertSnippet(Snippet(trigger: "SIG", expansion: "Kind regards"))

        let snippets = try store.snippets()
        XCTAssertEqual(snippets.count, 1)
        XCTAssertEqual(snippets[0].id, originalID)
        XCTAssertEqual(snippets[0].trigger, "sig")
        XCTAssertEqual(snippets[0].expansion, "Kind regards")
        XCTAssertEqual(try store.snippet(id: originalID)?.expansion, "Kind regards")
        XCTAssertNil(try store.snippet(id: UUID()))

        try store.recordSnippetUse(ids: [originalID])
        XCTAssertEqual(try store.snippets().first?.useCount, 1)
        try store.deleteSnippet(id: originalID)
        XCTAssertTrue(try store.snippets().isEmpty)
    }
}

final class KnowledgeStoreTemplateTests: XCTestCase {
    func testBuiltInPlusCustomAndRejectsBuiltInUpsert() throws {
        let store = try KnowledgeStore.inMemory()
        XCTAssertEqual(try store.allTemplates().count, NotesTemplate.builtIn.count)
        XCTAssertTrue(try store.customTemplates().isEmpty)

        XCTAssertThrowsError(try store.upsertTemplate(.general)) { error in
            XCTAssertEqual(error as? AlethiaError, .invalidInput("Built-in templates cannot be saved."))
        }

        let custom = NotesTemplate(
            id: "design-review",
            name: "Design Review",
            description: "UI/UX reviews",
            sections: ["Goals", "Feedback"],
            instructions: "Be specific."
        )
        try store.upsertTemplate(custom)
        XCTAssertEqual(try store.customTemplates(), [custom])
        XCTAssertEqual(try store.allTemplates().count, NotesTemplate.builtIn.count + 1)
        XCTAssertTrue(try store.allTemplates().contains(custom))

        try store.deleteTemplate(id: custom.id)
        XCTAssertTrue(try store.customTemplates().isEmpty)
    }
}

final class KnowledgeStoreSearchTests: XCTestCase {
    func testSearchTitleNotesUtteranceDictationPrefixQuotesEmptyAndDelete() throws {
        let store = try KnowledgeStore.inMemory()
        let meetingID = UUID()
        let utterance = Utterance(
            meetingID: meetingID,
            speakerLabel: "You",
            startMs: 1234,
            endMs: 2000,
            text: "please send the invoice today"
        )
        try store.saveMeeting(Meeting(
            id: meetingID,
            title: "Q1 invoice review",
            userNotes: "xylophonotes belong here",
            utterances: [utterance]
        ))
        let dictation = Dictation(rawText: "raw", finalText: "dictate this unique phrase")
        try store.saveDictation(dictation)

        let titleHits = try store.search("invoice review")
        XCTAssertTrue(titleHits.contains(where: { $0.kind == .meetingTitle && $0.id == meetingID && $0.meetingID == meetingID }))

        let noteHits = try store.search("xylophonotes")
        XCTAssertTrue(noteHits.contains(where: { $0.kind == .meetingNotes && $0.id == meetingID }))

        let utteranceHits = try store.search("invoice")
        let utteranceHit = utteranceHits.first(where: { $0.kind == .utterance })
        XCTAssertEqual(utteranceHit?.id, utterance.id)
        XCTAssertEqual(utteranceHit?.meetingID, meetingID)
        XCTAssertEqual(utteranceHit?.startMs, 1234)

        let prefixHits = try store.search("inv")
        XCTAssertTrue(prefixHits.contains(where: { $0.kind == .meetingTitle || $0.kind == .utterance }))

        let dictationHits = try store.search("unique phrase")
        XCTAssertTrue(dictationHits.contains(where: { $0.kind == .dictation && $0.id == dictation.id }))

        XCTAssertNoThrow(try store.search("foo \"bar baz"))
        XCTAssertEqual(try store.search(""), [])
        XCTAssertEqual(try store.search("   \t"), [])

        XCTAssertFalse(try store.search("invoice").isEmpty)

        try store.deleteMeeting(id: meetingID)
        XCTAssertTrue(try store.search("invoice").isEmpty)
        XCTAssertTrue(try store.search("xylophonotes").isEmpty)
        XCTAssertFalse(try store.search("unique phrase").isEmpty)
    }
}

final class KnowledgeStoreObservationTests: XCTestCase {
    func testStartObservingChangesPostsCoalescedNotification() throws {
        let store = try KnowledgeStore.inMemory()
        store.startObservingChanges()
        let exp = expectation(description: "meetings change")
        let token = NotificationCenter.default.addObserver(
            forName: KnowledgeStore.didChangeNotification,
            object: store,
            queue: nil
        ) { note in
            let changes = note.userInfo?[KnowledgeStore.changesKey] as? Set<KnowledgeStore.Change> ?? []
            if changes.contains(.meetings) {
                exp.fulfill()
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        try store.saveMeeting(Meeting(title: "Observed"))
        wait(for: [exp], timeout: 5)
    }

    func testChangeMapsKnownTables() {
        XCTAssertEqual(KnowledgeStore.Change(table: "meetings"), .meetings)
        XCTAssertEqual(KnowledgeStore.Change(table: "dictations"), .dictations)
        XCTAssertNil(KnowledgeStore.Change(table: "sqlite_master"))
    }
}

final class KnowledgeStoreStatsTests: XCTestCase {
    func testStatsCounts() throws {
        let store = try KnowledgeStore.inMemory()
        XCTAssertEqual(
            try store.stats(),
            KnowledgeStore.Stats(meetingCount: 0, dictationCount: 0, dictatedWords: 0, totalMeetingMs: 0, speakerCount: 0)
        )

        try store.saveMeeting(Meeting(title: "A", durationMs: 1000))
        try store.saveMeeting(Meeting(title: "B", durationMs: 2500))
        try store.upsertSpeaker(Speaker(displayName: "Ada"))
        try store.saveDictation(Dictation(rawText: "a", finalText: "one two three"))
        try store.saveDictation(Dictation(rawText: "b", finalText: "four five", editedText: "four"))

        let stats = try store.stats()
        XCTAssertEqual(stats.meetingCount, 2)
        XCTAssertEqual(stats.dictationCount, 2)
        XCTAssertEqual(stats.totalMeetingMs, 3500)
        XCTAssertEqual(stats.speakerCount, 1)
        XCTAssertEqual(stats.dictatedWords, 4)

        try store.vacuum()
    }

    func testConcurrentSaves() throws {
        let store = try KnowledgeStore.inMemory()
        let lock = NSLock()
        var failures: [String] = []

        DispatchQueue.concurrentPerform(iterations: 4) { worker in
            for index in 0..<50 {
                let meeting = Meeting(
                    title: "M-\(worker)-\(index)",
                    startedAt: Date(timeIntervalSince1970: Double(worker * 50 + index))
                )
                do {
                    try store.saveMeeting(meeting)
                } catch {
                    lock.lock()
                    failures.append(String(describing: error))
                    lock.unlock()
                }
            }
        }

        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
        XCTAssertEqual(try store.stats().meetingCount, 200)
        XCTAssertEqual(try store.listMeetings(limit: 500).count, 200)
    }
}

final class KnowledgeStoreLegacyImportTests: XCTestCase {
    func testImportsZeroOneKnowledgeSqliteOnce() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("alethia-legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = AppPaths(root: dir)
        try paths.ensureDirectories()

        let sessionID = UUID()
        let utteranceID = UUID()
        let dictationID = UUID()
        let speakerID = UUID()
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let legacy = try SQLiteDB(path: paths.legacyDatabase.path)
        try legacy.execRaw("""
            CREATE TABLE speakers (
                id TEXT PRIMARY KEY,
                display_name TEXT NOT NULL,
                embedding BLOB,
                updated_at REAL NOT NULL
            );
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY,
                title TEXT,
                started_at REAL NOT NULL,
                ended_at REAL,
                source TEXT NOT NULL,
                notes_markdown TEXT,
                notes_generated_at REAL,
                audio_path TEXT
            );
            CREATE TABLE utterances (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                speaker_id TEXT,
                speaker_label TEXT NOT NULL,
                start_ms INTEGER NOT NULL,
                end_ms INTEGER NOT NULL,
                text TEXT NOT NULL,
                intended_text TEXT,
                words_json TEXT,
                match_confidence REAL,
                suggested_label TEXT
            );
            CREATE TABLE dictations (
                id TEXT PRIMARY KEY,
                created_at REAL NOT NULL,
                text TEXT NOT NULL,
                verbatim_text TEXT,
                target_bundle_id TEXT
            );
            """)
        try legacy.exec(
            "INSERT INTO speakers(id, display_name, updated_at) VALUES(?,?,?)",
            bind: { stmt in
                try legacy.bindUUID(stmt, 1, speakerID)
                try legacy.bindText(stmt, 2, "Ada")
                try legacy.bindDate(stmt, 3, started)
            }
        )
        try legacy.exec(
            "INSERT INTO sessions(id, title, started_at, ended_at, source, notes_markdown, audio_path) VALUES(?,?,?,?,?,?,?)",
            bind: { stmt in
                try legacy.bindUUID(stmt, 1, sessionID)
                try legacy.bindText(stmt, 2, "Standup")
                try legacy.bindDate(stmt, 3, started)
                try legacy.bindDate(stmt, 4, started.addingTimeInterval(60))
                try legacy.bindText(stmt, 5, "mixed")
                try legacy.bindText(stmt, 6, "Ship it")
                try legacy.bindText(stmt, 7, "Recordings/\(sessionID.uuidString).wav")
            }
        )
        try legacy.exec(
            "INSERT INTO utterances(id, session_id, speaker_id, speaker_label, start_ms, end_ms, text) VALUES(?,?,?,?,?,?,?)",
            bind: { stmt in
                try legacy.bindUUID(stmt, 1, utteranceID)
                try legacy.bindUUID(stmt, 2, sessionID)
                try legacy.bindUUID(stmt, 3, speakerID)
                try legacy.bindText(stmt, 4, "Ada")
                try legacy.bindInt(stmt, 5, 0)
                try legacy.bindInt(stmt, 6, 1200)
                try legacy.bindText(stmt, 7, "Hello team")
            }
        )
        try legacy.exec(
            "INSERT INTO dictations(id, created_at, text, verbatim_text, target_bundle_id) VALUES(?,?,?,?,?)",
            bind: { stmt in
                try legacy.bindUUID(stmt, 1, dictationID)
                try legacy.bindDate(stmt, 2, started)
                try legacy.bindText(stmt, 3, "Hello")
                try legacy.bindText(stmt, 4, "hello")
                try legacy.bindText(stmt, 5, "com.apple.TextEdit")
            }
        )

        let store = try KnowledgeStore(paths: paths)
        let meetings = try store.listMeetings(includeUtterances: true)
        XCTAssertEqual(meetings.map(\.title), ["Standup"])
        XCTAssertEqual(meetings.first?.source, .microphoneAndSystem)
        XCTAssertEqual(meetings.first?.userNotes, "")
        XCTAssertEqual(meetings.first?.enhancedNotes, "Ship it")
        XCTAssertEqual(meetings.first?.utterances.map(\.text), ["Hello team"])
        XCTAssertEqual(try store.speakers().map(\.displayName), ["Ada"])
        XCTAssertEqual(try store.listDictations().map(\.finalText), ["Hello"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.legacyDatabase.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("knowledge.sqlite.imported").path))

        let again = try KnowledgeStore(paths: paths)
        XCTAssertEqual(try again.listMeetings().count, 1)
    }
}
