import Foundation
import AlethiaCore

extension KnowledgeStore {
    public func customTemplates() throws -> [NotesTemplate] {
        try withLock {
            try db.query(
                """
                SELECT id, name, description, sections_json, instructions
                FROM templates
                ORDER BY name COLLATE NOCASE
                """,
                row: { self.template(from: $0) }
            )
        }
    }

    public func upsertTemplate(_ template: NotesTemplate) throws {
        if template.isBuiltIn {
            throw AlethiaError.invalidInput("Built-in templates cannot be saved.")
        }
        let sections = try encodeJSON(template.sections)
        try withLock {
            try db.exec(
                """
                INSERT INTO templates (id, name, description, sections_json, instructions)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    description = excluded.description,
                    sections_json = excluded.sections_json,
                    instructions = excluded.instructions
                """,
                bind: { stmt in
                    try db.bindText(stmt, 1, template.id)
                    try db.bindText(stmt, 2, template.name)
                    try db.bindText(stmt, 3, template.description)
                    try db.bindText(stmt, 4, sections)
                    try db.bindText(stmt, 5, template.instructions)
                }
            )
        }
    }

    public func deleteTemplate(id: String) throws {
        try withLock {
            try db.exec("DELETE FROM templates WHERE id = ?", bind: { try db.bindText($0, 1, id) })
        }
    }

    public func allTemplates() throws -> [NotesTemplate] {
        try NotesTemplate.builtIn + customTemplates()
    }

    func template(from stmt: OpaquePointer) -> NotesTemplate? {
        guard let id = SQLite.text(stmt, 0) else {
            log.warning("Skipping template row with missing id")
            return nil
        }
        return NotesTemplate(
            id: id,
            name: SQLite.text(stmt, 1) ?? "",
            description: SQLite.text(stmt, 2) ?? "",
            sections: decodeJSON(SQLite.text(stmt, 3), as: [String].self, default: []),
            instructions: SQLite.text(stmt, 4) ?? "",
            isBuiltIn: false
        )
    }
}
