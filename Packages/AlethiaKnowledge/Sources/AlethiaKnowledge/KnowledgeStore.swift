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
            text TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS dictations (
            id TEXT PRIMARY KEY,
            created_at REAL NOT NULL,
            text TEXT NOT NULL,
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
            INSERT INTO sessions(id, title, started_at, ended_at, source)
            VALUES(?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
              title=excluded.title,
              ended_at=excluded.ended_at,
              source=excluded.source;
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
            }
        )

        for u in session.utterances {
            try exec(
                """
                INSERT INTO utterances(id, session_id, speaker_id, speaker_label, start_ms, end_ms, text)
                VALUES(?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET text=excluded.text, speaker_label=excluded.speaker_label, speaker_id=excluded.speaker_id;
                """,
                binder: { stmt in
                    bindText(stmt, 1, u.id.uuidString)
                    bindText(stmt, 2, session.id.uuidString)
                    if let sid = u.speakerID { bindText(stmt, 3, sid.uuidString) } else { sqlite3_bind_null(stmt, 3) }
                    bindText(stmt, 4, u.speakerLabel)
                    sqlite3_bind_int(stmt, 5, Int32(u.startMs))
                    sqlite3_bind_int(stmt, 6, Int32(u.endMs))
                    bindText(stmt, 7, u.text)
                }
            )
            try indexFTS(
                docID: u.id,
                kind: "utterance",
                title: u.speakerLabel,
                body: u.text,
                createdAt: session.startedAt
            )
        }
    }

    public func saveDictation(_ event: DictationEvent) throws {
        lock.lock(); defer { lock.unlock() }
        try exec(
            """
            INSERT INTO dictations(id, created_at, text, target_bundle_id, session_id)
            VALUES(?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET text=excluded.text;
            """,
            binder: { stmt in
                bindText(stmt, 1, event.id.uuidString)
                sqlite3_bind_double(stmt, 2, event.createdAt.timeIntervalSince1970)
                bindText(stmt, 3, event.text)
                if let bid = event.targetBundleID { bindText(stmt, 4, bid) } else { sqlite3_bind_null(stmt, 4) }
                if let sid = event.sessionID { bindText(stmt, 5, sid.uuidString) } else { sqlite3_bind_null(stmt, 5) }
            }
        )
        try indexFTS(
            docID: event.id,
            kind: "dictation",
            title: "Dictation",
            body: event.text,
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
            SELECT id, title, started_at, ended_at, source
            FROM sessions ORDER BY started_at DESC LIMIT ?;
            """,
            binder: { sqlite3_bind_int($0, 1, Int32(limit)) }
        ) { stmt in
            let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0)))!
            let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            let started = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
            let ended: Date? = sqlite3_column_type(stmt, 3) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            let source = CaptureSource(rawValue: String(cString: sqlite3_column_text(stmt, 4))) ?? .ambient
            sessions.append(ConversationSession(id: id, title: title, startedAt: started, endedAt: ended, source: source))
        }
        return sessions
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
