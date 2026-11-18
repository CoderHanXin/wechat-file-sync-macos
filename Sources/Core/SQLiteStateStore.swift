import Foundation
import SQLite3

struct SQLiteStoreError: Error, CustomStringConvertible {
    let description: String
}

private enum SQLValue {
    case text(String), blob(Data), integer(Int64)
}

/// Single-writer state store. Each save is a transaction; filesystem work has its own durable phases.
final class SQLiteStateStore: StateStore {
    private var database: OpaquePointer?
    private var cached: SyncState?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let readOnly: Bool

    init(url: URL, readOnly: Bool = false) throws {
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
            if !readOnly { try execute("PRAGMA synchronous = FULL") }
            let version = try scalar("PRAGMA user_version")
            if !existed {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                try transaction {
                    try execute("""
                        CREATE TABLE configuration (
                            id INTEGER PRIMARY KEY CHECK(id = 1),
                            state_version INTEGER NOT NULL,
                            source TEXT NOT NULL,
                            managed_root TEXT NOT NULL,
                            source_identity BLOB NOT NULL,
                            root_identity BLOB NOT NULL
                        )
                        """)
                    try execute("CREATE TABLE baseline (relative TEXT PRIMARY KEY, identity BLOB NOT NULL)")
                    try execute("""
                        CREATE TABLE transfers (
                            relative TEXT PRIMARY KEY, destination TEXT NOT NULL, temporary TEXT NOT NULL,
                            identity BLOB NOT NULL, phase TEXT NOT NULL CHECK(phase IN ('planned','linked','conflict')),
                            observed_info BLOB
                        )
                        """)
                    try execute("CREATE TABLE bookmarks (id INTEGER PRIMARY KEY CHECK(id = 1), source BLOB NOT NULL, managed_root BLOB NOT NULL)")
                    try execute("PRAGMA user_version = 1")
                }
            } else if version != 1 {
                throw SQLiteStoreError(description: "不支持的数据库版本 \(version)，原数据库已保留")
            }
            let check = try prepare("PRAGMA quick_check")
            defer { sqlite3_finalize(check) }
            guard sqlite3_step(check) == SQLITE_ROW, string(check, 0) == "ok" else {
                throw SQLiteStoreError(description: "数据库完整性检查失败，原数据库已保留")
            }
            // Validate all required tables even when the database currently has no configuration.
            for table in ["configuration", "baseline", "transfers", "bookmarks"] {
                _ = try scalar("SELECT count(*) FROM \(table)")
            }
        } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    func loadIfPresent() throws -> SyncState? {
        var loaded: SyncState?
        // A read transaction prevents mixed snapshots while another connection commits a save.
        try transaction(mode: "DEFERRED") {
            let statement = try prepare("SELECT state_version, source, managed_root, source_identity, root_identity FROM configuration WHERE id = 1")
            defer { sqlite3_finalize(statement) }
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                let orphaned = try scalar("SELECT (SELECT count(*) FROM baseline) + (SELECT count(*) FROM transfers) + (SELECT count(*) FROM bookmarks)")
                guard orphaned == 0 else {
                    throw SQLiteStoreError(description: "数据库缺少配置但仍有同步记录，拒绝回退或重新导入")
                }
                return
            }
            guard result == SQLITE_ROW else { throw failure("读取配置") }
            guard sqlite3_column_int(statement, 0) == 1 else {
                throw SQLiteStoreError(description: "不支持的同步状态版本")
            }
            let sourceIdentity = try decoder.decode(Identity.self, from: blob(statement, 3))
            let rootIdentity = try decoder.decode(Identity.self, from: blob(statement, 4))
            var baseline: [String: Identity] = [:]
            try rows("SELECT relative, identity FROM baseline") { row in
                baseline[string(row, 0)] = try decoder.decode(Identity.self, from: blob(row, 1))
            }
            var transfers: [String: Transfer] = [:]
            try rows("SELECT relative, destination, temporary, identity, phase, observed_info FROM transfers") { row in
                guard let phase = TransferPhase(rawValue: string(row, 4)) else {
                    throw SQLiteStoreError(description: "无效的同步阶段")
                }
                let observed = sqlite3_column_type(row, 5) == SQLITE_NULL ? nil
                    : try decoder.decode(FileInfo.self, from: blob(row, 5))
                transfers[string(row, 0)] = Transfer(destination: string(row, 1), temporary: string(row, 2),
                    identity: try decoder.decode(Identity.self, from: blob(row, 3)), phase: phase, observedInfo: observed)
            }
            loaded = SyncState(version: 1, source: string(statement, 1), managedRoot: string(statement, 2),
                               sourceIdentity: sourceIdentity, managedRootIdentity: rootIdentity,
                               baseline: baseline, transfers: transfers)
        }
        cached = loaded
        return loaded
    }

    func load() throws -> SyncState {
        guard let state = try loadIfPresent() else { throw SyncError.message("尚未配置同步目录") }
        return state
    }

    func bookmarks() throws -> DirectoryBookmarks? {
        let statement = try prepare("SELECT source, managed_root FROM bookmarks WHERE id = 1")
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw failure("读取授权") }
        return DirectoryBookmarks(source: blob(statement, 0), managedRoot: blob(statement, 1))
    }

    func save(_ state: SyncState) throws { try configure(state, bookmarks: nil) }

    /// Configuration and both bookmarks become visible together, or all changes roll back.
    func configure(_ state: SyncState, bookmarks: DirectoryBookmarks?) throws {
        guard !readOnly else { throw SQLiteStoreError(description: "诊断连接不允许修改状态") }
        guard state.version == 1 else { throw SQLiteStoreError(description: "不支持的同步状态版本") }
        let previous = try cached ?? loadIfPresent()
        if previous == state && bookmarks == nil { return }
        try transaction {
            try execute("INSERT OR REPLACE INTO configuration VALUES(1,?,?,?,?,?)", [
                .integer(Int64(state.version)), .text(state.source), .text(state.managedRoot),
                .blob(try encoder.encode(state.sourceIdentity)), .blob(try encoder.encode(state.managedRootIdentity))
            ])
            for relative in (previous?.baseline ?? [:]).keys where state.baseline[relative] == nil {
                try execute("DELETE FROM baseline WHERE relative = ?", [.text(relative)])
            }
            for (relative, identity) in state.baseline where previous?.baseline[relative] != identity {
                try execute("INSERT OR REPLACE INTO baseline VALUES(?,?)", [.text(relative), .blob(try encoder.encode(identity))])
            }
            for relative in (previous?.transfers ?? [:]).keys where state.transfers[relative] == nil {
                try execute("DELETE FROM transfers WHERE relative = ?", [.text(relative)])
            }
            for (relative, transfer) in state.transfers where previous?.transfers[relative] != transfer {
                if let observed = transfer.observedInfo {
                    try execute("INSERT OR REPLACE INTO transfers VALUES(?,?,?,?,?,?)", [
                        .text(relative), .text(transfer.destination), .text(transfer.temporary),
                        .blob(try encoder.encode(transfer.identity)), .text(transfer.phase.rawValue),
                        .blob(try encoder.encode(observed))
                    ])
                } else {
                    try execute("INSERT OR REPLACE INTO transfers VALUES(?,?,?,?,?,NULL)", [
                        .text(relative), .text(transfer.destination), .text(transfer.temporary),
                        .blob(try encoder.encode(transfer.identity)), .text(transfer.phase.rawValue)
                    ])
                }
            }
            if let bookmarks {
                try execute("INSERT OR REPLACE INTO bookmarks VALUES(1,?,?)", [.blob(bookmarks.source), .blob(bookmarks.managedRoot)])
            }
        }
        cached = state
    }

    private func failure(_ operation: String) -> SQLiteStoreError {
        SQLiteStoreError(description: "\(operation)：\(String(cString: sqlite3_errmsg(database)))")
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw failure("准备数据库操作")
        }
        return statement
    }

    private func execute(_ sql: String, _ values: [SQLValue] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let text): result = sqlite3_bind_text(statement, index, text, -1, transient)
            case .integer(let integer): result = sqlite3_bind_int64(statement, index, integer)
            case .blob(let data):
                result = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), transient) }
            }
            guard result == SQLITE_OK else { throw failure("绑定数据库参数") }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure("提交数据库操作") }
    }

    private func rows(_ sql: String, body: (OpaquePointer) throws -> Void) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return }
            guard result == SQLITE_ROW else { throw failure("读取数据库记录") }
            try body(statement)
        }
    }

    private func scalar(_ sql: String) throws -> Int32 {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure("读取数据库版本") }
        return sqlite3_column_int(statement, 0)
    }

    private func string(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    private func blob(_ statement: OpaquePointer, _ column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    private func transaction(mode: String = "IMMEDIATE", body: () throws -> Void) throws {
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
