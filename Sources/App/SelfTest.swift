import Foundation
import Darwin

func selfTest() throws {
    let expectedRoot = try expectedWeChatRoot()
    let validAccount = expectedRoot.appendingPathComponent("example-account/msg/file", isDirectory: true)
    let invalidAccount = expectedRoot.appendingPathComponent("example-account/msg/video", isDirectory: true)
    guard try isWeChatFileDirectory(validAccount), try !isWeChatFileDirectory(invalidAccount) else {
        throw SyncError.message("微信账号目录识别测试失败")
    }
    let root = try canonicalDirectory(FileManager.default.temporaryDirectory).appendingPathComponent("wechat-sync-" + UUID().uuidString)
    let source = root.appendingPathComponent("file", isDirectory: true)
    let month = source.appendingPathComponent("2026-11", isDirectory: true)
    let sharedRoot = root.appendingPathComponent("CustomArchive", isDirectory: true)
    try FileManager.default.createDirectory(at: month, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sharedRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let old = month.appendingPathComponent("old.txt")
    try Data("old".utf8).write(to: old)
    let stateURL = root.appendingPathComponent("state.sqlite")
    let repository = try AccountRepository(url: stateURL)
    let manager = AccountManager(repository: repository)
    try manager.configureRoot(sharedRoot, bookmark: nil)
    let account = try manager.add(source: source, name: "测试账号", bookmark: nil)
    let managedRoot = sharedRoot.appendingPathComponent(account.archiveRelative)
    func newWorker() throws -> SyncWorker {
        try SyncWorker(store: AccountStateStore(repository: repository, accountID: account.id),
                       archiveRelative: account.archiveRelative, archiveIdentity: account.archiveIdentity, settleSeconds: 0)
    }
    let worker = try newWorker()
    let incoming = month.appendingPathComponent("new.txt")
    try Data("new".utf8).write(to: incoming)
    try worker.scan()
    try worker.scan()
    let target = managedRoot.appendingPathComponent("new.txt")
    guard linkTarget(incoming.path) == target.path,
          try String(contentsOf: target, encoding: .utf8) == "new",
          fileInfo(old.path)?.regular == true else {
        throw SyncError.message("新文件或历史文件测试失败")
    }
    let restartedWorker = try newWorker()
    try FileManager.default.removeItem(at: target)
    try restartedWorker.scan()
    guard fileInfo(incoming.path) == nil, fileInfo(old.path)?.regular == true else {
        throw SyncError.message("删除同步测试失败")
    }
    let existingTarget = managedRoot.appendingPathComponent("same.txt")
    let collision = month.appendingPathComponent("same.txt")
    try Data("unrelated".utf8).write(to: existingTarget)
    try Data("wechat".utf8).write(to: collision)
    try restartedWorker.scan()
    try restartedWorker.scan()
    let alternate = managedRoot.appendingPathComponent("same (微信 2).txt")
    guard try String(contentsOf: existingTarget, encoding: .utf8) == "unrelated",
          try String(contentsOf: alternate, encoding: .utf8) == "wechat",
          linkTarget(collision.path) == alternate.path else {
        throw SyncError.message("同名文件测试失败")
    }
    let subfolder = managedRoot.appendingPathComponent("分类", isDirectory: true)
    try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
    let renamed = subfolder.appendingPathComponent("renamed.txt")
    try FileManager.default.moveItem(at: alternate, to: renamed)
    try restartedWorker.scan()
    guard linkTarget(collision.path) == renamed.path,
          try String(contentsOf: collision, encoding: .utf8) == "wechat" else {
        throw SyncError.message("归档文件改名或移动测试失败")
    }
    try FileManager.default.removeItem(at: renamed)
    try restartedWorker.scan()
    guard fileInfo(collision.path) == nil else {
        throw SyncError.message("改名后的删除同步测试失败")
    }
    let oldMoved = month.appendingPathComponent("old-renamed.txt")
    try FileManager.default.moveItem(at: old, to: oldMoved)
    try restartedWorker.scan()
    try restartedWorker.scan()
    guard fileInfo(oldMoved.path)?.regular == true,
          fileInfo(managedRoot.appendingPathComponent("old-renamed.txt").path) == nil else {
        throw SyncError.message("已有文件移动测试失败")
    }
    let recovery = month.appendingPathComponent("recovery.txt")
    let recoveryTarget = managedRoot.appendingPathComponent("recovery.txt")
    let recoveryTemporary = month.appendingPathComponent(temporaryPrefix + "recovery")
    try Data("recovery".utf8).write(to: recovery)
    guard let recoveryInfo = fileInfo(recovery.path) else {
        throw SyncError.message("恢复测试文件不存在")
    }
    restartedWorker.state.transfers["2026-11/recovery.txt"] = Transfer(
        destination: try relativePath(recoveryTarget, in: sharedRoot), temporary: recoveryTemporary.lastPathComponent,
        identity: recoveryInfo.identity, phase: .planned)
    try restartedWorker.save()
    try systemCall(symlink(recoveryTarget.path, recoveryTemporary.path), "创建恢复测试链接")
    try systemCall(renamex_np(recovery.path, recoveryTarget.path, UInt32(RENAME_EXCL)), "移动恢复测试文件")
    let recoveredWorker = try newWorker()
    try recoveredWorker.scan()
    guard linkTarget(recovery.path) == recoveryTarget.path,
          try String(contentsOf: recovery, encoding: .utf8) == "recovery" else {
        throw SyncError.message("中断恢复测试失败")
    }
    try FileManager.default.removeItem(at: recoveryTarget)
    try recoveredWorker.scan()
    guard fileInfo(recovery.path) == nil else {
        throw SyncError.message("恢复后的删除同步测试失败")
    }
    let secondSource = root.appendingPathComponent("second-account/msg/file")
    try FileManager.default.createDirectory(at: secondSource, withIntermediateDirectories: true)
    let second = try manager.add(source: secondSource, name: "第二账号", bookmark: nil)
    let secondFile = secondSource.appendingPathComponent("same.txt")
    try Data("second".utf8).write(to: secondFile)
    let coordinator = SyncCoordinator(repository: repository, settleSeconds: 0) { DirectoryLease(url: $0.sourceURL) }
    _ = try coordinator.scan()
    _ = try coordinator.scan()
    guard linkTarget(secondFile.path) == sharedRoot.appendingPathComponent(second.archiveRelative + "/same.txt").path,
          try repository.accounts().count == 2 else { throw SyncError.message("多账号隔离测试失败") }
    try contentSelfTest()
    print("M3 临时样本自测通过")
}

private func contentSelfTest() throws {
    let temp = try canonicalDirectory(FileManager.default.temporaryDirectory).appendingPathComponent("wechat-content-smoke-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }
    let source = temp.appendingPathComponent("source")
    let root = temp.appendingPathComponent("自定义资料")
    for url in [source, root] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    let store = try ContentRepository(url: temp.appendingPathComponent("state.sqlite"))
    let manager = AccountManager(repository: store.accounts)
    try manager.configureRoot(root, bookmark: nil)
    let account = try manager.add(source: source, name: "测试", bookmark: nil)
    let first = source.appendingPathComponent("first.txt"), second = source.appendingPathComponent("forward.pdf")
    try Data("content".utf8).write(to: first)
    try Data("content".utf8).write(to: second)
    let worker = ContentWorker(store: store, accountID: account.id, settleSeconds: 0)
    try worker.scan(); try worker.scan()
    guard let target = linkTarget(first.path), target == linkTarget(second.path),
          try store.entities(account.id).count == 1, try store.sources(account.id).count == 2,
          let info = try readFileInfo(target), info.mode & 0o222 == 0 else { throw SyncError.message("M3 去重或只读自测失败：\(worker.report.issues)") }
    let moved = root.appendingPathComponent("整理后.txt")
    try FileManager.default.moveItem(atPath: target, toPath: moved.path)
    try worker.scan()
    guard linkTarget(first.path) == moved.path, linkTarget(second.path) == moved.path else { throw SyncError.message("多来源改名自测失败") }
    try FileManager.default.removeItem(at: moved)
    try worker.scan()
    guard try store.sources(account.id).count == 2, try store.entities(account.id).first?.status == .missing,
          fileInfo(first.path) == nil, fileInfo(second.path) == nil else { throw SyncError.message("多来源失联记录自测失败") }
}
