import Foundation

func listAccounts(_ repository: AccountRepository) throws {
    guard let root = try repository.root() else { print("尚未配置管理根目录"); return }
    print("管理根目录：\(root.path)")
    print("以下为保存的配置状态；目录与授权请用 --check 检查，不代表后台实时运行状态。")
    for account in try repository.accounts() {
        let status = account.removed ? "已移除" : (account.intakeEnabled ? "同步新文件" : "暂停新文件（维护已有链接）")
        print("\(account.id)  \(account.name)  [\(status)]\n  微信：\(account.source)\n  归档：\(root.path)/\(account.archiveRelative)")
    }
    for setup in try repository.pendingSetups() {
        let action = setup.account.removed ? "已移除，须先用 --restore-account 重新授权恢复" : "可使用 --recover-accounts"
        print("未完成配置：\(setup.account.id)  \(setup.account.name)；\(action)")
    }
}

func checkAccounts(_ repository: AccountRepository, diagnose: Bool) throws {
    let root = try rootLease(repository)
    defer { withExtendedLifetime(root) {} }
    guard let configuredRoot = try repository.root() else { throw SyncError.message("尚未配置管理根目录") }
    var failures = 0
    for account in try repository.accounts() where !account.removed {
        do {
            let source = try securityScope(bookmark: account.sourceBookmark, expected: account.sourceURL, identity: account.sourceIdentity)
            defer { withExtendedLifetime(source) {} }
            guard try isWeChatFileDirectory(source.url) else { throw SyncError.message("微信账号目录格式不正确") }
            _ = try allFiles(source.url)
            let archive = try checkedFile(configuredRoot.url, relative: account.archiveRelative)
            guard let expected = account.archiveIdentity, try readFileInfo(archive.path)?.identity == expected else {
                throw SyncError.message("账号归档目录不可用；如为迁移后首次配置，请停止后台并执行 --recover-accounts")
            }
            if diagnose { try diagnoseAccess(source: source.url, managedRoot: root.url) }
            print("\(account.id) \(account.name)：授权和目录正常")
        } catch {
            failures += 1
            print("\(account.id) \(account.name)：\(error)")
        }
    }
    guard failures == 0 else { throw SyncError.message("\(failures) 个账号需要检查，其他账号可继续同步") }
}

func runBackground(content: ContentRepository) throws {
    let repository = content.accounts
    let root = try rootLease(repository)
    defer { withExtendedLifetime(root) {} }
    try recoverAccounts(repository)
    let coordinator = ContentCoordinator(store: content) { account in
        let lease = try securityScope(bookmark: account.sourceBookmark, expected: account.sourceURL, identity: account.sourceIdentity)
        guard try isWeChatFileDirectory(lease.url) else { throw SyncError.message("微信账号目录格式不正确") }
        return lease
    }
    while true {
        do {
            let result = try coordinator.scan()
            for account in result.accounts {
                if let error = account.error { NSLog("账号 %@ 暂停：%@", account.accountID, error) }
                for issue in account.report?.issues ?? [] { NSLog("文件 %@ 需要检查：%@", issue.relative, issue.message) }
            }
        } catch let error as SyncError {
            if case .persistence = error { throw error }
            NSLog("同步检查失败：%@", error.description)
        } catch { throw error }
        Thread.sleep(forTimeInterval: 2)
    }
}
