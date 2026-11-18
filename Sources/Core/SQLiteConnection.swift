import Foundation
import SQLite3
import Darwin

struct SQLiteStoreError: Error, CustomStringConvertible {
    let description: String
}

enum SQLValue {
    case text(String), blob(Data), integer(Int64), null
}

class SQLiteConnection {
    private(set) var database: OpaquePointer?
    let readOnly: Bool
    let url: URL

    init(url: URL, readOnly: Bool = false) throws {
        self.url = url
        self.readOnly = readOnly
        let existed = FileManager.default.fileExists(atPath: url.path)
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            if let database { sqlite3_close(database) }
            database = nil
            throw SQLiteStoreError(description: message)
        }
        do {
            sqlite3_busy_timeout(database, 5000)
            try execute("PRAGMA foreign_keys = ON")
            if !readOnly { try execute("PRAGMA synchronous = FULL") }
            if !existed { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    func backup(to destination: URL) throws {
        let fd = open(destination.path, O_CREAT | O_EXCL | O_WRONLY, mode_t(0o600))
        guard fd >= 0 else { throw SyncError.system("创建迁移备份", errno) }
        close(fd)
        do {
            let copy = try SQLiteConnection(url: destination)
            guard let handle = sqlite3_backup_init(copy.database, "main", database, "main") else {
                throw copy.failure("准备数据库备份")
            }
            let stepped = sqlite3_backup_step(handle, -1)
            let finished = sqlite3_backup_finish(handle)
            guard stepped == SQLITE_DONE && finished == SQLITE_OK else { throw copy.failure("备份数据库") }
            var valid = true
            try copy.rows("PRAGMA quick_check") { if copy.string($0, 0) != "ok" { valid = false } }
            guard valid else { throw SQLiteStoreError(description: "迁移备份完整性检查失败") }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    func failure(_ operation: String) -> SQLiteStoreError {
        SQLiteStoreError(description: "\(operation)：\(String(cString: sqlite3_errmsg(database)))")
    }

    func prepare(_ sql: String, _ values: [SQLValue] = []) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw failure("准备数据库操作")
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null: result = sqlite3_bind_null(statement, index)
            case .text(let text): result = sqlite3_bind_text(statement, index, text, -1, transient)
            case .integer(let integer): result = sqlite3_bind_int64(statement, index, integer)
            case .blob(let data):
                guard data.count <= Int32.max else {
                    sqlite3_finalize(statement)
                    throw SQLiteStoreError(description: "数据库参数过大")
                }
                result = data.isEmpty ? sqlite3_bind_zeroblob(statement, index, 0)
                    : data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), transient) }
            }
            guard result == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw failure("绑定数据库参数")
            }
        }
        return statement
    }

    func execute(_ sql: String, _ values: [SQLValue] = []) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure("提交数据库操作") }
    }

    func rows(_ sql: String, _ values: [SQLValue] = [], body: (OpaquePointer) throws -> Void) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return }
            guard result == SQLITE_ROW else { throw failure("读取数据库记录") }
            try body(statement)
        }
    }

    func scalar(_ sql: String, _ values: [SQLValue] = []) throws -> Int32 {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure("读取数据库版本") }
        return sqlite3_column_int(statement, 0)
    }

    func string(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    func blob(_ statement: OpaquePointer, _ column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    func transaction(mode: String = "IMMEDIATE", body: () throws -> Void) throws {
        try execute("BEGIN \(mode) TRANSACTION")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}
