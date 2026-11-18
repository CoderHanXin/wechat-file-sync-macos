import Foundation

final class DirectoryLease {
    let url: URL
    private let release: () -> Void
    init(url: URL, release: @escaping () -> Void = {}) { self.url = url; self.release = release }
    deinit { release() }
}

struct AccountScanResult {
    let accountID: String
    let paused: Bool
    let report: ScanReport?
    let error: String?
}

struct CoordinatorReport {
    var accounts: [AccountScanResult] = []
    var managedRootEnumerations = 0
}

/// Serial scheduling keeps SQLite and filesystem changes under one process writer lock.
final class SyncCoordinator {
    let repository: AccountRepository
    private let authorize: (Account) throws -> DirectoryLease
    private let enumerate: (URL) throws -> [String: FileInfo]
    private let clock: () -> Date
    private let settleSeconds: TimeInterval
    private var workers: [String: SyncWorker] = [:]
    private var bindings: [String: Account] = [:]

    init(repository: AccountRepository, settleSeconds: TimeInterval = 15,
         clock: @escaping () -> Date = Date.init,
         enumerate: @escaping (URL) throws -> [String: FileInfo] = allFiles,
         authorize: @escaping (Account) throws -> DirectoryLease) {
        self.repository = repository
        self.authorize = authorize
        self.enumerate = enumerate
        self.clock = clock
        self.settleSeconds = settleSeconds
    }

    func scan() throws -> CoordinatorReport {
        let manager = AccountManager(repository: repository)
        let root = try manager.validatedRoot()
        let accounts = try repository.accounts().filter { !$0.removed }
        let active = Set(accounts.map(\.id))
        workers = workers.filter { active.contains($0.key) }
        bindings = bindings.filter { active.contains($0.key) }
        let index = ManagedRootIndex(root: root.url, enumerate: enumerate)
        var result = CoordinatorReport()
        for account in accounts {
            do {
                let lease = try authorize(account)
                defer { withExtendedLifetime(lease) {} }
                guard try canonicalDirectory(lease.url).path == canonicalDirectory(account.sourceURL).path,
                      try readFileInfo(lease.url.path)?.identity == account.sourceIdentity else {
                    throw SyncError.message("微信账号授权与原目录不一致")
                }
                let binding = bindings[account.id]
                if workers[account.id] == nil || binding?.source != account.source
                    || binding?.archiveRelative != account.archiveRelative || binding?.archiveIdentity != account.archiveIdentity {
                    workers[account.id] = try SyncWorker(store: AccountStateStore(repository: repository, accountID: account.id),
                        archiveRelative: account.archiveRelative, archiveIdentity: account.archiveIdentity,
                        settleSeconds: settleSeconds, clock: clock, enumerate: enumerate)
                }
                bindings[account.id] = account
                try workers[account.id]?.scan(acceptNewFiles: account.intakeEnabled, sharedIndex: index)
                result.accounts.append(AccountScanResult(accountID: account.id, paused: !account.intakeEnabled,
                                                        report: workers[account.id]?.report, error: nil))
            } catch let error as SyncError {
                if case .persistence = error { throw error }
                // Re-observe intake after any period of unavailable authorization or source.
                workers.removeValue(forKey: account.id)
                bindings.removeValue(forKey: account.id)
                result.accounts.append(AccountScanResult(accountID: account.id, paused: !account.intakeEnabled, report: nil, error: error.description))
            } catch let error as SQLiteStoreError {
                throw SyncError.persistence(error.description)
            } catch {
                workers.removeValue(forKey: account.id)
                bindings.removeValue(forKey: account.id)
                result.accounts.append(AccountScanResult(accountID: account.id, paused: !account.intakeEnabled, report: nil, error: String(describing: error)))
            }
        }
        result.managedRootEnumerations = index.enumerations
        return result
    }
}
