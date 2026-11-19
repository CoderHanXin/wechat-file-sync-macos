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

func activateConfigurationUI() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.activate(ignoringOtherApps: true)
}

func securityScope(bookmark: Data?, expected: URL, identity: Identity) throws -> DirectoryLease {
    guard let bookmark else { throw SyncError.message("缺少目录授权，请重新授权原目录") }
    var stale = false
    let selected = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                           relativeTo: nil, bookmarkDataIsStale: &stale)
    guard !stale, selected.startAccessingSecurityScopedResource() else { throw SyncError.message("目录授权已失效，请重新授权原目录") }
    let lease = DirectoryLease(url: selected) { selected.stopAccessingSecurityScopedResource() }
    guard try canonicalDirectory(selected).path == canonicalDirectory(expected).path,
          try readFileInfo(selected.path)?.identity == identity else { throw SyncError.message("授权目录与原配置不一致") }
    return lease
}

func selectSource(suggested: URL? = nil, matching: Bool = false) throws -> DirectoryLease {
    activateConfigurationUI()
    let selected = try chooseDirectory(suggested ?? expectedWeChatRoot(), title: "选择微信账号文件夹",
        message: "请选择该微信账号目录下的 msg/file 文件夹。首次添加时已有文件将留在原处。", requireMatch: matching)
    guard try isWeChatFileDirectory(selected), selected.startAccessingSecurityScopedResource() else {
        throw SyncError.message("请选择并授权微信账号目录下的 msg/file 文件夹")
    }
    return DirectoryLease(url: selected) { selected.stopAccessingSecurityScopedResource() }
}

func newBookmark(_ url: URL) throws -> Data {
    try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
}

/// Resolves either a legacy exact source grant or a new xwechat_files parent grant.
func sourceScope(_ account: Account) throws -> DirectoryLease {
    guard !account.removed, let bookmark = account.sourceBookmark else {
        throw SyncError.message("请重新选择微信文件夹")
    }
    let grant = try bookmarkScope(bookmark)
    return try WeChatDirectories.sourceLease(grant: grant, expected: account.sourceURL, identity: account.sourceIdentity)
}

func bookmarkScope(_ bookmark: Data) throws -> DirectoryLease {
    var stale = false
    let selected = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
    guard !stale, selected.startAccessingSecurityScopedResource() else {
        throw SyncError.message("文件夹访问已失效，请重新选择")
    }
    return DirectoryLease(url: selected) { selected.stopAccessingSecurityScopedResource() }
}

func selectWeChatRoot(suggested: URL? = nil) throws -> DirectoryLease {
    activateConfigurationUI()
    let selected = try chooseDirectory(try suggested ?? expectedWeChatRoot(), title: "选择微信文件夹",
        message: "请选择 xwechat_files。下一步选择要同步的微信账号。", requireMatch: false)
    guard selected.lastPathComponent == "xwechat_files", selected.startAccessingSecurityScopedResource() else {
        throw SyncError.message("请选择并允许访问 xwechat_files 文件夹")
    }
    return DirectoryLease(url: selected) { selected.stopAccessingSecurityScopedResource() }
}

func chooseDiscoveredAccount(_ accounts: [DiscoveredAccount], registered: [Account]) throws -> DiscoveredAccount {
    let available = accounts.filter { candidate in
        !registered.contains { $0.source == candidate.source.path || $0.sourceIdentity == candidate.identity }
    }
    guard !available.isEmpty else {
        throw SyncError.message("没有可添加的账号。只列出已初始化且可访问的账号；已添加或已停止管理的账号请在主界面选择。")
    }
    let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
    available.forEach { picker.addItem(withTitle: $0.name) }
    let alert = NSAlert(); alert.messageText = "选择微信账号"
    alert.informativeText = "只管理你选择的账号。已有微信文件留在原处。"
    alert.accessoryView = picker; alert.addButton(withTitle: "下一步"); alert.addButton(withTitle: "取消")
    guard alert.runModal() == .alertFirstButtonReturn else { throw SyncError.message("已取消添加") }
    return available[picker.indexOfSelectedItem]
}

func rootLease(_ repository: AccountRepository) throws -> DirectoryLease {
    guard let root = try repository.root() else { throw SyncError.message("请先运行 --configure 配置管理根目录") }
    return try securityScope(bookmark: root.bookmark, expected: root.url, identity: root.identity)
}

@discardableResult
func recoverAccounts(_ repository: AccountRepository, accountID: String? = nil) throws -> Int {
    let manager = AccountManager(repository: repository)
    var failures = 0
    for setup in try repository.pendingSetups() {
        if let accountID, setup.account.id != accountID { continue }
        if let account = try repository.accounts().first(where: { $0.id == setup.account.id }), account.removed { continue }
        do {
            let source = try sourceScope(setup.account)
            defer { withExtendedLifetime(source) {} }
            try manager.recover(setup)
        } catch let error as SQLiteStoreError { throw SyncError.persistence(error.description) }
        catch {
            failures += 1
            NSLog("账号配置尚未恢复 %@：%@", setup.account.id, String(describing: error))
        }
    }
    return failures
}

/// Called only after the entry point acquired ProcessLock.
func runConfiguration(_ command: Command, repository: AccountRepository) throws {
    let manager = AccountManager(repository: repository)
    let hasExistingAccounts = try !repository.accounts().filter { !$0.removed }.isEmpty
    let hasPendingSetups = try !repository.pendingSetups().isEmpty
    if command == .configure && (hasExistingAccounts || hasPendingSetups) {
        let root = try rootLease(repository)
        defer { withExtendedLifetime(root) {} }
        guard try recoverAccounts(repository) == 0 else { throw SyncError.message("已有配置需重新授权或恢复，请使用 --list-accounts 查看账号 ID") }
        print("已有账号配置已保留；新增账号请使用 --add-account，重新授权请使用 --reauthorize-account")
        return
    }
    switch command {
    case .pauseAccount(let id): try manager.setPaused(id, paused: true)
    case .resumeAccount(let id): try manager.setPaused(id, paused: false)
    case .renameAccount(let id, let name): try manager.rename(id, name: name)
    case .removeAccount(let id): try repository.remove(id)
    case .restoreAccount(let id), .reauthorizeAccount(let id):
        let account = try repository.configurationAccount(id)
        let source = try selectSource(suggested: account.sourceURL, matching: true)
        defer { withExtendedLifetime(source) {} }
        try manager.reauthorize(id, source: source.url, bookmark: newBookmark(source.url), restoring: command == .restoreAccount(id))
    case .reauthorizeRoot:
        guard let root = try repository.root() else { throw SyncError.message("尚未配置管理根目录") }
        activateConfigurationUI()
        let canChoose = try repository.canChooseRoot()
        let selected = try chooseDirectory(root.url, title: "管理根目录", message: canChoose ? "尚未绑定账号，可重新选择目录，不搬动文件。" : "请选择原管理根目录。此版本不搬迁归档。", requireMatch: !canChoose)
        guard selected.startAccessingSecurityScopedResource() else { throw SyncError.message("无法获得管理根目录权限") }
        defer { selected.stopAccessingSecurityScopedResource() }
        try manager.configureRoot(selected, bookmark: newBookmark(selected))
    case .configure, .addAccount:
        let source = try selectSource()
        defer { withExtendedLifetime(source) {} }
        let name: String
        if case .addAccount(let provided) = command, let provided { name = provided } else { name = WeChatDirectories.displayName(source: source.url) }
        _ = try manager.checkedName(name)
        let root: DirectoryLease
        if try repository.root() == nil {
            activateConfigurationUI()
            let selected = try chooseDirectory(defaultManagedRoot(), title: "选择管理根目录",
                message: "选择保存文件并跟踪改名、移动的目录。下载目录仅为默认建议。", requireMatch: false)
            guard selected.startAccessingSecurityScopedResource() else { throw SyncError.message("无法获得管理根目录权限") }
            root = DirectoryLease(url: selected) { selected.stopAccessingSecurityScopedResource() }
            // Validate the pair before persisting root authorization.
            _ = try initialState(source: canonicalDirectory(source.url), managedRoot: canonicalDirectory(selected))
            try manager.configureRoot(selected, bookmark: newBookmark(selected))
        } else { root = try rootLease(repository) }
        defer { withExtendedLifetime(root) {} }
        let account = try manager.add(source: source.url, name: name, bookmark: newBookmark(source.url))
        print("已添加账号：\(account.name) ID=\(account.id)；已有文件保留原处")
    case .recoverAccounts:
        let root = try rootLease(repository)
        defer { withExtendedLifetime(root) {} }
        guard try recoverAccounts(repository) == 0 else { throw SyncError.message("部分账号配置尚未恢复，请检查错误并重新授权原目录") }
    default: throw SyncError.message("该命令不是配置操作")
    }
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
