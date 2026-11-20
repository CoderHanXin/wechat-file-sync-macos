import Foundation

enum ApplicationSyncStatus: Equatable {
    case waiting, idle, processing, paused, retrying, needsAttention, savingLocationUnavailable
}

struct ApplicationSnapshot {
    let root: ManagedRoot?
    let canChooseRoot: Bool
    let accounts: [Account]
    let readOnly: [String: Bool]
    let recoverable: [String: [ContentEntity]]
    let message: String
    var unavailableSources: Set<String> = []
    var syncStatus: ApplicationSyncStatus = .waiting
    var accountIssues: [String: String] = [:]
}

/// The desktop worker calls this on one serial queue; UI callbacks never use its connection.
final class ApplicationSession {
    static let databaseBusyMessage = "状态库暂被占用，稍后会自动重试。"

    let store: ContentRepository
    private let lock: ProcessLock
    private let rootAuthorization: (ManagedRoot) throws -> DirectoryLease
    private let sourceAuthorization: (Account) throws -> DirectoryLease
    private let settleSeconds: TimeInterval
    private var lease: DirectoryLease?
    private var coordinator: ContentCoordinator?
    private var halted = false
    private var unavailableSources: Set<String> = []
    private var syncStatus: ApplicationSyncStatus = .waiting
    private var accountIssues: [String: String] = [:]
    private(set) var message = "尚未检查目录"

    init(database: URL, rootAuthorization: @escaping (ManagedRoot) throws -> DirectoryLease,
         sourceAuthorization: @escaping (Account) throws -> DirectoryLease, settleSeconds: TimeInterval = 15) throws {
        try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        lock = try ProcessLock(url: database.deletingLastPathComponent().appendingPathComponent("sync.lock"))
        store = try ContentRepository(url: database)
        self.rootAuthorization = rootAuthorization; self.sourceAuthorization = sourceAuthorization
        self.settleSeconds = settleSeconds
    }

    func scan() throws {
        guard !halted else { return }
        var failureStatus = ApplicationSyncStatus.needsAttention
        do {
            guard let root = try store.accounts.root() else { message = "先添加微信账号，再选择文件保存位置"; return }
            failureStatus = .savingLocationUnavailable
            if lease == nil { lease = try rootAuthorization(root) }
            guard let lease, try canonicalDirectory(lease.url).path == canonicalDirectory(root.url).path,
                  try readFileInfo(lease.url.path)?.identity == root.identity else { throw SyncError.message("管理根目录授权不匹配") }
            failureStatus = .needsAttention
            let manager = AccountManager(repository: store.accounts)
            var setupErrors: [String] = []
            for setup in try store.accounts.pendingSetups() where !setup.account.removed {
                do {
                    let source = try sourceAuthorization(setup.account)
                    defer { withExtendedLifetime(source) {} }
                    try manager.recover(setup)
                } catch let error as SQLiteStoreError { throw error }
                catch let error as SyncError {
                    if case .persistence = error { throw error }
                    setupErrors.append("\(setup.account.name)：\(error)")
                } catch { setupErrors.append("\(setup.account.name)：\(error)") }
            }
            if coordinator == nil { coordinator = ContentCoordinator(store: store, settleSeconds: settleSeconds, authorize: sourceAuthorization) }
            let report = try coordinator!.scan()
            unavailableSources = Set(report.accounts.filter(\.sourceUnavailable).map(\.accountID))
            let accountMessages = report.accounts.map { result in
                var messages = result.error.map { [$0] } ?? []
                messages += (result.report?.issues ?? []).map { "\($0.relative)：\($0.message)" }
                return (result.accountID, messages)
            }
            accountIssues = Dictionary(uniqueKeysWithValues: accountMessages.compactMap { id, messages in
                messages.first.map { (id, $0) }
            })
            let errors = setupErrors + accountMessages.flatMap { $0.1 }
            if !errors.isEmpty {
                syncStatus = .needsAttention
                message = "需要处理：\(errors.prefix(3).joined(separator: "；"))"
            } else if report.accounts.isEmpty {
                syncStatus = .waiting
                message = "请添加微信账号"
            } else if report.accounts.allSatisfy(\.paused) {
                syncStatus = .paused
                message = "新文件同步已暂停，已有链接仍会维护。"
            } else if report.accounts.contains(where: { $0.report?.hasPendingIntake == true }) {
                syncStatus = .processing
                message = "已发现新文件，正在等待写入完成、校验或保存。"
            } else {
                syncStatus = .idle
                message = "已检查微信文件夹，当前没有待处理的新文件。"
            }
        } catch where isDatabaseBusy(error) {
            waitForDatabase()
            throw error
        } catch let error as SyncError {
            if case .persistence = error { halted = true; failureStatus = .needsAttention }
            resetScan(error.description, status: failureStatus)
            throw error
        } catch let error as SQLiteStoreError {
            halted = true; scanFailed("状态保存失败，已停止同步：\(error)")
            throw error
        } catch {
            resetScan(String(describing: error), status: failureStatus)
            throw error
        }
    }

    private func resetScan(_ reason: String, status: ApplicationSyncStatus) {
        coordinator = nil; lease = nil
        unavailableSources = []
        accountIssues = [:]
        syncStatus = status; message = reason
    }

    private func scanFailed(_ reason: String) {
        resetScan(reason, status: .needsAttention)
    }

    func waitForDatabase() {
        guard !halted else { return }
        resetScan(Self.databaseBusyMessage, status: .retrying)
    }

    func stopScanning(_ reason: String) {
        halted = true
        scanFailed(reason)
    }

    func change(_ action: (ContentRepository) throws -> Void) throws {
        // Release observation jobs before changing configuration; durable jobs remain in SQLite.
        coordinator = nil; lease = nil
        try action(store)
        halted = false
        unavailableSources = []
        accountIssues = [:]
        syncStatus = .waiting
        message = "设置已保存，等待下一次检查"
    }

    func savedRootAccess() throws -> DirectoryLease {
        guard let root = try store.accounts.root() else { throw SyncError.message("请先选择文件保存位置") }
        return try rootAuthorization(root)
    }

    func snapshot() throws -> ApplicationSnapshot {
        let accounts = try store.accounts.accounts()
        var defaults: [String: Bool] = [:]
        var lost: [String: [ContentEntity]] = [:]
        for account in accounts {
            defaults[account.id] = try store.readOnlyDefault(account.id)
            let sources = try store.sources(account.id)
            lost[account.id] = try store.entities(account.id).filter { entity in
                sources.contains { $0.entityID == entity.id && !$0.active && $0.endReason != .external && $0.endReason != .reused }
            }
        }
        return ApplicationSnapshot(root: try store.accounts.root(), canChooseRoot: try store.accounts.canChooseRoot(),
            accounts: accounts, readOnly: defaults, recoverable: lost, message: message,
            unavailableSources: unavailableSources, syncStatus: syncStatus, accountIssues: accountIssues)
    }
}
