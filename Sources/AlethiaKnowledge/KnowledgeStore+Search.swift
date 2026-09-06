import Foundation
import AlethiaCore

extension KnowledgeStore {
    public func search(_ query: String, limit: Int = 50) throws -> [SearchHit] {
        guard let match = Self.sanitizeFTSQuery(query), limit > 0 else { return [] }
        return try withLock {
            try db.query(
                """
                SELECT doc_id, kind, meeting_id, created_at, start_ms, title,
                       snippet(search_index, 6, '', '', '…', 14)
                FROM search_index
                WHERE search_index MATCH ?
                ORDER BY bm25(search_index)
                LIMIT ?
                """,
                bind: { stmt in
                    try db.bindText(stmt, 1, match)
                    try db.bindInt(stmt, 2, limit)
                },
                row: { self.searchHit(from: $0) }
            )
        }
    }

    /// Split on whitespace, drop empty, escape `"` by doubling, wrap each token as `"tok"*`.
    static func sanitizeFTSQuery(_ query: String) -> String? {
        let tokens = query.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { token in
            let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\"*"
        }.joined(separator: " ")
    }

    func ftsDeleteMeeting(_ meetingID: UUID) throws {
        try db.exec(
            "DELETE FROM search_index WHERE meeting_id = ?",
            bind: { try db.bindUUID($0, 1, meetingID) }
        )
    }

    func ftsInsertMeetingMeta(_ meeting: Meeting) throws {
        try ftsInsertMeetingMeta(
            meetingID: meeting.id,
            title: meeting.title,
            userNotes: meeting.userNotes,
            enhancedNotes: meeting.enhancedNotes,
            createdAt: meeting.createdAt
        )
    }

    func ftsInsertMeetingMeta(meetingID: UUID, title: String, userNotes: String, enhancedNotes: String?, createdAt: Date) throws {
        let id = idString(meetingID)
        let created = String(createdAt.timeIntervalSince1970)
        try insertFTSRow(
            docID: "\(id):title",
            kind: SearchHit.Kind.meetingTitle.rawValue,
            meetingID: id,
            createdAt: created,
            startMs: "",
            title: title,
            body: title
        )
        var notesParts: [String] = []
        if !userNotes.isEmpty { notesParts.append(userNotes) }
        if let enhancedNotes, !enhancedNotes.isEmpty { notesParts.append(enhancedNotes) }
        try insertFTSRow(
            docID: "\(id):notes",
            kind: SearchHit.Kind.meetingNotes.rawValue,
            meetingID: id,
            createdAt: created,
            startMs: "",
            title: title,
            body: notesParts.joined(separator: "\n")
        )
    }

    func ftsReindexMeetingMeta(meetingID: UUID) throws {
        guard let meta = try fetchMeetingFTSMeta(meetingID: meetingID) else { return }
        let id = idString(meetingID)
        try db.exec(
            "DELETE FROM search_index WHERE doc_id = ? OR doc_id = ?",
            bind: { stmt in
                try db.bindText(stmt, 1, "\(id):title")
                try db.bindText(stmt, 2, "\(id):notes")
            }
        )
        try ftsInsertMeetingMeta(
            meetingID: meetingID,
            title: meta.title,
            userNotes: meta.userNotes,
            enhancedNotes: meta.enhancedNotes,
            createdAt: meta.createdAt
        )
        try db.exec(
            "UPDATE search_index SET title = ? WHERE meeting_id = ? AND kind = ?",
            bind: { stmt in
                try db.bindText(stmt, 1, meta.title)
                try db.bindUUID(stmt, 2, meetingID)
                try db.bindText(stmt, 3, SearchHit.Kind.utterance.rawValue)
            }
        )
    }

    func ftsInsertUtterances(meetingID: UUID, title: String, createdAt: Date, utterances: [Utterance]) throws {
        let created = String(createdAt.timeIntervalSince1970)
        let meeting = idString(meetingID)
        for utterance in utterances {
            try insertFTSRow(
                docID: idString(utterance.id),
                kind: SearchHit.Kind.utterance.rawValue,
                meetingID: meeting,
                createdAt: created,
                startMs: String(utterance.startMs),
                title: title,
                body: utterance.text
            )
        }
    }

    func ftsReplaceUtterances(meetingID: UUID, title: String, createdAt: Date, utterances: [Utterance]) throws {
        try db.exec(
            "DELETE FROM search_index WHERE meeting_id = ? AND kind = ?",
            bind: { stmt in
                try db.bindUUID(stmt, 1, meetingID)
                try db.bindText(stmt, 2, SearchHit.Kind.utterance.rawValue)
            }
        )
        try ftsInsertUtterances(meetingID: meetingID, title: title, createdAt: createdAt, utterances: utterances)
    }

    func ftsUpdateUtteranceBody(id: UUID, text: String) throws {
        try db.exec(
            "UPDATE search_index SET body = ? WHERE doc_id = ? AND kind = ?",
            bind: { stmt in
                try db.bindText(stmt, 1, text)
                try db.bindUUID(stmt, 2, id)
                try db.bindText(stmt, 3, SearchHit.Kind.utterance.rawValue)
            }
        )
    }

    func ftsReplaceDictation(_ dictation: Dictation) throws {
        try ftsDeleteDictation(id: dictation.id)
        try insertFTSRow(
            docID: idString(dictation.id),
            kind: SearchHit.Kind.dictation.rawValue,
            meetingID: "",
            createdAt: String(dictation.createdAt.timeIntervalSince1970),
            startMs: "",
            title: dictation.displayText,
            body: dictation.displayText
        )
    }

    func ftsDeleteDictation(id: UUID) throws {
        try db.exec(
            "DELETE FROM search_index WHERE doc_id = ? AND kind = ?",
            bind: { stmt in
                try db.bindUUID(stmt, 1, id)
                try db.bindText(stmt, 2, SearchHit.Kind.dictation.rawValue)
            }
        )
    }

    func ftsDeleteAllDictations() throws {
        try db.exec(
            "DELETE FROM search_index WHERE kind = ?",
            bind: { try db.bindText($0, 1, SearchHit.Kind.dictation.rawValue) }
        )
    }

    func fetchMeetingFTSMeta(meetingID: UUID) throws -> (title: String, userNotes: String, enhancedNotes: String?, createdAt: Date)? {
        let rows: [(String, String, String?, Date)] = try db.query(
            "SELECT title, user_notes, enhanced_notes, created_at FROM meetings WHERE id = ?",
            bind: { try db.bindUUID($0, 1, meetingID) },
            row: { stmt in
                guard let createdAt = SQLite.date(stmt, 3) else { return nil }
                return (
                    SQLite.text(stmt, 0) ?? "",
                    SQLite.text(stmt, 1) ?? "",
                    SQLite.text(stmt, 2),
                    createdAt
                )
            }
        )
        return rows.first
    }

    func insertFTSRow(docID: String, kind: String, meetingID: String, createdAt: String, startMs: String, title: String, body: String) throws {
        try db.exec(
            """
            INSERT INTO search_index (doc_id, kind, meeting_id, created_at, start_ms, title, body)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            bind: { stmt in
                try db.bindText(stmt, 1, docID)
                try db.bindText(stmt, 2, kind)
                try db.bindText(stmt, 3, meetingID)
                try db.bindText(stmt, 4, createdAt)
                try db.bindText(stmt, 5, startMs)
                try db.bindText(stmt, 6, title)
                try db.bindText(stmt, 7, body)
            }
        )
    }

    func searchHit(from stmt: OpaquePointer) -> SearchHit? {
        guard let kindRaw = SQLite.text(stmt, 1), let kind = SearchHit.Kind(rawValue: kindRaw) else {
            log.warning("Skipping search hit with unknown kind")
            return nil
        }
        let docID = SQLite.text(stmt, 0) ?? ""
        let meetingID = SQLite.uuid(stmt, 2)
        let createdAt: Date
        if let raw = SQLite.text(stmt, 3), let value = Double(raw) {
            createdAt = Date(timeIntervalSince1970: value)
        } else {
            createdAt = Date(timeIntervalSince1970: 0)
        }
        let startMs: Int?
        if let raw = SQLite.text(stmt, 4), !raw.isEmpty, let value = Int(raw) {
            startMs = value
        } else {
            startMs = nil
        }
        let title = SQLite.text(stmt, 5) ?? ""
        let snippet = SQLite.text(stmt, 6) ?? ""

        switch kind {
        case .meetingTitle, .meetingNotes:
            guard let meetingID else {
                log.warning("Skipping meeting search hit with invalid meeting_id")
                return nil
            }
            return SearchHit(
                id: meetingID,
                kind: kind,
                meetingID: meetingID,
                title: title,
                snippet: snippet,
                createdAt: createdAt,
                startMs: nil
            )
        case .utterance:
            guard let id = UUID(uuidString: docID) else {
                log.warning("Skipping utterance search hit with invalid doc_id")
                return nil
            }
            return SearchHit(
                id: id,
                kind: .utterance,
                meetingID: meetingID,
                title: title,
                snippet: snippet,
                createdAt: createdAt,
                startMs: startMs
            )
        case .dictation:
            guard let id = UUID(uuidString: docID) else {
                log.warning("Skipping dictation search hit with invalid doc_id")
                return nil
            }
            return SearchHit(
                id: id,
                kind: .dictation,
                meetingID: nil,
                title: title,
                snippet: snippet,
                createdAt: createdAt,
                startMs: nil
            )
        }
    }
}
