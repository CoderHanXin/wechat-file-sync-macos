import Foundation
import AppKit
import ServiceManagement

/// Keeps SQLite and scanning off the main thread, on the same serial queue as settings writes.
private final class DesktopWorker {
    private let queue = DispatchQueue(label: "wechat-file-sync.session", qos: .utility)
    private var session: ApplicationSession?
    private var timer: DispatchSourceTimer?
    var update: ((ApplicationSnapshot?, String?) -> Void)?
    private let makeSession: () throws -> ApplicationSession
    private let scanInterval: TimeInterval

    init(makeSession: (() throws -> ApplicationSession)? = nil, scanInterval: TimeInterval = 2) {
        self.makeSession = makeSession ?? {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("WeChatFileSync", isDirectory: true)
            return try ApplicationSession(database: support.appendingPathComponent("state.sqlite"),
                rootAuthorization: { root in try securityScope(bookmark: root.bookmark, expected: root.url, identity: root.identity) },
                sourceAuthorization: { account in
                    let lease = try securityScope(bookmark: account.sourceBookmark, expected: account.sourceURL, identity: account.sourceIdentity)
                    guard try isWeChatFileDirectory(lease.url) else { throw SyncError.message("微信账号目录格式错误") }
                    return lease
                })
        }
        self.scanInterval = scanInterval
    }

    func start() {
        queue.async {
            do {
                self.session = try self.makeSession()
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now(), repeating: self.scanInterval)
                timer.setEventHandler { [weak runtime = self] in runtime?.tick() }
                self.timer = timer; timer.resume()
                self.publish()
            } catch { self.publish(error: String(describing: error)) }
        }
    }

    private func tick() {
        do { try session?.scan(); publish() }
        catch { publish(error: String(describing: error)) }
    }

    private func publish(error: String? = nil) {
        let snapshot: ApplicationSnapshot?
        let message: String?
        do { snapshot = try session?.snapshot(); message = error }
        catch {
            let failure = "状态读取失败，已停止同步：\(error)"
            snapshot = nil; message = failure
            session?.stopScanning(failure)
        }
        DispatchQueue.main.async { self.update?(snapshot, message) }
    }

    func perform<T>(_ action: @escaping (ApplicationSession) throws -> T, completion: @escaping (Result<T, Error>) -> Void) {
        queue.async {
            let result: Result<T, Error>
            do {
                guard let session = self.session else { throw SyncError.message("状态库未打开，请退出后重试；可能有另一个实例正在运行") }
                result = .success(try action(session))
            } catch { result = .failure(error) }
            self.publish()
            DispatchQueue.main.async { completion(result) }
        }
    }

    func stop(_ done: @escaping () -> Void) {
        queue.async {
            self.timer?.cancel(); self.timer = nil; self.session = nil
            DispatchQueue.main.async(execute: done)
        }
    }
}

fileprivate final class DesktopController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let worker = DesktopWorker()
    private var statusItem: NSStatusItem!
    fileprivate var window: NSWindow!
    private let status = NSTextField(wrappingLabelWithString: "正在打开状态库…")
    private let rootLabel = NSTextField(wrappingLabelWithString: "未选择归档目录")
    private let accountPicker = NSPopUpButton()
    private let accountInfo = NSTextField(wrappingLabelWithString: "添加后只整理新接收文件，已有微信文件留在原处。")
    fileprivate let readOnly = NSButton(checkboxWithTitle: "新建的归档文件默认只读", target: nil, action: nil)
    private let login = NSButton(checkboxWithTitle: "登录时启动", target: nil, action: nil)
    private let loginStatus = NSTextField(labelWithString: "")
    private var actionButtons: [NSButton] = []
    private var snapshot: ApplicationSnapshot?
    private var busy = false
    private var selectedID: String?
    private var terminating = false
    private var receivedInitialState = false
    private var stateUnavailable = true
    private var stateError: String?
    #if DESKTOP_TESTING
    fileprivate var manualPreviewOnly = false
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DESKTOP_TESTING
        if manualPreviewOnly { return }
        #endif
        NSApp.setActivationPolicy(.accessory)
        makeMenu(); makeWindow()
        worker.update = { [weak self] value, error in
            guard let self, !self.terminating else { return }
            self.render(value, error: error)
            if !self.receivedInitialState {
                self.receivedInitialState = true
                if value?.root == nil || error != nil { self.showSettings(nil) }
            }
        }
        worker.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings(nil); return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        #if DESKTOP_TESTING
        if manualPreviewOnly {
            NSApp.stop(nil)
            if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) { NSApp.postEvent(event, atStart: true) }
            return .terminateCancel // Return to the fixture so its temporary directory is removed.
        }
        #endif
        guard !terminating else { return .terminateLater }
        terminating = true; status.stringValue = "正在结束当前操作…"
        worker.stop { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    fileprivate func makeMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: "微信文件同步")
        let menu = NSMenu()
        for (title, selector) in [("设置…", #selector(showSettings(_:))), ("打开归档目录", #selector(openRoot(_:))), ("退出", #selector(quit(_:)))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: title == "退出" ? "q" : "")
            item.target = self; menu.addItem(item)
        }
        statusItem.menu = menu
        let main = NSMenu(), app = NSMenu(), item = NSMenuItem()
        item.submenu = app; main.addItem(item)
        app.addItem(withTitle: "退出微信文件同步", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(), editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        for (name, action, key) in [("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: name, action: action, keyEquivalent: key)
        }
        editItem.submenu = edit; main.addItem(editItem); NSApp.mainMenu = main
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        actionButtons.append(button); return button
    }

    private func row(_ views: NSView...) -> NSStackView {
        let row = NSStackView(views: views); row.orientation = .horizontal; row.spacing = 8; return row
    }

    fileprivate func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 610, height: 510),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "微信文件同步"; window.isReleasedWhenClosed = false; window.delegate = self; window.center()
        status.font = .systemFont(ofSize: 13, weight: .medium)
        rootLabel.isSelectable = true; rootLabel.font = .systemFont(ofSize: 12)
        accountInfo.isSelectable = true; accountInfo.textColor = .secondaryLabelColor
        accountPicker.target = self; accountPicker.action = #selector(selectAccount(_:))
        readOnly.target = self; readOnly.action = #selector(toggleReadOnly(_:))
        readOnly.toolTip = "复用已有归档时保持它的权限；此开关不会批量修改旧文件。"
        login.target = self; login.action = #selector(toggleLogin(_:))
        loginStatus.font = .systemFont(ofSize: 11); loginStatus.textColor = .secondaryLabelColor
        let note = NSTextField(wrappingLabelWithString: "原文件回到管理范围会自动恢复本程序清理的链接。另一份副本请使用“恢复文件关联”。删除实际文件会影响所有共享入口；本工具不备份内容。")
        note.textColor = .secondaryLabelColor; note.font = .systemFont(ofSize: 12)
        let stack = NSStackView(views: [status,
            NSTextField(labelWithString: "归档与跟踪目录"), rootLabel,
            row(button("选择／重新授权目录…", #selector(authorizeRoot(_:))), button("在访达中打开", #selector(openRoot(_:)))),
            row(NSTextField(labelWithString: "微信账号"), accountPicker, button("添加…", #selector(addAccount(_:)))),
            accountInfo,
            row(button("暂停／继续", #selector(pauseAccount(_:))), button("修改备注…", #selector(renameAccount(_:))), button("授权／恢复…", #selector(authorizeAccount(_:))), button("移除…", #selector(removeAccount(_:)))),
            readOnly, button("恢复文件关联…", #selector(restoreLinks(_:))), note,
            row(login, loginStatus)])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -18),
            rootLabel.widthAnchor.constraint(equalTo: stack.widthAnchor), status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            accountInfo.widthAnchor.constraint(equalTo: stack.widthAnchor), note.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        refreshLogin()
    }

    fileprivate var account: Account? { snapshot?.accounts.first { $0.id == selectedID } }

    fileprivate func render(_ value: ApplicationSnapshot?, error: String?) {
        if let value { snapshot = value; stateUnavailable = false; stateError = error }
        else if let error { stateUnavailable = true; stateError = error }
        status.stringValue = busy ? "正在处理…" : stateError ?? snapshot?.message ?? "状态库不可用"
        statusItem.button?.toolTip = status.stringValue
        rootLabel.stringValue = snapshot?.root?.path ?? "未选择；首次可自定义目录，下载只是默认建议"
        let previous = selectedID
        accountPicker.removeAllItems()
        for account in snapshot?.accounts ?? [] {
            accountPicker.addItem(withTitle: account.name + (account.removed ? "（已移除）" : account.intakeEnabled ? "" : "（暂停新增）"))
            accountPicker.lastItem?.representedObject = account.id
        }
        if let previous, let index = snapshot?.accounts.firstIndex(where: { $0.id == previous }) { accountPicker.selectItem(at: index) }
        selectedID = accountPicker.selectedItem?.representedObject as? String
        updateAccount()
        for button in actionButtons {
            button.isEnabled = !busy && snapshot != nil && !stateUnavailable && !terminating
            let action = button.action
            if [#selector(pauseAccount(_:)), #selector(renameAccount(_:)), #selector(authorizeAccount(_:)), #selector(removeAccount(_:)), #selector(restoreLinks(_:))].contains(where: { $0 == action }) {
                button.isEnabled = button.isEnabled && account != nil
                if account?.removed == true && action != #selector(authorizeAccount(_:)) && action != #selector(renameAccount(_:)) { button.isEnabled = false }
            }
            if action == #selector(openRoot(_:)) || action == #selector(addAccount(_:)) { button.isEnabled = button.isEnabled && snapshot?.root != nil }
            if action == #selector(pauseAccount(_:)) { button.title = account?.intakeEnabled == false ? "继续同步" : "暂停新增" }
            if action == #selector(authorizeRoot(_:)) { button.title = snapshot?.root == nil ? "选择归档目录…" : snapshot?.canChooseRoot == true ? "更改归档目录…" : "重新授权目录…" }
        }
        accountPicker.isEnabled = !busy && !stateUnavailable && !terminating
        readOnly.isEnabled = !busy && !stateUnavailable && account != nil && account?.removed == false && !terminating
        login.isEnabled = !busy && !stateUnavailable && !terminating
    }

    private func updateAccount() {
        if let account {
            accountInfo.stringValue = "\(account.source)\n新文件归档：\(account.archiveRelative)\n" + (account.removed ? "已移除：文件与记录保留，停止访问；可重新授权恢复管理。" : account.intakeEnabled ? "接纳新文件并维护已有链接" : "仅暂停新文件，继续维护已有链接")
            readOnly.state = snapshot?.readOnly[account.id] == false ? .off : .on
        } else { accountInfo.stringValue = "尚未添加账号。首次添加不会整理微信已有文件。"; readOnly.state = .on }
    }

    private func perform<T>(_ action: @escaping (ApplicationSession) throws -> T, then: ((T) -> Void)? = nil) {
        guard !busy, !terminating, !stateUnavailable else { return }
        busy = true; render(nil, error: nil)
        worker.perform(action) { [weak self] result in
            guard let self else { return }
            self.busy = false
            guard !self.terminating else { return }
            self.render(nil, error: nil)
            switch result {
            case .success(let value): if !self.stateUnavailable { then?(value) }
            case .failure(let error): _ = self.alert("操作未完成", String(describing: error))
            }
        }
    }

    private func alert(_ title: String, _ message: String, confirm: String? = nil) -> Bool {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: confirm ?? "好")
        if confirm != nil { alert.addButton(withTitle: "取消") }
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc fileprivate func showSettings(_ sender: Any?) { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); refreshLogin() }
    @objc private func quit(_ sender: Any?) { NSApp.terminate(nil) }
    @objc private func selectAccount(_ sender: Any?) { selectedID = accountPicker.selectedItem?.representedObject as? String; render(nil, error: nil) }

    @objc private func openRoot(_ sender: Any?) {
        guard !stateUnavailable, let root = snapshot?.root else { return }
        do {
            let lease = try securityScope(bookmark: root.bookmark, expected: root.url, identity: root.identity)
            defer { withExtendedLifetime(lease) {} }
            NSWorkspace.shared.open(lease.url)
        } catch { _ = alert("无法打开目录", String(describing: error)) }
    }

    @objc private func authorizeRoot(_ sender: Any?) {
        do {
            let existing = snapshot?.root
            let canChoose = snapshot?.canChooseRoot == true
            let url = try chooseDirectory(try existing?.url ?? defaultManagedRoot(), title: "归档与跟踪目录",
                message: existing == nil || canChoose ? "尚未绑定账号，可选择管理根目录；不会搬动已有文件。" : "请选择原管理根目录以重新授权。此版本不搬迁已有归档。", requireMatch: existing != nil && !canChoose)
            guard url.startAccessingSecurityScopedResource() else { throw SyncError.message("未获得目录授权") }
            let lease = DirectoryLease(url: url) { url.stopAccessingSecurityScopedResource() }
            let bookmark = try newBookmark(url)
            perform { session in defer { withExtendedLifetime(lease) {} }; try session.change { try AccountManager(repository: $0.accounts).configureRoot(url, bookmark: bookmark) } }
        } catch { _ = alert("目录未变更", String(describing: error)) }
    }

    @objc private func addAccount(_ sender: Any?) {
        guard snapshot?.root != nil else { _ = alert("先选择归档目录", "请选择保存并跟踪文件的管理根目录，再添加微信账号。"); return }
        do {
            let source = try selectSource()
            let name = try askAccountName(), bookmark = try newBookmark(source.url)
            perform { session in
                defer { withExtendedLifetime(source) {} }
                try session.change { store in
                    let root = try rootLease(store.accounts); defer { withExtendedLifetime(root) {} }
                    _ = try AccountManager(repository: store.accounts).add(source: source.url, name: name, bookmark: bookmark)
                }
            }
        } catch { _ = alert("未添加账号", String(describing: error)) }
    }

    @objc private func pauseAccount(_ sender: Any?) {
        guard let account, !account.removed else { return }
        perform { session in try session.change { try AccountManager(repository: $0.accounts).setPaused(account.id, paused: account.intakeEnabled) } }
    }

    @objc private func renameAccount(_ sender: Any?) {
        guard let account else { return }
        let alert = NSAlert(); alert.messageText = "修改备注"; alert.informativeText = "不会改名或搬动归档文件夹。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24)); field.stringValue = account.name
        alert.accessoryView = field; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue
        perform { session in try session.change { try AccountManager(repository: $0.accounts).rename(account.id, name: name) } }
    }

    @objc private func authorizeAccount(_ sender: Any?) {
        guard let account else { return }
        do {
            let source = try selectSource(suggested: account.sourceURL, matching: true), bookmark = try newBookmark(source.url)
            perform { session in
                defer { withExtendedLifetime(source) {} }
                try session.change { store in
                    let root = try rootLease(store.accounts); defer { withExtendedLifetime(root) {} }
                    try AccountManager(repository: store.accounts).reauthorize(account.id, source: source.url, bookmark: bookmark, restoring: account.removed)
                }
            }
        } catch { _ = alert("未更新授权", String(describing: error)) }
    }

    @objc private func removeAccount(_ sender: Any?) {
        guard let account, !account.removed,
              alert("移除 \(account.name)？", "文件、微信链接和记录保留，停止管理并清除当前源授权。", confirm: "移除管理") else { return }
        perform { session in try session.change { try $0.accounts.remove(account.id) } }
    }

    @objc private func toggleReadOnly(_ sender: Any?) {
        guard let account else { return }
        let enabled = readOnly.state == .on
        perform { session in try session.change { try $0.setReadOnly(account.id, enabled) } }
    }

    @objc private func restoreLinks(_ sender: Any?) {
        guard let account, !account.removed else { return }
        let entities = snapshot?.recoverable[account.id] ?? []
        guard !entities.isEmpty else { _ = alert("没有可手动恢复的记录", "原身份返回时会自动处理程序清理的链接。"); return }
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 490, height: 26))
        for entity in entities { picker.addItem(withTitle: entity.relative) }
        let alert = NSAlert(); alert.messageText = "选择失联文件"; alert.informativeText = "账号：\(account.name)\n下一步选择已经放回管理根目录的副本。"
        alert.accessoryView = picker; alert.addButton(withTitle: "选择副本…"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let entityID = entities[picker.indexOfSelectedItem].id
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.directoryURL = snapshot?.root?.url; panel.message = "请选择当前管理根目录内的副本；不会搬动或修改它。"
        guard panel.runModal() == .OK, let candidate = panel.url else { return }
        perform({ session -> RecoveryPreview in
            let root = try rootLease(session.store.accounts)
            let source = try securityScope(bookmark: account.sourceBookmark, expected: account.sourceURL, identity: account.sourceIdentity)
            defer { withExtendedLifetime((root, source)) {} }
            return try LinkRecovery(store: session.store).preview(accountID: account.id, entityID: entityID, file: candidate)
        }, then: { [weak self] preview in self?.confirmRecovery(preview, account: account) })
    }

    private func confirmRecovery(_ preview: RecoveryPreview, account: Account) {
        let alert = NSAlert(); alert.messageText = "恢复文件关联"
        alert.informativeText = "账号：\(account.name)\n原位置：\(preview.original.relative)\n所选：\(preview.candidate.path)\n大小：\(preview.info.size) 字节\n请选择需要恢复的来源。不备份文件内容。"
        var checkboxes: [NSButton] = []
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        for choice in preview.choices {
            let check = NSButton(checkboxWithTitle: "\(choice.source.originalName) · \(choice.source.relative)\n\(choice.skipReason ?? choice.comparison)", target: nil, action: nil)
            check.state = choice.skipReason == nil ? .on : .off; check.isEnabled = choice.skipReason == nil
            check.title = choice.source.originalName
            let detail = NSTextField(wrappingLabelWithString: "\(choice.source.relative)\n\(choice.skipReason ?? choice.comparison)")
            detail.font = .systemFont(ofSize: 11); detail.textColor = .secondaryLabelColor
            detail.widthAnchor.constraint(equalToConstant: 480).isActive = true
            let group = NSStackView(views: [check, detail]); group.orientation = .vertical; group.alignment = .leading; group.spacing = 3
            checkboxes.append(check); stack.addArrangedSubview(group)
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 510, height: min(240, max(50, preview.choices.count * 52))))
        scroll.hasVerticalScroller = true
        stack.frame = NSRect(x: 0, y: 0, width: 490, height: max(50, stack.fittingSize.height))
        scroll.documentView = stack; alert.accessoryView = scroll
        alert.addButton(withTitle: "恢复选中关联"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let selected = Set(zip(preview.choices, checkboxes).filter { $0.1.state == .on && $0.1.isEnabled }.map { $0.0.source.id })
        guard !selected.isEmpty else { return }
        perform({ session -> [ScanIssue] in
            let root = try rootLease(session.store.accounts)
            let source = try securityScope(bookmark: account.sourceBookmark, expected: account.sourceURL, identity: account.sourceIdentity)
            defer { withExtendedLifetime((root, source)) {} }
            return try LinkRecovery(store: session.store).apply(preview, sourceIDs: selected)
        }, then: { [weak self] issues in
            _ = self?.alert("恢复结果", "完成 \(selected.count - issues.count) 条，未完成 \(issues.count) 条。\n" + issues.map { "\($0.relative)：\($0.message)" }.joined(separator: "\n"))
        })
    }

    private func refreshLogin() {
        #if DESKTOP_TESTING
        login.state = .off; loginStatus.stringValue = "界面测试：未操作登录项"
        return
        #else
        let status = SMAppService.mainApp.status
        login.state = status == .enabled || status == .requiresApproval ? .on : .off
        switch status {
        case .enabled: loginStatus.stringValue = "已启用；退出后本次不再同步"
        case .requiresApproval: loginStatus.stringValue = "请在系统设置的登录项中允许"
        case .notRegistered: loginStatus.stringValue = "未启用"
        default: loginStatus.stringValue = "服务不可用，请确认应用位于 Applications"
        }
        #endif
    }

    @objc private func toggleLogin(_ sender: Any?) {
        do {
            if login.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { _ = alert("登录启动未更新", String(describing: error)) }
        refreshLogin()
    }
}

func runDesktop() {
    let app = NSApplication.shared
    let controller = DesktopController()
    app.delegate = controller
    withExtendedLifetime(controller) { app.run() }
}

#if DESKTOP_TESTING
/// Compiled only by test-desktop.sh; no real app support, bookmarks, login item or source access.
func desktopPreviewTest(output: URL, manual: Bool = false, autoClose: Bool = false) throws {
    let temporary = try canonicalDirectory(FileManager.default.temporaryDirectory).appendingPathComponent("wechat-ui-tests-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let root = temporary.appendingPathComponent("自定义资料")
    let source = temporary.appendingPathComponent("假账号/msg/file")
    for url in [root, source] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    let session = try ApplicationSession(database: temporary.appendingPathComponent("state.sqlite"),
        rootAuthorization: { DirectoryLease(url: $0.url) }, sourceAuthorization: { DirectoryLease(url: $0.sourceURL) })
    let manager = AccountManager(repository: session.store.accounts)
    try manager.configureRoot(root, bookmark: nil)
    let account = try manager.add(source: source, name: "工作微信（临时样本）", bookmark: nil)
    try session.scan()
    let controller = DesktopController()
    NSApp.setActivationPolicy(.accessory)
    controller.makeMenu(); controller.makeWindow(); controller.render(try session.snapshot(), error: nil)
    if manual {
        controller.prepareManualPreview()
        NSApp.delegate = controller
        controller.showSettings(nil)
        if autoClose { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) } }
        NSApp.run()
        NSApp.delegate = nil
        controller.window.close()
        print("手动预览已退出；临时样本正在清理，未启动真实同步。")
        return
    }
    controller.window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    controller.window.contentView!.layoutSubtreeIfNeeded()
    controller.window.display()
    controller.window.contentView!.display()
    guard controller.account?.id == account.id, controller.readOnly.state == .on,
          !controller.applicationShouldTerminateAfterLastWindowClosed(NSApp) else { throw SyncError.message("设置窗口状态或生命周期不符") }
    let content = controller.window.contentView!
    guard let stack = content.subviews.first as? NSStackView else { throw SyncError.message("设置布局不存在") }
    guard stack.frame.minY >= 0, stack.frame.maxY <= content.bounds.height,
          stack.arrangedSubviews.allSatisfy({ $0.frame.minY >= -1 && $0.frame.maxY <= stack.bounds.height + 1 }) else {
        throw SyncError.message("设置内容超出窗口范围")
    }
    try content.dataWithPDF(inside: content.bounds).write(to: output.deletingPathExtension().appendingPathExtension("pdf"))
    // Native layer-backed controls aren't represented by NSView.cacheDisplay on newer macOS.
    // Capture only this fixture window when existing screen capture permission permits it.
    if CGPreflightScreenCaptureAccess() {
        let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-l", String(controller.window.windowNumber), output.path]
        try capture.run(); capture.waitUntilExit()
        guard capture.terminationStatus == 0 else { throw SyncError.message("临时窗口捕获失败") }
    } else {
        print("未请求屏幕录制权限：已保存 PDF 文字布局；原生控件外观留待人工验收")
    }
    controller.window.performClose(nil)
    guard !controller.window.isVisible else { throw SyncError.message("设置窗口未关闭") }
    controller.showSettings(nil)
    guard controller.window.isVisible else { throw SyncError.message("设置窗口无法重新打开") }
    controller.reviewReadFailureState(try session.snapshot())
    controller.window.close()
    try desktopWorkerReviewTest(temporary: temporary)
    print("临时样本设置界面、自定义目录、账号状态和关闭／重开检查通过")
}
fileprivate extension DesktopController {
    func prepareManualPreview() {
        manualPreviewOnly = true
        window.title = "微信文件同步 · 临时样本预览"
        status.stringValue = "仅检查界面：不运行同步，不授权目录，不修改登录项。"
        statusItem.button?.toolTip = "临时样本界面预览"
        // Detach actions as well as disabling controls, so no chooser or service API can run.
        for button in actionButtons + [readOnly, login] { button.isEnabled = false; button.target = nil; button.action = nil }
        accountPicker.isEnabled = false; accountPicker.target = nil; accountPicker.action = nil
        statusItem.menu?.autoenablesItems = false
        if let item = statusItem.menu?.items.first(where: { $0.action == #selector(openRoot(_:)) }) {
            item.isEnabled = false; item.target = nil; item.action = nil
        }
        precondition(actionButtons.allSatisfy { !$0.isEnabled && $0.action == nil })
        precondition(!login.isEnabled && login.action == nil)
    }

    func reviewReadFailureState(_ good: ApplicationSnapshot) {
        render(nil, error: "状态读取失败：临时注入")
        precondition(status.stringValue.contains("状态读取失败") && !readOnly.isEnabled)
        precondition(actionButtons.allSatisfy { !$0.isEnabled })
        render(nil, error: nil)
        precondition(status.stringValue.contains("状态读取失败"), "本地刷新不能将读库错误变回旧的正常状态")
        render(good, error: nil)
        precondition(readOnly.isEnabled && !status.stringValue.contains("状态读取失败"))
    }
}

private func desktopWorkerReviewTest(temporary: URL) throws {
    let root = temporary.appendingPathComponent("worker-root")
    let source = temporary.appendingPathComponent("worker-source")
    for url in [root, source] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    let database = temporary.appendingPathComponent("worker-state/state.sqlite")
    let worker = DesktopWorker(makeSession: {
        let session = try ApplicationSession(database: database, rootAuthorization: { DirectoryLease(url: $0.url) }, sourceAuthorization: { DirectoryLease(url: $0.sourceURL) })
        let manager = AccountManager(repository: session.store.accounts)
        try manager.configureRoot(root, bookmark: nil)
        _ = try manager.add(source: source, name: "queue-fixture", bookmark: nil)
        return session
    }, scanInterval: 60)
    var opened = false, readFailed = false, corruptCompleted = false
    worker.update = { value, error in
        if value != nil { opened = true }
        if value == nil && error?.contains("状态读取失败") == true { readFailed = true }
    }
    func wait(_ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        throw SyncError.message("串行会话隔离测试等待超时")
    }
    worker.start()
    try wait { opened }
    worker.perform({ session in try session.store.accounts.execute("DROP TABLE account_settings") }) { _ in corruptCompleted = true }
    try wait { corruptCompleted }
    guard readFailed else { throw SyncError.message("读库错误被隐藏为旧的正常状态") }
    let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    var actionCompleted = false, stopped = false
    worker.perform({ session in
        try session.store.accounts.execute("CREATE TABLE account_settings(account_id TEXT PRIMARY KEY REFERENCES accounts(id), read_only INTEGER NOT NULL CHECK(read_only IN (0,1)))")
        started.signal()
        guard release.wait(timeout: .now() + 5) == .success else { throw SyncError.message("测试释放超时") }
        return true
    }) { result in if case .success = result { actionCompleted = true } }
    try wait { started.wait(timeout: .now()) == .success }
    worker.stop { stopped = true }
    precondition(!stopped)
    release.signal()
    try wait { stopped }
    guard actionCompleted else { throw SyncError.message("退出没有等待已排队动作") }
    let fresh = try ApplicationSession(database: database, rootAuthorization: { DirectoryLease(url: $0.url) }, sourceAuthorization: { DirectoryLease(url: $0.sourceURL) })
    withExtendedLifetime(fresh) {}
    print("临时串行会话：读库错误明确报告、退出等待动作并释放写锁检查通过")
}

#endif
