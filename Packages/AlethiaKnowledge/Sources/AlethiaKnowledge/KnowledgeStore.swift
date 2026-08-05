import Foundation
import SQLite3
import AlethiaCore

public final class KnowledgeStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let path: URL
    private let lock = NSLock()

    public init(directory: URL? = nil) throws {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Alethia", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.path = base.appendingPathComponent("knowledge.sqlite")
        try open()
        try migrate()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private func open() throws {
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path.path, &db, flags, nil) != SQLITE_OK {
            throw AlethiaError.database(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_exec(db, "PRAGMA foreign_keys = ON;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA journal_mode = WAL;", nil, nil, nil)
    }

    private func migrate() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS speakers (
            id TEXT PRIMARY KEY,
            display_name TEXT NOT NULL,
            embedding BLOB,
            updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS sessions (
            id TEXT PRIMARY KEY,
            title TEXT,
            started_at REAL NOT NULL,
            ended_at REAL,
            source TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS utterances (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            speaker_id TEXT REFERENCES speakers(id),
            speaker_label TEXT NOT NULL,
            start_ms INTEGER NOT NULL,
            end_ms INTEGER NOT NULL,
            text TEXT NOT NULL,
            intended_text TEXT,
            words_json TEXT
        );
            CREATE TABLE IF NOT EXISTS dictations (
            id TEXT PRIMARY KEY,
            created_at REAL NOT NULL,
            text TEXT NOT NULL,
            verbatim_text TEXT,
            target_bundle_id TEXT,
            session_id TEXT REFERENCES sessions(id)
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS fts_documents USING fts5(
            doc_id UNINDEXED,
            kind UNINDEXED,
            title,
            body,
            created_at UNINDEXED
        );
        """
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            throw AlethiaError.database(String(cString: sqlite3_errmsg(db)))
        }
        // Additive migrations for existing installs.
        _ = sqlite3_exec(db, "ALTER TABLE dictations ADD COLUMN verbatim_text TEXT;", nil, nil, nil)
        _ = sqlite3_exec(db, "ALTER TABLE utterances ADD COLUMN intended_text TEXT;", nil, nil, nil)
        _ = sqlite3_exec(db, "ALTER TABLE utterances ADD COLUMN words_json TEXT;", nil, nil, nil)
        _ = sqlite3_exec(db, "ALTER TABLE utterances ADD COLUMN match_confidence REAL;", nil, nil, nil)
        _ = sqlite3_exec(db, "ALTER TABLE utterances ADD COLUMN suggested_label TEXT;", nil, nil, nil)
        _ = sqlite3_exec(db, "ALTER TABLE sessions ADD COLUMN notes_markdown TEXT;", nil, nil, nil)
        _ = sqlite3_exec(db, "ALTER TABLE sessions ADD COLUMN notes_generated_at REAL;", nil, nil, nil)
    }

    public func upsertSpeaker(_ speaker: SpeakerProfile) throws {
        lock.lock(); defer { lock.unlock() }
        let emb = Data(bytes: speaker.embedding, count: speaker.embedding.count * MemoryLayout<Float>.size)
        try exec(
            """
            INSERT INTO speakers(id, display_name, embedding, updated_at)
            VALUES(?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
              display_name=excluded.display_name,
              embedding=excluded.embedding,
              updated_at=excluded.updated_at;
            """,
            binder: { stmt in
                sqlite3_bind_text(stmt, 1, speaker.id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_text(stmt, 2, speaker.displayName, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                _ = emb.withUnsafeBytes { raw in
                    sqlite3_bind_blob(stmt, 3, raw.baseAddress, Int32(emb.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
                sqlite3_bind_double(stmt, 4, speaker.updatedAt.timeIntervalSince1970)
            }
        )
    }

    public func saveSession(_ session: ConversationSession) throws {
        lock.lock(); defer { lock.unlock() }
        try exec(
            """
            INSERT INTO sessions(id, title, started_at, ended_at, source, notes_markdown, notes_generated_at)
            VALUES(?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
              title=excluded.title,
              ended_at=excluded.ended_at,
              source=excluded.source,
              notes_markdown=excluded.notes_markdown,
              notes_generated_at=excluded.notes_generated_at;
            """,
            binder: { stmt in
                bindText(stmt, 1, session.id.uuidString)
                if let title = session.title { bindText(stmt, 2, title) } else { sqlite3_bind_null(stmt, 2) }
                sqlite3_bind_double(stmt, 3, session.startedAt.timeIntervalSince1970)
                if let ended = session.endedAt {
                    sqlite3_bind_double(stmt, 4, ended.timeIntervalSince1970)
                } else {
                    sqlite3_bind_null(stmt, 4)
                }
                bindText(stmt, 5, session.source.rawValue)
                if let notes = session.notesMarkdown { bindText(stmt, 6, notes) } else { sqlite3_bind_null(stmt, 6) }
                if let generated = session.notesGeneratedAt {
                    sqlite3_bind_double(stmt, 7, generated.timeIntervalSince1970)
                } else {
                    sqlite3_bind_null(stmt, 7)
                }
            }
        )

        for u in session.utterances {
            try exec(
                """
                INSERT INTO utterances(id, session_id, speaker_id, speaker_label, start_ms, end_ms, text, intended_text, words_json, match_confidence, suggested_label)
                VALUES(?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET
                  text=excluded.text,
                  intended_text=excluded.intended_text,
                  words_json=excluded.words_json,
                  speaker_label=excluded.speaker_label,
                  speaker_id=excluded.speaker_id,
                  match_confidence=excluded.match_confidence,
                  suggested_label=excluded.suggested_label;
                """,
                binder: { stmt in
                    bindText(stmt, 1, u.id.uuidString)
                    bindText(stmt, 2, session.id.uuidString)
                    if let sid = u.speakerID { bindText(stmt, 3, sid.uuidString) } else { sqlite3_bind_null(stmt, 3) }
                    bindText(stmt, 4, u.speakerLabel)
                    sqlite3_bind_int(stmt, 5, Int32(u.startMs))
                    sqlite3_bind_int(stmt, 6, Int32(u.endMs))
                    bindText(stmt, 7, u.text)
                    if let intended = u.intendedText { bindText(stmt, 8, intended) } else { sqlite3_bind_null(stmt, 8) }
                    if u.words.isEmpty {
                        sqlite3_bind_null(stmt, 9)
                    } else if let data = try? JSONEncoder().encode(u.words),
                              let json = String(data: data, encoding: .utf8) {
                        bindText(stmt, 9, json)
                    } else {
                        sqlite3_bind_null(stmt, 9)
                    }
                    if let conf = u.matchConfidence {
                        sqlite3_bind_double(stmt, 10, Double(conf))
                    } else {
                        sqlite3_bind_null(stmt, 10)
                    }
                    if let suggested = u.suggestedSpeakerLabel {
                        bindText(stmt, 11, suggested)
                    } else {
                        sqlite3_bind_null(stmt, 11)
                    }
                }
            )
            let body = [u.text, u.intendedText].compactMap { $0 }.joined(separator: "\n")
            try indexFTS(
                docID: u.id,
                kind: "utterance",
                title: u.speakerLabel,
                body: body,
                createdAt: session.startedAt
            )
        }
    }

    public func updateSessionNotes(sessionID: UUID, markdown: String) throws {
        lock.lock(); defer { lock.unlock() }
        try exec(
            """
            UPDATE sessions
            SET notes_markdown=?, notes_generated_at=?
            WHERE id=?;
            """,
            binder: { stmt in
                bindText(stmt, 1, markdown)
                sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
                bindText(stmt, 3, sessionID.uuidString)
            }
        )
    }

    /// Renames a speaker within one meeting and clears suggestions for that identity.
    public func relabelSpeaker(sessionID: UUID, speakerID: UUID, to name: String) throws {
        lock.lock(); defer { lock.unlock() }
        try exec(
            """
            UPDATE utterances
            SET speaker_label=?, suggested_label=NULL, match_confidence=NULL
            WHERE session_id=? AND speaker_id=?;
            """,
            binder: { stmt in
                bindText(stmt, 1, name)
                bindText(stmt, 2, sessionID.uuidString)
                bindText(stmt, 3, speakerID.uuidString)
            }
        )
        try exec(
            "UPDATE speakers SET display_name=?, updated_at=? WHERE id=?;",
            binder: { stmt in
                bindText(stmt, 1, name)
                sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
                bindText(stmt, 3, speakerID.uuidString)
            }
        )
    }

    public func saveDictation(_ event: DictationEvent) throws {
        lock.lock(); defer { lock.unlock() }
        try exec(
            """
            INSERT INTO dictations(id, created_at, text, verbatim_text, target_bundle_id, session_id)
            VALUES(?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
              text=excluded.text,
              verbatim_text=excluded.verbatim_text;
            """,
            binder: { stmt in
                bindText(stmt, 1, event.id.uuidString)
                sqlite3_bind_double(stmt, 2, event.createdAt.timeIntervalSince1970)
                bindText(stmt, 3, event.text)
                if let verbatim = event.verbatimText { bindText(stmt, 4, verbatim) } else { sqlite3_bind_null(stmt, 4) }
                if let bid = event.targetBundleID { bindText(stmt, 5, bid) } else { sqlite3_bind_null(stmt, 5) }
                if let sid = event.sessionID { bindText(stmt, 6, sid.uuidString) } else { sqlite3_bind_null(stmt, 6) }
            }
        )
        let body = [event.verbatimText, event.text]
            .compactMap { $0 }
            .joined(separator: "\n")
        try indexFTS(
            docID: event.id,
            kind: "dictation",
            title: "Dictation",
            body: body,
            createdAt: event.createdAt
        )
    }

    public func renameSpeaker(id: UUID, to name: String) throws {
        lock.lock(); defer { lock.unlock() }
        try exec(
            "UPDATE speakers SET display_name=?, updated_at=? WHERE id=?;",
            binder: { stmt in
                bindText(stmt, 1, name)
                sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
                bindText(stmt, 3, id.uuidString)
            }
        )
        try exec(
            "UPDATE utterances SET speaker_label=? WHERE speaker_id=?;",
            binder: { stmt in
                bindText(stmt, 1, name)
                bindText(stmt, 2, id.uuidString)
            }
        )
    }

    /// Deletes a meeting session, its utterances (CASCADE), FTS rows, and nullifies linked dictations.
    public func deleteSession(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        var utteranceIDs: [UUID] = []
        try query(
            "SELECT id FROM utterances WHERE session_id=?;",
            binder: { bindText($0, 1, id.uuidString) }
        ) { stmt in
            if let uuid = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))) {
                utteranceIDs.append(uuid)
            }
        }
        for uid in utteranceIDs {
            try exec("DELETE FROM fts_documents WHERE doc_id=?;", binder: { bindText($0, 1, uid.uuidString) })
        }
        try exec("DELETE FROM fts_documents WHERE doc_id=?;", binder: { bindText($0, 1, id.uuidString) })
        try exec(
            "UPDATE dictations SET session_id=NULL WHERE session_id=?;",
            binder: { bindText($0, 1, id.uuidString) }
        )
        try exec("DELETE FROM sessions WHERE id=?;", binder: { bindText($0, 1, id.uuidString) })
    }

    public func sessionID(forUtteranceID id: UUID) throws -> UUID? {
        lock.lock(); defer { lock.unlock() }
        var found: UUID?
        try query(
            "SELECT session_id FROM utterances WHERE id=? LIMIT 1;",
            binder: { bindText($0, 1, id.uuidString) }
        ) { stmt in
            found = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0)))
        }
        return found
    }

    public func allSpeakers() throws -> [SpeakerProfile] {
        lock.lock(); defer { lock.unlock() }
        var result: [SpeakerProfile] = []
        try query("SELECT id, display_name, embedding, updated_at FROM speakers ORDER BY display_name;") { stmt in
            let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0)))!
            let name = String(cString: sqlite3_column_text(stmt, 1))
            var embedding: [Float] = []
            if let blob = sqlite3_column_blob(stmt, 2) {
                let count = Int(sqlite3_column_bytes(stmt, 2)) / MemoryLayout<Float>.size
                embedding = Array(UnsafeBufferPointer(start: blob.assumingMemoryBound(to: Float.self), count: count))
            }
            let updated = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            result.append(SpeakerProfile(id: id, displayName: name, embedding: embedding, updatedAt: updated))
        }
        return result
    }

    public func recentSessions(limit: Int = 50) throws -> [ConversationSession] {
        lock.lock(); defer { lock.unlock() }
        var sessions: [ConversationSession] = []
        try query(
            """
            SELECT id, title, started_at, ended_at, source, notes_markdown, notes_generated_at
            FROM sessions ORDER BY started_at DESC LIMIT ?;
            """,
            binder: { sqlite3_bind_int($0, 1, Int32(limit)) }
        ) { stmt in
            sessions.append(Self.sessionFromStatement(stmt))
        }

        for i in sessions.indices {
            sessions[i].utterances = try loadUtterancesLocked(sessionID: sessions[i].id)
        }
        return sessions
    }

    public func session(id: UUID) throws -> ConversationSession? {
        lock.lock(); defer { lock.unlock() }
        var found: ConversationSession?
        try query(
            """
            SELECT id, title, started_at, ended_at, source, notes_markdown, notes_generated_at
            FROM sessions WHERE id=? LIMIT 1;
            """,
            binder: { bindText($0, 1, id.uuidString) }
        ) { stmt in
            found = Self.sessionFromStatement(stmt)
        }
        guard var session = found else { return nil }
        session.utterances = try loadUtterancesLocked(sessionID: session.id)
        return session
    }

    private static func sessionFromStatement(_ stmt: OpaquePointer) -> ConversationSession {
        let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0)))!
        let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
        let started = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
        let ended: Date? = sqlite3_column_type(stmt, 3) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
        let source = CaptureSource(rawValue: String(cString: sqlite3_column_text(stmt, 4))) ?? .meeting
        let notes = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
        let notesAt: Date? = sqlite3_column_type(stmt, 6) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
        return ConversationSession(
            id: id,
            title: title,
            startedAt: started,
            endedAt: ended,
            source: source,
            notesMarkdown: notes,
            notesGeneratedAt: notesAt
        )
    }

    public func recentDictations(limit: Int = 50) throws -> [DictationEvent] {
        lock.lock(); defer { lock.unlock() }
        var events: [DictationEvent] = []
        try query(
            """
            SELECT id, created_at, text, verbatim_text, target_bundle_id, session_id
            FROM dictations ORDER BY created_at DESC LIMIT ?;
            """,
            binder: { sqlite3_bind_int($0, 1, Int32(limit)) }
        ) { stmt in
            let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0)))!
            let created = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
            let text = String(cString: sqlite3_column_text(stmt, 2))
            let verbatim = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
            let bundle = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
            let sessionID = sqlite3_column_text(stmt, 5).flatMap { UUID(uuidString: String(cString: $0)) }
            events.append(DictationEvent(
                id: id,
                createdAt: created,
                text: text,
                verbatimText: verbatim,
                targetBundleID: bundle,
                sessionID: sessionID
            ))
        }
        return events
    }

    private func loadUtterancesLocked(sessionID: UUID) throws -> [Utterance] {
        var utterances: [Utterance] = []
        try query(
            """
            SELECT id, speaker_id, speaker_label, start_ms, end_ms, text, intended_text, words_json,
                   match_confidence, suggested_label
            FROM utterances
            WHERE session_id=?
            ORDER BY start_ms ASC, rowid ASC;
            """,
            binder: { bindText($0, 1, sessionID.uuidString) }
        ) { stmt in
            let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0)))!
            let speakerID = sqlite3_column_text(stmt, 1).flatMap { UUID(uuidString: String(cString: $0)) }
            let label = String(cString: sqlite3_column_text(stmt, 2))
            let startMs = Int(sqlite3_column_int(stmt, 3))
            let endMs = Int(sqlite3_column_int(stmt, 4))
            let text = String(cString: sqlite3_column_text(stmt, 5))
            let intended = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
            var words: [TimedWord] = []
            if let jsonC = sqlite3_column_text(stmt, 7) {
                let json = String(cString: jsonC)
                if let data = json.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode([TimedWord].self, from: data) {
                    words = decoded
                }
            }
            let confidence: Float? = sqlite3_column_type(stmt, 8) == SQLITE_NULL
                ? nil
                : Float(sqlite3_column_double(stmt, 8))
            let suggested = sqlite3_column_text(stmt, 9).map { String(cString: $0) }
            utterances.append(Utterance(
                id: id,
                speakerID: speakerID,
                speakerLabel: label,
                startMs: startMs,
                endMs: endMs,
                text: text,
                intendedText: intended,
                words: words,
                matchConfidence: confidence,
                suggestedSpeakerLabel: suggested
            ))
        }
        return utterances
    }

    public func search(query text: String, limit: Int = 40) throws -> [KnowledgeHit] {
        lock.lock(); defer { lock.unlock() }
        let escaped = text.replacingOccurrences(of: "\"", with: "\"\"")
        var hits: [KnowledgeHit] = []
        try self.query(
            """
            SELECT doc_id, kind, title, body, created_at
            FROM fts_documents
            WHERE fts_documents MATCH ?
            ORDER BY rank
            LIMIT ?;
            """,
            binder: { stmt in
                bindText(stmt, 1, "\(escaped)*")
                sqlite3_bind_int(stmt, 2, Int32(limit))
            }
        ) { stmt in
            let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0)))!
            let kind = KnowledgeHit.Kind(rawValue: String(cString: sqlite3_column_text(stmt, 1))) ?? .utterance
            let title = String(cString: sqlite3_column_text(stmt, 2))
            let body = String(cString: sqlite3_column_text(stmt, 3))
            let created = Date(timeIntervalSince1970: Double(String(cString: sqlite3_column_text(stmt, 4))) ?? 0)
            let snippet = String(body.prefix(180))
            hits.append(KnowledgeHit(id: id, kind: kind, title: title, snippet: snippet, createdAt: created))
        }
        return hits
    }

    // MARK: - SQLite helpers

    private func indexFTS(docID: UUID, kind: String, title: String, body: String, createdAt: Date) throws {
        try exec("DELETE FROM fts_documents WHERE doc_id=?;", binder: { bindText($0, 1, docID.uuidString) })
        try exec(
            "INSERT INTO fts_documents(doc_id, kind, title, body, created_at) VALUES(?,?,?,?,?);",
            binder: { stmt in
                bindText(stmt, 1, docID.uuidString)
                bindText(stmt, 2, kind)
                bindText(stmt, 3, title)
                bindText(stmt, 4, body)
                bindText(stmt, 5, String(createdAt.timeIntervalSince1970))
            }
        )
    }

    private func exec(_ sql: String, binder: ((OpaquePointer) -> Void)? = nil) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw AlethiaError.database(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        binder?(stmt!)
        let step = sqlite3_step(stmt)
        // Multi-statement CREATE via sqlite3_exec path
        if step != SQLITE_DONE && step != SQLITE_ROW {
            // Fallback for multi-statement SQL without bindings
            if binder == nil {
                if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
                    throw AlethiaError.database(String(cString: sqlite3_errmsg(db)))
                }
                return
            }
            throw AlethiaError.database(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func query(
        _ sql: String,
        binder: ((OpaquePointer) -> Void)? = nil,
        row: (OpaquePointer) -> Void
    ) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw AlethiaError.database(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        binder?(stmt!)
        while sqlite3_step(stmt) == SQLITE_ROW {
            row(stmt!)
        }
    }

}

private func bindText(_ stmt: OpaquePointer, _ idx: Int32, _ value: String) {
    sqlite3_bind_text(stmt, idx, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
}
