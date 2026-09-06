import Foundation
import AlethiaCore

extension KnowledgeStore {
    private static let meetingColumns = """
        id, title, started_at, ended_at, source, status, processing_error, audio_path, duration_ms, language, \
        user_notes, enhanced_notes, enhanced_template_id, enhanced_at, enhanced_by, summary, \
        calendar_event_id, attendees_json, created_at, updated_at
        """

    private static let utteranceColumns = """
        id, meeting_id, speaker_id, speaker_label, start_ms, end_ms, text, words_json, \
        is_local_speaker, match_confidence, suggested_speaker_name
        """

    public func saveMeeting(_ meeting: Meeting) throws {
        try withLock {
            try transaction {
                try upsertMeetingRow(meeting)
                try replaceUtteranceRows(meetingID: meeting.id, meeting.utterances)
                try ftsDeleteMeeting(meeting.id)
                try ftsInsertMeetingMeta(meeting)
                try ftsInsertUtterances(meetingID: meeting.id, title: meeting.title, createdAt: meeting.createdAt, utterances: meeting.utterances)
            }
        }
    }

    public func updateMeetingMetadata(_ meeting: Meeting) throws {
        try withLock {
            try transaction {
                try upsertMeetingRow(meeting)
                try ftsReindexMeetingMeta(meetingID: meeting.id)
            }
        }
    }

    public func updateUserNotes(meetingID: UUID, notes: String) throws {
        try withLock {
            try transaction {
                try db.exec(
                    "UPDATE meetings SET user_notes = ?, updated_at = ? WHERE id = ?",
                    bind: { stmt in
                        try db.bindText(stmt, 1, notes)
                        try db.bindDate(stmt, 2, Date())
                        try db.bindUUID(stmt, 3, meetingID)
                    }
                )
                try requireChanges("Meeting", id: idString(meetingID))
                try ftsReindexMeetingMeta(meetingID: meetingID)
            }
        }
    }

    public func updateEnhancedNotes(meetingID: UUID, markdown: String?, templateID: String?, producedBy: String?, summary: String?) throws {
        try withLock {
            try transaction {
                let enhancedAt: Date? = markdown == nil ? nil : Date()
                try db.exec(
                    """
                    UPDATE meetings SET
                        enhanced_notes = ?,
                        enhanced_template_id = ?,
                        enhanced_by = ?,
                        summary = ?,
                        enhanced_at = ?,
                        updated_at = ?
                    WHERE id = ?
                    """,
                    bind: { stmt in
                        try db.bindText(stmt, 1, markdown)
                        try db.bindText(stmt, 2, templateID)
                        try db.bindText(stmt, 3, producedBy)
                        try db.bindText(stmt, 4, summary)
                        try db.bindDate(stmt, 5, enhancedAt)
                        try db.bindDate(stmt, 6, Date())
                        try db.bindUUID(stmt, 7, meetingID)
                    }
                )
                try requireChanges("Meeting", id: idString(meetingID))
                try ftsReindexMeetingMeta(meetingID: meetingID)
            }
        }
    }

    public func updateStatus(meetingID: UUID, status: MeetingStatus, error: String?) throws {
        try withLock {
            try db.exec(
                "UPDATE meetings SET status = ?, processing_error = ?, updated_at = ? WHERE id = ?",
                bind: { stmt in
                    try db.bindText(stmt, 1, status.rawValue)
                    try db.bindText(stmt, 2, error)
                    try db.bindDate(stmt, 3, Date())
                    try db.bindUUID(stmt, 4, meetingID)
                }
            )
            try requireChanges("Meeting", id: idString(meetingID))
        }
    }

    public func updateTitle(meetingID: UUID, title: String) throws {
        try withLock {
            try transaction {
                try db.exec(
                    "UPDATE meetings SET title = ?, updated_at = ? WHERE id = ?",
                    bind: { stmt in
                        try db.bindText(stmt, 1, title)
                        try db.bindDate(stmt, 2, Date())
                        try db.bindUUID(stmt, 3, meetingID)
                    }
                )
                try requireChanges("Meeting", id: idString(meetingID))
                try ftsReindexMeetingMeta(meetingID: meetingID)
            }
        }
    }

    public func meeting(id: UUID) throws -> Meeting? {
        try withLock {
            let meetings: [Meeting] = try db.query(
                "SELECT \(Self.meetingColumns) FROM meetings WHERE id = ?",
                bind: { try db.bindUUID($0, 1, id) },
                row: { self.meeting(from: $0) }
            )
            guard var meeting = meetings.first else { return nil }
            meeting.utterances = try loadUtterances(meetingIDs: [id])[id] ?? []
            return meeting
        }
    }

    public func listMeetings(limit: Int = 200, offset: Int = 0, includeUtterances: Bool = false) throws -> [Meeting] {
        try withLock {
            var meetings: [Meeting] = try db.query(
                "SELECT \(Self.meetingColumns) FROM meetings ORDER BY started_at DESC LIMIT ? OFFSET ?",
                bind: { stmt in
                    try db.bindInt(stmt, 1, max(limit, 0))
                    try db.bindInt(stmt, 2, max(offset, 0))
                },
                row: { self.meeting(from: $0) }
            )
            if includeUtterances, !meetings.isEmpty {
                let grouped = try loadUtterances(meetingIDs: meetings.map(\.id))
                for i in meetings.indices {
                    meetings[i].utterances = grouped[meetings[i].id] ?? []
                }
            }
            return meetings
        }
    }

    public func meetingsInProgress() throws -> [Meeting] {
        try withLock {
            var meetings: [Meeting] = try db.query(
                """
                SELECT \(Self.meetingColumns) FROM meetings
                WHERE status IN ('recording', 'processing')
                ORDER BY started_at DESC
                """,
                row: { self.meeting(from: $0) }
            )
            if !meetings.isEmpty {
                let grouped = try loadUtterances(meetingIDs: meetings.map(\.id))
                for i in meetings.indices {
                    meetings[i].utterances = grouped[meetings[i].id] ?? []
                }
            }
            return meetings
        }
    }

    public func deleteMeeting(id: UUID) throws {
        let deleted: (found: Bool, audioPath: String?) = try withLock {
            try transaction {
                let rows: [(String, String?)] = try db.query(
                    "SELECT id, audio_path FROM meetings WHERE id = ?",
                    bind: { try db.bindUUID($0, 1, id) },
                    row: { stmt in
                        guard let rawID = SQLite.text(stmt, 0) else { return nil }
                        return (rawID, SQLite.text(stmt, 1))
                    }
                )
                guard let row = rows.first else { return (false, nil) }
                try ftsDeleteMeeting(id)
                try db.exec("DELETE FROM meetings WHERE id = ?", bind: { try db.bindUUID($0, 1, id) })
                return (true, row.1)
            }
        }
        if deleted.found {
            deleteAudioFiles(meetingID: id, audioPath: deleted.audioPath)
        }
    }

    public func replaceUtterances(meetingID: UUID, _ utterances: [Utterance]) throws {
        try withLock {
            try transaction {
                let exists = try db.scalarInt(
                    "SELECT COUNT(*) FROM meetings WHERE id = ?",
                    bind: { try db.bindUUID($0, 1, meetingID) }
                )
                if exists == 0 {
                    throw AlethiaError.notFound("Meeting \(idString(meetingID))")
                }
                try replaceUtteranceRows(meetingID: meetingID, utterances)
                let meta = try fetchMeetingFTSMeta(meetingID: meetingID)
                try ftsReplaceUtterances(
                    meetingID: meetingID,
                    title: meta?.title ?? "",
                    createdAt: meta?.createdAt ?? Date(),
                    utterances: utterances
                )
            }
        }
    }

    public func updateUtteranceText(id: UUID, text: String) throws {
        try withLock {
            try transaction {
                try db.exec(
                    "UPDATE utterances SET text = ? WHERE id = ?",
                    bind: { stmt in
                        try db.bindText(stmt, 1, text)
                        try db.bindUUID(stmt, 2, id)
                    }
                )
                try requireChanges("Utterance", id: idString(id))
                try ftsUpdateUtteranceBody(id: id, text: text)
            }
        }
    }

    public func relabelSpeaker(meetingID: UUID, currentLabel: String, newLabel: String, speakerID: UUID?) throws {
        try withLock {
            try db.exec(
                """
                UPDATE utterances
                SET speaker_label = ?, speaker_id = ?, suggested_speaker_name = NULL, match_confidence = NULL
                WHERE meeting_id = ? AND speaker_label = ?
                """,
                bind: { stmt in
                    try db.bindText(stmt, 1, newLabel)
                    try db.bindUUID(stmt, 2, speakerID)
                    try db.bindUUID(stmt, 3, meetingID)
                    try db.bindText(stmt, 4, currentLabel)
                }
            )
        }
    }

    func upsertMeetingRow(_ meeting: Meeting) throws {
        let attendees = try encodeJSON(meeting.attendees)
        try db.exec(
            """
            INSERT INTO meetings (
                id, title, started_at, ended_at, source, status, processing_error, audio_path, duration_ms, language,
                user_notes, enhanced_notes, enhanced_template_id, enhanced_at, enhanced_by, summary,
                calendar_event_id, attendees_json, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                started_at = excluded.started_at,
                ended_at = excluded.ended_at,
                source = excluded.source,
                status = excluded.status,
                processing_error = excluded.processing_error,
                audio_path = excluded.audio_path,
                duration_ms = excluded.duration_ms,
                language = excluded.language,
                user_notes = excluded.user_notes,
                enhanced_notes = excluded.enhanced_notes,
                enhanced_template_id = excluded.enhanced_template_id,
                enhanced_at = excluded.enhanced_at,
                enhanced_by = excluded.enhanced_by,
                summary = excluded.summary,
                calendar_event_id = excluded.calendar_event_id,
                attendees_json = excluded.attendees_json,
                updated_at = excluded.updated_at
            """,
            bind: { stmt in
                try db.bindUUID(stmt, 1, meeting.id)
                try db.bindText(stmt, 2, meeting.title)
                try db.bindDate(stmt, 3, meeting.startedAt)
                try db.bindDate(stmt, 4, meeting.endedAt)
                try db.bindText(stmt, 5, meeting.source.rawValue)
                try db.bindText(stmt, 6, meeting.status.rawValue)
                try db.bindText(stmt, 7, meeting.processingError)
                try db.bindText(stmt, 8, meeting.audioPath)
                try db.bindInt(stmt, 9, meeting.durationMs)
                try db.bindText(stmt, 10, meeting.language)
                try db.bindText(stmt, 11, meeting.userNotes)
                try db.bindText(stmt, 12, meeting.enhancedNotes)
                try db.bindText(stmt, 13, meeting.enhancedNotesTemplateID)
                try db.bindDate(stmt, 14, meeting.enhancedAt)
                try db.bindText(stmt, 15, meeting.enhancedBy)
                try db.bindText(stmt, 16, meeting.summary)
                try db.bindText(stmt, 17, meeting.calendarEventID)
                try db.bindText(stmt, 18, attendees)
                try db.bindDate(stmt, 19, meeting.createdAt)
                try db.bindDate(stmt, 20, meeting.updatedAt)
            }
        )
    }

    func replaceUtteranceRows(meetingID: UUID, _ utterances: [Utterance]) throws {
        try db.exec("DELETE FROM utterances WHERE meeting_id = ?", bind: { try db.bindUUID($0, 1, meetingID) })
        for utterance in utterances {
            try insertUtteranceRow(utterance, meetingID: meetingID)
        }
    }

    func insertUtteranceRow(_ utterance: Utterance, meetingID: UUID) throws {
        let wordsJSON: String? = utterance.words.isEmpty ? nil : try encodeJSON(utterance.words)
        try db.exec(
            """
            INSERT INTO utterances (
                id, meeting_id, speaker_id, speaker_label, start_ms, end_ms, text, words_json,
                is_local_speaker, match_confidence, suggested_speaker_name
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bind: { stmt in
                try db.bindUUID(stmt, 1, utterance.id)
                try db.bindUUID(stmt, 2, meetingID)
                try db.bindUUID(stmt, 3, utterance.speakerID)
                try db.bindText(stmt, 4, utterance.speakerLabel)
                try db.bindInt(stmt, 5, utterance.startMs)
                try db.bindInt(stmt, 6, utterance.endMs)
                try db.bindText(stmt, 7, utterance.text)
                try db.bindText(stmt, 8, wordsJSON)
                try db.bindBool(stmt, 9, utterance.isLocalSpeaker)
                if let confidence = utterance.matchConfidence {
                    try db.bindDouble(stmt, 10, Double(confidence))
                } else {
                    try db.bindNull(stmt, 10)
                }
                try db.bindText(stmt, 11, utterance.suggestedSpeakerName)
            }
        )
    }

    func loadUtterances(meetingIDs: [UUID]) throws -> [UUID: [Utterance]] {
        guard !meetingIDs.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: meetingIDs.count).joined(separator: ",")
        let sql = """
            SELECT \(Self.utteranceColumns) FROM utterances
            WHERE meeting_id IN (\(placeholders))
            ORDER BY meeting_id, start_ms
            """
        let utterances: [Utterance] = try db.query(sql, bind: { stmt in
            for (index, id) in meetingIDs.enumerated() {
                try db.bindUUID(stmt, Int32(index + 1), id)
            }
        }, row: { self.utterance(from: $0) })
        var grouped: [UUID: [Utterance]] = [:]
        for utterance in utterances {
            grouped[utterance.meetingID, default: []].append(utterance)
        }
        return grouped
    }

    func meeting(from stmt: OpaquePointer) -> Meeting? {
        guard let id = SQLite.uuid(stmt, 0) else {
            log.warning("Skipping meeting row with invalid id")
            return nil
        }
        let title = SQLite.text(stmt, 1) ?? ""
        guard let startedAt = SQLite.date(stmt, 2) else {
            log.warning("Skipping meeting \(idString(id)) with invalid started_at")
            return nil
        }
        let endedAt = SQLite.date(stmt, 3)
        guard let sourceRaw = SQLite.text(stmt, 4), let source = CaptureSource(rawValue: sourceRaw) else {
            log.warning("Skipping meeting \(idString(id)) with unknown source")
            return nil
        }
        guard let statusRaw = SQLite.text(stmt, 5), let status = MeetingStatus(rawValue: statusRaw) else {
            log.warning("Skipping meeting \(idString(id)) with unknown status")
            return nil
        }
        guard let createdAt = SQLite.date(stmt, 18), let updatedAt = SQLite.date(stmt, 19) else {
            log.warning("Skipping meeting \(idString(id)) with invalid timestamps")
            return nil
        }
        return Meeting(
            id: id,
            title: title,
            startedAt: startedAt,
            endedAt: endedAt,
            source: source,
            status: status,
            processingError: SQLite.text(stmt, 6),
            audioPath: SQLite.text(stmt, 7),
            durationMs: SQLite.int(stmt, 8) ?? 0,
            language: SQLite.text(stmt, 9),
            userNotes: SQLite.text(stmt, 10) ?? "",
            enhancedNotes: SQLite.text(stmt, 11),
            enhancedNotesTemplateID: SQLite.text(stmt, 12),
            enhancedAt: SQLite.date(stmt, 13),
            enhancedBy: SQLite.text(stmt, 14),
            summary: SQLite.text(stmt, 15),
            calendarEventID: SQLite.text(stmt, 16),
            attendees: decodeJSON(SQLite.text(stmt, 17), as: [String].self, default: []),
            utterances: [],
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    func utterance(from stmt: OpaquePointer) -> Utterance? {
        guard let id = SQLite.uuid(stmt, 0) else {
            log.warning("Skipping utterance row with invalid id")
            return nil
        }
        guard let meetingID = SQLite.uuid(stmt, 1) else {
            log.warning("Skipping utterance \(id.uuidString) with invalid meeting_id")
            return nil
        }
        let speakerID = SQLite.uuid(stmt, 2)
        let speakerLabel = SQLite.text(stmt, 3) ?? ""
        let startMs = SQLite.int(stmt, 4) ?? 0
        let endMs = SQLite.int(stmt, 5) ?? startMs
        let text = SQLite.text(stmt, 6) ?? ""
        let words = decodeJSON(SQLite.text(stmt, 7), as: [TimedWord].self, default: [])
        let isLocalSpeaker = SQLite.bool(stmt, 8)
        let matchConfidence = SQLite.double(stmt, 9).map { Float($0) }
        let suggestedSpeakerName = SQLite.text(stmt, 10)
        return Utterance(
            id: id,
            meetingID: meetingID,
            speakerID: speakerID,
            speakerLabel: speakerLabel,
            startMs: startMs,
            endMs: endMs,
            text: text,
            words: words,
            isLocalSpeaker: isLocalSpeaker,
            matchConfidence: matchConfidence,
            suggestedSpeakerName: suggestedSpeakerName
        )
    }

    func deleteAudioFiles(meetingID: UUID, audioPath: String?) {
        guard let paths else { return }
        var seen = Set<String>()
        var urls = [paths.recordingURL(for: meetingID)]
        if let audioPath, !audioPath.isEmpty {
            urls.append(paths.resolve(relativePath: audioPath))
        }
        for url in urls {
            if seen.insert(url.path).inserted {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
