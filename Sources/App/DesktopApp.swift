import Foundation
import AppKit
import ServiceManagement
#if DESKTOP_TESTING
import ScreenCaptureKit
#endif

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
                    let lease = try sourceScope(account)
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
    private let rootLabel = NSTextField(wrappingLabelWithString: "尚未选择文件夹")
    private let accountPicker = NSPopUpButton()
    private let accountInfo = NSTextField(wrappingLabelWithString: "添加账号后，只同步之后收到的新文件。")
    fileprivate let readOnly = NSSwitch()
    fileprivate let syncSwitch = NSSwitch()
    private let more = NSPopUpButton(frame: .zero, pullsDown: true)
    private var accountPage: NSStackView!
    private var generalPage: NSStackView!
    private var navigation: [NSButton] = []
    private let pageTitle = NSTextField(labelWithString: "账号与文件")
    private var pageScroll: NSScrollView!
    private let login = NSSwitch()
    private let loginStatus = NSTextField(labelWithString: "")
    private var actionButtons: [NSButton] = []
    private var snapshot: ApplicationSnapshot?
    private var busy = false
    private var selectedID: String?
    private var terminating = false
    private var receivedInitialState = false
    private var hasShownSettings = false
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
        for (title, selector) in [("设置…", #selector(showSettings(_:))), ("打开文件保存位置", #selector(openRoot(_:))), ("退出", #selector(quit(_:)))] {
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
        button.bezelStyle = .roundRect; button.controlSize = .small; button.font = .systemFont(ofSize: 12)
        button.setContentHuggingPriority(.required, for: .horizontal)
        switch action {
        case #selector(pauseAccount(_:)): button.toolTip = "暂停只影响新文件；已保存文件的改名、移动仍会更新到微信。"
        case #selector(removeAccount(_:)): button.toolTip = "停止同步和文件位置更新，保留文件，不删除微信账号。"
        case #selector(restoreLinks(_:)): button.toolTip = "原文件放回保存位置后会自动恢复。找回另一份副本时，可在这里选择。"
        case #selector(authorizeRoot(_:)): button.toolTip = "选择保存文件的位置；已有账号时只能重新选择原文件夹以恢复访问。"
        case #selector(addAccount(_:)): button.toolTip = "选择一个微信账号的文件夹，只同步之后收到的新文件。"
        default: break
        }
        actionButtons.append(button); return button
    }

    private func row(_ views: NSView...) -> NSStackView {
        let row = NSStackView(views: views); row.orientation = .horizontal; row.spacing = 8; row.alignment = .centerY; row.distribution = .fill; return row
    }

    private func column(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
        return stack
    }

    private func spacer() -> NSView {
        let view = NSView(); view.setContentHuggingPriority(.defaultLow, for: .horizontal); return view
    }

    private func group(_ rows: [NSView]) -> NSView {
        let box = SettingsSurface(.group)
        let stack = column([], spacing: 0); stack.translatesAutoresizingMaskIntoConstraints = false
        for (index, view) in rows.enumerated() {
            if index > 0 {
                let separator = NSBox(); separator.boxType = .separator
                separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
                stack.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            let inset = NSView(); view.translatesAutoresizingMaskIntoConstraints = false; inset.addSubview(view)
            stack.addArrangedSubview(inset)
            NSLayoutConstraint.activate([inset.widthAnchor.constraint(equalTo: stack.widthAnchor),
                view.leadingAnchor.constraint(equalTo: inset.leadingAnchor), view.trailingAnchor.constraint(equalTo: inset.trailingAnchor),
                view.topAnchor.constraint(equalTo: inset.topAnchor, constant: 13), view.bottomAnchor.constraint(equalTo: inset.bottomAnchor, constant: -13),
                inset.heightAnchor.constraint(greaterThanOrEqualToConstant: 52)])
        }
        box.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: box.topAnchor), stack.bottomAnchor.constraint(equalTo: box.bottomAnchor)])
        return box
    }

    private func section(_ title: String, _ content: NSView, note: String? = nil) -> NSStackView {
        let heading = NSTextField(labelWithString: title); heading.font = .systemFont(ofSize: 12, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        let stack = column([heading, content], spacing: 10)
        content.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        if let note {
            let label = NSTextField(wrappingLabelWithString: note); label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor; stack.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func settingRow(_ title: String, detail: String? = nil, control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 13)
        var labels: [NSView] = [label]
        if let detail {
            let hint = NSTextField(wrappingLabelWithString: detail); hint.font = .systemFont(ofSize: 11)
            hint.textColor = .secondaryLabelColor; labels.append(hint)
        }
        let text = column(labels, spacing: 3)
        if let toggle = control as? NSSwitch { toggle.controlSize = .small; toggle.setAccessibilityLabel(title) }
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        return row(text, spacer(), control)
    }

    fileprivate func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 880, height: 680)
        window.title = "微信文件同步 · 设置"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false; window.delegate = self; window.center()
        window.backgroundColor = .textBackgroundColor
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        for label in [rootLabel, accountInfo] {
            label.isSelectable = true; label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor
            label.maximumNumberOfLines = 1; label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        accountPicker.target = self; accountPicker.action = #selector(selectAccount(_:))
        accountPicker.controlSize = .small; accountPicker.font = .systemFont(ofSize: 12)
        accountPicker.widthAnchor.constraint(equalToConstant: 260).isActive = true
        readOnly.target = self; readOnly.action = #selector(toggleReadOnly(_:))
        readOnly.toolTip = "只影响以后新保存的文件；复用已有文件时保留原权限。"
        syncSwitch.target = self; syncSwitch.action = #selector(pauseAccount(_:))
        syncSwitch.toolTip = "关闭后不再保存新文件；已保存文件的改名、移动仍会更新到微信。"
        login.target = self; login.action = #selector(toggleLogin(_:))
        loginStatus.font = .systemFont(ofSize: 11); loginStatus.textColor = .secondaryLabelColor
        more.bezelStyle = .roundRect; more.controlSize = .small; more.font = .systemFont(ofSize: 12)
        more.addItem(withTitle: "更多操作")
        for (title, action) in [("恢复文件关联…", #selector(restoreLinks(_:))), ("重新选择微信文件夹…", #selector(authorizeAccount(_:))), ("停止管理此账号…", #selector(removeAccount(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; more.menu?.addItem(item)
        }
        more.menu?.autoenablesItems = false
        let accountGroup = group([settingRow("当前账号", control: accountPicker),
            row(button("添加账号…", #selector(addAccount(_:))), more, spacer())])
        let syncGroup = group([settingRow("同步新文件", detail: "关闭后，仍会更新已有文件的位置。", control: syncSwitch),
            settingRow("新文件只读", detail: "编辑时，建议另存为新文件。", control: readOnly)])
        let folderTitle = NSTextField(labelWithString: "账号文件夹"); folderTitle.font = .systemFont(ofSize: 13)
        let folderContent = column([folderTitle, accountInfo], spacing: 5)
        accountInfo.widthAnchor.constraint(equalTo: folderContent.widthAnchor).isActive = true
        let folderGroup = group([folderContent, row(button("在 Finder 中打开", #selector(openAccountFolder(_:))), spacer())])
        accountPage = column([section("微信账号", accountGroup), section("文件同步", syncGroup),
            section("文件位置", folderGroup, note: "可在保存范围内整理文件；本工具不备份内容。"), status], spacing: 28)
        let rootTitle = NSTextField(labelWithString: "文件保存位置"); rootTitle.font = .systemFont(ofSize: 13)
        let rootContent = column([rootTitle, rootLabel], spacing: 5)
        rootLabel.widthAnchor.constraint(equalTo: rootContent.widthAnchor).isActive = true
        let rootGroup = group([rootContent,
            row(button("选择保存文件夹…", #selector(authorizeRoot(_:))), button("在 Finder 中打开", #selector(openRoot(_:))), spacer())])
        let loginText = column([NSTextField(labelWithString: "登录时启动"), loginStatus], spacing: 3)
        login.controlSize = .small; login.setAccessibilityLabel("登录时启动")
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版"
        let versionLabel = NSTextField(labelWithString: version); versionLabel.font = .systemFont(ofSize: 12); versionLabel.textColor = .secondaryLabelColor
        generalPage = column([section("存储", rootGroup, note: "不同账号分别保存，改名或移动后仍可从微信打开。"),
            section("启动", group([row(loginText, spacer(), login)])),
            section("关于", group([settingRow("微信文件同步", detail: "保存微信新文件，维护原消息中的文件关联。", control: versionLabel)]))], spacing: 28)
        let side = SettingsSurface(.sidebar)
        let sideStack = column([], spacing: 6); sideStack.translatesAutoresizingMaskIntoConstraints = false
        for (index, title) in ["账号与文件", "通用"].enumerated() {
            let button = SettingsNavigationButton(title: title, symbol: index == 0 ? "person.crop.circle" : "gearshape.fill", target: self, action: #selector(changePage(_:)))
            button.tag = index; button.heightAnchor.constraint(equalToConstant: 38).isActive = true
            navigation.append(button); sideStack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: sideStack.widthAnchor).isActive = true
        }
        side.addSubview(sideStack)
        let body = SettingsSurface(.content)
        pageTitle.font = .systemFont(ofSize: 14, weight: .semibold); pageTitle.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(pageTitle)
        let headerLine = NSBox(); headerLine.boxType = .separator; headerLine.translatesAutoresizingMaskIntoConstraints = false; body.addSubview(headerLine)
        pageScroll = NSScrollView(); pageScroll.drawsBackground = false; pageScroll.hasVerticalScroller = true
        pageScroll.autohidesScrollers = true; pageScroll.borderType = .noBorder
        pageScroll.translatesAutoresizingMaskIntoConstraints = false; body.addSubview(pageScroll)
        let document = SettingsDocument(); document.translatesAutoresizingMaskIntoConstraints = false
        pageScroll.documentView = document
        for page in [accountPage!, generalPage!] {
            page.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(page)
            NSLayoutConstraint.activate([page.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 32),
                page.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -32),
                page.topAnchor.constraint(equalTo: document.topAnchor, constant: 28)])
            for view in page.arrangedSubviews { view.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true }
        }
        // Only the selected page sets the scrollable height.
        accountPage.identifier = NSUserInterfaceItemIdentifier("accountPage")
        generalPage.identifier = NSUserInterfaceItemIdentifier("generalPage")
        let outer = row(side, body); outer.spacing = 0; outer.alignment = .height
        outer.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(outer)
        NSLayoutConstraint.activate([outer.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor), outer.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            outer.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            window.contentView!.widthAnchor.constraint(greaterThanOrEqualToConstant: 880),
            window.contentView!.heightAnchor.constraint(greaterThanOrEqualToConstant: 680), side.widthAnchor.constraint(equalToConstant: 200),
            body.widthAnchor.constraint(equalTo: window.contentView!.widthAnchor, constant: -200),
            sideStack.leadingAnchor.constraint(equalTo: side.leadingAnchor, constant: 10), sideStack.trailingAnchor.constraint(equalTo: side.trailingAnchor, constant: -10),
            sideStack.topAnchor.constraint(equalTo: side.topAnchor, constant: 58),
            pageTitle.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 32), pageTitle.topAnchor.constraint(equalTo: body.topAnchor, constant: 18),
            headerLine.leadingAnchor.constraint(equalTo: body.leadingAnchor), headerLine.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            headerLine.topAnchor.constraint(equalTo: body.topAnchor, constant: 53), headerLine.heightAnchor.constraint(equalToConstant: 1),
            pageScroll.topAnchor.constraint(equalTo: headerLine.bottomAnchor), pageScroll.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            pageScroll.trailingAnchor.constraint(equalTo: body.trailingAnchor), pageScroll.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            document.widthAnchor.constraint(equalTo: pageScroll.contentView.widthAnchor)])
        showPage(0); refreshLogin()
    }

    private var pageHeight: NSLayoutConstraint?
    private func showPage(_ index: Int) {
        pageTitle.stringValue = index == 0 ? "账号与文件" : "通用"
        pageHeight?.isActive = false
        let page = index == 0 ? accountPage! : generalPage!
        pageHeight = page.bottomAnchor.constraint(equalTo: page.superview!.bottomAnchor, constant: -24)
        pageHeight?.isActive = true
        accountPage.isHidden = index != 0; generalPage.isHidden = index != 1
        for button in navigation { button.state = button.tag == index ? .on : .off }
        pageScroll.contentView.scroll(to: .zero)
    }
    @objc private func changePage(_ sender: NSButton) { showPage(sender.tag) }

    fileprivate var account: Account? { snapshot?.accounts.first { $0.id == selectedID } }

    fileprivate func render(_ value: ApplicationSnapshot?, error: String?) {
        if let value { snapshot = value; stateUnavailable = false; stateError = error }
        else if let error { stateUnavailable = true; stateError = error }
        status.stringValue = busy ? "正在处理…" : stateError ?? snapshot?.message ?? "状态库不可用"
        statusItem.button?.toolTip = status.stringValue
        rootLabel.stringValue = snapshot?.root?.path ?? "请选择用于保存微信文件的文件夹"
        rootLabel.toolTip = snapshot?.root.map { "\($0.path)\n程序只在这个文件夹内查找改名或移动后的文件。" }
        let previous = selectedID
        let accounts = snapshot?.accounts ?? []
        let titles = accounts.map { WeChatDirectories.displayName(source: $0.sourceURL) + ($0.removed ? "（已停止管理）" : "") }
        let menuChanged = accountPicker.itemArray.count != accounts.count || zip(accountPicker.itemArray, accounts).contains {
            $0.0.representedObject as? String != $0.1.id
        } || accountPicker.itemTitles != titles
        // Periodic status updates must not replace a menu while the user is selecting an account.
        if menuChanged {
            accountPicker.removeAllItems()
            for (account, title) in zip(accounts, titles) {
                accountPicker.addItem(withTitle: title)
                accountPicker.lastItem?.representedObject = account.id
            }
            if let previous, let index = accounts.firstIndex(where: { $0.id == previous }) { accountPicker.selectItem(at: index) }
        }
        selectedID = accountPicker.selectedItem?.representedObject as? String
        updateAccount()
        for button in actionButtons {
            button.isEnabled = !busy && snapshot != nil && !stateUnavailable && !terminating
            let action = button.action
            if action == #selector(openAccountFolder(_:)) { button.isEnabled = button.isEnabled && account != nil && account?.removed == false }
            if action == #selector(openRoot(_:)) { button.isEnabled = button.isEnabled && snapshot?.root != nil }
            if action == #selector(authorizeRoot(_:)) {
                button.title = snapshot?.root == nil ? "选择保存文件夹…" : snapshot?.canChooseRoot == true ? "更改保存位置…" : "重新选择保存文件夹…"
            }
        }
        accountPicker.isEnabled = !busy && !stateUnavailable && !terminating && !(snapshot?.accounts.isEmpty ?? true)
        let editable = !busy && !stateUnavailable && !terminating
        syncSwitch.isEnabled = editable && account != nil && account?.removed == false
        more.isEnabled = editable && account != nil
        for item in more.menu?.items.dropFirst() ?? [] {
            item.isEnabled = editable && account != nil
            if item.action == #selector(authorizeAccount(_:)) {
                item.title = account?.removed == true ? "恢复管理此账号…" : "重新选择微信文件夹…"
            } else {
                item.isEnabled = item.isEnabled && account?.removed == false
                if item.action == #selector(restoreLinks(_:)) { item.isEnabled = item.isEnabled && !(snapshot?.recoverable[account?.id ?? ""] ?? []).isEmpty }
            }
        }
        readOnly.isEnabled = !busy && !stateUnavailable && account != nil && account?.removed == false && !terminating
        login.isEnabled = !busy && !stateUnavailable && !terminating
    }

    private func updateAccount() {
        if let account {
            accountInfo.stringValue = (snapshot?.root?.url.appendingPathComponent(account.archiveRelative).path ?? account.archiveRelative)
            accountInfo.toolTip = "可在整个保存位置内查找改名或移动后的文件。\n微信文件夹：\(account.source)"
            accountPicker.toolTip = account.source
            syncSwitch.state = account.intakeEnabled && !account.removed ? .on : .off
            readOnly.state = snapshot?.readOnly[account.id] == false ? .off : .on
        } else {
            accountInfo.stringValue = "先添加微信账号，再选择文件保存位置。"
            accountInfo.toolTip = nil; accountPicker.toolTip = nil; syncSwitch.state = .off; readOnly.state = .on
        }
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

    @objc fileprivate func showSettings(_ sender: Any?) {
        window.makeKeyAndOrderFront(nil)
        if !hasShownSettings {
            window.setContentSize(NSSize(width: 960, height: 720))
            window.center(); hasShownSettings = true
        }
        NSApp.activate(ignoringOtherApps: true); refreshLogin()
    }
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
            let url = try chooseDirectory(try existing?.url ?? defaultManagedRoot(), title: "文件保存位置",
                message: existing == nil || canChoose ? "请选择用于保存微信新文件的文件夹。" : "请选择原来的保存文件夹，恢复访问权限；不会搬动文件。", requireMatch: existing != nil && !canChoose)
            guard url.startAccessingSecurityScopedResource() else { throw SyncError.message("未获得目录授权") }
            let lease = DirectoryLease(url: url) { url.stopAccessingSecurityScopedResource() }
            let bookmark = try newBookmark(url)
            perform { session in defer { withExtendedLifetime(lease) {} }; try session.change { try AccountManager(repository: $0.accounts).configureRoot(url, bookmark: bookmark) } }
        } catch { _ = alert("目录未变更", String(describing: error)) }
    }

    @objc private func openAccountFolder(_ sender: Any?) {
        guard !stateUnavailable, let account, let root = snapshot?.root else { return }
        do {
            let lease = try securityScope(bookmark: root.bookmark, expected: root.url, identity: root.identity)
            defer { withExtendedLifetime(lease) {} }
            let folder = try checkedFile(root.url, relative: account.archiveRelative)
            guard try readFileInfo(folder.path)?.identity == account.archiveIdentity else {
                throw SyncError.message("账号初始文件夹已移动或不存在，请在通用中打开文件保存位置查找。")
            }
            NSWorkspace.shared.open(folder)
        } catch { _ = alert("无法打开账号文件夹", String(describing: error)) }
    }

    @objc private func addAccount(_ sender: Any?) {
        do {
            // Reuse only a live parent grant. Legacy exact-source bookmarks require choosing the parent once.
            var grant: DirectoryLease?
            for account in snapshot?.accounts ?? [] where !account.removed {
                if let bookmark = account.sourceBookmark, let existing = try? bookmarkScope(bookmark),
                   existing.url.lastPathComponent == "xwechat_files" { grant = existing; break }
            }
            let parent = try grant ?? selectWeChatRoot()
            perform({ _ in try WeChatDirectories.discover(in: parent.url) }, then: { [weak self] candidates in
                guard let self else { return }
                do {
                    let choice = try chooseDiscoveredAccount(candidates, registered: self.snapshot?.accounts ?? [])
                    try self.finishAdding(choice, parent: parent)
                } catch { _ = self.alert("未添加账号", String(describing: error)) }
            })
        } catch { _ = alert("未添加账号", String(describing: error)) }
    }

    private func finishAdding(_ choice: DiscoveredAccount, parent: DirectoryLease) throws {
        let selectedRoot: DirectoryLease?
        if snapshot?.root == nil {
            let url = try chooseDirectory(defaultManagedRoot(), title: "选择文件保存位置",
                message: "为 \(choice.name) 选择保存位置。以后添加的账号也会分别保存在这里。", requireMatch: false)
            guard url.startAccessingSecurityScopedResource() else { throw SyncError.message("未获得文件夹访问许可") }
            selectedRoot = DirectoryLease(url: url) { url.stopAccessingSecurityScopedResource() }
        } else { selectedRoot = nil }
        guard let destination = selectedRoot?.url ?? snapshot?.root?.url else { throw SyncError.message("请重新选择文件保存位置") }
        guard alert("添加 \(choice.name)？", "文件保存位置：\n\(destination.path)\n\n将创建独立账号文件夹，同名位置会自动避让。已有微信文件留在原处。", confirm: "开始同步") else { return }
        let sourceBookmark = try newBookmark(parent.url)
        let destinationBookmark = try selectedRoot.map { try newBookmark($0.url) }
        perform({ session -> String in
            defer { withExtendedLifetime((parent, selectedRoot)) {} }
            var addedID = ""
            try session.change { store in
                let source = try WeChatDirectories.authorizedSource(grant: parent.url, expected: choice.source, identity: choice.identity)
                let manager = AccountManager(repository: store.accounts)
                if let selectedRoot {
                    _ = try initialState(source: source, managedRoot: canonicalDirectory(selectedRoot.url))
                    try manager.configureRoot(selectedRoot.url, bookmark: destinationBookmark)
                }
                let root = try rootLease(store.accounts); defer { withExtendedLifetime(root) {} }
                addedID = try manager.add(source: source, name: choice.name, bookmark: sourceBookmark).id
            }
            return addedID
        }, then: { [weak self] id in
            guard let self else { return }
            if let index = self.accountPicker.itemArray.firstIndex(where: { $0.representedObject as? String == id }) {
                self.accountPicker.selectItem(at: index)
            }
            self.selectedID = id; self.render(nil, error: nil)
        })
    }

    @objc private func pauseAccount(_ sender: Any?) {
        guard let account, !account.removed else { return }
        let paused = syncSwitch.state != .on
        perform { session in try session.change { try AccountManager(repository: $0.accounts).setPaused(account.id, paused: paused) } }
    }

    @objc private func authorizeAccount(_ sender: Any?) {
        guard let account else { return }
        do {
            let parent = account.sourceURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let source = try selectWeChatRoot(suggested: parent), bookmark = try newBookmark(source.url)
            if account.removed && !alert("恢复管理此账号？", "将沿用原记录与文件夹，不重新建立历史基线。", confirm: "恢复管理") { return }
            perform { session in
                defer { withExtendedLifetime(source) {} }
                try session.change { store in
                    let root = try rootLease(store.accounts); defer { withExtendedLifetime(root) {} }
                    let sourceURL = try WeChatDirectories.authorizedSource(grant: source.url, expected: account.sourceURL, identity: account.sourceIdentity)
                    try AccountManager(repository: store.accounts).reauthorize(account.id, source: sourceURL, bookmark: bookmark, restoring: account.removed)
                }
            }
        } catch { _ = alert("未更新授权", String(describing: error)) }
    }

    @objc private func removeAccount(_ sender: Any?) {
        guard let account, !account.removed,
              alert("停止管理“\(WeChatDirectories.displayName(source: account.sourceURL))”？", "保留已保存的文件。此后不再同步新文件，也不再更新微信中的文件位置。", confirm: "停止管理") else { return }
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
        guard !entities.isEmpty else { _ = alert("没有需要重新选择文件的记录", "原文件放回保存位置后，程序会自动恢复它在微信中的打开位置。"); return }
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 490, height: 26))
        for entity in entities { picker.addItem(withTitle: entity.relative) }
        let alert = NSAlert(); alert.messageText = "哪个微信文件打不开？"; alert.informativeText = "账号：\(account.name)\n选择原来的记录，下一步再选择你找回的文件。"
        alert.accessoryView = picker; alert.addButton(withTitle: "选择找回的文件…"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let entityID = entities[picker.indexOfSelectedItem].id
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.directoryURL = snapshot?.root?.url; panel.message = "请选择已放入保存文件夹的文件。不会搬动或修改它。"
        guard panel.runModal() == .OK, let candidate = panel.url else { return }
        perform({ session -> RecoveryPreview in
            let root = try rootLease(session.store.accounts)
            let source = try sourceScope(account)
            defer { withExtendedLifetime((root, source)) {} }
            return try LinkRecovery(store: session.store).preview(accountID: account.id, entityID: entityID, file: candidate)
        }, then: { [weak self] preview in self?.confirmRecovery(preview, account: account) })
    }

    private func confirmRecovery(_ preview: RecoveryPreview, account: Account) {
        let alert = NSAlert(); alert.messageText = "让微信重新打开这个文件"
        alert.informativeText = "账号：\(account.name)\n原位置：\(preview.original.relative)\n所选：\(preview.candidate.path)\n大小：\(preview.info.size) 字节\n勾选要恢复的微信文件记录。"
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
        alert.addButton(withTitle: "确认使用此文件"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let selected = Set(zip(preview.choices, checkboxes).filter { $0.1.state == .on && $0.1.isEnabled }.map { $0.0.source.id })
        guard !selected.isEmpty else { return }
        perform({ session -> [ScanIssue] in
            let root = try rootLease(session.store.accounts)
            let source = try sourceScope(account)
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
        case .enabled: loginStatus.stringValue = "下次登录时自动启动"
        case .requiresApproval: loginStatus.stringValue = "还需在系统设置的“登录项”中允许"
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
func desktopPreviewTest(output: URL, manual: Bool = false, autoClose: Bool = false, captureRequested: Bool = false) throws {
    let temporary = try canonicalDirectory(FileManager.default.temporaryDirectory).appendingPathComponent("wechat-ui-tests-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let root = temporary.appendingPathComponent("自定义资料")
    let source = temporary.appendingPathComponent("xwechat_files/sample_account_2070/msg/file")
    for url in [root, source] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    let session = try ApplicationSession(database: temporary.appendingPathComponent("state.sqlite"),
        rootAuthorization: { DirectoryLease(url: $0.url) }, sourceAuthorization: { DirectoryLease(url: $0.sourceURL) })
    let manager = AccountManager(repository: session.store.accounts)
    try manager.configureRoot(root, bookmark: nil)
    let account = try manager.add(source: source, name: "sample_account_2070", bookmark: nil)
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
    controller.showSettings(nil)
    NSApp.activate(ignoringOtherApps: true)
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    controller.window.contentView!.layoutSubtreeIfNeeded()
    controller.window.display()
    controller.window.contentView!.display()
    guard controller.account?.id == account.id, controller.readOnly.state == .on,
          !controller.applicationShouldTerminateAfterLastWindowClosed(NSApp) else { throw SyncError.message("设置窗口状态或生命周期不符") }
    let content = controller.window.contentView!
    guard abs(content.bounds.width - 960) < 1, abs(content.bounds.height - 720) < 1 else { throw SyncError.message("首次显示没有保持默认窗口尺寸") }
    try controller.reviewAccountSelection()
    try controller.reviewSettingsLayout()
    try content.dataWithPDF(inside: content.bounds).write(to: output.deletingPathExtension().appendingPathExtension("pdf"))
    try controller.writeGeneralPreview(output.deletingPathExtension().appendingPathExtension("general.pdf"))
    // Native layer-backed controls aren't represented by NSView.cacheDisplay on newer macOS.
    // Capture only this fixture window when existing screen capture permission permits it.
    if captureRequested {
        if #available(macOS 14.4, *) {
            try controller.captureOwnWindow(output)
            try controller.captureGeneralSettings(output.deletingPathExtension().appendingPathExtension("general.png"))
        } else { throw SyncError.message("无屏幕录制许可的窗口截图需要 macOS 14.4 或更高版本") }
    } else if CGPreflightScreenCaptureAccess() {
        let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-l", String(controller.window.windowNumber), output.path]
        try capture.run(); capture.waitUntilExit()
        if capture.terminationStatus != 0 {
            print("可选窗口截图失败，已保留 PDF；继续执行布局与生命周期检查。")
        }
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
    func reviewAccountSelection() throws {
        let good = snapshot!, first = good.accounts[0]
        let second = Account(id: "preview-second", rootID: first.rootID, name: "second_preview",
            source: first.sourceURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("second_preview/msg/file").path,
            sourceIdentity: first.sourceIdentity, sourceBookmark: nil, archiveRelative: "微信文件/second_preview", archiveIdentity: first.archiveIdentity,
            intakeEnabled: false, removedAt: nil, createdAt: first.createdAt + 1)
        let two = ApplicationSnapshot(root: good.root, canChooseRoot: false, accounts: [first, second], readOnly: [first.id: true, second.id: false], recoverable: [:], message: "刷新状态")
        render(two, error: nil)
        accountPicker.selectItem(at: 1) // Selection may arrive just before its target/action callback.
        render(two, error: nil)
        precondition(account?.id == second.id && syncSwitch.state == .off && readOnly.state == .off, "状态刷新不能把账号切换重置为旧账号")
        selectAccount(nil)
        render(two, error: nil)
        precondition(account?.id == second.id)
        render(good, error: nil)
    }

    @available(macOS 14.4, *)
    func captureOwnWindow(_ output: URL) throws {
        window.display(); window.contentView!.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        var result: Result<CGImage, Error>?
        let windowID = CGWindowID(window.windowNumber)
        Task { @MainActor in
            do {
                // This API exposes only content this process may capture without a TCC grant.
                let content = try await SCShareableContent.currentProcess
                guard let own = content.windows.first(where: { $0.windowID == windowID }) else {
                    throw SyncError.message("系统未提供当前临时窗口的截图范围")
                }
                let filter = SCContentFilter(desktopIndependentWindow: own)
                let config = SCStreamConfiguration()
                config.width = Int(own.frame.width * window.backingScaleFactor)
                config.height = Int(own.frame.height * window.backingScaleFactor)
                config.showsCursor = false; config.ignoreShadowsSingleWindow = true
                result = .success(try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config))
            } catch { result = .failure(error) }
        }
        let deadline = Date().addingTimeInterval(10)
        while result == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        guard let result else { throw SyncError.message("临时窗口截图超时") }
        let bitmap = NSBitmapImageRep(cgImage: try result.get())
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw SyncError.message("无法编码窗口截图") }
        try png.write(to: output)
        print("已截取当前临时窗口：\(output.path)")
    }

    @available(macOS 14.4, *)
    func captureGeneralSettings(_ output: URL) throws {
        showPage(1); window.contentView!.layoutSubtreeIfNeeded()
        try captureOwnWindow(output)
        showPage(0)
    }

    func writeGeneralPreview(_ output: URL) throws {
        showPage(1); window.contentView!.layoutSubtreeIfNeeded()
        let content = window.contentView!
        try content.dataWithPDF(inside: content.bounds).write(to: output)
        window.appearance = NSAppearance(named: .darkAqua)
        content.layoutSubtreeIfNeeded()
        try content.dataWithPDF(inside: content.bounds).write(to: output.deletingPathExtension().appendingPathExtension("dark.pdf"))
        window.appearance = nil
        showPage(0); content.layoutSubtreeIfNeeded()
    }

    func reviewSettingsLayout() throws {
        // Both appearances and page sizes use the same geometry and semantic controls.
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for size in [NSSize(width: 960, height: 720), NSSize(width: 880, height: 680)] {
                window.setContentSize(size)
                for index in [0, 1] {
                    showPage(index); window.contentView!.layoutSubtreeIfNeeded()
                    let page = index == 0 ? accountPage! : generalPage!
                    guard page.frame.minY >= 0, page.frame.maxY <= page.superview!.bounds.height + 1,
                          page.arrangedSubviews.allSatisfy({ $0.frame.minY >= -1 && $0.frame.maxY <= page.bounds.height + 1 }) else {
                        throw SyncError.message("设置页面超出窗口范围：\(index)")
                    }
                    func check(_ view: NSView) throws {
                        if let stack = view as? NSStackView, stack.orientation == .horizontal {
                            for child in stack.arrangedSubviews {
                                guard child.frame.minX >= -2, child.frame.maxX <= stack.bounds.width + 2 else {
                                    throw SyncError.message("设置行超出窗口范围")
                                }
                                if let button = child as? NSButton, !(button is NSPopUpButton) {
                                    guard button.frame.width + 1 >= button.fittingSize.width else {
                                        throw SyncError.message("按钮文字被压缩：\(button.title)")
                                    }
                                }
                            }
                        }
                        for child in view.subviews { try check(child) }
                    }
                    try check(page)
                    let body = pageScroll.superview!
                    let bodyFrame = body.convert(body.bounds, to: window.contentView!)
                    guard abs(bodyFrame.minX - 200) < 1, abs(bodyFrame.maxX - window.contentView!.bounds.width) < 1,
                          abs(page.bounds.width - (body.bounds.width - 64)) < 2 else {
                        throw SyncError.message("设置内容没有填满右侧区域")
                    }
                    let visible = page.convert(page.bounds, to: pageScroll.contentView)
                    guard abs(visible.minY - 28) <= 2, visible.maxY <= pageScroll.contentView.bounds.height + 1 else {
                        throw SyncError.message("设置初始内容未完整显示或未从顶部开始")
                    }
                    precondition(navigation[index].state == .on && navigation[1 - index].state == .off)
                    precondition(pageTitle.stringValue == (index == 0 ? "账号与文件" : "通用"))
                }
            }
        }
        window.appearance = nil
        window.setContentSize(NSSize(width: 960, height: 720)); showPage(0)
        window.contentView!.layoutSubtreeIfNeeded()
        precondition(accountPicker.titleOfSelectedItem == "sample_account_2070")
        precondition(syncSwitch.state == .on && syncSwitch.isEnabled)
        precondition(actionButtons.allSatisfy { !$0.title.contains("备注") && !$0.title.contains("暂停") })
        precondition(more.menu?.items.contains { $0.action == #selector(removeAccount(_:)) } == true)
        let good = snapshot!
        var removed = good.accounts[0]; removed.removedAt = 1
        render(ApplicationSnapshot(root: good.root, canChooseRoot: false, accounts: [removed], readOnly: good.readOnly, recoverable: good.recoverable, message: "停止管理"), error: nil)
        precondition(accountInfo.stringValue == good.root!.url.appendingPathComponent(removed.archiveRelative).path)
        precondition(!syncSwitch.isEnabled && !readOnly.isEnabled && more.isEnabled)
        precondition(more.menu?.items.first { $0.action == #selector(authorizeAccount(_:)) }?.title == "恢复管理此账号…")
        precondition(more.menu?.items.first { $0.action == #selector(removeAccount(_:)) }?.isEnabled == false)
        render(good, error: nil)
        render(ApplicationSnapshot(root: nil, canChooseRoot: true, accounts: [], readOnly: [:], recoverable: [:], message: "先添加微信账号"), error: nil)
        precondition(actionButtons.first { $0.action == #selector(addAccount(_:)) }?.isEnabled == true)
        precondition(!syncSwitch.isEnabled && !readOnly.isEnabled && !more.isEnabled)
        render(good, error: nil)
    }

    func prepareManualPreview() {
        manualPreviewOnly = true
        window.title = "微信文件同步 · 临时样本预览"
        status.stringValue = "临时预览 · 操作不会写入配置"
        statusItem.button?.toolTip = "临时样本界面预览"
        // Preserve normal control appearance while removing every action that can reach real configuration.
        for control in actionButtons.map({ $0 as NSControl }) + [readOnly, syncSwitch, login, more] { control.target = nil; control.action = nil }
        for item in more.menu?.items.dropFirst() ?? [] { item.isEnabled = false; item.target = nil; item.action = nil }
        accountPicker.target = nil; accountPicker.action = nil
        statusItem.menu?.autoenablesItems = false
        if let item = statusItem.menu?.items.first(where: { $0.action == #selector(openRoot(_:)) }) {
            item.isEnabled = false; item.target = nil; item.action = nil
        }
        precondition(actionButtons.allSatisfy { $0.target == nil && $0.action == nil })
        precondition([readOnly, syncSwitch, login].allSatisfy { $0.target == nil && $0.action == nil })
        precondition(accountPicker.target == nil && accountPicker.action == nil)
        precondition(more.menu?.items.dropFirst().allSatisfy { $0.target == nil && $0.action == nil } == true)
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
