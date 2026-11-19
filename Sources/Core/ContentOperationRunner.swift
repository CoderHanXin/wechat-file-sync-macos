import Foundation
import Darwin

final class ContentOperationRunner {
    let store: ContentRepository
    let checkpoint: ((ContentCheckpoint) throws -> Void)?
    init(store: ContentRepository, checkpoint: ((ContentCheckpoint) throws -> Void)? = nil) {
        self.store = store; self.checkpoint = checkpoint
    }

    private func validateRoots(_ accountID: String, root: URL, sourceRoot: URL) throws {
        let account = try store.accounts.account(accountID)
        guard !account.removed, let configuredRoot = try store.accounts.root(),
              try readFileInfo(root.path)?.identity == configuredRoot.identity,
              try readFileInfo(sourceRoot.path)?.identity == account.sourceIdentity else {
            throw SyncError.message("去重操作的授权目录不可用或已变化")
        }
    }

    private func paths(_ op: ContentOperation, source: ContentSource, root: URL, sourceRoot: URL) throws -> (URL, URL) {
        try validateRoots(op.accountID, root: root, sourceRoot: sourceRoot)
        let file = try checkedFile(sourceRoot, relative: source.relative)
        let temp = file.deletingLastPathComponent().appendingPathComponent(op.temporary)
        _ = try checkedFile(sourceRoot, relative: relativePath(temp, in: sourceRoot))
        return (file, temp)
    }

    private func ownedTargets(_ op: ContentOperation, source: ContentSource, root: URL) -> Set<String> {
        // Historical destinations are compared as strings, never followed during rollback.
        Set(([source.linkRelative] + (op.linkTargets ?? [])).map { root.appendingPathComponent($0).path })
    }

    private func recordTarget(_ original: ContentOperation, source: ContentSource, relative: String) throws -> ContentOperation {
        var op = original
        let targets = Set([source.linkRelative] + (op.linkTargets ?? []) + [relative]).sorted()
        if op.linkTargets != targets {
            op.linkTargets = targets
            try store.atomic { try store.put(op) }
        }
        return op
    }

    func attach(_ original: ContentOperation, root: URL, sourceRoot: URL) throws {
        guard var op = try store.operations(original.accountID).first(where: { $0.id == original.id }), op.phase != .conflict else { return }
        guard let sourceID = op.sourceID,
              var source = try store.sources(op.accountID).first(where: { $0.id == sourceID }),
              let entity = try store.entities(op.accountID).first(where: { $0.id == op.entityID }),
              let expected = op.expected else { throw SyncError.message("接入操作缺少有效关系") }
        let (file, temp) = try paths(op, source: source, root: root, sourceRoot: sourceRoot)

        if op.phase == .rollback {
            try rollback(op, source: source, root: root, sourceRoot: sourceRoot)
            return
        }
        let target = try checkedFile(root, relative: entity.relative)
        if try readFileInfo(temp.path) == nil, op.phase == .cleanup {
            if try readFileInfo(file.path) == nil || readFileInfo(file.path)?.regular == true {
                source.status = .detached; source.active = false
            } else if let link = linkTarget(file.path), ownedTargets(op, source: source, root: root).contains(link) {
                source.linkRelative = try relativePath(URL(fileURLWithPath: link), in: root)
                source.status = .linked
            } else {
                source.status = .conflict
            }
            try store.atomic { try store.put(source); try store.finish(op) }
            return
        }
        if try readFileInfo(file.path) == nil, try readFileInfo(temp.path) == nil {
            source.status = .detached; source.active = false
            try store.atomic { try store.put(source); try store.finish(op) }
            return
        }

        if try readFileInfo(file.path)?.regular == true {
            guard try readFileInfo(file.path) == expected else {
                if try readFileInfo(temp.path) == nil {
                    source.active = false; source.status = .detached
                    try store.atomic { try store.put(source); try store.finish(op) }
                }
                throw SyncError.message("接入前源文件已变化，重新观察")
            }
            let incoming: OpenedContent
            let archived: OpenedContent
            do {
                incoming = try OpenedContent(file, identity: expected.identity, scope: sourceRoot)
                archived = try OpenedContent(target, identity: entity.identity, scope: root)
                guard try incoming.digest() == op.digest, try archived.digest() == op.digest,
                      try incoming.sameBytes(as: archived), try incoming.compatibleMetadata(with: archived) else {
                    throw SyncError.message("接入前内容或附加属性不一致")
                }
            } catch {
                if try readFileInfo(temp.path) == nil {
                    source.active = false; source.status = .detached
                    try store.atomic { try store.put(source); try store.finish(op) }
                }
                throw error
            }
            if let info = try readFileInfo(temp.path) {
                guard info.symbolicLink, let old = linkTarget(temp.path), ownedTargets(op, source: source, root: root).contains(old) else {
                    throw SyncError.message("接入临时名已被占用")
                }
                if old != target.path {
                    _ = try paths(op, source: source, root: root, sourceRoot: sourceRoot)
                    try systemCall(unlink(temp.path), "清理旧的准备链接")
                }
            }
            // Save the intended target before either link creation or replacement.
            op = try recordTarget(op, source: source, relative: entity.relative)
            if try readFileInfo(temp.path) == nil {
                _ = try paths(op, source: source, root: root, sourceRoot: sourceRoot)
                try systemCall(symlink(target.path, temp.path), "创建去重链接")
            }
            op.swappedQuarantine = nil
            if try incoming.attributes()["com.apple.quarantine"] == nil,
               try archived.attributes()["com.apple.quarantine"] != nil {
                op.swappedQuarantine = try OpenedContent.quarantineOnLink(temp)
            }
            try store.atomic { try store.put(op) }
            try incoming.validate(); try archived.validate()
            _ = try paths(op, source: source, root: root, sourceRoot: sourceRoot)
            try systemCall(renamex_np(file.path, temp.path, UInt32(RENAME_SWAP)), "交换去重来源")
            try checkpoint?(.swapped)
        }

        guard try readFileInfo(temp.path)?.identity == expected.identity else { throw SyncError.message("冗余临时内容身份不符") }
        let actualLink = linkTarget(file.path)
        guard let actualLink, ownedTargets(op, source: source, root: root).contains(actualLink) else {
            throw SyncError.message("去重来源路径已被其他对象占用")
        }
        let duplicate: OpenedContent
        let archived: OpenedContent
        do {
            duplicate = try OpenedContent(temp, identity: expected.identity, scope: sourceRoot)
            archived = try OpenedContent(target, identity: entity.identity, scope: root)
            guard try duplicate.digest() == op.digest, try archived.digest() == op.digest,
                  try duplicate.sameBytes(as: archived), try duplicate.compatibleMetadata(with: archived, swappedQuarantine: op.swappedQuarantine) else {
                throw SyncError.message("去重清理前内容或附加属性发生变化")
            }
        } catch {
            if let rollbackOp = try requestRollback(op) {
                try rollback(rollbackOp, source: source, root: root, sourceRoot: sourceRoot)
            }
            throw error
        }
        if actualLink != target.path {
            op = try recordTarget(op, source: source, relative: entity.relative)
            _ = try paths(op, source: source, root: root, sourceRoot: sourceRoot)
            try updateLink(file, oldTarget: URL(fileURLWithPath: actualLink), newTarget: target)
        }
        source.status = .linked
        source.linkRelative = entity.relative
        op.phase = .cleanup; op.error = nil
        try store.atomic { try store.put(source); try store.put(op) }
        try checkpoint?(.associationSaved)
        // Recheck boundaries too: a parent can be redirected without changing either file inode.
        _ = try paths(op, source: source, root: root, sourceRoot: sourceRoot)
        try duplicate.validate(); try archived.validate()
        guard linkTarget(file.path) == target.path else { throw SyncError.message("清理前来源链接已变化") }
        try systemCall(unlink(temp.path), "移除已核对的冗余内容")
        try checkpoint?(.duplicateRemoved)
        try store.atomic { try store.finish(op) }
        try checkpoint?(.completed)
    }

    @discardableResult
    func requestRollback(_ original: ContentOperation) throws -> ContentOperation? {
        guard var op = try store.operations(original.accountID).first(where: { $0.id == original.id }) else { return nil }
        op.phase = .rollback
        try store.atomic { try store.put(op) }
        return op
    }

    private func rollback(_ op: ContentOperation, source original: ContentSource, root: URL, sourceRoot: URL) throws {
        var source = original
        let (file, temp) = try paths(op, source: source, root: root, sourceRoot: sourceRoot)
        let targets = ownedTargets(op, source: source, root: root)
        guard let expected = op.expected else { throw SyncError.message("回滚缺少源快照") }
        if try readFileInfo(file.path)?.identity == expected.identity {
            if let info = try readFileInfo(temp.path) {
                guard info.symbolicLink, let link = linkTarget(temp.path), targets.contains(link) else { throw SyncError.message("回滚临时名需要检查") }
                _ = try paths(op, source: source, root: root, sourceRoot: sourceRoot)
                try systemCall(unlink(temp.path), "清理回滚链接")
                try checkpoint?(.rollbackLinkRemoved)
            }
        } else {
            guard try readFileInfo(temp.path)?.identity == expected.identity,
                  let link = linkTarget(file.path), targets.contains(link) else { throw SyncError.message("回滚位置已被占用，保留临时内容") }
            _ = try paths(op, source: source, root: root, sourceRoot: sourceRoot)
            try systemCall(renamex_np(file.path, temp.path, UInt32(RENAME_SWAP)), "回滚重复来源")
            try checkpoint?(.rollbackSwapped)
            _ = try paths(op, source: source, root: root, sourceRoot: sourceRoot)
            guard let swappedLink = linkTarget(temp.path), targets.contains(swappedLink) else { throw SyncError.message("回滚后临时对象变化，未清理") }
            try systemCall(unlink(temp.path), "清理回滚链接")
            try checkpoint?(.rollbackLinkRemoved)
        }
        source.status = .detached; source.active = false
        try store.atomic { try store.put(source); try store.finish(op) }
    }
}
