import Foundation
import Darwin

struct RecoveryChoice {
    let source: ContentSource
    let comparison: String
    let skipReason: String?
}

struct RecoveryPreview {
    let original: ContentEntity
    let candidate: URL
    let info: FileInfo
    let token: String
    let digest: String
    let choices: [RecoveryChoice]
}

/// Restores links only. It never moves, deletes, or chmods the selected content.
final class LinkRecovery {
    let store: ContentRepository
    let checkpoint: ((ContentCheckpoint) throws -> Void)?
    init(store: ContentRepository, checkpoint: ((ContentCheckpoint) throws -> Void)? = nil) {
        self.store = store; self.checkpoint = checkpoint
    }

    private func context(_ accountID: String) throws -> (Account, ManagedRoot) {
        let account = try store.accounts.account(accountID)
        guard !account.removed else { throw SyncError.message("账号已移除，请先恢复并重新授权") }
        let root = try AccountManager(repository: store.accounts).validatedRoot()
        guard try readFileInfo(account.source)?.identity == account.sourceIdentity else { throw SyncError.message("微信源目录身份变化") }
        return (account, root)
    }

    private func sourceFile(_ source: ContentSource, account: Account) throws -> URL {
        let file = try checkedFile(account.sourceURL, relative: source.relative)
        guard try readFileInfo(file.deletingLastPathComponent().path)?.directory == true else {
            throw SyncError.message("微信父目录不存在，不重建目录")
        }
        return file
    }

    private func newerSource(_ source: ContentSource) throws -> Bool {
        try store.sources(source.accountID).last(where: { $0.relative == source.relative })?.id != source.id
    }

    private func target(_ relative: String, identity: Identity, root: URL, accountID: String) throws -> OpenedContent {
        let file = try OpenedContent(checkedFile(root, relative: relative), identity: identity, scope: root)
        try file.validatePermissionSupport()
        for other in try store.accounts.accounts() where other.id != accountID {
            if try store.entities(other.id).contains(where: { $0.identity == identity }) {
                throw SyncError.message("文件属于其他账号，不跨账号共享")
            }
        }
        return file
    }

    func preview(accountID: String, entityID: String, file: URL) throws -> RecoveryPreview {
        let (account, root) = try context(accountID)
        guard let original = try store.entities(accountID).first(where: { $0.id == entityID }) else { throw SyncError.message("失联实体不存在") }
        let relative = try relativePath(file, in: root.url)
        let opened = try OpenedContent(checkedFile(root.url, relative: relative), scope: root.url)
        let candidate = try target(relative, identity: opened.info.identity, root: root.url, accountID: accountID)
        let digest = try candidate.digest()
        let ops = try store.operations(accountID)
        var choices: [RecoveryChoice] = []
        for source in try store.sources(accountID) where source.entityID == entityID && !source.active {
            var reason: String?
            if source.endReason == .external || source.endReason == .reused { reason = "来源已由外部清理或路径已复用" }
            else if try newerSource(source) { reason = "原路径已进入新生命周期" }
            else if ops.contains(where: { $0.entityID == entityID || $0.sourceID == source.id || $0.recoveryTargetID == entityID }) { reason = "存在未完成操作" }
            else {
                do {
                    let path = try sourceFile(source, account: account)
                    if try readFileInfo(path.path) != nil { reason = "原路径已占用" }
                } catch { reason = String(describing: error) }
            }
            let comparison = source.receivedDigest.map { $0 == digest ? "与原接收内容一致" : "内容不同，将关联你选择的文件" } ?? "无原摘要，无法核对原内容"
            choices.append(RecoveryChoice(source: source, comparison: comparison, skipReason: reason))
        }
        try candidate.validate()
        return RecoveryPreview(original: original, candidate: candidate.url, info: candidate.info, token: candidate.token, digest: digest, choices: choices)
    }

    /// Only confirmed choices enter the durable operation journal; preview has no writes.
    func apply(_ preview: RecoveryPreview, sourceIDs: Set<String>? = nil) throws -> [ScanIssue] {
        let accountID = preview.original.accountID
        let (account, root) = try context(accountID)
        let relative = try relativePath(preview.candidate, in: root.url)
        let file = try target(relative, identity: preview.info.identity, root: root.url, accountID: accountID)
        guard file.token == preview.token, try file.digest() == preview.digest else { throw SyncError.message("候选在预览后变化，请重新预览") }
        var results: [ScanIssue] = []
        for choice in preview.choices where sourceIDs == nil || sourceIDs!.contains(choice.source.id) {
            if let reason = choice.skipReason { results.append(ScanIssue(relative: choice.source.relative, message: reason)); continue }
            do {
                guard let source = try store.sources(accountID).first(where: { $0.id == choice.source.id }), source == choice.source,
                      !source.active, try !newerSource(source) else { throw SyncError.message("来源在预览后变化") }
                let path = try sourceFile(source, account: account)
                guard try readFileInfo(path.path) == nil else { throw SyncError.message("原路径已占用") }
                let operations = try store.operations(accountID)
                guard !operations.contains(where: { $0.entityID == source.entityID || $0.sourceID == source.id }) else { throw SyncError.message("来源存在未完成操作") }
                try file.validate()
                var entity = try store.entities(accountID).first { $0.identity == file.info.identity }
                if entity == nil {
                    entity = ContentEntity(id: UUID().uuidString, accountID: accountID, relative: relative, identity: file.info.identity,
                        info: file.info, digest: preview.digest, status: .ready)
                }
                guard let entity else { continue }
                guard !operations.contains(where: { $0.entityID == entity.id || $0.recoveryTargetID == entity.id }) else { throw SyncError.message("候选存在未完成操作") }
                let op = ContentOperation(id: UUID().uuidString, accountID: accountID, entityID: source.entityID, sourceID: source.id,
                    kind: .restoreLink, temporary: temporaryPrefix + UUID().uuidString, expected: file.info,
                    digest: preview.digest, protect: false, recoveryTargetID: entity.id, linkTargets: [relative])
                try store.atomic { try store.put(entity); try store.put(op) }
                try checkpoint?(.planSaved)
                try run(op)
            } catch let error as SQLiteStoreError { throw SyncError.persistence(error.description) }
            catch let error as SyncError {
                if case .persistence = error { throw error }
                results.append(ScanIssue(relative: choice.source.relative, message: error.description))
            }
        }
        return results
    }

    func clear(_ source: ContentSource) throws {
        let (account, root) = try context(source.accountID)
        let file = try sourceFile(source, account: account)
        let old = try checkedFile(root.url, relative: source.linkRelative)
        guard let info = try readFileInfo(file.path), info.symbolicLink, linkTarget(file.path) == old.path else { throw SyncError.message("待清理链接已变化") }
        let op = ContentOperation(id: UUID().uuidString, accountID: source.accountID, entityID: source.entityID, sourceID: source.id,
            kind: .clearLink, temporary: temporaryPrefix + UUID().uuidString, expected: info, digest: nil, protect: false, linkTargets: [source.linkRelative])
        try store.atomic { try store.put(op) }
        try checkpoint?(.planSaved)
        try run(op)
    }

    func automatic(_ source: ContentSource, entity: ContentEntity) throws {
        guard !source.active, source.endReason == .toolCleaned else { return }
        let (account, root) = try context(source.accountID)
        let file = try sourceFile(source, account: account)
        if try newerSource(source) || readFileInfo(file.path) != nil {
            var ended = source; ended.endReason = .reused
            try store.atomic { try store.put(ended) }
            return
        }
        let candidate = try target(entity.relative, identity: entity.identity, root: root.url, accountID: source.accountID)
        let op = ContentOperation(id: UUID().uuidString, accountID: source.accountID, entityID: entity.id, sourceID: source.id,
            kind: .restoreLink, temporary: temporaryPrefix + UUID().uuidString, expected: candidate.info,
            digest: nil, protect: false, recoveryTargetID: entity.id, linkTargets: [entity.relative])
        try store.atomic { try store.put(op) }
        try checkpoint?(.planSaved)
        try run(op)
    }

    private func temporary(_ op: ContentOperation, source: ContentSource, account: Account) throws -> URL {
        let file = try sourceFile(source, account: account)
        let url = file.deletingLastPathComponent().appendingPathComponent(op.temporary)
        return try checkedFile(account.sourceURL, relative: relativePath(url, in: account.sourceURL))
    }

    private func cancel(_ op: ContentOperation, source: ContentSource, account: Account) throws {
        let paths = [try temporary(op, source: source, account: account), try sourceFile(source, account: account)]
        for path in paths {
            if let actual = try readFileInfo(path.path), actual.identity == op.installedIdentity {
                _ = try context(op.accountID); _ = try sourceFile(source, account: account)
                guard actual.symbolicLink else { throw SyncError.message("恢复回退对象不是本操作链接") }
                try systemCall(unlink(path.path), "取消已变化的恢复链接")
            } else if path == paths[0], try readFileInfo(path.path) != nil {
                throw SyncError.message("临时对象归属不明，保留恢复记录")
            }
        }
        try store.atomic { try store.finish(op) }
    }

    func run(_ original: ContentOperation) throws {
        guard var op = try store.operations(original.accountID).first(where: { $0.id == original.id }) else { return }
        let (account, root) = try context(op.accountID)
        guard let sourceID = op.sourceID, var source = try store.sources(op.accountID).first(where: { $0.id == sourceID }),
              source.entityID == op.entityID, let expected = op.expected, let relative = op.linkTargets?.first else { throw SyncError.persistence("恢复操作前提缺失") }
        let file = try sourceFile(source, account: account)
        let intended = try checkedFile(root.url, relative: relative)
        if op.kind == .clearLink {
            if let actual = try readFileInfo(file.path) {
                guard actual == expected, linkTarget(file.path) == intended.path else {
                    source.active = false; source.status = .detached; source.endReason = actual.regular ? .reused : .external
                    try store.atomic { try store.put(source); try store.finish(op) }
                    return
                }
                _ = try context(op.accountID); _ = try sourceFile(source, account: account)
                try systemCall(unlink(file.path), "清理失联链接")
                try checkpoint?(.linkCleared)
            }
            source.active = false; source.status = .missing; source.endReason = .toolCleaned
            try store.atomic { try store.put(source); try store.finish(op) }
            return
        }
        guard op.kind == .restoreLink, !source.active else { throw SyncError.message("恢复来源已变化") }
        if try newerSource(source) {
            op.phase = .rollback; try store.atomic { try store.put(op) }
            try cancel(op, source: source, account: account)
            source.endReason = .reused; try store.atomic { try store.put(source) }
            return
        }
        guard let targetID = op.recoveryTargetID, var entity = try store.entities(op.accountID).first(where: { $0.id == targetID }) else { throw SyncError.message("恢复来源或目标已变化") }
        if op.phase == .rollback { try cancel(op, source: source, account: account); return }
        let candidate: OpenedContent
        do {
            candidate = try target(relative, identity: expected.identity, root: root.url, accountID: op.accountID)
            guard candidate.info == expected else { throw SyncError.message("恢复文件已变化，请重新预览") }
            if let digest = op.digest, try candidate.digest() != digest { throw SyncError.message("恢复内容已变化，请重新预览") }
        } catch let error as SyncError {
            if case .persistence = error { throw error }
            op.phase = .rollback
            try store.atomic { try store.put(op) }
            try cancel(op, source: source, account: account)
            throw error
        }
        let temp = try temporary(op, source: source, account: account)
        if op.installedIdentity == nil {
            guard try readFileInfo(temp.path) == nil, try readFileInfo(file.path) == nil else { throw SyncError.message("恢复路径已占用") }
            try systemCall(symlink(intended.path, temp.path), "准备恢复链接")
            guard let identity = try readFileInfo(temp.path)?.identity else { throw SyncError.message("恢复临时链接消失") }
            op.installedIdentity = identity
            try store.atomic { try store.put(op) }
            try checkpoint?(.recoveryPrepared)
        }
        guard let installed = op.installedIdentity else { return }
        if try readFileInfo(file.path)?.identity != installed {
            guard try readFileInfo(file.path) == nil, try readFileInfo(temp.path)?.identity == installed,
                  linkTarget(temp.path) == intended.path else { throw SyncError.message("恢复路径已被其他对象占用") }
            try candidate.validate(); _ = try context(op.accountID); _ = try sourceFile(source, account: account)
            try systemCall(renamex_np(temp.path, file.path, UInt32(RENAME_EXCL)), "安装恢复链接")
            try checkpoint?(.recoveryInstalled)
        }
        try candidate.validate(); _ = try sourceFile(source, account: account)
        guard try readFileInfo(file.path)?.identity == installed, linkTarget(file.path) == intended.path else { throw SyncError.message("安装后链接被修改") }
        entity.relative = relative; entity.info = candidate.info; entity.digest = op.digest
        entity.verifiedToken = nil; entity.status = .unchecked
        source.entityID = targetID; source.active = true; source.status = .linked; source.endReason = nil; source.linkRelative = relative
        // Remove the old triple FK before rebinding, within the same transaction.
        try store.atomic { try store.finish(op); try store.put(entity); try store.put(source) }
        try checkpoint?(.completed)
    }
}
