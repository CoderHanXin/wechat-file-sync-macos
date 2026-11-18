import Foundation
import SQLite3

/// One connection and writer lock are shared by all account stores.
final class AccountRepository: SQLiteConnection {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try decoder.decode(type, from: data) }
        catch { throw SQLiteStoreError(description: "数据库记录无法解码，原数据已保留") }
    }

    init(url: URL, readOnly: Bool = false, allowContentSchema: Bool = false,
         migrationCheckpoint: ((DatabaseMigrationCheckpoint) throws -> Void)? = nil) throws {
        let existed = FileManager.default.fileExists(atPath: url.path)
        try super.init(url: url, readOnly: readOnly)
        let version = try scalar("PRAGMA user_version")
        if !existed {
            try transaction { try createSchema(); try execute("PRAGMA user_version = 2") }
        } else if version == 1 && !readOnly {
            let legacy = try SQLiteStateStore(url: url, readOnly: true)
            let state = try legacy.loadIfPresent()
            let bookmarks = try legacy.bookmarks()
            let backupURL = url.deletingLastPathComponent().appendingPathComponent("state.v1-backup-\(UUID().uuidString).sqlite")
            try backup(to: backupURL)
            try migrationCheckpoint?(.backupCreated)
            try transaction {
                try execute("ALTER TABLE baseline RENAME TO legacy_baseline")
                try execute("ALTER TABLE transfers RENAME TO legacy_transfers")
                try createSchema()
                if let state { try importState(state, bookmarks: bookmarks) }
                try migrationCheckpoint?(.rowsCopied)
                for table in ["legacy_baseline", "legacy_transfers", "configuration", "bookmarks"] {
                    try execute("DROP TABLE \(table)")
                }
                try execute("PRAGMA user_version = 2")
                try migrationCheckpoint?(.beforeCommit)
            }
        } else if version != 2 && !(allowContentSchema && (version == 3 || version == 4)) {
            throw SQLiteStoreError(description: "数据库版本 \(version) 需要迁移或不受支持，原数据库已保留；请停止后台后使用配置命令")
        }
        try rows("PRAGMA quick_check") {
            guard string($0, 0) == "ok" else { throw SQLiteStoreError(description: "数据库完整性检查失败") }
        }
        var foreignError = false
        try rows("PRAGMA foreign_key_check") { _ in foreignError = true }
        guard !foreignError else { throw SQLiteStoreError(description: "数据库账号关联损坏") }
        for table in ["managed_roots", "accounts", "baseline", "transfers", "account_operations"] {
            _ = try scalar("SELECT count(*) FROM \(table)")
        }
        _ = try root()
        _ = try accounts()
        _ = try pendingSetups()
    }

    private func createSchema() throws {
        try execute("CREATE TABLE managed_roots(id TEXT PRIMARY KEY CHECK(id = 'primary'), path TEXT NOT NULL, identity BLOB NOT NULL, bookmark BLOB)")
        try execute("""
            CREATE TABLE accounts(
                id TEXT PRIMARY KEY, root_id TEXT NOT NULL REFERENCES managed_roots(id),
                name TEXT NOT NULL, source TEXT NOT NULL, source_identity BLOB NOT NULL,
                source_key TEXT NOT NULL, source_bookmark BLOB, archive_relative TEXT NOT NULL,
                archive_identity BLOB, intake_enabled INTEGER NOT NULL CHECK(intake_enabled IN (0,1)),
                removed_at INTEGER, created_at INTEGER NOT NULL,
                UNIQUE(root_id, archive_relative))
            """)
        try execute("CREATE UNIQUE INDEX active_source_identity ON accounts(source_key) WHERE removed_at IS NULL")
        try execute("CREATE UNIQUE INDEX active_source_path ON accounts(source) WHERE removed_at IS NULL")
        try execute("CREATE TABLE baseline(account_id TEXT NOT NULL REFERENCES accounts(id), relative TEXT NOT NULL, identity BLOB NOT NULL, PRIMARY KEY(account_id, relative))")
        try execute("""
            CREATE TABLE transfers(
                account_id TEXT NOT NULL REFERENCES accounts(id), relative TEXT NOT NULL,
                destination TEXT NOT NULL, temporary TEXT NOT NULL, identity BLOB NOT NULL,
                phase TEXT NOT NULL CHECK(phase IN ('planned','linked','conflict')), observed_info BLOB,
                PRIMARY KEY(account_id, relative))
            """)
        try execute("CREATE TABLE account_operations(account_id TEXT PRIMARY KEY, root_id TEXT NOT NULL REFERENCES managed_roots(id), payload BLOB NOT NULL)")
    }

    func root() throws -> ManagedRoot? {
        var result: ManagedRoot?
        try rows("SELECT id,path,identity,bookmark FROM managed_roots") { row in
            result = ManagedRoot(id: string(row, 0), path: string(row, 1),
                identity: try decode(Identity.self, from: blob(row, 2)),
                bookmark: sqlite3_column_type(row, 3) == SQLITE_NULL ? nil : blob(row, 3))
        }
        return result
    }

    func configureRoot(_ root: ManagedRoot) throws {
        guard !readOnly else { throw SyncError.message("只读连接不允许修改配置") }
        if let current = try self.root() {
            guard current.id == root.id && current.path == root.path && current.identity == root.identity else {
                throw SyncError.message("M2 不支持更换管理根目录；请重新授权原目录")
            }
            try execute("UPDATE managed_roots SET bookmark=? WHERE id=?", [root.bookmark.map(SQLValue.blob) ?? .null, .text(root.id)])
        } else {
            try execute("INSERT INTO managed_roots VALUES(?,?,?,?)", [
                .text(root.id), .text(root.path), .blob(try encoder.encode(root.identity)), root.bookmark.map(SQLValue.blob) ?? .null])
        }
    }

    func accounts() throws -> [Account] {
        var result: [Account] = []
        try rows("SELECT id,root_id,name,source,source_identity,source_bookmark,archive_relative,archive_identity,intake_enabled,removed_at,created_at,source_key FROM accounts ORDER BY created_at,id") { row in
            let account = Account(id: string(row, 0), rootID: string(row, 1), name: string(row, 2), source: string(row, 3),
                sourceIdentity: try decode(Identity.self, from: blob(row, 4)),
                sourceBookmark: sqlite3_column_type(row, 5) == SQLITE_NULL ? nil : blob(row, 5),
                archiveRelative: string(row, 6),
                archiveIdentity: sqlite3_column_type(row, 7) == SQLITE_NULL ? nil : try decode(Identity.self, from: blob(row, 7)),
                intakeEnabled: sqlite3_column_int(row, 8) == 1,
                removedAt: sqlite3_column_type(row, 9) == SQLITE_NULL ? nil : sqlite3_column_int64(row, 9),
                createdAt: sqlite3_column_int64(row, 10))
            guard validRelativePath(account.archiveRelative), account.sourceIdentity.key == string(row, 11) else {
                throw SQLiteStoreError(description: "账号归档路径或身份键无效")
            }
            result.append(account)
        }
        return result
    }

    func account(_ id: String) throws -> Account {
        guard let account = try accounts().first(where: { $0.id == id }) else { throw SyncError.message("找不到账号 \(id)") }
        return account
    }

    func configurationAccount(_ id: String) throws -> Account {
        if let account = try accounts().first(where: { $0.id == id }) { return account }
        if let setup = try pendingSetups().first(where: { $0.account.id == id }) { return setup.account }
        throw SyncError.message("找不到账号或未完成配置 \(id)")
    }

    /// Does not replace the row: baseline/transfers keep their foreign key and ownership.
    func updateAccount(_ account: Account) throws {
        guard !readOnly else { throw SyncError.message("只读连接不允许修改配置") }
        _ = try self.account(account.id)
        try execute("""
            UPDATE accounts SET name=?,source=?,source_bookmark=?,archive_relative=?,archive_identity=?,
                intake_enabled=?,removed_at=? WHERE id=?
            """, [.text(account.name), .text(account.source), account.sourceBookmark.map(SQLValue.blob) ?? .null,
                .text(account.archiveRelative), try account.archiveIdentity.map { .blob(try encoder.encode($0)) } ?? .null,
                .integer(account.intakeEnabled ? 1 : 0), account.removedAt.map(SQLValue.integer) ?? .null, .text(account.id)])
    }

    private func insertAccount(_ account: Account) throws {
        try execute("INSERT INTO accounts VALUES(?,?,?,?,?,?,?,?,?,?,?,?)", [
            .text(account.id), .text(account.rootID), .text(account.name), .text(account.source),
            .blob(try encoder.encode(account.sourceIdentity)), .text(account.sourceIdentity.key),
            account.sourceBookmark.map(SQLValue.blob) ?? .null, .text(account.archiveRelative),
            try account.archiveIdentity.map { .blob(try encoder.encode($0)) } ?? .null,
            .integer(account.intakeEnabled ? 1 : 0), account.removedAt.map(SQLValue.integer) ?? .null, .integer(account.createdAt)])
    }

    func pendingSetups() throws -> [AccountSetup] {
        var result: [AccountSetup] = []
        try rows("SELECT payload,account_id,root_id FROM account_operations ORDER BY account_id") {
            let setup = try decode(AccountSetup.self, from: blob($0, 0))
            guard setup.account.id == string($0, 1), setup.account.rootID == string($0, 2),
                  validRelativePath(setup.account.archiveRelative), validRelativePath(setup.temporaryRelative),
                  setup.temporaryRelative.hasPrefix(temporaryPrefix), !setup.temporaryRelative.contains("/") else {
                throw SQLiteStoreError(description: "未完成的账号配置关联或路径无效")
            }
            result.append(setup)
        }
        return result
    }

    func reserve(_ setup: AccountSetup) throws {
        guard !readOnly else { throw SyncError.message("只读连接不允许修改配置") }
        try execute("INSERT INTO account_operations VALUES(?,?,?) ON CONFLICT(account_id) DO UPDATE SET payload=excluded.payload",
            [.text(setup.account.id), .text(setup.account.rootID), .blob(try encoder.encode(setup))])
    }

    func activate(_ setup: AccountSetup) throws {
        try transaction {
            guard setup.directoryIdentity != nil,
                  try pendingSetups().first(where: { $0.account.id == setup.account.id }) == setup else {
                throw SyncError.message("账号配置操作已变化或目录尚未准备，拒绝注册")
            }
            if try accounts().contains(where: { $0.id == setup.account.id }) {
                // A migrated account already has live records. Never replay its old baseline.
                var current = try account(setup.account.id)
                guard !current.removed else { throw SyncError.message("已移除账号不能自动恢复") }
                current.archiveRelative = setup.account.archiveRelative
                current.archiveIdentity = setup.directoryIdentity
                try updateAccount(current)
            } else {
                var account = setup.account
                account.archiveIdentity = setup.directoryIdentity
                try insertAccount(account)
                try writeRecords(accountID: account.id, baseline: setup.baseline, transfers: [:], previous: nil)
            }
            try execute("DELETE FROM account_operations WHERE account_id=?", [.text(setup.account.id)])
        }
    }

    func remove(_ id: String) throws {
        let registered = try accounts().contains { $0.id == id }
        var account = try configurationAccount(id)
        account.removedAt = Int64(Date().timeIntervalSince1970)
        account.sourceBookmark = nil
        try transaction {
            if registered {
                try updateAccount(account)
            } else {
                // A reserved account can be removed before directory activation too.
                // Keep its UUID/baseline so explicit restoration needs no new baseline.
                let setup = try pendingSetups().first { $0.account.id == id }
                guard let setup else { throw SyncError.message("账号配置操作不存在") }
                try insertAccount(account)
                try writeRecords(accountID: id, baseline: setup.baseline, transfers: [:], previous: nil)
            }
            if var setup = try pendingSetups().first(where: { $0.account.id == id }) {
                // Preserve operation-owned destination and identity after a collision retry.
                setup.account.removedAt = account.removedAt
                setup.account.sourceBookmark = nil
                try reserve(setup)
            }
        }
    }

    func loadState(_ id: String) throws -> SyncState {
        var state: SyncState!
        try transaction(mode: "DEFERRED") {
            let account = try self.account(id)
            guard let root = try root(), root.id == account.rootID else { throw SyncError.message("缺少管理根目录") }
            var baseline: [String: Identity] = [:]
            try rows("SELECT relative,identity FROM baseline WHERE account_id=?", [.text(id)]) {
                baseline[string($0, 0)] = try decode(Identity.self, from: blob($0, 1))
            }
            var transfers: [String: Transfer] = [:]
            try rows("SELECT relative,destination,temporary,identity,phase,observed_info FROM transfers WHERE account_id=?", [.text(id)]) { row in
                guard let phase = TransferPhase(rawValue: string(row, 4)) else { throw SyncError.message("同步阶段无效") }
                transfers[string(row, 0)] = Transfer(destination: string(row, 1), temporary: string(row, 2),
                    identity: try decode(Identity.self, from: blob(row, 3)), phase: phase,
                    observedInfo: sqlite3_column_type(row, 5) == SQLITE_NULL ? nil : try decode(FileInfo.self, from: blob(row, 5)))
            }
            state = SyncState(version: 1, source: account.source, managedRoot: root.path, sourceIdentity: account.sourceIdentity,
                              managedRootIdentity: root.identity, baseline: baseline, transfers: transfers)
        }
        return state
    }

    fileprivate func saveState(_ id: String, state: SyncState, previous: SyncState?) throws {
        guard !readOnly else { throw SyncError.message("只读连接不允许修改同步状态") }
        let account = try self.account(id)
        guard let root = try root(), !account.removed,
              state.version == 1, state.source == account.source, state.sourceIdentity == account.sourceIdentity,
              state.managedRoot == root.path, state.managedRootIdentity == root.identity else {
            throw SyncError.message("账号状态与配置不一致，拒绝保存")
        }
        try transaction { try writeRecords(accountID: id, baseline: state.baseline, transfers: state.transfers, previous: previous) }
    }

    private func writeRecords(accountID: String, baseline: [String: Identity], transfers: [String: Transfer], previous: SyncState?) throws {
        for path in (previous?.baseline ?? [:]).keys where baseline[path] == nil {
            try execute("DELETE FROM baseline WHERE account_id=? AND relative=?", [.text(accountID), .text(path)])
        }
        for (path, identity) in baseline where previous?.baseline[path] != identity {
            try execute("INSERT OR REPLACE INTO baseline VALUES(?,?,?)", [.text(accountID), .text(path), .blob(try encoder.encode(identity))])
        }
        for path in (previous?.transfers ?? [:]).keys where transfers[path] == nil {
            try execute("DELETE FROM transfers WHERE account_id=? AND relative=?", [.text(accountID), .text(path)])
        }
        for (path, record) in transfers where previous?.transfers[path] != record {
            try execute("INSERT OR REPLACE INTO transfers VALUES(?,?,?,?,?,?,?)", [.text(accountID), .text(path),
                .text(record.destination), .text(record.temporary), .blob(try encoder.encode(record.identity)),
                .text(record.phase.rawValue), try record.observedInfo.map { .blob(try encoder.encode($0)) } ?? .null])
        }
    }

    private func importState(_ state: SyncState, bookmarks: DirectoryBookmarks?) throws {
        guard state.version == 1 else { throw SyncError.message("不支持的旧状态版本") }
        let root = ManagedRoot(id: "primary", path: state.managedRoot, identity: state.managedRootIdentity, bookmark: bookmarks?.managedRoot)
        try configureRoot(root)
        let account = Account(id: UUID().uuidString, rootID: root.id, name: "原账号", source: state.source,
            sourceIdentity: state.sourceIdentity, sourceBookmark: bookmarks?.source, archiveRelative: "微信文件/原账号",
            archiveIdentity: nil, intakeEnabled: true, removedAt: nil, createdAt: Int64(Date().timeIntervalSince1970))
        try insertAccount(account)
        try writeRecords(accountID: account.id, baseline: state.baseline, transfers: state.transfers, previous: nil)
        try reserve(AccountSetup(account: account, baseline: [:], temporaryRelative: temporaryPrefix + "account-" + UUID().uuidString))
    }

    func importLegacyJSON(_ state: SyncState, bookmarks: DirectoryBookmarks?) throws {
        guard try root() == nil, try accounts().isEmpty, try pendingSetups().isEmpty else { return }
        try transaction { try importState(state, bookmarks: bookmarks) }
    }
}

final class AccountStateStore: StateStore {
    let repository: AccountRepository
    let accountID: String
    private var cached: SyncState?
    init(repository: AccountRepository, accountID: String) { self.repository = repository; self.accountID = accountID }
    func load() throws -> SyncState {
        let state = try repository.loadState(accountID)
        cached = state
        return state
    }
    func save(_ state: SyncState) throws {
        let previous = try cached ?? load()
        if previous == state { return }
        try repository.saveState(accountID, state: state, previous: previous)
        cached = state
    }
}

func openAccountRepository(appSupport: URL) throws -> AccountRepository {
    let repository = try AccountRepository(url: appSupport.appendingPathComponent("state.sqlite"))
    let legacy = appSupport.appendingPathComponent("state.json")
    if try repository.root() == nil && FileManager.default.fileExists(atPath: legacy.path) {
        let state = try JSONDecoder().decode(SyncState.self, from: Data(contentsOf: legacy))
        let source = appSupport.appendingPathComponent("source.bookmark")
        let root = appSupport.appendingPathComponent("downloads.bookmark")
        let bookmarks: DirectoryBookmarks?
        if FileManager.default.fileExists(atPath: source.path) || FileManager.default.fileExists(atPath: root.path) {
            bookmarks = try DirectoryBookmarks(source: Data(contentsOf: source), managedRoot: Data(contentsOf: root))
        } else { bookmarks = nil }
        try repository.importLegacyJSON(state, bookmarks: bookmarks)
    }
    return repository
}
