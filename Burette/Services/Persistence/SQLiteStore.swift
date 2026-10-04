import Foundation
import SQLite3

enum SQLiteStoreError: Error, LocalizedError {
    case unavailable
    case prepare
    case step

    var errorDescription: String? {
        switch self {
        case .unavailable: return "SQLite 数据库不可用。"
        case .prepare: return "SQLite 语句准备失败。"
        case .step: return "SQLite 写入失败。"
        }
    }
}

/// 把 SQLite 的 destructor 标记为 TRANSIENT：SQLite 会自行拷贝绑定的数据。
private let buretteSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 用 SQLite 保存持久化对象（键 → JSON blob）。
///
/// 与 JSONStore 的「一个对象一个文件」相比，SQLite 写入是原子的、
/// 不会出现半截文件，键多了也不会产生大量小文件。
final class SQLiteStore: @unchecked Sendable, PersistenceStore {
    private let lock = NSLock()
    private var db: OpaquePointer?

    /// 打开失败（或建表失败）返回 nil，调用方可回退到 JSONStore。
    init?(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("burette.sqlite")
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        db = handle
        guard execute("CREATE TABLE IF NOT EXISTS kv (name TEXT PRIMARY KEY NOT NULL, data BLOB NOT NULL, updated_at REAL NOT NULL);") else {
            sqlite3_close(handle)
            db = nil
            return nil
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - PersistenceStore

    func load<T: Decodable>(_ type: T.Type, from name: String) throws -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw SQLiteStoreError.unavailable }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT data FROM kv WHERE name = ?1;", -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepare
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, name, -1, buretteSQLiteTransient)
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else {
            return nil
        }
        let length = Int(sqlite3_column_bytes(statement, 0))
        let data = Data(bytes: bytes, count: length)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    func save<T: Encodable>(_ value: T, to name: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try saveRaw(encoder.encode(value), name: name)
    }

    /// 该键是否已有数据（用于首次迁移时判断）。
    func contains(_ name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return false }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM kv WHERE name = ?1 LIMIT 1;", -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, name, -1, buretteSQLiteTransient)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// 直接写入已经序列化好的 JSON 数据（迁移用）。
    func saveRaw(_ data: Data, name: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw SQLiteStoreError.unavailable }
        var statement: OpaquePointer?
        let sql = "INSERT INTO kv (name, data, updated_at) VALUES (?1, ?2, ?3) ON CONFLICT(name) DO UPDATE SET data = excluded.data, updated_at = excluded.updated_at;"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepare
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, name, -1, buretteSQLiteTransient)
        data.withUnsafeBytes { buffer in
            _ = sqlite3_bind_blob(statement, 2, buffer.baseAddress, Int32(buffer.count), buretteSQLiteTransient)
        }
        sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteStoreError.step
        }
    }

    @discardableResult
    private func execute(_ sql: String) -> Bool {
        guard let db else { return false }
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            if let errorMessage { sqlite3_free(errorMessage) }
            return false
        }
        return true
    }
}
