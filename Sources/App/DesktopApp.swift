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
        guard let session else { return }
        do { try session.scan(); publish() }
        catch where isDatabaseBusy(error) { publish() }
        catch { publish(error: String(describing: error)) }
    }

    private func publish(error: String? = nil) {
        let snapshot: ApplicationSnapshot?
        let message: String?
        do { snapshot = try session?.snapshot(); message = error }
        catch where isDatabaseBusy(error) {
            snapshot = nil; message = ApplicationSession.databaseBusyMessage
            session?.waitForDatabase()
        }
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
            } catch {
                if isDatabaseBusy(error) { self.session?.waitForDatabase() }
                result = .failure(error)
            }
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

fileprivate final class DesktopController: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    fileprivate static let defaultSettingsSize = NSSize(width: 960, height: 620)
    private static let minimumSettingsSize = NSSize(width: 880, height: 600)

    private let worker: DesktopWorker
    private let makeBookmark: (URL) throws -> Data
    private let resolveBookmark: (Data) throws -> DirectoryLease
    private var statusItem: NSStatusItem!
    private let menuStatus = NSMenuItem(title: "等待检查", action: nil, keyEquivalent: "")
    private let menuProblem = NSMenuItem(title: "查看同步问题", action: #selector(showSyncProblem(_:)), keyEquivalent: "")
    private let menuOpenRoot = NSMenuItem(title: "打开文件保存位置", action: #selector(openRoot(_:)), keyEquivalent: "")
    fileprivate var window: NSWindow!
    private let status = NSTextField(labelWithString: "等待检查")
    private let statusDot = NSImageView()
    private var accountStatus: NSStackView!
    private let rootLabel = NSTextField(wrappingLabelWithString: "尚未选择文件夹")
    private let rootFeedback = NSTextField(wrappingLabelWithString: "")
    private var rootSelectionError: String?
    private let accountPicker = NSPopUpButton()
    private let accountInfo = NSTextField(wrappingLabelWithString: "添加账号后，只同步之后收到的新文件。")
    fileprivate let readOnly = NSSwitch()
    fileprivate let syncSwitch = NSSwitch()
    private let more = NSPopUpButton(frame: .zero, pullsDown: true)
    private var managedAccountGroup: NSView!
    private var setupGroup: NSView!
    private var syncSection: NSView!
    private var folderSection: NSView!
    private var storageSection: NSView!
    private var allowWeChat: NSButton!
    private var reauthorizeWeChat: NSButton!
    private var addAccountButton: NSButton!
    private let addPopover = NSPopover()
    private let addList = NSStackView()
    private let addScroll = NSScrollView()
    private let addHint = NSTextField(wrappingLabelWithString: "")
    private let addFeedback = NSTextField(wrappingLabelWithString: "")
    private var addBody: NSStackView!
    private var addScrollHeight: NSLayoutConstraint!
    private var allowAddAccess: NSButton!
    private var returningFromAddAuthorization = false
    private var addEscapeMonitor: Any?
    private let setupHint = NSTextField(wrappingLabelWithString: "")
    private let setupFeedback = NSTextField(wrappingLabelWithString: "")
    private let draftPath = NSTextField(labelWithString: "")
    private var draftDestination: NSView!
    private var chooseDraftDestination: NSButton!
    private var startSync: NSButton!
    private var cancelSetup: NSButton!
    private let candidateList = NSStackView()
    private var candidateButtons: [NSButton] = []
    private var visibleCandidates: [DiscoveredAccount] = []
    private var candidateButtonsAddDirectly = false
    private var addingAccount = false
    private var parentGrant: DirectoryLease?
    private var discoveredAccounts: [DiscoveredAccount] = []
    private var draftAccount: DiscoveredAccount?
    private var draftRoot: DirectoryLease?
    private var setupError: String?
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

    fileprivate init(worker: DesktopWorker = DesktopWorker(), makeBookmark: @escaping (URL) throws -> Data = newBookmark,
                     resolveBookmark: @escaping (Data) throws -> DirectoryLease = bookmarkScope) {
        self.worker = worker
        self.makeBookmark = makeBookmark
        self.resolveBookmark = resolveBookmark
        super.init()
    }

    deinit {
        if let addEscapeMonitor { NSEvent.removeMonitor(addEscapeMonitor) }
    }

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
                if value?.root == nil || value?.accounts.isEmpty == true || error != nil { self.showSettings(nil) }
            }
        }
        worker.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings(nil); return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func windowWillClose(_ notification: Notification) {
        if addPopover.isShown { addPopover.close() }
    }

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
        terminating = true; updateSyncStatus()
        worker.stop { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    fileprivate func makeMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let icon = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "pdf").flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: nil)
        icon?.isTemplate = true
        icon?.accessibilityDescription = "微信文件同步"
        statusItem.button?.image = icon
        let menu = NSMenu()
        menu.autoenablesItems = false
        menuStatus.isEnabled = false; menu.addItem(menuStatus)
        menuProblem.target = self; menuProblem.isHidden = true; menu.addItem(menuProblem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "设置", action: #selector(showSettings(_:)), keyEquivalent: ",").target = self
        menuOpenRoot.target = self; menuOpenRoot.isEnabled = false; menu.addItem(menuOpenRoot)
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(quit(_:)), keyEquivalent: "q").target = self
        statusItem.menu = menu
        let main = NSMenu(), app = NSMenu(), item = NSMenuItem()
        item.submenu = app; main.addItem(item)
        app.addItem(withTitle: "设置", action: #selector(showSettings(_:)), keyEquivalent: ",").target = self
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
        case #selector(addAccount(_:)): button.toolTip = "查看还可以添加哪些微信账号。"
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

    private func section(_ title: String, _ content: NSView, note: String? = nil, trailing: NSView? = nil) -> NSStackView {
        let heading = NSTextField(labelWithString: title); heading.font = .systemFont(ofSize: 12, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        let header: NSView = trailing.map { row(heading, spacer(), $0) } ?? heading
        let stack = column([header, content], spacing: 10)
        if trailing != nil { header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
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

    private func makeAddPopover() {
        let width: CGFloat = 360
        let board = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        let title = NSTextField(labelWithString: "添加微信账号")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        for hint in [addHint, addFeedback] {
            hint.font = .systemFont(ofSize: 12)
            hint.textColor = .secondaryLabelColor
            hint.preferredMaxLayoutWidth = width - 32
        }
        allowAddAccess = button("允许访问微信文件夹…", #selector(allowWeChatAccess(_:)))
        addList.orientation = .vertical; addList.alignment = .leading; addList.spacing = 8
        addList.translatesAutoresizingMaskIntoConstraints = false
        let document = SettingsDocument()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(addList)
        addScroll.documentView = document
        addScroll.drawsBackground = false; addScroll.hasVerticalScroller = true; addScroll.autohidesScrollers = true
        addScroll.borderType = .noBorder
        addScrollHeight = addScroll.heightAnchor.constraint(equalToConstant: 0)
        addBody = column([title, addHint, addFeedback, allowAddAccess, addScroll], spacing: 10)
        addBody.translatesAutoresizingMaskIntoConstraints = false
        board.addSubview(addBody)
        NSLayoutConstraint.activate([addBody.leadingAnchor.constraint(equalTo: board.leadingAnchor, constant: 16),
            addBody.trailingAnchor.constraint(equalTo: board.trailingAnchor, constant: -16),
            addBody.topAnchor.constraint(equalTo: board.topAnchor, constant: 16),
            addScroll.widthAnchor.constraint(equalTo: addBody.widthAnchor), addScrollHeight,
            addHint.widthAnchor.constraint(equalTo: addBody.widthAnchor),
            addFeedback.widthAnchor.constraint(equalTo: addBody.widthAnchor),
            document.widthAnchor.constraint(equalTo: addScroll.contentView.widthAnchor),
            addList.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            addList.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -4),
            addList.topAnchor.constraint(equalTo: document.topAnchor),
            addList.bottomAnchor.constraint(equalTo: document.bottomAnchor)])
        let content = NSViewController(); content.view = board
        addPopover.contentViewController = content
        addPopover.contentSize = board.frame.size
        addPopover.behavior = .transient; addPopover.delegate = self
        addPopover.animates = false
    }

    fileprivate func makeWindow() {
        window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.defaultSettingsSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.minSize = Self.minimumSettingsSize
        window.title = "微信文件同步 · 设置"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false; window.delegate = self; window.center()
        window.backgroundColor = .textBackgroundColor
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        statusDot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        statusDot.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 7, weight: .regular)
        statusDot.setAccessibilityElement(false)
        accountStatus = row(statusDot, status); accountStatus.spacing = 6
        for label in [rootLabel, accountInfo, draftPath] {
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
        for (title, action) in [("恢复文件关联…", #selector(restoreLinks(_:))), ("恢复管理此账号…", #selector(authorizeAccount(_:))), ("停止管理此账号…", #selector(removeAccount(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; more.menu?.addItem(item)
        }
        more.menu?.autoenablesItems = false
        addAccountButton = button("添加账号", #selector(addAccount(_:)))
        makeAddPopover()
        reauthorizeWeChat = button("重新允许访问…", #selector(authorizeAccount(_:)))
        managedAccountGroup = group([settingRow("当前账号", control: accountPicker),
            row(addAccountButton, reauthorizeWeChat, more, spacer())])
        allowWeChat = button("允许访问微信文件夹…", #selector(allowWeChatAccess(_:)))
        chooseDraftDestination = button("选择保存位置…", #selector(chooseSetupRoot(_:)))
        startSync = button("开始同步", #selector(startFirstSync(_:)))
        startSync.bezelStyle = .rounded
        cancelSetup = button("取消设置", #selector(cancelAccountSetup(_:)))
        candidateList.orientation = .vertical
        candidateList.alignment = .leading
        candidateList.spacing = 8
        setupHint.font = .systemFont(ofSize: 11)
        setupHint.textColor = .secondaryLabelColor
        let draftLocation = column([NSTextField(labelWithString: "文件保存位置"), draftPath], spacing: 4)
        draftPath.widthAnchor.constraint(equalTo: draftLocation.widthAnchor).isActive = true
        draftDestination = row(draftLocation, spacer(), chooseDraftDestination)
        let setupBody = column([setupHint, allowWeChat, candidateList, draftDestination,
            row(startSync, cancelSetup, spacer())], spacing: 12)
        for view in [setupHint, candidateList, draftDestination!] as [NSView] {
            view.widthAnchor.constraint(equalTo: setupBody.widthAnchor).isActive = true
        }
        setupGroup = group([setupBody])
        setupFeedback.font = .systemFont(ofSize: 12)
        setupFeedback.textColor = .secondaryLabelColor
        setupFeedback.maximumNumberOfLines = 2
        let accountGroups = column([managedAccountGroup, setupGroup, setupFeedback], spacing: 12)
        managedAccountGroup.widthAnchor.constraint(equalTo: accountGroups.widthAnchor).isActive = true
        setupGroup.widthAnchor.constraint(equalTo: accountGroups.widthAnchor).isActive = true
        setupFeedback.widthAnchor.constraint(equalTo: accountGroups.widthAnchor).isActive = true
        let syncGroup = group([settingRow("同步新文件", detail: "开启后，自动保存微信新收到的文件。", control: syncSwitch),
            settingRow("文件只读", detail: "新保存的文件设为只读。需要编辑时，请另存一份。", control: readOnly)])
        let folderTitle = NSTextField(labelWithString: "账号文件夹"); folderTitle.font = .systemFont(ofSize: 13)
        let folderContent = column([folderTitle, accountInfo], spacing: 5)
        accountInfo.widthAnchor.constraint(equalTo: folderContent.widthAnchor).isActive = true
        let folderGroup = group([folderContent, row(button("在 Finder 中打开", #selector(openAccountFolder(_:))), spacer())])
        syncSection = section("文件同步", syncGroup)
        folderSection = section("文件位置", folderGroup, note: "在保存范围内改名或移动文件，微信里的文件链接会自动更新。")
        accountPage = column([section("微信账号", accountGroups, trailing: accountStatus), syncSection, folderSection], spacing: 28)
        let rootTitle = NSTextField(labelWithString: "文件保存位置"); rootTitle.font = .systemFont(ofSize: 13)
        rootFeedback.font = .systemFont(ofSize: 12)
        rootFeedback.textColor = .secondaryLabelColor
        rootFeedback.isHidden = true
        let rootContent = column([rootTitle, rootLabel, rootFeedback], spacing: 5)
        for label in [rootLabel, rootFeedback] {
            label.widthAnchor.constraint(equalTo: rootContent.widthAnchor).isActive = true
        }
        let rootGroup = group([rootContent,
            row(button("选择保存文件夹…", #selector(authorizeRoot(_:))), button("在 Finder 中打开", #selector(openRoot(_:))), spacer())])
        let loginText = column([NSTextField(labelWithString: "登录时启动"), loginStatus], spacing: 3)
        login.controlSize = .small; login.setAccessibilityLabel("登录时启动")
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版"
        let versionLabel = NSTextField(labelWithString: version); versionLabel.font = .systemFont(ofSize: 12); versionLabel.textColor = .secondaryLabelColor
        storageSection = section("存储", rootGroup, note: "不同账号分别保存，文件改名或移动后仍可从微信打开。")
        generalPage = column([storageSection,
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
            window.contentView!.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumSettingsSize.width),
            window.contentView!.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumSettingsSize.height), side.widthAnchor.constraint(equalToConstant: 200),
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
        if index != 0 && addPopover.isShown { addPopover.close() }
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
        updateSyncStatus()
        rootLabel.stringValue = snapshot?.root?.path ?? "请选择用于保存微信文件的文件夹"
        rootLabel.toolTip = snapshot?.root.map { "\($0.path)\n程序只在这个文件夹内查找改名或移动后的文件。" }
        let rootIssue = rootSelectionError ?? (savingLocationUnavailable ? "无法访问保存位置，请重新选择原文件夹。" : nil)
        rootFeedback.stringValue = rootIssue ?? ""
        rootFeedback.toolTip = rootSelectionError ?? (savingLocationUnavailable ? snapshot?.message : nil)
        rootFeedback.isHidden = rootIssue == nil
        let previous = selectedID
        let accounts = snapshot?.accounts ?? []
        let titles = accounts.map { account in
            let name = WeChatDirectories.displayName(source: account.sourceURL)
            if account.removed { return name + "（已停止管理）" }
            if !stateUnavailable && snapshot?.accountIssues[account.id] != nil { return name + "（需要处理）" }
            return name
        }
        let menuChanged = accountPicker.itemArray.count != accounts.count || zip(accountPicker.itemArray, accounts).contains {
            $0.0.representedObject as? String != $0.1.id
        }
        // Periodic status updates must not replace a menu while the user is selecting an account.
        if menuChanged {
            accountPicker.removeAllItems()
            for (account, title) in zip(accounts, titles) {
                accountPicker.addItem(withTitle: title)
                accountPicker.lastItem?.representedObject = account.id
            }
            if let previous, let index = accounts.firstIndex(where: { $0.id == previous }) { accountPicker.selectItem(at: index) }
        } else {
            for (item, title) in zip(accountPicker.itemArray, titles) where item.title != title { item.title = title }
        }
        selectedID = accountPicker.selectedItem?.representedObject as? String
        updateAccount()
        for button in actionButtons {
            button.isEnabled = !busy && snapshot != nil && !stateUnavailable && !terminating
            let action = button.action
            if action == #selector(openAccountFolder(_:)) { button.isEnabled = button.isEnabled && account != nil && account?.removed == false }
            if action == #selector(openRoot(_:)) { button.isEnabled = button.isEnabled && menuOpenRoot.isEnabled }
            if action == #selector(authorizeRoot(_:)) {
                button.title = snapshot?.root == nil ? "选择保存文件夹…" : snapshot?.canChooseRoot == true ? "更改保存位置…" : "重新选择保存文件夹…"
            }
        }
        let editable = !busy && !stateUnavailable && !terminating && snapshot != nil
        accountPicker.isEnabled = editable && !accounts.isEmpty
        syncSwitch.isEnabled = editable && account != nil && account?.removed == false
        more.isEnabled = editable && account != nil
        for item in more.menu?.items.dropFirst() ?? [] {
            item.isEnabled = editable && account != nil
            if item.action == #selector(authorizeAccount(_:)) {
                item.isHidden = account?.removed != true
            } else {
                item.isEnabled = item.isEnabled && account?.removed == false
                if item.action == #selector(restoreLinks(_:)) { item.isEnabled = item.isEnabled && !(snapshot?.recoverable[account?.id ?? ""] ?? []).isEmpty }
            }
        }
        readOnly.isEnabled = !busy && !stateUnavailable && account != nil && account?.removed == false && !terminating
        login.isEnabled = !busy && !stateUnavailable && !terminating
        renderAccountSetup(accounts: accounts, editable: editable)
    }

    private var savingLocationUnavailable: Bool {
        !stateUnavailable && snapshot?.syncStatus == .savingLocationUnavailable
    }

    private func updateSyncStatus() {
        let syncStatus = snapshot?.syncStatus ?? .waiting
        var color = NSColor.tertiaryLabelColor
        var hasProblem = false
        if terminating { status.stringValue = "正在结束当前操作…" }
        else if busy { status.stringValue = "正在处理…" }
        else if stateError == ApplicationSession.databaseBusyMessage { status.stringValue = "正在重试" }
        else if stateError != nil && !savingLocationUnavailable {
            status.stringValue = "需要处理"; hasProblem = true
        } else {
            switch syncStatus {
            case .waiting:
                let configured = snapshot?.root != nil && snapshot?.accounts.contains { !$0.removed } == true
                status.stringValue = snapshot == nil || configured ? "等待检查" : "等待设置"
            case .idle: status.stringValue = "等待新文件"; color = .systemGreen
            case .processing: status.stringValue = "正在处理新文件"
            case .paused: status.stringValue = "新文件同步已暂停"
            case .retrying: status.stringValue = "正在重试"
            case .needsAttention:
                let count = snapshot?.accountIssues.count ?? 0
                status.stringValue = count == 0 ? "需要处理" : "\(count) 个账号需要处理"
                hasProblem = true
            case .savingLocationUnavailable:
                status.stringValue = "无法访问保存位置"; hasProblem = true
            }
        }
        if hasProblem { color = .systemOrange }
        statusDot.contentTintColor = color
        status.toolTip = stateError ?? snapshot?.message
        if menuStatus.title != status.stringValue { menuStatus.title = status.stringValue }
        menuProblem.isHidden = !hasProblem
        menuOpenRoot.isEnabled = !stateUnavailable && !savingLocationUnavailable && !busy && !terminating && snapshot?.root != nil
        statusItem.button?.toolTip = status.toolTip ?? status.stringValue
    }

    private func renderAccountSetup(accounts: [Account], editable: Bool) {
        let firstSetup = accounts.isEmpty
        managedAccountGroup.isHidden = firstSetup
        syncSection.isHidden = firstSetup
        folderSection.isHidden = firstSetup
        storageSection.isHidden = snapshot?.root == nil
        setupGroup.isHidden = !firstSetup
        reauthorizeWeChat.isHidden = stateUnavailable || (account.map { snapshot?.unavailableSources.contains($0.id) != true || $0.removed } ?? true)
        let accountIssue = account.flatMap { snapshot?.accountIssues[$0.id] }
        let generalIssue: String?
        if case .retrying? = snapshot?.syncStatus {
            generalIssue = snapshot?.message
        } else if case .needsAttention? = snapshot?.syncStatus, snapshot?.accountIssues.isEmpty == true {
            generalIssue = snapshot?.message
        } else { generalIssue = nil }
        let accountDetail = reauthorizeWeChat.isHidden ? accountIssue : "无法访问此账号的微信文件夹。"
        let detail = (!addingAccount ? setupError : nil) ?? (savingLocationUnavailable ? nil : stateError ?? accountDetail ?? generalIssue)
        setupFeedback.stringValue = detail ?? ""
        setupFeedback.toolTip = detail == accountDetail ? accountIssue ?? detail : detail
        setupFeedback.isHidden = detail == nil

        allowWeChat.isHidden = parentGrant != nil || busy
        setupHint.stringValue = parentGrant == nil ? "允许访问微信文件夹后，即可选择要同步的账号。" : "选择要同步的账号。已有文件留在原处。"
        let available = discoveredAccounts.filter { candidate in
            !accounts.contains { $0.source == candidate.source.path || $0.sourceIdentity == candidate.identity }
        }
        if parentGrant != nil && available.isEmpty { setupHint.stringValue = "没有可添加的微信账号。" }
        if busy && parentGrant == nil { setupHint.stringValue = "正在查找微信账号…" }
        let addDirectly = !firstSetup
        if visibleCandidates != available || candidateButtonsAddDirectly != addDirectly {
            visibleCandidates = available
            candidateButtonsAddDirectly = addDirectly
            for view in candidateList.arrangedSubviews + addList.arrangedSubviews { view.removeFromSuperview() }
            let list = addDirectly ? addList : candidateList
            candidateButtons = available.map { candidate in
                let button = NSButton(title: firstSetup ? "选择" : "添加", target: self, action: #selector(chooseCandidate(_:)))
                button.bezelStyle = .roundRect
                button.controlSize = .small
                let name = NSTextField(labelWithString: candidate.name)
                name.lineBreakMode = .byTruncatingMiddle
                name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                name.toolTip = candidate.name
                let candidateRow = row(name, spacer(), button)
                list.addArrangedSubview(candidateRow)
                candidateRow.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
                return button
            }
        }
        for (button, candidate) in zip(candidateButtons, available) {
            let selected = candidate == draftAccount && firstSetup
            button.title = firstSetup ? (selected ? "已选择" : "选择") : "添加"
            button.setAccessibilityLabel("\(button.title) \(candidate.name)")
            button.isEnabled = editable && !selected
        }
        candidateList.isHidden = available.isEmpty || !firstSetup
        let destination = (draftRoot?.url ?? snapshot?.root?.url)?.path
        draftPath.stringValue = destination ?? "尚未选择文件夹"
        draftPath.toolTip = destination
        chooseDraftDestination.title = destination == nil ? "选择保存位置…" : "更改保存位置…"
        chooseDraftDestination.isEnabled = editable && (snapshot?.canChooseRoot == true || snapshot?.root == nil)
        draftDestination.isHidden = !firstSetup || draftAccount == nil
        startSync.isHidden = !firstSetup || draftAccount == nil
        startSync.isEnabled = editable && draftAccount != nil && destination != nil
        cancelSetup.isHidden = parentGrant == nil
        if addingAccount { renderAddPopover(hasCandidates: !available.isEmpty) }
    }

    private func renderAddPopover(hasCandidates: Bool) {
        let loading = busy && parentGrant == nil
        addHint.stringValue = loading ? "正在查找微信账号…" :
            parentGrant == nil ? "允许访问微信文件夹后，可查看可添加的账号。" : "没有可添加的微信账号。"
        addHint.isHidden = hasCandidates
        addFeedback.stringValue = setupError ?? ""
        addFeedback.isHidden = setupError == nil
        allowAddAccess.isHidden = parentGrant != nil || loading
        addScroll.isHidden = !hasCandidates
        addScrollHeight.constant = min(addList.fittingSize.height, 200)
        let size = NSSize(width: 360, height: 32 + addBody.fittingSize.height)
        if addPopover.contentSize != size { addPopover.contentSize = size }
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

    private func perform<T>(_ action: @escaping (ApplicationSession) throws -> T, then: ((T) -> Void)? = nil,
                            onError: ((String) -> Void)? = nil) {
        guard !busy, !terminating, !stateUnavailable else { return }
        busy = true; render(nil, error: nil)
        worker.perform(action) { [weak self] result in
            guard let self else { return }
            self.busy = false
            guard !self.terminating else { return }
            self.render(nil, error: nil)
            switch result {
            case .success(let value): if !self.stateUnavailable { then?(value) }
            case .failure(let error):
                if let onError { onError(String(describing: error)) }
                else { _ = self.alert("操作未完成", String(describing: error)) }
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
            window.setContentSize(Self.defaultSettingsSize)
            window.center(); hasShownSettings = true
        }
        NSApp.activate(ignoringOtherApps: true); refreshLogin()
    }
    @objc private func quit(_ sender: Any?) { NSApp.terminate(nil) }
    @objc private func selectAccount(_ sender: Any?) {
        let selected = accountPicker.selectedItem?.representedObject as? String
        if selectedID != selected { setupError = nil }
        selectedID = selected
        render(nil, error: nil)
    }

    @objc private func showSyncProblem(_ sender: Any?) {
        guard !menuProblem.isHidden else { return }
        if addPopover.isShown { addPopover.close() }
        if savingLocationUnavailable {
            showPage(1)
        } else {
            setupError = nil
            if !stateUnavailable && stateError == nil, let snapshot, snapshot.accountIssues[selectedID ?? ""] == nil,
               let item = accountPicker.itemArray.first(where: { item in
                   guard let id = item.representedObject as? String else { return false }
                   return snapshot.accountIssues[id] != nil
               }) {
                accountPicker.select(item)
            }
            selectAccount(nil)
            showPage(0)
        }
        showSettings(nil)
    }

    @objc private func openRoot(_ sender: Any?) {
        guard !stateUnavailable, let root = snapshot?.root else { return }
        do {
            let lease = try securityScope(bookmark: root.bookmark, expected: root.url, identity: root.identity)
            defer { withExtendedLifetime(lease) {} }
            NSWorkspace.shared.open(lease.url)
        } catch { _ = alert("无法打开目录", String(describing: error)) }
    }

    private func showDirectorySheet(suggested: @autoclosure () throws -> URL, title: String, message: String,
                                    onDismiss: (() -> Void)? = nil,
                                    onError: ((String) -> Void)? = nil, onSelection: @escaping (URL) throws -> Void) {
        guard !busy, !terminating, !stateUnavailable, window.attachedSheet == nil else { return }
        let reportError = onError ?? { [weak self] in self?.showSetupError($0) }
        do {
            let panel = directoryPanel(try suggested(), title: title, message: message)
            panel.beginSheetModal(for: window) { [weak self] response in
                guard let self, !self.terminating else { return }
                onDismiss?()
                guard response == .OK, let url = panel.url else { return }
                do { try onSelection(url) }
                catch { reportError(String(describing: error)) }
            }
        } catch {
            onDismiss?()
            reportError(String(describing: error))
        }
    }

    private func selectedDirectory(_ url: URL) throws -> DirectoryLease {
        guard url.startAccessingSecurityScopedResource() else { throw SyncError.message("未获得文件夹访问许可") }
        return DirectoryLease(url: url) { url.stopAccessingSecurityScopedResource() }
    }

    private func selectedWeChatDirectory(_ url: URL) throws -> DirectoryLease {
        guard url.lastPathComponent == "xwechat_files" else { throw SyncError.message("请选择 xwechat_files 文件夹。") }
        return try selectedDirectory(url)
    }

    private func showSetupError(_ message: String) {
        setupError = message
        render(nil, error: nil)
    }

    @objc private func authorizeRoot(_ sender: Any?) {
        guard let existing = snapshot?.root else { return }
        let canChoose = snapshot?.canChooseRoot == true
        let showError: (String) -> Void = { [weak self] message in
            self?.rootSelectionError = message
            self?.render(nil, error: nil)
        }
        showDirectorySheet(suggested: existing.url, title: "文件保存位置",
                           message: canChoose ? "请选择用于保存微信新文件的文件夹。" : "请选择原来的保存文件夹，恢复访问权限。",
                           onError: showError) { [weak self] url in
            guard let self else { return }
            let lease = try self.selectedDirectory(url)
            let bookmark = try self.makeBookmark(url)
            self.rootSelectionError = nil
            self.perform({ session in
                defer { withExtendedLifetime(lease) {} }
                try session.change { try AccountManager(repository: $0.accounts).configureRoot(url, bookmark: bookmark) }
            }, onError: showError)
        }
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

    @objc private func allowWeChatAccess(_ sender: Any?) {
        requestWeChatAccess(suggested: try expectedWeChatRoot())
    }

    private func requestWeChatAccess(suggested: @autoclosure () throws -> URL) {
        guard !busy, !terminating, !stateUnavailable, window.attachedSheet == nil else { return }
        if addPopover.isShown {
            returningFromAddAuthorization = true
            addPopover.close()
        }
        showDirectorySheet(suggested: try suggested(), title: "允许访问微信文件夹",
                           message: "请选择 xwechat_files 文件夹。",
                           onDismiss: { [weak self] in self?.returnToAddPopover() }) { [weak self] url in
            guard let self else { return }
            guard self.snapshot?.accounts.isEmpty == true || self.addingAccount else { return }
            self.discoverAccounts(using: try self.selectedWeChatDirectory(url))
        }
    }

    @objc private func addAccount(_ sender: Any?) {
        guard !busy, !terminating, !stateUnavailable else { return }
        if addPopover.isShown { addPopover.close(); return }
        addingAccount = true
        discoverAccounts(using: nil)
        showAddPopover()
    }

    private func showAddPopover() {
        addPopover.show(relativeTo: addAccountButton.bounds, of: addAccountButton, preferredEdge: .maxY)
        // The settings window can still have keyboard focus after a sheet is dismissed.
        if addEscapeMonitor == nil {
            addEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.addPopover.isShown, event.keyCode == 53 else { return event }
                let popoverWindow = self.addPopover.contentViewController?.view.window
                guard event.window === self.window || event.window === popoverWindow else { return event }
                self.addPopover.close()
                return nil
            }
        }
    }

    private func returnToAddPopover() {
        guard returningFromAddAuthorization else { return }
        returningFromAddAuthorization = false
        if window.isVisible && !accountPage.isHidden { showAddPopover() }
        else { cancelAccountSetup(nil) }
    }

    func popoverWillClose(_ notification: Notification) {
        if let addEscapeMonitor { NSEvent.removeMonitor(addEscapeMonitor); self.addEscapeMonitor = nil }
        if !returningFromAddAuthorization { cancelAccountSetup(nil) }
    }

    private func discoverAccounts(using explicitGrant: DirectoryLease?) {
        setupError = nil
        let resolveBookmark = self.resolveBookmark
        let fromPopover = addingAccount
        perform({ session -> (DirectoryLease?, [DiscoveredAccount]) in
            if let explicitGrant {
                return (explicitGrant, try WeChatDirectories.discover(in: explicitGrant.url))
            }
            // The stored bookmark is only usable once the directory is actually readable.
            for account in try session.store.accounts.accounts() where !account.removed {
                if let bookmark = account.sourceBookmark, let grant = try? resolveBookmark(bookmark),
                   grant.url.lastPathComponent == "xwechat_files",
                   let candidates = try? WeChatDirectories.discover(in: grant.url) {
                    return (grant, candidates)
                }
            }
            return (nil, [])
        }, then: { [weak self] grant, candidates in
            guard let self, !fromPopover || self.addingAccount else { return }
            self.parentGrant = grant
            self.discoveredAccounts = candidates
            self.render(nil, error: nil)
        }, onError: { [weak self] error in
            guard let self, !fromPopover || self.addingAccount else { return }
            self.showSetupError(error)
        })
    }

    @objc private func chooseCandidate(_ sender: NSButton) {
        guard !busy, !terminating, !stateUnavailable,
              let index = candidateButtons.firstIndex(where: { $0 === sender }) else { return }
        let choice = visibleCandidates[index]
        if snapshot?.accounts.isEmpty == true {
            draftAccount = choice
            setupError = nil
            render(nil, error: nil)
        } else {
            finishAdding(choice)
        }
    }

    @objc private func chooseSetupRoot(_ sender: Any?) {
        guard draftAccount != nil else { return }
        showDirectorySheet(suggested: try draftRoot?.url ?? snapshot?.root?.url ?? defaultManagedRoot(),
                           title: "文件保存位置", message: "请选择用于保存微信新文件的文件夹。") { [weak self] url in
            guard let self else { return }
            self.setDraftRoot(try self.selectedDirectory(url))
        }
    }

    private func setDraftRoot(_ lease: DirectoryLease) {
        draftRoot = lease
        setupError = nil
        render(nil, error: nil)
    }

    @objc private func startFirstSync(_ sender: Any?) {
        guard let draftAccount, draftRoot != nil || snapshot?.root != nil else { return }
        finishAdding(draftAccount)
    }

    @objc private func cancelAccountSetup(_ sender: Any?) {
        addingAccount = false
        parentGrant = nil
        discoveredAccounts = []
        draftAccount = nil
        draftRoot = nil
        setupError = nil
        render(nil, error: nil)
    }

    private func finishAdding(_ choice: DiscoveredAccount) {
        guard let parent = parentGrant else { return }
        setupError = nil
        let selectedRoot = draftRoot
        let makeBookmark = self.makeBookmark
        perform({ session -> String in
            defer { withExtendedLifetime((parent, selectedRoot)) {} }
            let sourceBookmark = try makeBookmark(parent.url)
            let destinationBookmark = try selectedRoot.map { try makeBookmark($0.url) }
            var addedID = ""
            try session.change { store in
                let source = try WeChatDirectories.authorizedSource(grant: parent.url, expected: choice.source, identity: choice.identity)
                let manager = AccountManager(repository: store.accounts)
                if let selectedRoot {
                    _ = try initialState(source: source, managedRoot: canonicalDirectory(selectedRoot.url))
                    try manager.configureRoot(selectedRoot.url, bookmark: destinationBookmark)
                }
                let root = try session.savedRootAccess()
                defer { withExtendedLifetime(root) {} }
                addedID = try manager.add(source: source, name: choice.name, bookmark: sourceBookmark).id
            }
            return addedID
        }, then: { [weak self] id in
            guard let self else { return }
            if let index = self.accountPicker.itemArray.firstIndex(where: { $0.representedObject as? String == id }) {
                self.accountPicker.selectItem(at: index)
            }
            if self.addPopover.isShown { self.addPopover.close() }
            else { self.cancelAccountSetup(nil) }
        }, onError: { [weak self] in self?.showSetupError($0) })
    }

    @objc private func pauseAccount(_ sender: Any?) {
        guard let account, !account.removed else { return }
        let paused = syncSwitch.state != .on
        perform { session in try session.change { try AccountManager(repository: $0.accounts).setPaused(account.id, paused: paused) } }
    }

    @objc private func authorizeAccount(_ sender: Any?) {
        guard let account else { return }
        let parent = account.sourceURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        showDirectorySheet(suggested: parent, title: "重新授权微信文件夹",
                           message: "请选择原来的 xwechat_files 文件夹。") { [weak self] url in
            guard let self else { return }
            let source = try self.selectedWeChatDirectory(url)
            let bookmark = try self.makeBookmark(url)
            if account.removed && !self.alert("恢复管理此账号？", "将沿用原记录与文件夹，不重新建立历史基线。", confirm: "恢复管理") { return }
            self.setupError = nil
            self.perform({ session in
                defer { withExtendedLifetime(source) {} }
                try session.change { store in
                    let root = try session.savedRootAccess()
                    defer { withExtendedLifetime(root) {} }
                    let sourceURL = try WeChatDirectories.authorizedSource(grant: source.url, expected: account.sourceURL, identity: account.sourceIdentity)
                    try AccountManager(repository: store.accounts).reauthorize(account.id, source: sourceURL, bookmark: bookmark, restoring: account.removed)
                }
            }, onError: { [weak self] in self?.showSetupError($0) })
        }
    }

    @objc private func removeAccount(_ sender: Any?) {
        guard !busy, !terminating, !stateUnavailable, window.attachedSheet == nil, let account, !account.removed else { return }
        let confirmation = NSAlert()
        confirmation.messageText = "停止管理“\(WeChatDirectories.displayName(source: account.sourceURL))”？"
        confirmation.informativeText = "停止同步和更新链接，保留已同步的文件。"
        let stop = confirmation.addButton(withTitle: "停止管理")
        stop.hasDestructiveAction = true
        stop.keyEquivalent = ""
        confirmation.addButton(withTitle: "取消").keyEquivalent = "\u{1B}"
        confirmation.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.perform { session in try session.change { try $0.accounts.remove(account.id) } }
        }
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
        case .notFound: loginStatus.stringValue = "系统未找到登录项"
        @unknown default: loginStatus.stringValue = "无法读取登录项状态"
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
    let expected = DesktopController.defaultSettingsSize
    guard abs(content.bounds.width - expected.width) < 1, abs(content.bounds.height - expected.height) < 1 else {
        throw SyncError.message("首次显示没有保持默认窗口尺寸")
    }
    try controller.reviewAccountSelection()
    controller.reviewMenuStatus()
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
    try controller.reviewSettingsShortcut()
    controller.reviewReadFailureState(try session.snapshot())
    controller.window.close()
    try DesktopController.reviewInlineSetup(temporary: temporary)
    try desktopWorkerReviewTest(temporary: temporary)
    print("临时样本设置界面、自定义目录、账号状态和关闭／重开检查通过")
}
fileprivate extension DesktopController {
    func reviewSettingsShortcut() throws {
        guard let item = statusItem.menu?.item(withTitle: "设置"), item.keyEquivalent == ",",
              item.keyEquivalentModifierMask == .command,
              let shortcut = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                characters: ",", charactersIgnoringModifiers: ",", isARepeat: false, keyCode: 43),
              NSApp.mainMenu?.performKeyEquivalent(with: shortcut) == true, window.isVisible else {
            throw SyncError.message("设置菜单没有显示快捷键，或无法用 Command–逗号重新打开设置")
        }
    }

    static func reviewInlineSetup(temporary: URL) throws {
        let base = temporary.appendingPathComponent("inline-setup")
        let parent = base.appendingPathComponent("xwechat_files")
        let root = base.appendingPathComponent("保存目录")
        let first = parent.appendingPathComponent("first_account/msg/file")
        let second = parent.appendingPathComponent("second_account/msg/file")
        let expired = base.appendingPathComponent("fake-expired")
        let expiredParent = base.appendingPathComponent("fake-parent-expired")
        let database = base.appendingPathComponent("state.sqlite")
        for url in [root, first, second] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let history = first.appendingPathComponent("history.txt")
        try Data("existing".utf8).write(to: history)
        let worker = DesktopWorker(makeSession: {
            try ApplicationSession(database: database, rootAuthorization: { DirectoryLease(url: $0.url) },
                sourceAuthorization: { account in
                    if account.source == first.path && FileManager.default.fileExists(atPath: expired.path) {
                        throw SyncError.message("临时授权已失效")
                    }
                    return DirectoryLease(url: account.sourceURL)
                })
        }, scanInterval: 0.2)
        let fakeBookmark = Data("test-parent-grant".utf8)
        let controller = DesktopController(worker: worker, makeBookmark: { url in
            guard url == parent || url == root else { throw SyncError.message("测试书签只能用于临时样本") }
            return fakeBookmark
        }, resolveBookmark: { data in
            guard data == fakeBookmark, !FileManager.default.fileExists(atPath: expiredParent.path) else {
                throw SyncError.message("临时父目录授权不可用")
            }
            return DirectoryLease(url: parent)
        })
        defer { controller.window?.close(); worker.stop {} }
        func wait(_ message: String, _ condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(5)
            while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            guard condition() else { throw SyncError.message(message + (controller.setupError.map { "：\($0)" } ?? "")) }
        }
        func cancelSheet() throws {
            try wait("点击后未打开目录选择窗口") { controller.window.attachedSheet is NSOpenPanel }
            let panel = controller.window.attachedSheet as! NSOpenPanel
            panel.cancel(nil)
            try wait("目录选择窗口没有关闭") { controller.window.attachedSheet == nil }
            precondition(controller.setupError == nil && NSApp.modalWindow == nil, "取消不应弹出提示")
        }

        controller.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        try wait("空配置启动未打开设置") { controller.window.isVisible && controller.allowWeChat.isEnabled }
        precondition(controller.window.attachedSheet == nil && !controller.setupGroup.isHidden)
        precondition(!controller.allowWeChat.isHidden && controller.draftDestination.isHidden)
        controller.requestWeChatAccess(suggested: parent)
        try cancelSheet()
        precondition(controller.parentGrant == nil && !controller.allowWeChat.isHidden)

        controller.discoverAccounts(using: DirectoryLease(url: root))
        try wait("选错文件夹后未显示页内提示") { !controller.setupFeedback.isHidden && !controller.busy }
        precondition(controller.parentGrant == nil && !controller.allowWeChat.isHidden && NSApp.modalWindow == nil)

        controller.discoverAccounts(using: DirectoryLease(url: parent))
        try wait("没有在设置页列出两个账号") { controller.candidateButtons.count == 2 && !controller.busy }
        precondition(controller.allowWeChat.isHidden && controller.snapshot?.accounts.isEmpty == true)
        let firstButton = controller.candidateButtons[0]
        firstButton.performClick(nil)
        precondition(controller.draftAccount?.source.path == first.path && !controller.draftDestination.isHidden && !controller.startSync.isEnabled,
                     "选择账号后应显示保存位置，但还不能开始同步")
        controller.setDraftRoot(DirectoryLease(url: root))
        controller.chooseDraftDestination.performClick(nil)
        try cancelSheet()
        precondition(controller.draftRoot?.url == root && controller.startSync.isEnabled && controller.snapshot?.root == nil)
        controller.window.setContentSize(minimumSettingsSize)
        controller.window.contentView!.layoutSubtreeIfNeeded()
        let visible = controller.pageScroll.contentView.bounds
        let startFrame = controller.startSync.convert(controller.startSync.bounds, to: controller.pageScroll.contentView)
        precondition(visible.contains(startFrame), "两个候选账号时应能在最小窗口中看到开始同步按钮")
        controller.window.performClose(nil)
        controller.showSettings(nil)
        precondition(controller.draftAccount?.source.path == first.path && controller.draftRoot?.url.path == root.path)
        controller.startSync.performClick(nil)
        try wait("开始同步未保存首个账号") { controller.snapshot?.accounts.count == 1 && !controller.busy }
        precondition(controller.snapshot?.root?.url.path == root.path && controller.setupGroup.isHidden)
        let historyInfo = try readFileInfo(history.path)
        precondition(historyInfo?.regular == true)
        try wait("首个账号状态没有显示在微信账号栏") { controller.status.stringValue == "等待新文件" }
        controller.window.contentView!.layoutSubtreeIfNeeded()
        let settingsHeight = controller.pageScroll.documentView!.frame.height
        let viewportHeight = controller.pageScroll.contentView.bounds.height

        try Data().write(to: expiredParent)
        controller.addAccountButton.performClick(nil)
        try wait("旧授权不可用时未显示浮层授权入口") {
            controller.addPopover.isShown && !controller.allowAddAccess.isHidden && !controller.busy
        }
        precondition(controller.candidateButtons.isEmpty && controller.window.attachedSheet == nil)
        controller.requestWeChatAccess(suggested: parent)
        try cancelSheet()
        try wait("取消授权后没有回到浮层") { controller.addPopover.isShown }
        precondition(controller.snapshot?.accounts.count == 1 && !controller.allowAddAccess.isHidden)
        guard let popoverWindow = controller.addPopover.contentViewController?.view.window,
              let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: popoverWindow.windowNumber,
                context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53) else {
            throw SyncError.message("无法检查浮层 Esc 操作")
        }
        NSApp.sendEvent(escape)
        try wait("按 Esc 后浮层没有关闭") {
            !controller.addPopover.isShown && !controller.addingAccount
        }
        try FileManager.default.removeItem(at: expiredParent)

        for index in 0..<10 {
            let source = parent.appendingPathComponent("test_extra_\(index)/msg/file")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        }
        controller.addAccountButton.performClick(nil)
        try wait("添加时未复用已有授权") { controller.addPopover.isShown && controller.candidateButtons.count == 11 && !controller.busy }
        precondition(controller.window.attachedSheet == nil && controller.allowAddAccess.isHidden)
        controller.addPopover.contentViewController!.view.layoutSubtreeIfNeeded()
        controller.window.contentView!.layoutSubtreeIfNeeded()
        precondition(controller.addScroll.documentView!.frame.height > controller.addScroll.contentView.bounds.height,
                     "长列表应在浮层内滚动")
        precondition(abs(controller.pageScroll.documentView!.frame.height - settingsHeight) < 1 &&
                     settingsHeight <= viewportHeight + 1 && !controller.addAccountButton.isHidden,
                     "打开浮层后设置页不应长高或出现滚动条")
        precondition(controller.visibleCandidates.first?.source.path == second.path && controller.candidateButtons[0].title == "添加")
        controller.chooseCandidate(firstButton)
        precondition(!controller.busy && controller.snapshot?.accounts.count == 1, "旧候选按钮不能误添加当前列表中的其他账号")
        controller.candidateButtons[0].performClick(nil)
        try wait("浮层添加未保存第二个账号或没有关闭") {
            controller.snapshot?.accounts.count == 2 && !controller.busy && !controller.addPopover.isShown
        }
        precondition(controller.account?.source == second.path && controller.snapshot?.root?.url.path == root.path)
        precondition(controller.setupGroup.isHidden && controller.reauthorizeWeChat.isHidden)
        try wait("添加第二个账号后未恢复等待新文件") { controller.status.stringValue == "等待新文件" }

        try Data().write(to: expired)
        try wait("授权失效没有反映在状态中") { controller.snapshot?.unavailableSources.count == 1 }
        precondition(controller.reauthorizeWeChat.isHidden, "另一个账号的授权错误不应影响当前账号")
        precondition(controller.status.stringValue == "1 个账号需要处理" && controller.setupFeedback.isHidden)
        let firstID = controller.snapshot!.accounts.first { $0.source == first.path }!.id
        let firstItem = controller.accountPicker.itemArray.first { $0.representedObject as? String == firstID }!
        precondition(firstItem.title.hasSuffix("（需要处理）") && !controller.menuProblem.isHidden)
        controller.showPage(1)
        precondition(NSApp.sendAction(controller.menuProblem.action!, to: controller.menuProblem.target, from: controller.menuProblem))
        precondition(controller.account?.id == firstID && !controller.accountPage.isHidden)
        precondition(!controller.reauthorizeWeChat.isHidden)
        precondition(!controller.setupFeedback.isHidden && controller.setupFeedback.stringValue == "无法访问此账号的微信文件夹。")
        precondition(controller.setupFeedback.toolTip == "临时授权已失效")
        controller.reauthorizeWeChat.performClick(nil)
        try cancelSheet()
        precondition(!controller.reauthorizeWeChat.isHidden && controller.account?.id == firstID)
        try FileManager.default.removeItem(at: expired)
        try wait("访问恢复后仍显示重新授权") { controller.reauthorizeWeChat.isHidden }
        precondition(controller.menuProblem.isHidden && !firstItem.title.hasSuffix("（需要处理）"))

        let savedFile = root.appendingPathComponent(controller.account!.archiveRelative).appendingPathComponent("saved.txt")
        try Data("keep".utf8).write(to: savedFile)
        func stopConfirmationButton(_ title: String) throws -> NSButton {
            try wait("停止管理没有打开确认窗口") { controller.window.attachedSheet != nil }
            let sheet = controller.window.attachedSheet!
            sheet.contentView?.layoutSubtreeIfNeeded()
            func visibleViews(_ view: NSView) -> [NSView] {
                guard !view.isHidden else { return [] }
                return [view] + view.subviews.flatMap(visibleViews)
            }
            let views = sheet.contentView.map(visibleViews) ?? []
            let visibleIcons = views.compactMap { $0 as? NSImageView }.filter {
                $0.image != nil && $0.alphaValue > 0 && $0.frame.width >= 24
            }
            print("停止管理确认的可见大图标数量：\(visibleIcons.count)")
            guard let button = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else {
                throw SyncError.message("停止管理确认缺少按钮：\(title)")
            }
            return button
        }
        controller.removeAccount(nil)
        try stopConfirmationButton("取消").performClick(nil)
        try wait("取消停止管理后确认窗口没有关闭") { controller.window.attachedSheet == nil }
        precondition(controller.account?.id == firstID && controller.account?.removed == false)
        controller.removeAccount(nil)
        try stopConfirmationButton("停止管理").performClick(nil)
        try wait("确认停止管理后账号状态没有更新") { controller.account?.removed == true && !controller.busy }
        let savedContent = try String(contentsOf: savedFile, encoding: .utf8)
        precondition(savedContent == "keep" && controller.snapshot?.accounts.filter { !$0.removed }.count == 1)

        var stopped = false
        worker.stop { stopped = true }
        try wait("临时会话没有结束") { stopped }
        print("临时设置：首次启动、授权取消、浮层添加、内部滚动及账号状态均通过")
    }

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

    func reviewMenuStatus() {
        let good = snapshot!
        let menu = statusItem.menu!
        precondition(statusItem.button?.image?.isTemplate == true)
        if Bundle.main.url(forResource: "MenuBarIcon", withExtension: "pdf") != nil {
            precondition(statusItem.button?.image?.size == NSSize(width: 19, height: 19))
        }
        precondition(menu.items.first === menuStatus && !menuStatus.isEnabled)
        let unconfigured = ApplicationSnapshot(root: nil, canChooseRoot: true, accounts: [], readOnly: [:], recoverable: [:], message: "请添加微信账号")
        render(unconfigured, error: nil)
        precondition(menuStatus.title == "等待设置" && !accountStatus.isHidden && menuProblem.isHidden && !menuOpenRoot.isEnabled)
        var sample = good
        for (state, title) in [(ApplicationSyncStatus.waiting, "等待检查"), (.idle, "等待新文件"),
                               (.processing, "正在处理新文件"), (.paused, "新文件同步已暂停"), (.retrying, "正在重试")] {
            sample.syncStatus = state
            render(sample, error: nil)
            precondition(menuStatus.title == title && status.stringValue == title && menuProblem.isHidden)
        }
        render(nil, error: ApplicationSession.databaseBusyMessage)
        precondition(menuStatus.title == "正在重试" && menuProblem.isHidden && !menuOpenRoot.isEnabled)
        sample.syncStatus = .savingLocationUnavailable
        render(sample, error: "保存位置授权失效")
        precondition(menuStatus.title == "无法访问保存位置" && !menuProblem.isHidden && !menuOpenRoot.isEnabled)
        precondition(NSApp.sendAction(menuProblem.action!, to: menuProblem.target, from: menuProblem))
        precondition(!generalPage.isHidden && !rootFeedback.isHidden)
        render(good, error: nil)
        precondition(menuProblem.isHidden && rootFeedback.isHidden && menuOpenRoot.isEnabled)
        showPage(0)
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
            for size in [Self.defaultSettingsSize, Self.minimumSettingsSize] {
                window.setContentSize(size)
                for index in [0, 1] {
                    showPage(index); window.contentView!.layoutSubtreeIfNeeded()
                    let page = index == 0 ? accountPage! : generalPage!
                    guard page.frame.minY >= 0, page.frame.maxY <= page.superview!.bounds.height + 1,
                          page.arrangedSubviews.filter({ !$0.isHidden }).allSatisfy({ $0.frame.minY >= -1 && $0.frame.maxY <= page.bounds.height + 1 }) else {
                        throw SyncError.message("设置页面超出窗口范围：\(index)")
                    }
                    func check(_ view: NSView) throws {
                        if view.isHidden { return }
                        if let stack = view as? NSStackView, stack.orientation == .horizontal {
                            for child in stack.arrangedSubviews where !child.isHidden {
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
                    guard abs(visible.minY - 28) <= 2, visible.maxY <= pageScroll.contentView.bounds.height + 1,
                          pageScroll.documentView!.bounds.height <= pageScroll.contentView.bounds.height + 1 else {
                        throw SyncError.message("设置初始内容未完整显示或未从顶部开始")
                    }
                    precondition(navigation[index].state == .on && navigation[1 - index].state == .off)
                    precondition(pageTitle.stringValue == (index == 0 ? "账号与文件" : "通用"))
                }
            }
        }
        window.appearance = nil
        window.setContentSize(Self.defaultSettingsSize); showPage(0)
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
        precondition(!allowWeChat.isHidden && allowWeChat.isEnabled && managedAccountGroup.isHidden)
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
        precondition(status.stringValue == "需要处理" && setupFeedback.stringValue.contains("状态读取失败") && !readOnly.isEnabled)
        precondition(actionButtons.allSatisfy { !$0.isEnabled })
        render(nil, error: nil)
        precondition(status.stringValue == "需要处理" && setupFeedback.stringValue.contains("状态读取失败"),
                     "本地刷新不能将读库错误变回旧的正常状态")
        render(good, error: nil)
        precondition(readOnly.isEnabled && status.stringValue != "需要处理")
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
        _ = try session.store.accounts.scalar("PRAGMA busy_timeout = 0")
        return session
    }, scanInterval: 0.2)
    var healthy = false, databaseBusy = false, readFailed = false, corruptCompleted = false
    var lastMessage: String?
    worker.update = { value, error in
        lastMessage = error ?? value?.message
        healthy = value?.syncStatus == .idle && error == nil
        if value == nil && error == ApplicationSession.databaseBusyMessage { databaseBusy = true }
        if value == nil && error?.contains("状态读取失败") == true { readFailed = true }
    }
    func wait(_ step: String, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        throw SyncError.message("串行会话测试超时（\(step)）：\(lastMessage ?? "无状态")")
    }
    worker.start()
    try wait("启动并完成首次扫描") { healthy }
    let blocker = try SQLiteConnection(url: database)
    try blocker.execute("BEGIN EXCLUSIVE TRANSACTION")
    do {
        defer { try? blocker.execute("ROLLBACK") }
        try wait("运行时识别数据库占用") { databaseBusy }
    }
    try wait("从运行时占用恢复") { healthy }

    worker.perform({ session in try session.store.accounts.execute("DROP TABLE account_settings") }) { _ in corruptCompleted = true }
    try wait("处理读库故障") { corruptCompleted }
    guard readFailed else { throw SyncError.message("读库错误被隐藏为旧的正常状态") }
    let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    var actionCompleted = false, stopped = false
    worker.perform({ session in
        try session.store.accounts.execute("CREATE TABLE account_settings(account_id TEXT PRIMARY KEY REFERENCES accounts(id), read_only INTEGER NOT NULL CHECK(read_only IN (0,1)))")
        started.signal()
        guard release.wait(timeout: .now() + 5) == .success else { throw SyncError.message("测试释放超时") }
        return true
    }) { result in if case .success = result { actionCompleted = true } }
    try wait("退出前的动作开始") { started.wait(timeout: .now()) == .success }
    worker.stop { stopped = true }
    precondition(!stopped)
    release.signal()
    try wait("退出完成") { stopped }
    guard actionCompleted else { throw SyncError.message("退出没有等待已排队动作") }
    let fresh = try ApplicationSession(database: database, rootAuthorization: { DirectoryLease(url: $0.url) }, sourceAuthorization: { DirectoryLease(url: $0.sourceURL) })
    withExtendedLifetime(fresh) {}
    print("临时串行会话：运行时数据库占用可恢复，读库故障及退出写锁检查通过")
}

#endif
