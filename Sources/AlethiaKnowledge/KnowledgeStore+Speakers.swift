import Foundation
import AlethiaCore

extension KnowledgeStore {
    public func upsertSpeaker(_ speaker: Speaker) throws {
        try withLock {
            try db.exec(
                """
                INSERT INTO speakers (id, display_name, embedding, sample_count, is_self, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    display_name = excluded.display_name,
                    embedding = excluded.embedding,
                    sample_count = excluded.sample_count,
                    is_self = excluded.is_self,
                    updated_at = excluded.updated_at
                """,
                bind: { stmt in
                    try db.bindUUID(stmt, 1, speaker.id)
                    try db.bindText(stmt, 2, speaker.displayName)
                    try db.bindBlob(stmt, 3, Float32LECodec.encode(speaker.embedding))
                    try db.bindInt(stmt, 4, speaker.sampleCount)
                    try db.bindBool(stmt, 5, speaker.isSelf)
                    try db.bindDate(stmt, 6, speaker.createdAt)
                    try db.bindDate(stmt, 7, speaker.updatedAt)
                }
            )
        }
    }

    public func speaker(id: UUID) throws -> Speaker? {
        try withLock {
            let rows: [Speaker] = try db.query(
                """
                SELECT id, display_name, embedding, sample_count, is_self, created_at, updated_at
                FROM speakers WHERE id = ?
                """,
                bind: { try db.bindUUID($0, 1, id) },
                row: { self.speaker(from: $0) }
            )
            return rows.first
        }
    }

    public func speakers() throws -> [Speaker] {
        try withLock {
            try db.query(
                """
                SELECT id, display_name, embedding, sample_count, is_self, created_at, updated_at
                FROM speakers
                ORDER BY display_name COLLATE NOCASE, id
                """,
                row: { self.speaker(from: $0) }
            )
        }
    }

    public func deleteSpeaker(id: UUID) throws {
        try withLock {
            try db.exec("DELETE FROM speakers WHERE id = ?", bind: { try db.bindUUID($0, 1, id) })
        }
    }

    public func mergeSpeakers(keep: UUID, remove: UUID) throws {
        try withLock {
            try transaction {
                if keep == remove {
                    throw AlethiaError.invalidInput("Cannot merge a speaker with itself.")
                }
                let keepRows: [Speaker] = try db.query(
                    """
                    SELECT id, display_name, embedding, sample_count, is_self, created_at, updated_at
                    FROM speakers WHERE id = ?
                    """,
                    bind: { try db.bindUUID($0, 1, keep) },
                    row: { self.speaker(from: $0) }
                )
                let removeRows: [Speaker] = try db.query(
                    """
                    SELECT id, display_name, embedding, sample_count, is_self, created_at, updated_at
                    FROM speakers WHERE id = ?
                    """,
                    bind: { try db.bindUUID($0, 1, remove) },
                    row: { self.speaker(from: $0) }
                )
                guard let keepSpeaker = keepRows.first else {
                    throw AlethiaError.notFound("Speaker \(idString(keep))")
                }
                guard let removeSpeaker = removeRows.first else {
                    throw AlethiaError.notFound("Speaker \(idString(remove))")
                }

                try db.exec(
                    "UPDATE utterances SET speaker_id = ? WHERE speaker_id = ?",
                    bind: { stmt in
                        try db.bindUUID(stmt, 1, keep)
                        try db.bindUUID(stmt, 2, remove)
                    }
                )

                let mergedEmbedding = Self.weightedAverage(
                    keepSpeaker.embedding,
                    count: keepSpeaker.sampleCount,
                    with: removeSpeaker.embedding,
                    sampleCount: removeSpeaker.sampleCount
                )
                let mergedCount = keepSpeaker.sampleCount + removeSpeaker.sampleCount

                try db.exec(
                    "UPDATE speakers SET embedding = ?, sample_count = ?, updated_at = ? WHERE id = ?",
                    bind: { stmt in
                        try db.bindBlob(stmt, 1, Float32LECodec.encode(mergedEmbedding))
                        try db.bindInt(stmt, 2, mergedCount)
                        try db.bindDate(stmt, 3, Date())
                        try db.bindUUID(stmt, 4, keep)
                    }
                )
                try db.exec("DELETE FROM speakers WHERE id = ?", bind: { try db.bindUUID($0, 1, remove) })
            }
        }
    }

    func speaker(from stmt: OpaquePointer) -> Speaker? {
        guard let id = SQLite.uuid(stmt, 0) else {
            log.warning("Skipping speaker row with invalid id")
            return nil
        }
        guard let createdAt = SQLite.date(stmt, 5), let updatedAt = SQLite.date(stmt, 6) else {
            log.warning("Skipping speaker \(idString(id)) with invalid timestamps")
            return nil
        }
        return Speaker(
            id: id,
            displayName: SQLite.text(stmt, 1) ?? "",
            embedding: Float32LECodec.decode(SQLite.blob(stmt, 2)),
            sampleCount: SQLite.int(stmt, 3) ?? 0,
            isSelf: SQLite.bool(stmt, 4) ?? false,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    static func weightedAverage(_ keep: [Float], count keepCount: Int, with remove: [Float], sampleCount removeCount: Int) -> [Float] {
        if keep.isEmpty { return remove }
        if remove.isEmpty { return keep }
        guard keep.count == remove.count else { return keep }
        let weightKeep = Float(max(keepCount, 0))
        let weightRemove = Float(max(removeCount, 0))
        let total = weightKeep + weightRemove
        if total == 0 { return keep }
        return zip(keep, remove).map { ($0 * weightKeep + $1 * weightRemove) / total }
    }
}
