import Foundation
import Darwin

func runBackground(appSupport: URL) throws {
    let diagnostic = CommandLine.arguments.contains("--check") || CommandLine.arguments.contains("--diagnose")
    let lock = try diagnostic ? nil : ProcessLock(url: appSupport.appendingPathComponent("sync.lock"))
    defer { withExtendedLifetime(lock) {} }
    let store = try diagnostic
        ? SQLiteStateStore(url: appSupport.appendingPathComponent("state.sqlite"), readOnly: true)
        : openConfiguredStore(appSupport: appSupport)
    let state = try store.load()
    guard let bookmarks = try store.bookmarks() else { throw SyncError.message("缺少目录授权，请重新配置") }
    let data = bookmarks.source
    var stale = false
    let selection = try URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                            relativeTo: nil, bookmarkDataIsStale: &stale)
    guard !stale, selection.startAccessingSecurityScopedResource() else {
        throw SyncError.message("微信文件夹授权已失效")
    }
    defer { selection.stopAccessingSecurityScopedResource() }
    let rootData = bookmarks.managedRoot
    var rootStale = false
    let rootSelection = try URL(resolvingBookmarkData: rootData, options: [.withSecurityScope],
                                    relativeTo: nil, bookmarkDataIsStale: &rootStale)
    guard !rootStale, rootSelection.startAccessingSecurityScopedResource() else {
        throw SyncError.message("管理根目录授权已失效")
    }
    defer { rootSelection.stopAccessingSecurityScopedResource() }
    let source = URL(fileURLWithPath: state.source, isDirectory: true)
    let managedRoot = URL(fileURLWithPath: state.managedRoot, isDirectory: true)
    guard state.version == 1, try isWeChatFileDirectory(source),
          selection.resolvingSymlinksInPath().path == source.resolvingSymlinksInPath().path,
          rootSelection.resolvingSymlinksInPath().path == managedRoot.resolvingSymlinksInPath().path else {
        throw SyncError.message("同步配置与授权路径不一致")
    }
    try validateConfiguration(state, source: selection, managedRoot: rootSelection)
    if CommandLine.arguments.contains("--check") {
        guard fileInfo(source.path)?.identity == state.sourceIdentity,
              fileInfo(managedRoot.path)?.identity == state.managedRootIdentity else {
            throw SyncError.message("同步目录已更改或不可用")
        }
        _ = try allFiles(source)
        print("文件夹授权和同步配置正常")
        return
    }
    if CommandLine.arguments.contains("--diagnose") {
        try diagnoseAccess(source: source, managedRoot: managedRoot)
        return
    }
    let worker = try SyncWorker(store: store)
    while true {
        do { try worker.scan() } catch { NSLog("同步检查失败：%@", String(describing: error)) }
        Thread.sleep(forTimeInterval: 2)
    }
}
