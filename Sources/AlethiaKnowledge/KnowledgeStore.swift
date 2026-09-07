import Foundation
import AlethiaCore

/// SQLite-backed knowledge base: meetings, transcripts, notes, dictations, speakers,
/// dictionary, snippets, custom templates, and FTS5 search.
public final class KnowledgeStore: @unchecked Sendable {
    public struct Stats: Sendable, Equatable {
        public var meetingCount: Int
        public var dictationCount: Int
        public var dictatedWords: Int
        public var totalMeetingMs: Int
        public var speakerCount: Int

        public init(meetingCount: Int, dictationCount: Int, dictatedWords: Int, totalMeetingMs: Int, speakerCount: Int) {
            self.meetingCount = meetingCount
            self.dictationCount = dictationCount
            self.dictatedWords = dictatedWords
            self.totalMeetingMs = totalMeetingMs
            self.speakerCount = speakerCount
        }
    }

    public let databaseURL: URL

    let paths: AppPaths?
    let db: SQLiteDB
    let lock = NSLock()
    let log = Log("Knowledge")
    var changeCoalescer: ChangeCoalescer?

    /// Ordered migrations. Adding v2 later is appending `(2, sql)` here.
    static let migrations: [(Int, String)] = [
        (1, schemaV1),
    ]

    static let schemaV1 = """
        CREATE TABLE meetings (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            started_at REAL NOT NULL,
            ended_at REAL,
            source TEXT NOT NULL,
            status TEXT NOT NULL,
            processing_error TEXT,
            audio_path TEXT,
            duration_ms INTEGER NOT NULL DEFAULT 0,
            language TEXT,
            user_notes TEXT NOT NULL DEFAULT '',
            enhanced_notes TEXT,
            enhanced_template_id TEXT,
            enhanced_at REAL,
            enhanced_by TEXT,
            summary TEXT,
            calendar_event_id TEXT,
            attendees_json TEXT NOT NULL DEFAULT '[]',
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE INDEX meetings_started_at ON meetings(started_at DESC);
        CREATE INDEX meetings_status ON meetings(status);

        CREATE TABLE speakers (
            id TEXT PRIMARY KEY,
            display_name TEXT NOT NULL,
            embedding BLOB,
            sample_count INTEGER NOT NULL DEFAULT 0,
            is_self INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );

        CREATE TABLE utterances (
            id TEXT PRIMARY KEY,
            meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            speaker_id TEXT REFERENCES speakers(id) ON DELETE SET NULL,
            speaker_label TEXT NOT NULL,
            start_ms INTEGER NOT NULL,
            end_ms INTEGER NOT NULL,
            text TEXT NOT NULL,
            words_json TEXT,
            is_local_speaker INTEGER,
            match_confidence REAL,
            suggested_speaker_name TEXT
        );
        CREATE INDEX utterances_meeting_start ON utterances(meeting_id, start_ms);

        CREATE TABLE dictations (
            id TEXT PRIMARY KEY,
            created_at REAL NOT NULL,
            raw_text TEXT NOT NULL,
            final_text TEXT NOT NULL,
            edited_text TEXT,
            target_bundle_id TEXT,
            target_app_name TEXT,
            duration_ms INTEGER NOT NULL DEFAULT 0,
            insertion TEXT,
            applied_stages_json TEXT NOT NULL DEFAULT '[]'
        );
        CREATE INDEX dictations_created_at ON dictations(created_at DESC);

        CREATE TABLE dictionary (
            id TEXT PRIMARY KEY,
            spoken TEXT NOT NULL,
            written TEXT NOT NULL,
            origin TEXT NOT NULL,
            created_at REAL NOT NULL,
            use_count INTEGER NOT NULL DEFAULT 0
        );
        CREATE UNIQUE INDEX dictionary_spoken_unique ON dictionary(lower(spoken));

        CREATE TABLE snippets (
            id TEXT PRIMARY KEY,
            trigger TEXT NOT NULL,
            expansion TEXT NOT NULL,
            created_at REAL NOT NULL,
            use_count INTEGER NOT NULL DEFAULT 0
        );
        CREATE UNIQUE INDEX snippets_trigger_unique ON snippets(lower(trigger));

        CREATE TABLE templates (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            description TEXT NOT NULL,
            sections_json TEXT NOT NULL,
            instructions TEXT NOT NULL
        );

        CREATE VIRTUAL TABLE search_index USING fts5(
            doc_id UNINDEXED,
            kind UNINDEXED,
            meeting_id UNINDEXED,
            created_at UNINDEXED,
            start_ms UNINDEXED,
            title,
            body,
            tokenize='unicode61 remove_diacritics 2'
        );
        """

    public init(databaseURL: URL, paths: AppPaths?) throws {
        self.databaseURL = databaseURL
        self.paths = paths
        let memory = Self.isMemoryURL(databaseURL)
        let sqlitePath = memory ? ":memory:" : databaseURL.path
        if !memory {
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        db = try SQLiteDB(path: sqlitePath)
        try withLock {
            try db.execRaw("PRAGMA foreign_keys = ON")
            try db.execRaw("PRAGMA journal_mode = WAL")
            try db.execRaw("PRAGMA synchronous = NORMAL")
            try db.execRaw("PRAGMA busy_timeout = 5000")
            try migrate()
        }
        if let paths {
            do {
                try importLegacyKnowledgeStoreIfNeeded(from: paths)
            } catch {
                log.warning("legacy import skipped: \(error.localizedDescription)")
            }
        }
    }

    public convenience init(paths: AppPaths) throws {
        try paths.ensureDirectories()
        try self.init(databaseURL: paths.database, paths: paths)
    }

    public static func inMemory() throws -> KnowledgeStore {
        try KnowledgeStore(databaseURL: URL(fileURLWithPath: ":memory:"), paths: nil)
    }

    public var schemaVersion: Int {
        do {
            return try withLock { try db.userVersion() }
        } catch {
            return 0
        }
    }

    public func vacuum() throws {
        try withLock {
            try db.execRaw("VACUUM")
        }
    }

    public func stats() throws -> Stats {
        try withLock {
            let meetingCount = try db.scalarInt("SELECT COUNT(*) FROM meetings")
            let dictationCount = try db.scalarInt("SELECT COUNT(*) FROM dictations")
            let totalMeetingMs = try db.scalarInt("SELECT COALESCE(SUM(duration_ms), 0) FROM meetings")
            let speakerCount = try db.scalarInt("SELECT COUNT(*) FROM speakers")
            let texts: [(String?, String)] = try db.query("SELECT edited_text, final_text FROM dictations") { stmt in
                (SQLite.text(stmt, 0), SQLite.text(stmt, 1) ?? "")
            }
            let dictatedWords = texts.reduce(0) { sum, pair in
                let display = pair.0 ?? pair.1
                return sum + display.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
            }
            return Stats(
                meetingCount: meetingCount,
                dictationCount: dictationCount,
                dictatedWords: dictatedWords,
                totalMeetingMs: totalMeetingMs,
                speakerCount: speakerCount
            )
        }
    }

    func migrate() throws {
        try transaction {
            let current = try db.userVersion()
            for (version, sql) in Self.migrations where version > current {
                try db.execRaw(sql)
                try db.execRaw("PRAGMA user_version = \(version)")
            }
        }
    }

    static func isMemoryURL(_ url: URL) -> Bool {
        url.lastPathComponent == ":memory:" || url.path == ":memory:"
    }

    func withLock<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        let result: T
        do {
            result = try body()
        } catch {
            lock.unlock()
            changeCoalescer?.flush()
            throw error
        }
        lock.unlock()
        // Post after releasing the store lock so observers can read without deadlocking.
        changeCoalescer?.flush()
        return result
    }

    func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        let result = body()
        lock.unlock()
        changeCoalescer?.flush()
        return result
    }

    /// Multi-row writes use BEGIN IMMEDIATE. Caller must already hold `lock`.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try db.execRaw("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try db.execRaw("COMMIT")
            return value
        } catch {
            try? db.execRaw("ROLLBACK")
            throw error
        }
    }

    func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        do {
            let data = try JSONEncoder().encode(value)
            if let string = String(data: data, encoding: .utf8) {
                return string
            }
            throw AlethiaError.database("JSON encoding produced non-UTF8 output")
        } catch let error as AlethiaError {
            throw error
        } catch {
            throw AlethiaError.database("JSON encoding failed: \(error.localizedDescription)")
        }
    }

    func decodeJSON<T: Decodable>(_ string: String?, as type: T.Type, default defaultValue: T) -> T {
        guard let string, let data = string.data(using: .utf8) else { return defaultValue }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            log.warning("Failed to decode JSON: \(error.localizedDescription)")
            return defaultValue
        }
    }

    func idString(_ id: UUID) -> String {
        id.uuidString.uppercased()
    }

    func requireChanges(_ entity: String, id: String) throws {
        if db.changes == 0 {
            throw AlethiaError.notFound("\(entity) \(id)")
        }
    }
}
