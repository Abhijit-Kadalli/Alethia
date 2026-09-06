import Foundation
import AlethiaCore

extension KnowledgeStore {
    public func saveDictation(_ dictation: Dictation) throws {
        try withLock {
            try transaction {
                let stages = try encodeJSON(dictation.appliedStages)
                try db.exec(
                    """
                    INSERT INTO dictations (
                        id, created_at, raw_text, final_text, edited_text, target_bundle_id, target_app_name,
                        duration_ms, insertion, applied_stages_json
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        created_at = excluded.created_at,
                        raw_text = excluded.raw_text,
                        final_text = excluded.final_text,
                        edited_text = excluded.edited_text,
                        target_bundle_id = excluded.target_bundle_id,
                        target_app_name = excluded.target_app_name,
                        duration_ms = excluded.duration_ms,
                        insertion = excluded.insertion,
                        applied_stages_json = excluded.applied_stages_json
                    """,
                    bind: { stmt in
                        try db.bindUUID(stmt, 1, dictation.id)
                        try db.bindDate(stmt, 2, dictation.createdAt)
                        try db.bindText(stmt, 3, dictation.rawText)
                        try db.bindText(stmt, 4, dictation.finalText)
                        try db.bindText(stmt, 5, dictation.editedText)
                        try db.bindText(stmt, 6, dictation.targetBundleID)
                        try db.bindText(stmt, 7, dictation.targetAppName)
                        try db.bindInt(stmt, 8, dictation.durationMs)
                        try db.bindText(stmt, 9, dictation.insertion?.rawValue)
                        try db.bindText(stmt, 10, stages)
                    }
                )
                try ftsReplaceDictation(dictation)
            }
        }
    }

    public func updateDictationEdit(id: UUID, editedText: String?) throws {
        try withLock {
            try transaction {
                try db.exec(
                    "UPDATE dictations SET edited_text = ? WHERE id = ?",
                    bind: { stmt in
                        try db.bindText(stmt, 1, editedText)
                        try db.bindUUID(stmt, 2, id)
                    }
                )
                try requireChanges("Dictation", id: idString(id))
                let rows: [Dictation] = try db.query(
                    """
                    SELECT id, created_at, raw_text, final_text, edited_text, target_bundle_id, target_app_name,
                           duration_ms, insertion, applied_stages_json
                    FROM dictations WHERE id = ?
                    """,
                    bind: { try db.bindUUID($0, 1, id) },
                    row: { self.dictation(from: $0) }
                )
                if let dictation = rows.first {
                    try ftsReplaceDictation(dictation)
                }
            }
        }
    }

    public func listDictations(limit: Int = 200, offset: Int = 0) throws -> [Dictation] {
        try withLock {
            try db.query(
                """
                SELECT id, created_at, raw_text, final_text, edited_text, target_bundle_id, target_app_name,
                       duration_ms, insertion, applied_stages_json
                FROM dictations
                ORDER BY created_at DESC
                LIMIT ? OFFSET ?
                """,
                bind: { stmt in
                    try db.bindInt(stmt, 1, max(limit, 0))
                    try db.bindInt(stmt, 2, max(offset, 0))
                },
                row: { self.dictation(from: $0) }
            )
        }
    }

    public func deleteDictation(id: UUID) throws {
        try withLock {
            try transaction {
                try ftsDeleteDictation(id: id)
                try db.exec("DELETE FROM dictations WHERE id = ?", bind: { try db.bindUUID($0, 1, id) })
            }
        }
    }

    public func deleteAllDictations() throws {
        try withLock {
            try transaction {
                try ftsDeleteAllDictations()
                try db.exec("DELETE FROM dictations")
            }
        }
    }

    func dictation(from stmt: OpaquePointer) -> Dictation? {
        guard let id = SQLite.uuid(stmt, 0) else {
            log.warning("Skipping dictation row with invalid id")
            return nil
        }
        guard let createdAt = SQLite.date(stmt, 1) else {
            log.warning("Skipping dictation \(idString(id)) with invalid created_at")
            return nil
        }
        let insertion: InsertionMethod?
        if let raw = SQLite.text(stmt, 8) {
            insertion = InsertionMethod(rawValue: raw)
            if insertion == nil {
                log.warning("Skipping unknown insertion method \(raw) on dictation \(idString(id))")
            }
        } else {
            insertion = nil
        }
        return Dictation(
            id: id,
            createdAt: createdAt,
            rawText: SQLite.text(stmt, 2) ?? "",
            finalText: SQLite.text(stmt, 3) ?? "",
            editedText: SQLite.text(stmt, 4),
            targetBundleID: SQLite.text(stmt, 5),
            targetAppName: SQLite.text(stmt, 6),
            durationMs: SQLite.int(stmt, 7) ?? 0,
            insertion: insertion,
            appliedStages: decodeJSON(SQLite.text(stmt, 9), as: [String].self, default: [])
        )
    }
}
