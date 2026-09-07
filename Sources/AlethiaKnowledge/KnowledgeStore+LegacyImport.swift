import Foundation
import AlethiaCore

extension KnowledgeStore {
    /// Copies 0.1.x `knowledge.sqlite` (`sessions`) into the rewrite schema, then renames the
    /// old file so the import runs once.
    func importLegacyKnowledgeStoreIfNeeded(from paths: AppPaths) throws {
        let legacyURL = paths.legacyDatabase
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return }
        let existingMeetings = try stats().meetingCount
        guard existingMeetings == 0 else { return }

        let sessionCount: Int
        let dictationCount: Int
        do {
            let legacy = try SQLiteDB(path: legacyURL.path)
            let hasSessions = try legacy.scalarInt(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'sessions'"
            )
            guard hasSessions > 0 else { return }

            let speakers = try legacy.query(
                "SELECT id, display_name, embedding, updated_at FROM speakers"
            ) { stmt -> Speaker? in
                guard let id = SQLite.uuid(stmt, 0) else { return nil }
                let updated = SQLite.date(stmt, 3) ?? Date()
                return Speaker(
                    id: id,
                    displayName: SQLite.text(stmt, 1) ?? "Speaker",
                    embedding: Float32LECodec.decode(SQLite.blob(stmt, 2)),
                    createdAt: updated,
                    updatedAt: updated
                )
            }
            for speaker in speakers {
                try upsertSpeaker(speaker)
            }

            let sessions = try legacy.query(
                """
                SELECT id, title, started_at, ended_at, source, notes_markdown, notes_generated_at, audio_path
                FROM sessions
                """
            ) { stmt -> Meeting? in
                guard let id = SQLite.uuid(stmt, 0), let started = SQLite.date(stmt, 2) else { return nil }
                let sourceRaw = SQLite.text(stmt, 4) ?? ""
                let source: CaptureSource = (sourceRaw == "mixed") ? .microphoneAndSystem : .microphone
                let ended = SQLite.date(stmt, 3)
                var meeting = Meeting(
                    id: id,
                    title: {
                        let raw = SQLite.text(stmt, 1)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        return raw.isEmpty ? "Imported meeting" : raw
                    }(),
                    startedAt: started,
                    endedAt: ended,
                    source: source,
                    status: .ready,
                    audioPath: SQLite.text(stmt, 7)
                )
                meeting.userNotes = SQLite.text(stmt, 5) ?? ""
                meeting.enhancedNotes = SQLite.text(stmt, 5)
                meeting.enhancedAt = SQLite.date(stmt, 6)
                if let ended {
                    meeting.durationMs = max(0, Int(ended.timeIntervalSince(started) * 1000))
                }
                return meeting
            }

            for var meeting in sessions {
                let utterances = try legacy.query(
                    """
                    SELECT id, speaker_id, speaker_label, start_ms, end_ms, text, intended_text,
                           words_json, match_confidence, suggested_label
                    FROM utterances WHERE session_id = ?
                    ORDER BY start_ms
                    """,
                    bind: { try legacy.bindUUID($0, 1, meeting.id) },
                    row: { stmt -> Utterance? in
                        guard let id = SQLite.uuid(stmt, 0) else { return nil }
                        let intended = SQLite.text(stmt, 6)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let text = intended.isEmpty ? (SQLite.text(stmt, 5) ?? "") : intended
                        return Utterance(
                            id: id,
                            meetingID: meeting.id,
                            speakerID: SQLite.uuid(stmt, 1),
                            speakerLabel: SQLite.text(stmt, 2) ?? "Speaker",
                            startMs: SQLite.int(stmt, 3) ?? 0,
                            endMs: SQLite.int(stmt, 4) ?? 0,
                            text: text,
                            words: Self.decodeLegacyWords(SQLite.text(stmt, 7)),
                            matchConfidence: SQLite.double(stmt, 8).map { Float($0) },
                            suggestedSpeakerName: SQLite.text(stmt, 9)
                        )
                    }
                )
                meeting.utterances = utterances
                if meeting.durationMs == 0, let last = utterances.last {
                    meeting.durationMs = last.endMs
                }
                try saveMeeting(meeting)
            }

            let dictations = try legacy.query(
                """
                SELECT id, created_at, text, verbatim_text, target_bundle_id
                FROM dictations
                """
            ) { stmt -> Dictation? in
                guard let id = SQLite.uuid(stmt, 0) else { return nil }
                let finalText = SQLite.text(stmt, 2) ?? ""
                return Dictation(
                    id: id,
                    createdAt: SQLite.date(stmt, 1) ?? Date(),
                    rawText: SQLite.text(stmt, 3) ?? finalText,
                    finalText: finalText,
                    targetBundleID: SQLite.text(stmt, 4)
                )
            }
            for dictation in dictations {
                try saveDictation(dictation)
            }
            sessionCount = sessions.count
            dictationCount = dictations.count
        }

        let imported = legacyURL.deletingPathExtension().appendingPathExtension("sqlite.imported")
        try? FileManager.default.removeItem(at: imported)
        try FileManager.default.moveItem(at: legacyURL, to: imported)
        log.info("imported \(sessionCount) meetings and \(dictationCount) dictations from 0.1.x store")
    }

    private static func decodeLegacyWords(_ json: String?) -> [TimedWord] {
        guard let json, let data = json.data(using: .utf8),
              let words = try? JSONDecoder().decode([TimedWord].self, from: data) else {
            return []
        }
        return words
    }
}
