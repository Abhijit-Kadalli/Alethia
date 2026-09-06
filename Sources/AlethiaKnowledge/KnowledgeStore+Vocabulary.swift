import Foundation
import AlethiaCore

extension KnowledgeStore {
    public func dictionaryEntries() throws -> [DictionaryEntry] {
        try withLock {
            try db.query(
                """
                SELECT id, spoken, written, origin, created_at, use_count
                FROM dictionary
                ORDER BY spoken COLLATE NOCASE
                """,
                row: { self.dictionaryEntry(from: $0) }
            )
        }
    }

    public func upsertDictionaryEntry(_ entry: DictionaryEntry) throws {
        try withLock {
            try transaction {
                let existing: [UUID] = try db.query(
                    "SELECT id FROM dictionary WHERE lower(spoken) = lower(?)",
                    bind: { try db.bindText($0, 1, entry.spoken) },
                    row: { SQLite.uuid($0, 0) }
                )
                if let existingID = existing.first {
                    try db.exec(
                        "UPDATE dictionary SET written = ?, origin = ? WHERE id = ?",
                        bind: { stmt in
                            try db.bindText(stmt, 1, entry.written)
                            try db.bindText(stmt, 2, entry.origin.rawValue)
                            try db.bindUUID(stmt, 3, existingID)
                        }
                    )
                } else {
                    try db.exec(
                        """
                        INSERT INTO dictionary (id, spoken, written, origin, created_at, use_count)
                        VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            spoken = excluded.spoken,
                            written = excluded.written,
                            origin = excluded.origin
                        """,
                        bind: { stmt in
                            try db.bindUUID(stmt, 1, entry.id)
                            try db.bindText(stmt, 2, entry.spoken)
                            try db.bindText(stmt, 3, entry.written)
                            try db.bindText(stmt, 4, entry.origin.rawValue)
                            try db.bindDate(stmt, 5, entry.createdAt)
                            try db.bindInt(stmt, 6, entry.useCount)
                        }
                    )
                }
            }
        }
    }

    public func deleteDictionaryEntry(id: UUID) throws {
        try withLock {
            try db.exec("DELETE FROM dictionary WHERE id = ?", bind: { try db.bindUUID($0, 1, id) })
        }
    }

    public func recordDictionaryUse(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        try withLock {
            try transaction {
                for id in ids {
                    try db.exec(
                        "UPDATE dictionary SET use_count = use_count + 1 WHERE id = ?",
                        bind: { try db.bindUUID($0, 1, id) }
                    )
                }
            }
        }
    }

    public func snippets() throws -> [Snippet] {
        try withLock {
            try db.query(
                """
                SELECT id, trigger, expansion, created_at, use_count
                FROM snippets
                ORDER BY trigger COLLATE NOCASE
                """,
                row: { self.snippet(from: $0) }
            )
        }
    }

    public func upsertSnippet(_ snippet: Snippet) throws {
        try withLock {
            try transaction {
                let existing: [UUID] = try db.query(
                    "SELECT id FROM snippets WHERE lower(trigger) = lower(?)",
                    bind: { try db.bindText($0, 1, snippet.trigger) },
                    row: { SQLite.uuid($0, 0) }
                )
                if let existingID = existing.first {
                    try db.exec(
                        "UPDATE snippets SET expansion = ? WHERE id = ?",
                        bind: { stmt in
                            try db.bindText(stmt, 1, snippet.expansion)
                            try db.bindUUID(stmt, 2, existingID)
                        }
                    )
                } else {
                    try db.exec(
                        """
                        INSERT INTO snippets (id, trigger, expansion, created_at, use_count)
                        VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            trigger = excluded.trigger,
                            expansion = excluded.expansion
                        """,
                        bind: { stmt in
                            try db.bindUUID(stmt, 1, snippet.id)
                            try db.bindText(stmt, 2, snippet.trigger)
                            try db.bindText(stmt, 3, snippet.expansion)
                            try db.bindDate(stmt, 4, snippet.createdAt)
                            try db.bindInt(stmt, 5, snippet.useCount)
                        }
                    )
                }
            }
        }
    }

    public func deleteSnippet(id: UUID) throws {
        try withLock {
            try db.exec("DELETE FROM snippets WHERE id = ?", bind: { try db.bindUUID($0, 1, id) })
        }
    }

    public func recordSnippetUse(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        try withLock {
            try transaction {
                for id in ids {
                    try db.exec(
                        "UPDATE snippets SET use_count = use_count + 1 WHERE id = ?",
                        bind: { try db.bindUUID($0, 1, id) }
                    )
                }
            }
        }
    }

    func dictionaryEntry(from stmt: OpaquePointer) -> DictionaryEntry? {
        guard let id = SQLite.uuid(stmt, 0) else {
            log.warning("Skipping dictionary row with invalid id")
            return nil
        }
        guard let originRaw = SQLite.text(stmt, 3), let origin = DictionaryEntry.Origin(rawValue: originRaw) else {
            log.warning("Skipping dictionary entry \(idString(id)) with unknown origin")
            return nil
        }
        guard let createdAt = SQLite.date(stmt, 4) else {
            log.warning("Skipping dictionary entry \(idString(id)) with invalid created_at")
            return nil
        }
        return DictionaryEntry(
            id: id,
            spoken: SQLite.text(stmt, 1) ?? "",
            written: SQLite.text(stmt, 2) ?? "",
            origin: origin,
            createdAt: createdAt,
            useCount: SQLite.int(stmt, 5) ?? 0
        )
    }

    func snippet(from stmt: OpaquePointer) -> Snippet? {
        guard let id = SQLite.uuid(stmt, 0) else {
            log.warning("Skipping snippet row with invalid id")
            return nil
        }
        guard let createdAt = SQLite.date(stmt, 3) else {
            log.warning("Skipping snippet \(idString(id)) with invalid created_at")
            return nil
        }
        return Snippet(
            id: id,
            trigger: SQLite.text(stmt, 1) ?? "",
            expansion: SQLite.text(stmt, 2) ?? "",
            createdAt: createdAt,
            useCount: SQLite.int(stmt, 4) ?? 0
        )
    }
}
