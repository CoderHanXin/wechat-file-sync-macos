import Foundation
import Darwin

final class ReadOnlyPolicy {
    let store: ContentRepository
    let checkpoint: ((ContentCheckpoint) throws -> Void)?
    init(store: ContentRepository, checkpoint: ((ContentCheckpoint) throws -> Void)? = nil) {
        self.store = store; self.checkpoint = checkpoint
    }

    func apply(_ original: ContentEntity, at url: URL, protect: Bool) throws {
        guard var entity = try store.entities(original.accountID).first(where: { $0.id == original.id }) else {
            throw SyncError.message("权限操作的实体不存在")
        }
        guard try !store.accounts.account(entity.accountID).removed else { throw SyncError.message("账号已移除") }
        var operation = try store.operations(entity.accountID).first { $0.entityID == entity.id && $0.kind == .permission }
        let root = try AccountManager(repository: store.accounts).validatedRoot()
        guard try checkedFile(root.url, relative: entity.relative).path == url.path else { throw SyncError.message("权限位置与实体记录不一致") }
        let file = try OpenedContent(url, identity: entity.identity, scope: root.url)
        try file.validatePermissionSupport()
        let current = UInt16(file.info.mode & 0o7777)
        if operation == nil {
            if protect, entity.protectionBefore != nil, entity.protectionAfter == current { return }
            let desired: UInt16
            if protect { desired = current & ~0o222 }
            else {
                guard let before = entity.protectionBefore, let after = entity.protectionAfter else { return }
                guard current == after else { throw SyncError.message("权限已被外部修改，未强制解锁") }
                desired = current | (before & 0o222)
            }
            operation = ContentOperation(id: UUID().uuidString, accountID: entity.accountID, entityID: entity.id,
                sourceID: nil, kind: .permission, temporary: temporaryPrefix + UUID().uuidString,
                expected: file.info, digest: nil, protect: protect, beforeMode: current, afterMode: desired)
            try store.atomic { try store.put(operation!) }
        }
        guard let op = operation, let before = op.beforeMode, let after = op.afterMode,
              current == before || current == after else { throw SyncError.message("权限操作的模式已变化，保留现场") }
        try file.validate()
        if current != after {
            try systemCall(fchmod(file.fd, mode_t(after)), "设置实体权限")
            try checkpoint?(.permissionChanged)
        }
        try file.validateScope()
        guard let actual = try readFileInfo(url.path), actual.identity == entity.identity,
              actual.mode & 0o7777 == mode_t(after) else { throw SyncError.message("权限操作期间实体或模式被替换") }
        if op.protect {
            entity.protectionBefore = before
            entity.protectionAfter = after
        } else {
            entity.protectionBefore = nil
            entity.protectionAfter = nil
        }
        entity.info = try readFileInfo(url.path)
        try store.atomic { try store.put(entity); try store.finish(op) }
        if op.protect != protect { try apply(entity, at: url, protect: protect) }
    }
}
