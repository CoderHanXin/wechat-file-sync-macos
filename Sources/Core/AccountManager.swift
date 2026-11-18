import Foundation
import Darwin

/// Caller holds ProcessLock and security scopes for the selected source and shared root.
final class AccountManager {
    let repository: AccountRepository
    let checkpoint: ((AccountSetupCheckpoint) throws -> Void)?

    init(repository: AccountRepository, checkpoint: ((AccountSetupCheckpoint) throws -> Void)? = nil) {
        self.repository = repository
        self.checkpoint = checkpoint
    }

    func configureRoot(_ url: URL, bookmark: Data?) throws {
        let directory = try canonicalDirectory(url)
        guard let info = try readFileInfo(directory.path), info.directory else { throw SyncError.message("管理根目录不存在") }
        if var existing = try repository.root() {
            guard try canonicalDirectory(existing.url).path == directory.path, existing.identity == info.identity else {
                throw SyncError.message("M2 不支持更换管理根目录；请重新授权原目录")
            }
            existing.bookmark = bookmark
            try repository.configureRoot(existing)
        } else {
            try repository.configureRoot(ManagedRoot(id: "primary", path: directory.path, identity: info.identity, bookmark: bookmark))
        }
    }

    func validatedRoot() throws -> ManagedRoot {
        guard let root = try repository.root(), try readFileInfo(root.path)?.identity == root.identity else {
            throw SyncError.message("管理根目录不可用或已被替换，请重新授权原目录")
        }
        return root
    }

    func checkedName(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(":"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !name.hasPrefix(temporaryPrefix), name.utf8.count <= 160 else {
            throw SyncError.message("账号备注须为 1–160 字节的文件夹名称，不能包含斜杠、冒号或控制字符")
        }
        return name
    }

    private func availableArchive(root: ManagedRoot, name: String, excluding id: String? = nil) throws -> String {
        let used = Set(try repository.accounts().filter { $0.id != id }.map(\.archiveRelative)
            + repository.pendingSetups().filter { $0.account.id != id }.map { $0.account.archiveRelative })
        for number in 1...10000 {
            let candidate = "微信文件/" + name + (number == 1 ? "" : " (\(number))")
            let path = try checkedFile(root.url, relative: candidate)
            if !used.contains(candidate), try readFileInfo(path.path) == nil { return candidate }
        }
        throw SyncError.message("无法分配账号归档目录")
    }

    @discardableResult
    func add(source: URL, name: String, bookmark: Data?) throws -> Account {
        let root = try validatedRoot()
        let source = try canonicalDirectory(source)
        let name = try checkedName(name)
        guard let identity = try readFileInfo(source.path)?.identity else { throw SyncError.message("微信账号目录不可用") }
        let accounts = try repository.accounts()
        for other in accounts {
            if other.sourceIdentity == identity || other.source == source.path {
                throw SyncError.message(other.removed ? "该目录属于已移除账号，请使用 --restore-account \(other.id)" : "该微信账号已添加：\(other.id)")
            }
            if !other.removed && directoriesOverlap(source.path, other.source) {
                throw SyncError.message("微信账号源目录不能相互包含")
            }
        }
        if let pending = try repository.pendingSetups().first(where: { $0.account.sourceIdentity == identity || $0.account.source == source.path }) {
            throw SyncError.message("该账号配置尚未完成：\(pending.account.id)，请先用 --recover-accounts 恢复")
        }
        let state = try initialState(source: source, managedRoot: root.url)
        let account = Account(id: UUID().uuidString, rootID: root.id, name: name, source: source.path,
            sourceIdentity: state.sourceIdentity, sourceBookmark: bookmark,
            archiveRelative: try availableArchive(root: root, name: name), archiveIdentity: nil,
            intakeEnabled: true, removedAt: nil, createdAt: Int64(Date().timeIntervalSince1970))
        let setup = AccountSetup(account: account, baseline: state.baseline,
                                 temporaryRelative: temporaryPrefix + "account-" + UUID().uuidString)
        try repository.reserve(setup)
        try checkpoint?(.reserved)
        try recover(setup)
        return try repository.account(account.id)
    }

    private func directoriesOverlap(_ first: String, _ second: String) -> Bool {
        let a = URL(fileURLWithPath: first).pathComponents
        let b = URL(fileURLWithPath: second).pathComponents
        return a.starts(with: b) || b.starts(with: a)
    }

    /// Only identity-matched directories created by this operation may be adopted.
    func recover(_ pending: AccountSetup) throws {
        let root = try validatedRoot()
        // The argument identifies the operation, but its snapshot may predate a retry,
        // removal or reauthorization. Only the durable current plan may be replayed.
        let account = try repository.accounts().first(where: { $0.id == pending.account.id })
        if account?.removed == true { return }
        guard var setup = try repository.pendingSetups().first(where: { $0.account.id == pending.account.id }) else {
            if account != nil { return } // Already committed: replay is a no-op.
            throw SyncError.message("账号配置操作不存在，原目录未修改")
        }
        guard setup.account.rootID == root.id,
              try readFileInfo(setup.account.source)?.identity == setup.account.sourceIdentity else {
            throw SyncError.message("未完成配置的微信账号目录不可用")
        }
        let parent = try checkedFile(root.url, relative: "微信文件")
        if let existing = try readFileInfo(parent.path) {
            guard existing.directory else { throw SyncError.message("微信文件归档父目录被其他对象占用") }
        } else {
            try systemCall(mkdir(parent.path, 0o700), "创建微信文件归档目录")
        }
        var destination = try checkedFile(root.url, relative: setup.account.archiveRelative)
        var temporary = try checkedFile(root.url, relative: setup.temporaryRelative)
        if let identity = setup.directoryIdentity {
            if try readFileInfo(destination.path)?.identity == identity {
                try repository.activate(setup)
                try checkpoint?(.activated)
                return
            }
            guard try readFileInfo(temporary.path)?.identity == identity else {
                throw SyncError.message("账号配置目录已移动或被替换，保留现场等待检查")
            }
        } else {
            // A crash between mkdir and recording identity may leave an unowned directory.
            // Keep it untouched and use another exclusive temporary name.
            if try readFileInfo(temporary.path) != nil {
                setup.temporaryRelative = temporaryPrefix + "account-" + UUID().uuidString
                try repository.reserve(setup)
                temporary = try checkedFile(root.url, relative: setup.temporaryRelative)
            }
            try systemCall(mkdir(temporary.path, 0o700), "创建账号临时归档目录")
            guard let info = try readFileInfo(temporary.path), info.directory else { throw SyncError.message("账号临时目录不可用") }
            setup.directoryIdentity = info.identity
            try repository.reserve(setup)
            try checkpoint?(.directoryCreated)
        }
        while renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) != 0 {
            guard errno == EEXIST || errno == ENOTEMPTY else { throw SyncError.system("启用账号归档目录", errno) }
            setup.account.archiveRelative = try availableArchive(root: root, name: checkedName(setup.account.name), excluding: setup.account.id)
            try repository.reserve(setup)
            destination = try checkedFile(root.url, relative: setup.account.archiveRelative)
        }
        try checkpoint?(.directoryRenamed)
        guard try readFileInfo(destination.path)?.identity == setup.directoryIdentity else { throw SyncError.message("账号归档目录在创建期间被替换") }
        try repository.activate(setup)
        try checkpoint?(.activated)
    }

    func setPaused(_ id: String, paused: Bool) throws {
        var account = try active(id)
        account.intakeEnabled = !paused
        try repository.updateAccount(account)
    }

    func rename(_ id: String, name: String) throws {
        var account = try repository.account(id)
        account.name = try checkedName(name)
        try repository.updateAccount(account)
    }

    private func active(_ id: String) throws -> Account {
        let account = try repository.account(id)
        guard !account.removed else { throw SyncError.message("账号已移除，请先显式恢复") }
        return account
    }

    func reauthorize(_ id: String, source: URL, bookmark: Data, restoring: Bool = false) throws {
        let registered = try repository.accounts().contains { $0.id == id }
        var account = try repository.configurationAccount(id)
        let canonical = try canonicalDirectory(source)
        guard try canonical.path == canonicalDirectory(account.sourceURL).path,
              try readFileInfo(canonical.path)?.identity == account.sourceIdentity else {
            throw SyncError.message("必须重新授权原微信账号目录；目录已被替换时不能继承原基线")
        }
        guard restoring || !account.removed else { throw SyncError.message("已移除账号必须使用 --restore-account 显式恢复") }
        if restoring && (!registered || !account.removed) { throw SyncError.message("该账号尚未移除，无需恢复；更新授权请使用 --reauthorize-account") }
        if restoring { account.removedAt = nil }
        account.sourceBookmark = bookmark
        try repository.transaction {
            if registered { try repository.updateAccount(account) }
            if var setup = try repository.pendingSetups().first(where: { $0.account.id == id }) {
                setup.account.sourceBookmark = bookmark
                setup.account.removedAt = account.removedAt
                try repository.reserve(setup)
            }
        }
    }
}
