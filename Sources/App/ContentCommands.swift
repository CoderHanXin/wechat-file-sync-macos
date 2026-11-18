import Foundation

func runContentCommand(_ command: Command, store: ContentRepository) throws {
    switch command {
    case .setReadOnly(let id, let enabled): try store.setReadOnly(id, enabled)
    case .listFileIssues(let selected):
        if let selected { _ = try store.accounts.account(selected) }
        for account in try store.accounts.accounts() where selected == nil || account.id == selected {
            print("账号 \(account.id) \(account.name)：新建实体默认只读=\(try store.readOnlyDefault(account.id))")
            for issue in try store.issues(account.id) { print("需要检查 \(issue.relative)：\(issue.message)") }
            for entity in try store.entities(account.id) {
                let permission = entity.info.map { String($0.mode & 0o7777, radix: 8) } ?? "未知"
                print("实体 \(entity.id) [\(entity.status.rawValue)] \(entity.relative)，记录权限=\(permission)（实时状态需检查）")
            }
            for source in try store.sources(account.id) where source.status != .linked {
                print("来源 \(source.id) [\(source.status.rawValue)] \(source.relative)")
            }
            for op in try store.operations(account.id) {
                print("操作 \(op.id) \(op.kind.rawValue)/\(op.phase.rawValue)，临时名 \(op.temporary)，\(op.error ?? "待恢复")")
            }
        }
    case .applyReadOnly(let id, let enabled):
        guard try !store.accounts.account(id).removed else { throw SyncError.message("请先显式恢复账号") }
        let lease = try rootLease(store.accounts)
        defer { withExtendedLifetime(lease) {} }
        let root = try AccountManager(repository: store.accounts).validatedRoot()
        let index = ManagedRootIndex(root: root.url)
        var failures = 0
        for entity in try store.entities(id) where entity.status != .missing && entity.status != .pending && entity.status != .conflict {
            let pendingPermission = try store.operations(id).contains { $0.entityID == entity.id && $0.kind == .permission }
            if !enabled && entity.protectionBefore == nil && !pendingPermission {
                print("保持原权限：\(entity.relative)（没有本工具移除写位的记录）")
                continue
            }
            do {
                var entity = entity
                if try readFileInfo(root.url.appendingPathComponent(entity.relative).path)?.identity != entity.identity,
                   let moved = try index.find(entity.identity) { entity.relative = moved; try store.atomic { try store.put(entity) } }
                try ReadOnlyPolicy(store: store).apply(entity, at: checkedFile(root.url, relative: entity.relative), protect: enabled)
                print("权限已核对：\(entity.relative)")
            } catch let error as SQLiteStoreError { throw SyncError.persistence(error.description) }
            catch let error as SyncError {
                if case .persistence = error { throw error }
                failures += 1; print("权限未完成：\(entity.relative)：\(error)")
            }
        }
        if failures > 0 { throw SyncError.message("\(failures) 个实体权限需要检查") }
    case .recoverOperations(let selected):
        if let selected { _ = try store.accounts.account(selected) }
        let root = try rootLease(store.accounts)
        defer { withExtendedLifetime(root) {} }
        try recoverAccounts(store.accounts, accountID: selected)
        let coordinator = ContentCoordinator(store: store, acceptNewFiles: false) { account in
            if let selected, selected != account.id { throw SyncError.message("未选中此账号") }
            let lease = try securityScope(bookmark: account.sourceBookmark, expected: account.sourceURL, identity: account.sourceIdentity)
            guard try isWeChatFileDirectory(lease.url) else { throw SyncError.message("账号目录格式错误") }
            return lease
        }
        let result = try coordinator.scan()
        let failures = result.accounts.filter { selected == nil || $0.accountID == selected }.filter { $0.error != nil || !($0.report?.issues.isEmpty ?? true) }
        for account in failures { print("账号 \(account.accountID)：\(account.error ?? String(describing: account.report?.issues))") }
        if !failures.isEmpty { throw SyncError.message("部分操作仍需检查") }
    default: throw SyncError.message("不是内容管理命令")
    }
}
