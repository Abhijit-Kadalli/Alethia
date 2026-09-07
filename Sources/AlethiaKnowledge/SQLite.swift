import Foundation
import CSQLite
import AlethiaCore

/// SQLITE_TRANSIENT: SQLite copies the buffer so Swift memory can die after the bind.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thin SQLite helpers. All access is serialized by `KnowledgeStore`'s lock.
final class SQLiteDB {
    let handle: OpaquePointer

    init(path: String) throws {
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &opened, flags, nil)
        if rc != SQLITE_OK {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database (code \(rc))"
            if let opened {
                sqlite3_close(opened)
            }
            throw AlethiaError.database(message)
        }
        guard let opened else {
            throw AlethiaError.database("Unable to open database")
        }
        handle = opened
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    var changes: Int {
        Int(sqlite3_changes(handle))
    }

    func throwIfNeeded(_ code: Int32) throws {
        if code != SQLITE_OK {
            throw error()
        }
    }

    func error() -> AlethiaError {
        AlethiaError.database(String(cString: sqlite3_errmsg(handle)))
    }

    func execRaw(_ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errMsg)
        if let errMsg {
            let message = String(cString: errMsg)
            sqlite3_free(errMsg)
            if rc != SQLITE_OK {
                throw AlethiaError.database(message)
            }
        } else if rc != SQLITE_OK {
            throw error()
        }
    }

    func exec(_ sql: String) throws {
        try exec(sql) { _ in }
    }

    func exec(_ sql: String, bind: (OpaquePointer) throws -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw error()
        }
        defer { sqlite3_finalize(stmt) }
        try bind(stmt)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            throw error()
        }
    }

    func query<T>(_ sql: String, row: (OpaquePointer) throws -> T?) throws -> [T] {
        try query(sql, bind: { _ in }, row: row)
    }

    func query<T>(_ sql: String, bind: (OpaquePointer) throws -> Void, row: (OpaquePointer) throws -> T?) throws -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw error()
        }
        defer { sqlite3_finalize(stmt) }
        try bind(stmt)
        var results: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                if let value = try row(stmt) {
                    results.append(value)
                }
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw error()
            }
        }
        return results
    }

    func scalarInt(_ sql: String) throws -> Int {
        try scalarInt(sql) { _ in }
    }

    func scalarInt(_ sql: String, bind: (OpaquePointer) throws -> Void) throws -> Int {
        let rows: [Int] = try query(sql, bind: bind) { stmt in
            Int(sqlite3_column_int64(stmt, 0))
        }
        return rows.first ?? 0
    }

    func userVersion() throws -> Int {
        try scalarInt("PRAGMA user_version")
    }

    func bindNull(_ stmt: OpaquePointer, _ index: Int32) throws {
        try throwIfNeeded(sqlite3_bind_null(stmt, index))
    }

    func bindInt(_ stmt: OpaquePointer, _ index: Int32, _ value: Int) throws {
        try throwIfNeeded(sqlite3_bind_int64(stmt, index, sqlite3_int64(value)))
    }

    func bindInt(_ stmt: OpaquePointer, _ index: Int32, _ value: Int?) throws {
        if let value {
            try bindInt(stmt, index, value)
        } else {
            try bindNull(stmt, index)
        }
    }

    func bindDouble(_ stmt: OpaquePointer, _ index: Int32, _ value: Double) throws {
        try throwIfNeeded(sqlite3_bind_double(stmt, index, value))
    }

    func bindDouble(_ stmt: OpaquePointer, _ index: Int32, _ value: Double?) throws {
        if let value {
            try bindDouble(stmt, index, value)
        } else {
            try bindNull(stmt, index)
        }
    }

    func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) throws {
        guard let value else {
            try bindNull(stmt, index)
            return
        }
        try value.withCString { ptr in
            try throwIfNeeded(sqlite3_bind_text(stmt, index, ptr, -1, sqliteTransient))
        }
    }

    func bindUUID(_ stmt: OpaquePointer, _ index: Int32, _ value: UUID?) throws {
        try bindText(stmt, index, value.map { $0.uuidString.uppercased() })
    }

    func bindDate(_ stmt: OpaquePointer, _ index: Int32, _ value: Date?) throws {
        try bindDouble(stmt, index, value.map { $0.timeIntervalSince1970 })
    }

    func bindBool(_ stmt: OpaquePointer, _ index: Int32, _ value: Bool?) throws {
        if let value {
            try bindInt(stmt, index, value ? 1 : 0)
        } else {
            try bindNull(stmt, index)
        }
    }

    func bindBlob(_ stmt: OpaquePointer, _ index: Int32, _ value: Data?) throws {
        guard let value, !value.isEmpty else {
            try bindNull(stmt, index)
            return
        }
        try value.withUnsafeBytes { raw in
            try throwIfNeeded(sqlite3_bind_blob(stmt, index, raw.baseAddress, Int32(value.count), sqliteTransient))
        }
    }
}

enum SQLite {
    static func text(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        if sqlite3_column_type(stmt, index) == SQLITE_NULL { return nil }
        guard let ptr = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: ptr)
    }

    static func int(_ stmt: OpaquePointer, _ index: Int32) -> Int? {
        if sqlite3_column_type(stmt, index) == SQLITE_NULL { return nil }
        return Int(sqlite3_column_int64(stmt, index))
    }

    static func double(_ stmt: OpaquePointer, _ index: Int32) -> Double? {
        if sqlite3_column_type(stmt, index) == SQLITE_NULL { return nil }
        return sqlite3_column_double(stmt, index)
    }

    static func bool(_ stmt: OpaquePointer, _ index: Int32) -> Bool? {
        guard let value = int(stmt, index) else { return nil }
        return value != 0
    }

    static func date(_ stmt: OpaquePointer, _ index: Int32) -> Date? {
        guard let value = double(stmt, index) else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    static func uuid(_ stmt: OpaquePointer, _ index: Int32) -> UUID? {
        guard let text = text(stmt, index) else { return nil }
        return UUID(uuidString: text)
    }

    static func blob(_ stmt: OpaquePointer, _ index: Int32) -> Data? {
        if sqlite3_column_type(stmt, index) == SQLITE_NULL { return nil }
        let length = Int(sqlite3_column_bytes(stmt, index))
        guard length > 0, let ptr = sqlite3_column_blob(stmt, index) else {
            return Data()
        }
        return Data(bytes: ptr, count: length)
    }
}

enum Float32LECodec {
    static func encode(_ values: [Float]) -> Data? {
        guard !values.isEmpty else { return nil }
        var bytes = Data(capacity: values.count * 4)
        for value in values {
            var le = value.bitPattern.littleEndian
            withUnsafeBytes(of: &le) { bytes.append(contentsOf: $0) }
        }
        return bytes
    }

    static func decode(_ data: Data?) -> [Float] {
        guard let data, data.count >= 4 else { return [] }
        let count = data.count / 4
        var result: [Float] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            let start = i * 4
            var bits: UInt32 = 0
            _ = withUnsafeMutableBytes(of: &bits) { dest in
                data.copyBytes(to: dest, from: start..<(start + 4))
            }
            result.append(Float(bitPattern: UInt32(littleEndian: bits)))
        }
        return result
    }
}
