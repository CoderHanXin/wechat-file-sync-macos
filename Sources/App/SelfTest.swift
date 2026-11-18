import Foundation
import Darwin

func selfTest() throws {
    let expectedRoot = try expectedWeChatRoot()
    let validAccount = expectedRoot.appendingPathComponent("example-account/msg/file", isDirectory: true)
    let invalidAccount = expectedRoot.appendingPathComponent("example-account/msg/video", isDirectory: true)
    guard try isWeChatFileDirectory(validAccount), try !isWeChatFileDirectory(invalidAccount) else {
        throw SyncError.message("微信账号目录识别测试失败")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("wechat-sync-" + UUID().uuidString)
    let source = root.appendingPathComponent("file", isDirectory: true)
    let month = source.appendingPathComponent("2026-11", isDirectory: true)
    let managedRoot = root.appendingPathComponent("CustomArchive", isDirectory: true)
    try FileManager.default.createDirectory(at: month, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: managedRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let old = month.appendingPathComponent("old.txt")
    try Data("old".utf8).write(to: old)
    let stateURL = root.appendingPathComponent("state.sqlite")
    let store = try SQLiteStateStore(url: stateURL)
    try store.save(initialState(source: source, managedRoot: managedRoot))
    let worker = try SyncWorker(store: store, settleSeconds: 0)
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
    let restartedWorker = try SyncWorker(store: SQLiteStateStore(url: stateURL), settleSeconds: 0)
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
        destination: recoveryTarget.lastPathComponent, temporary: recoveryTemporary.lastPathComponent,
        identity: recoveryInfo.identity, phase: .planned)
    try restartedWorker.save()
    try systemCall(symlink(recoveryTarget.path, recoveryTemporary.path), "创建恢复测试链接")
    try systemCall(renamex_np(recovery.path, recoveryTarget.path, UInt32(RENAME_EXCL)), "移动恢复测试文件")
    let recoveredWorker = try SyncWorker(store: SQLiteStateStore(url: stateURL), settleSeconds: 0)
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
    print("模拟测试通过")
}
