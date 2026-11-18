import Foundation

/// Recovery of one v2 move cannot rewrite or advance another operation's state.
final class LegacyTransferStore: StateStore {
    let repository: AccountRepository
    let accountID: String
    let relative: String
    init(repository: AccountRepository, accountID: String, relative: String) {
        self.repository = repository; self.accountID = accountID; self.relative = relative
    }
    func load() throws -> SyncState {
        var state = try repository.loadState(accountID)
        state.transfers = state.transfers.filter { $0.key == relative }
        return state
    }
    func save(_ state: SyncState) throws {
        let adapter = AccountStateStore(repository: repository, accountID: accountID)
        var full = try adapter.load()
        guard full.source == state.source, full.sourceIdentity == state.sourceIdentity,
              full.managedRoot == state.managedRoot, full.managedRootIdentity == state.managedRootIdentity else {
            throw SyncError.persistence("旧移动恢复配置不一致")
        }
        full.transfers[relative] = state.transfers[relative]
        try adapter.save(full)
    }
}
