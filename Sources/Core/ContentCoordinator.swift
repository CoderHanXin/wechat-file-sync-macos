import Foundation

final class ContentCoordinator {
    let store: ContentRepository
    private let authorize: (Account) throws -> DirectoryLease
    private let settleSeconds: TimeInterval
    private let acceptNewFiles: Bool?
    private var workers: [String: ContentWorker] = [:]

    init(store: ContentRepository, settleSeconds: TimeInterval = 15, acceptNewFiles: Bool? = nil,
         authorize: @escaping (Account) throws -> DirectoryLease) {
        self.store = store; self.settleSeconds = settleSeconds
        self.acceptNewFiles = acceptNewFiles; self.authorize = authorize
    }

    func scan() throws -> CoordinatorReport {
        let root = try AccountManager(repository: store.accounts).validatedRoot()
        let accounts = try store.accounts.accounts().filter { !$0.removed }
        workers = workers.filter { id, _ in accounts.contains { $0.id == id } }
        let index = ManagedRootIndex(root: root.url)
        var result = CoordinatorReport()
        for account in accounts {
            var sourceValidated = false
            do {
                let lease = try authorize(account)
                defer { withExtendedLifetime(lease) {} }
                guard try canonicalDirectory(lease.url).path == canonicalDirectory(account.sourceURL).path,
                      try readFileInfo(lease.url.path)?.identity == account.sourceIdentity else { throw SyncError.message("账号源授权不匹配") }
                sourceValidated = true
                if workers[account.id] == nil { workers[account.id] = ContentWorker(store: store, accountID: account.id, settleSeconds: settleSeconds) }
                try workers[account.id]?.scan(index: index, acceptNewFiles: acceptNewFiles, lease: lease)
                result.accounts.append(AccountScanResult(accountID: account.id, paused: !account.intakeEnabled, report: workers[account.id]?.report, error: nil))
            } catch let error as SQLiteStoreError { throw SyncError.persistenceFailure(error) }
            catch let error as SyncError {
                if case .persistence = error { throw error }
                workers.removeValue(forKey: account.id)
                result.accounts.append(AccountScanResult(accountID: account.id, paused: !account.intakeEnabled, report: nil, error: error.description, sourceUnavailable: !sourceValidated))
            } catch {
                workers.removeValue(forKey: account.id)
                result.accounts.append(AccountScanResult(accountID: account.id, paused: !account.intakeEnabled, report: nil, error: String(describing: error), sourceUnavailable: !sourceValidated))
            }
        }
        result.managedRootEnumerations = index.enumerations
        return result
    }
}
