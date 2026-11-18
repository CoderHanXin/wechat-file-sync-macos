import Foundation

struct ApplicationSnapshot {
    let root: ManagedRoot?
    let accounts: [Account]
    let readOnly: [String: Bool]
    let recoverable: [String: [ContentEntity]]
    let message: String
}

/// The desktop worker calls this on one serial queue; UI callbacks never use its connection.
final class ApplicationSession {
    let store: ContentRepository
    private let lock: ProcessLock
    private let rootAuthorization: (ManagedRoot) throws -> DirectoryLease
    private let sourceAuthorization: (Account) throws -> DirectoryLease
    private var lease: DirectoryLease?
    private var coordinator: ContentCoordinator?
    private var halted = false
    private(set) var message = "尚未检查目录"

    init(database: URL, rootAuthorization: @escaping (ManagedRoot) throws -> DirectoryLease,
         sourceAuthorization: @escaping (Account) throws -> DirectoryLease) throws {
        try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        lock = try ProcessLock(url: database.deletingLastPathComponent().appendingPathComponent("sync.lock"))
        store = try ContentRepository(url: database)
        self.rootAuthorization = rootAuthorization; self.sourceAuthorization = sourceAuthorization
    }

    func scan() throws {
        guard !halted else { return }
        guard let root = try store.accounts.root() else { message = "请选择归档目录并添加账号"; return }
        do {
            if lease == nil { lease = try rootAuthorization(root) }
            guard let lease, try canonicalDirectory(lease.url).path == canonicalDirectory(root.url).path,
                  try readFileInfo(lease.url.path)?.identity == root.identity else { throw SyncError.message("管理根目录授权不匹配") }
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
            if coordinator == nil { coordinator = ContentCoordinator(store: store, authorize: sourceAuthorization) }
            let report = try coordinator!.scan()
            let errors = setupErrors + report.accounts.flatMap { result -> [String] in
                var messages = result.error.map { [$0] } ?? []
                messages += (result.report?.issues ?? []).map { "\($0.relative)：\($0.message)" }
                return messages
            }
            let active = report.accounts.filter { !$0.paused }.count
            message = errors.isEmpty ? (report.accounts.isEmpty ? "请添加微信账号" : "正常 · \(active) 个账号接纳新文件，其余暂停新增") : "需要处理：\(errors.prefix(3).joined(separator: "；"))"
        } catch let error as SyncError {
            if case .persistence = error { halted = true }
            coordinator = nil; lease = nil; message = error.description
            throw error
        } catch let error as SQLiteStoreError {
            halted = true; coordinator = nil; lease = nil; message = "状态保存失败，已停止同步：\(error)"
            throw error
        } catch {
            coordinator = nil; lease = nil; message = String(describing: error)
            throw error
        }
    }

    func change(_ action: (ContentRepository) throws -> Void) throws {
        // Release observation jobs before changing configuration; durable jobs remain in SQLite.
        coordinator = nil; lease = nil
        try action(store)
        halted = false
        message = "设置已保存，等待下一次检查"
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
        return ApplicationSnapshot(root: try store.accounts.root(), accounts: accounts, readOnly: defaults, recoverable: lost, message: message)
    }
}
