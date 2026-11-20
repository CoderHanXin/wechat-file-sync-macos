import Foundation
import SQLite3

/// v3 owns content relationships; M2 tables retain only compatibility recovery records.
final class ContentRepository {
    let accounts: AccountRepository
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder
    }()
    private let decoder = JSONDecoder()

    init(url: URL, readOnly: Bool = false,
         checkpoint: ((DatabaseMigrationCheckpoint) throws -> Void)? = nil,
         recoveryCheckpoint: ((DatabaseMigrationCheckpoint) throws -> Void)? = nil) throws {
        let existed = FileManager.default.fileExists(atPath: url.path)
        accounts = try AccountRepository(url: url, readOnly: readOnly, allowContentSchema: true)
        if !readOnly, try accounts.root() == nil {
            let support = url.deletingLastPathComponent()
            let json = support.appendingPathComponent("state.json")
            if FileManager.default.fileExists(atPath: json.path) {
                let state = try decoder.decode(SyncState.self, from: Data(contentsOf: json))
                let source = support.appendingPathComponent("source.bookmark")
                let root = support.appendingPathComponent("downloads.bookmark")
                var bookmarks: DirectoryBookmarks?
                if FileManager.default.fileExists(atPath: source.path) || FileManager.default.fileExists(atPath: root.path) {
                    bookmarks = try DirectoryBookmarks(source: Data(contentsOf: source), managedRoot: Data(contentsOf: root))
                }
                try accounts.importLegacyJSON(state, bookmarks: bookmarks)
            }
        }
        if try accounts.scalar("PRAGMA user_version") == 2 {
            guard !readOnly else { throw SyncError.message("请先停止后台并迁移到 SQLite v3，只读查询不执行升级") }
            if existed {
                try accounts.backup(to: url.deletingLastPathComponent().appendingPathComponent("state.v2-backup-\(UUID().uuidString).sqlite"))
                try checkpoint?(.backupCreated)
            }
            var states: [(Account, SyncState)] = []
            for account in try accounts.accounts() { states.append((account, try accounts.loadState(account.id))) }
            try accounts.transaction {
                try schema()
                for (account, state) in states {
                    var grouped: [String: ContentEntity] = [:]
                    for (relative, transfer) in state.transfers.sorted(by: { $0.key < $1.key }) {
                        guard validRelativePath(relative), validRelativePath(transfer.destination),
                              transfer.temporary.hasPrefix(temporaryPrefix), !transfer.temporary.contains("/"), !transfer.temporary.contains("\0") else {
                            throw SQLiteStoreError(description: "旧同步记录路径无效，迁移已停止并保留 v2")
                        }
                        let key = transfer.destination + "\0" + transfer.identity.key
                        let shared = transfer.phase == .linked ? grouped[key] : nil
                        let entity = shared ?? ContentEntity(id: UUID().uuidString, accountID: account.id,
                            relative: transfer.destination, identity: transfer.identity, info: nil, digest: nil,
                            status: transfer.phase == .linked ? .unchecked : (transfer.phase == .planned ? .pending : .conflict))
                        try put(entity)
                        if transfer.phase == .linked { grouped[key] = entity }
                        let source = ContentSource(id: UUID().uuidString, accountID: account.id, relative: relative,
                            entityID: entity.id, originalName: URL(fileURLWithPath: relative).lastPathComponent,
                            receivedIdentity: transfer.identity, receivedDigest: nil,
                            status: transfer.phase == .linked ? .linked : (transfer.phase == .planned ? .pending : .conflict),
                            active: true, linkRelative: transfer.destination)
                        try put(source)
                        if transfer.phase == .linked {
                            try accounts.execute("DELETE FROM transfers WHERE account_id=? AND relative=?", [.text(account.id), .text(relative)])
                        } else if transfer.phase == .planned {
                            try put(ContentOperation(id: UUID().uuidString, accountID: account.id, entityID: entity.id,
                                sourceID: source.id, kind: .legacy, temporary: transfer.temporary,
                                expected: transfer.observedInfo, digest: nil, protect: false))
                        }
                    }
                }
                try checkpoint?(.rowsCopied)
                try validateForeignKeys()
                try accounts.execute("PRAGMA user_version=3")
                try checkpoint?(.beforeCommit)
            }
        }
        if try accounts.scalar("PRAGMA user_version") == 3 {
            guard !readOnly else { throw SyncError.message("请先停止后台并升级到 SQLite v4，只读查询不执行迁移") }
            if existed {
                try accounts.backup(to: url.deletingLastPathComponent().appendingPathComponent("state.v3-backup-\(UUID().uuidString).sqlite"))
                try recoveryCheckpoint?(.backupCreated)
            }
            try accounts.transaction {
                for account in try accounts.accounts() {
                    for var source in try sources(account.id) where !source.active && source.endReason == nil {
                        source.endReason = source.status == .missing ? .toolCleaned : .unknown
                        try put(source)
                    }
                }
                try recoveryCheckpoint?(.rowsCopied)
                try validateForeignKeys()
                try accounts.execute("PRAGMA user_version=4")
                try recoveryCheckpoint?(.beforeCommit)
            }
        }
        for table in ["entities", "sources", "content_operations", "account_settings", "content_issues"] {
            _ = try accounts.scalar("SELECT count(*) FROM \(table)")
        }
        try validateForeignKeys()
    }

    private func schema() throws {
        try accounts.execute("""
            CREATE TABLE entities(account_id TEXT NOT NULL REFERENCES accounts(id), id TEXT NOT NULL,
                relative TEXT NOT NULL, size INTEGER, sha256 TEXT, status TEXT NOT NULL, payload BLOB NOT NULL,
                PRIMARY KEY(account_id,id))
            """)
        try accounts.execute("CREATE INDEX entity_content ON entities(account_id,size,sha256)")
        try accounts.execute("""
            CREATE TABLE sources(account_id TEXT NOT NULL, id TEXT NOT NULL, relative TEXT NOT NULL,
                entity_id TEXT NOT NULL, active INTEGER NOT NULL CHECK(active IN (0,1)), payload BLOB NOT NULL,
                PRIMARY KEY(account_id,id), UNIQUE(account_id,id,entity_id),
                FOREIGN KEY(account_id,entity_id) REFERENCES entities(account_id,id))
            """)
        try accounts.execute("CREATE UNIQUE INDEX current_source ON sources(account_id,relative) WHERE active=1")
        try accounts.execute("""
            CREATE TABLE content_operations(account_id TEXT NOT NULL, id TEXT NOT NULL, entity_id TEXT NOT NULL,
                source_id TEXT, payload BLOB NOT NULL, PRIMARY KEY(account_id,id),
                FOREIGN KEY(account_id,entity_id) REFERENCES entities(account_id,id),
                FOREIGN KEY(account_id,source_id,entity_id) REFERENCES sources(account_id,id,entity_id))
            """)
        try accounts.execute("CREATE TABLE account_settings(account_id TEXT PRIMARY KEY REFERENCES accounts(id), read_only INTEGER NOT NULL CHECK(read_only IN (0,1)))")
        try accounts.execute("CREATE TABLE content_issues(account_id TEXT NOT NULL REFERENCES accounts(id), relative TEXT NOT NULL, message TEXT NOT NULL, PRIMARY KEY(account_id,relative))")
    }

    private func validateForeignKeys() throws {
        try accounts.rows("PRAGMA foreign_key_check") { _ in throw SQLiteStoreError(description: "内容关系外键损坏") }
    }

    func atomic(_ body: () throws -> Void) throws {
        guard !accounts.readOnly else { throw SyncError.persistence("只读连接不能修改内容状态") }
        do { try accounts.transaction(body: body) }
        catch { throw SyncError.persistenceFailure(error) }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try decoder.decode(type, from: data) }
        catch { throw SyncError.persistence("内容记录无法解码，原数据已保留") }
    }

    func entities(_ account: String) throws -> [ContentEntity] {
        var result: [ContentEntity] = []
        try accounts.rows("SELECT id,relative,payload FROM entities WHERE account_id=? ORDER BY rowid", [.text(account)]) {
            let entity = try decode(ContentEntity.self, accounts.blob($0, 2))
            guard entity.accountID == account, entity.id == accounts.string($0, 0), entity.relative == accounts.string($0, 1), validRelativePath(entity.relative) else {
                throw SyncError.persistence("实体身份或路径记录不一致")
            }
            result.append(entity)
        }
        return result
    }

    func sources(_ account: String) throws -> [ContentSource] {
        var result: [ContentSource] = []
        try accounts.rows("SELECT id,relative,entity_id,active,payload FROM sources WHERE account_id=? ORDER BY rowid", [.text(account)]) {
            let source = try decode(ContentSource.self, accounts.blob($0, 4))
            guard source.accountID == account, source.id == accounts.string($0, 0), source.relative == accounts.string($0, 1),
                  source.entityID == accounts.string($0, 2), source.active == (sqlite3_column_int($0, 3) == 1),
                  validRelativePath(source.relative), validRelativePath(source.linkRelative) else {
                throw SyncError.persistence("来源关系记录不一致")
            }
            result.append(source)
        }
        return result
    }

    func operations(_ account: String) throws -> [ContentOperation] {
        var result: [ContentOperation] = []
        try accounts.rows("SELECT id,entity_id,source_id,payload FROM content_operations WHERE account_id=? ORDER BY rowid", [.text(account)]) {
            let op = try decode(ContentOperation.self, accounts.blob($0, 3))
            let sourceID = sqlite3_column_type($0, 2) == SQLITE_NULL ? nil : accounts.string($0, 2)
            guard op.accountID == account, op.id == accounts.string($0, 0), op.entityID == accounts.string($0, 1), op.sourceID == sourceID,
                  (op.linkTargets ?? []).allSatisfy(validRelativePath),
                  op.temporary.hasPrefix(temporaryPrefix), !op.temporary.contains("/"), !op.temporary.contains("\0") else {
                throw SyncError.persistence("内容操作记录不一致")
            }
            result.append(op)
        }
        return result
    }

    func put(_ entity: ContentEntity) throws {
        try accounts.execute("""
            INSERT INTO entities VALUES(?,?,?,?,?,?,?) ON CONFLICT(account_id,id) DO UPDATE SET
                relative=excluded.relative,size=excluded.size,sha256=excluded.sha256,status=excluded.status,payload=excluded.payload
                WHERE entities.payload != excluded.payload
            """, [.text(entity.accountID), .text(entity.id), .text(entity.relative), entity.info.map { .integer($0.size) } ?? .null,
                entity.digest.map(SQLValue.text) ?? .null, .text(entity.status.rawValue), .blob(try encoder.encode(entity))])
    }

    func put(_ source: ContentSource) throws {
        try accounts.execute("""
            INSERT INTO sources VALUES(?,?,?,?,?,?) ON CONFLICT(account_id,id) DO UPDATE SET
                relative=excluded.relative,entity_id=excluded.entity_id,active=excluded.active,payload=excluded.payload
                WHERE sources.payload != excluded.payload
            """, [.text(source.accountID), .text(source.id), .text(source.relative), .text(source.entityID),
                .integer(source.active ? 1 : 0), .blob(try encoder.encode(source))])
    }

    func put(_ op: ContentOperation) throws {
        try accounts.execute("""
            INSERT INTO content_operations VALUES(?,?,?,?,?) ON CONFLICT(account_id,id) DO UPDATE SET payload=excluded.payload
                WHERE content_operations.payload != excluded.payload
            """, [.text(op.accountID), .text(op.id), .text(op.entityID), op.sourceID.map(SQLValue.text) ?? .null, .blob(try encoder.encode(op))])
    }

    func finish(_ op: ContentOperation) throws {
        try accounts.execute("DELETE FROM content_operations WHERE account_id=? AND id=?", [.text(op.accountID), .text(op.id)])
    }

    func readOnlyDefault(_ account: String) throws -> Bool {
        _ = try accounts.account(account)
        var result = true
        try accounts.rows("SELECT read_only FROM account_settings WHERE account_id=?", [.text(account)]) { result = sqlite3_column_int($0, 0) == 1 }
        return result
    }

    func setReadOnly(_ account: String, _ enabled: Bool) throws {
        guard try !accounts.account(account).removed else { throw SyncError.message("账号已移除") }
        try atomic {
            try accounts.execute("INSERT INTO account_settings VALUES(?,?) ON CONFLICT(account_id) DO UPDATE SET read_only=excluded.read_only",
                                 [.text(account), .integer(enabled ? 1 : 0)])
        }
    }

    func issues(_ account: String) throws -> [ScanIssue] {
        var result: [ScanIssue] = []
        try accounts.rows("SELECT relative,message FROM content_issues WHERE account_id=? ORDER BY relative", [.text(account)]) {
            result.append(ScanIssue(relative: accounts.string($0, 0), message: accounts.string($0, 1)))
        }
        return result
    }

    func recordIssue(_ account: String, relative: String, message: String?) throws {
        try atomic {
            if let message {
                try accounts.execute("""
                    INSERT INTO content_issues VALUES(?,?,?) ON CONFLICT(account_id,relative) DO UPDATE SET message=excluded.message
                        WHERE content_issues.message != excluded.message
                    """, [.text(account), .text(relative), .text(message)])
            } else {
                try accounts.execute("DELETE FROM content_issues WHERE account_id=? AND relative=?", [.text(account), .text(relative)])
            }
        }
    }
}
