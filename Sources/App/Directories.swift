import Foundation
import AppKit
import Darwin

func realHomeDirectory() throws -> URL {
    guard let entry = getpwuid(getuid()), let path = entry.pointee.pw_dir else {
        throw SyncError.message("无法确定当前用户的主目录")
    }
    return URL(fileURLWithPath: String(cString: path), isDirectory: true)
}

func expectedWeChatRoot() throws -> URL {
    return try realHomeDirectory().appendingPathComponent(
        "Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files", isDirectory: true)
}

func defaultManagedRoot() throws -> URL {
    return try realHomeDirectory().appendingPathComponent("Downloads", isDirectory: true)
}

func isWeChatFileDirectory(_ selected: URL) throws -> Bool {
    let root = try expectedWeChatRoot().standardizedFileURL.path
    let path = selected.standardizedFileURL.path
    guard path.hasPrefix(root + "/") else { return false }
    let components = String(path.dropFirst(root.count + 1)).split(separator: "/")
    return components.count == 3 && components[1] == "msg" && components[2] == "file"
}

func showMessage(_ text: String) {
    let alert = NSAlert()
    alert.messageText = "微信下载同步"
    alert.informativeText = text
    alert.addButton(withTitle: "好")
    alert.runModal()
}

func chooseDirectory(_ suggested: URL, title: String, message: String, requireMatch: Bool) throws -> URL {
    let panel = NSOpenPanel()
    panel.title = title
    panel.message = message
    panel.prompt = "授权此文件夹"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = suggested
    guard panel.runModal() == .OK, let selection = panel.url else {
        throw SyncError.message("未选择文件夹")
    }
    guard !requireMatch || selection.resolvingSymlinksInPath().path == suggested.resolvingSymlinksInPath().path else {
        throw SyncError.message("所选目录与要求的文件夹不一致")
    }
    return selection
}

func configure(appSupport: URL) throws {
    let lock = try ProcessLock(url: appSupport.appendingPathComponent("sync.lock"))
    defer { withExtendedLifetime(lock) {} }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.activate(ignoringOtherApps: true)
    let suggestedRoot = try defaultManagedRoot()
    let sourceSelection = try chooseDirectory(expectedWeChatRoot(), title: "选择微信文件夹",
        message: "请选择微信账号目录下的 msg/file 文件夹。已有文件将留在原处。", requireMatch: false)
    guard try isWeChatFileDirectory(sourceSelection) else {
        throw SyncError.message("请选择微信账号目录下的 msg/file 文件夹")
    }
    let source = sourceSelection.standardizedFileURL
    guard sourceSelection.startAccessingSecurityScopedResource() else {
        throw SyncError.message("无法获得微信文件夹访问权限")
    }
    defer { sourceSelection.stopAccessingSecurityScopedResource() }
    let rootSelection = try chooseDirectory(suggestedRoot, title: "选择管理根目录",
        message: "请选择保存文件并跟踪改名、移动的管理根目录。下载目录仅为默认建议。", requireMatch: false)
    guard rootSelection.startAccessingSecurityScopedResource() else {
        throw SyncError.message("无法获得管理根目录访问权限")
    }
    defer { rootSelection.stopAccessingSecurityScopedResource() }
    let sourceBookmark = try sourceSelection.bookmarkData(options: [.withSecurityScope],
                                                           includingResourceValuesForKeys: nil, relativeTo: nil)
    let rootBookmark = try rootSelection.bookmarkData(options: [.withSecurityScope],
                                                                includingResourceValuesForKeys: nil, relativeTo: nil)
    let store = try openConfiguredStore(appSupport: appSupport)
    try configureDirectories(store: store, source: source, managedRoot: rootSelection.standardizedFileURL,
                             bookmarks: DirectoryBookmarks(source: sourceBookmark, managedRoot: rootBookmark))
}

func diagnoseAccess(source: URL, managedRoot: URL) throws {
    let name = temporaryPrefix + UUID().uuidString
    let sourceTest = source.appendingPathComponent(name)
    let destinationTest = managedRoot.appendingPathComponent(name)
    defer {
        _ = unlink(sourceTest.path)
        _ = unlink(destinationTest.path)
    }
    let sourceFD = open(sourceTest.path, O_CREAT | O_EXCL | O_WRONLY, mode_t(0o600))
    guard sourceFD >= 0 else { throw SyncError.system("创建微信目录测试文件", errno) }
    close(sourceFD)
    let rootFD = open(destinationTest.path, O_CREAT | O_EXCL | O_WRONLY, mode_t(0o600))
    guard rootFD >= 0 else { throw SyncError.system("创建管理目录测试文件", errno) }
    close(rootFD)
    try systemCall(unlink(destinationTest.path), "清理管理目录测试文件")
    print("两个目录均可写入")
    if link(sourceTest.path, destinationTest.path) == 0 {
        print("跨目录建立文件链接成功")
        try systemCall(unlink(destinationTest.path), "清理测试链接")
    } else {
        print("跨目录建立文件链接失败：\(String(cString: strerror(errno)))")
    }
    if renamex_np(sourceTest.path, destinationTest.path, UInt32(RENAME_EXCL)) == 0 {
        print("跨目录移动文件成功")
        try systemCall(renamex_np(destinationTest.path, sourceTest.path, UInt32(RENAME_EXCL)), "恢复测试文件")
    } else {
        print("跨目录移动文件失败：\(String(cString: strerror(errno)))")
    }
}
