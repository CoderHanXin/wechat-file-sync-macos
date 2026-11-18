import Foundation
import Testing
@testable import SyncCore

final class AccountMigrationTests {
    @Test func missingV1ConfigurationWithRemainingRecordsNeverMigratesOrReimports() throws {
        let f = try Fixture(existing: ["old.txt": "old"])
        try JSONEncoder().encode(f.worker.state).write(to: f.root.appendingPathComponent("state.json"))
        try f.store.base.execute("DELETE FROM configuration")
        #expect(throws: (any Error).self) { try openAccountRepository(appSupport: f.root) }
        #expect(try f.store.base.scalar("PRAGMA user_version") == 1)
        #expect(try f.store.base.scalar("SELECT count(*) FROM baseline") == 1)
        #expect(try f.store.base.scalar("SELECT count(*) FROM sqlite_master WHERE name='managed_roots'") == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.root.path).allSatisfy { !$0.hasPrefix("state.v1-backup-") })
    }

    @Test func backupFailureDoesNotOverwriteAnotherFileOrModifyTheSourceDatabase() throws {
        let f = try Fixture(existing: ["old.txt": "old"])
        let before = try f.store.load()
        let occupied = f.root.appendingPathComponent("occupied-backup.sqlite")
        let marker = Data("keep existing file".utf8)
        try marker.write(to: occupied)
        #expect(throws: (any Error).self) { try f.store.base.backup(to: occupied) }
        #expect(try Data(contentsOf: occupied) == marker)
        #expect(try SQLiteStateStore(url: f.databaseURL, readOnly: true).load() == before)
        #expect(try f.store.base.scalar("PRAGMA user_version") == 1)
    }

    @Test func removedMigratedAccountRetainsRetargetedSetupForRecovery() throws {
        let f = try Fixture(existing: ["old.txt": "old"])
        let repository = try AccountRepository(url: f.databaseURL)
        let manager = AccountManager(repository: repository)
        let account = try #require(repository.accounts().first)
        let occupied = f.managedRoot.appendingPathComponent(account.archiveRelative)
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        let marker = occupied.appendingPathComponent("user.txt")
        try Data("keep user data".utf8).write(to: marker)
        try repository.execute("CREATE TRIGGER fail_activation BEFORE UPDATE ON accounts BEGIN SELECT RAISE(ABORT,'fake failure'); END")
        #expect(throws: (any Error).self) { try manager.recover(#require(repository.pendingSetups().first)) }
        let planned = try #require(repository.pendingSetups().first)
        #expect(planned.account.archiveRelative != account.archiveRelative)
        #expect(fileInfo(f.managedRoot.appendingPathComponent(planned.account.archiveRelative).path)?.identity == planned.directoryIdentity)
        try repository.execute("DROP TRIGGER fail_activation")
        try repository.remove(account.id)
        let removedPlan = try #require(repository.pendingSetups().first)
        #expect(removedPlan.account.archiveRelative == planned.account.archiveRelative)
        #expect(removedPlan.account.sourceBookmark == nil)
        try manager.reauthorize(account.id, source: f.source, bookmark: Data("new".utf8), restoring: true)
        try manager.recover(#require(repository.pendingSetups().first))
        #expect(try repository.account(account.id).archiveRelative == planned.account.archiveRelative)
        #expect(try repository.loadState(account.id) == f.worker.state)
        #expect(try String(contentsOf: marker) == "keep user data")
    }

    @Test func migratedDirectoryAliasesCanBeReauthorizedWithoutChangingStoredPaths() throws {
        let f = try Fixture(existing: ["old.txt": "old"])
        let repository = try AccountRepository(url: f.databaseURL)
        let manager = AccountManager(repository: repository)
        let account = try #require(repository.accounts().first)
        try manager.configureRoot(canonicalDirectory(f.managedRoot), bookmark: Data("root-new".utf8))
        try manager.reauthorize(account.id, source: canonicalDirectory(f.source), bookmark: Data("source-new".utf8))
        #expect(try repository.root()?.path == f.managedRoot.path)
        #expect(try repository.account(account.id).source == f.source.path)
        #expect(try repository.loadState(account.id) == f.worker.state)
    }

    @Test func corruptAccountRecordsStopTheSharedCoordinator() throws {
        let f = try MultiAccountFixture()
        _ = try f.incoming(0, "old.txt")
        let a = try f.add(0); _ = try f.add(1)
        let sourceB = try f.incoming(1)
        try f.repository.execute("UPDATE baseline SET identity=? WHERE account_id=?", [.blob(Data("invalid identity".utf8)), .text(a.id)])
        do {
            _ = try f.coordinator().scan()
            Issue.record("corrupt state should stop the round")
        } catch let error as SyncError {
            if case .persistence = error {} else { Issue.record("expected a global persistence error") }
        }
        #expect(fileInfo(sourceB.path)?.regular == true)
        #expect(throws: SQLiteStoreError.self) { try f.repository.loadState(a.id) }
    }

    @Test func migrationKeepsEveryPhaseBaselineBookmarksAndFileLocation() throws {
        let f = try Fixture(existing: ["old.txt": "old"])
        let linked = try f.sync("linked.txt")
        let pending = try f.incoming("planned.txt")
        let conflict = try f.incoming("conflict.txt")
        f.worker.state.transfers["planned.txt"] = Transfer(destination: "planned.txt", temporary: temporaryPrefix + "plan",
            identity: try #require(fileInfo(pending.path)?.identity), phase: .planned, observedInfo: fileInfo(pending.path))
        f.worker.state.transfers["conflict.txt"] = Transfer(destination: "conflict.txt", temporary: temporaryPrefix + "conflict",
            identity: try #require(fileInfo(conflict.path)?.identity), phase: .conflict)
        let before = f.worker.state
        let bookmarks = DirectoryBookmarks(source: Data("fake-source".utf8), managedRoot: Data("fake-root".utf8))
        try f.store.base.configure(before, bookmarks: bookmarks)
        let repository = try AccountRepository(url: f.databaseURL)
        let account = try #require(repository.accounts().first)
        #expect(account.name == "原账号")
        #expect(account.sourceBookmark == bookmarks.source)
        #expect(try repository.root()?.bookmark == bookmarks.managedRoot)
        #expect(try repository.loadState(account.id) == before)
        #expect(linkTarget(linked.path) == f.target("linked.txt").path)
        #expect(fileInfo(f.managedRoot.appendingPathComponent(account.archiveRelative).path) == nil)
        let backups = try FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("state.v1-backup-") }
        let backup = try #require(backups.first)
        #expect(try SQLiteStateStore(url: backup, readOnly: true).load() == before)
        #expect((try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let manager = AccountManager(repository: repository)
        try manager.recover(#require(repository.pendingSetups().first))
        let ready = try repository.account(account.id)
        let worker = try SyncWorker(store: AccountStateStore(repository: repository, accountID: account.id), archiveRelative: ready.archiveRelative,
                                    archiveIdentity: ready.archiveIdentity, settleSeconds: 0)
        try worker.scan()
        #expect(linkTarget(pending.path) == f.target("planned.txt").path)
        let fresh = try f.incoming("new-after-upgrade.txt")
        try worker.scan(); try worker.scan()
        #expect(linkTarget(fresh.path) == f.managedRoot.appendingPathComponent(ready.archiveRelative + "/new-after-upgrade.txt").path)
        #expect(linkTarget(linked.path) == f.target("linked.txt").path)
        #expect(try repository.loadState(account.id).transfers["conflict.txt"]?.phase == .conflict)
    }

    @Test(arguments: [DatabaseMigrationCheckpoint.backupCreated, .rowsCopied, .beforeCommit])
    func migrationFailureLeavesReadableV1AndRetryDoesNotDuplicate(_ stage: DatabaseMigrationCheckpoint) throws {
        let f = try Fixture(existing: ["old.txt": "old"])
        _ = try f.sync("linked.txt")
        let before = try f.store.load()
        #expect(throws: (any Error).self) {
            try AccountRepository(url: f.databaseURL, migrationCheckpoint: { if $0 == stage { throw SyncError.message("migration interrupted") } })
        }
        #expect(try SQLiteStateStore(url: f.databaseURL, readOnly: true).load() == before)
        let repository = try AccountRepository(url: f.databaseURL)
        #expect(try repository.accounts().count == 1)
        #expect(try repository.loadState(#require(repository.accounts().first).id) == before)
        #expect(try AccountRepository(url: f.databaseURL).accounts() == repository.accounts())
    }

    @Test func readonlyNeverMigratesOrBacksUpV1() throws {
        let f = try Fixture()
        #expect(throws: (any Error).self) { try AccountRepository(url: f.databaseURL, readOnly: true) }
        #expect(try SQLiteStateStore(url: f.databaseURL).load() == f.worker.state)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.root.path).allSatisfy { !$0.hasPrefix("state.v1-backup-") })
    }

    @Test func removedMigratedAccountClearsPendingAuthorizationAndDoesNotReactivate() throws {
        let f = try Fixture()
        try f.store.base.configure(f.worker.state, bookmarks: DirectoryBookmarks(source: Data("secret-fake".utf8), managedRoot: Data("root-fake".utf8)))
        let repository = try AccountRepository(url: f.databaseURL)
        let account = try #require(repository.accounts().first)
        try repository.remove(account.id)
        let setup = try #require(repository.pendingSetups().first)
        #expect(setup.account.sourceBookmark == nil && setup.account.removed)
        try AccountManager(repository: repository).recover(setup)
        #expect(try repository.account(account.id).removed)
        #expect(try repository.account(account.id).archiveIdentity == nil)
        #expect(fileInfo(f.managedRoot.appendingPathComponent(account.archiveRelative).path) == nil)
    }

    @Test func jsonImportOnlyOnceAndNeverRestoresRemovedAuthorization() throws {
        let f = try Fixture()
        let support = f.root.appendingPathComponent("v2-json")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let jsonURL = support.appendingPathComponent("state.json")
        let original = try JSONEncoder().encode(f.worker.state)
        try original.write(to: jsonURL)
        try Data("fake-source".utf8).write(to: support.appendingPathComponent("source.bookmark"))
        try Data("fake-root".utf8).write(to: support.appendingPathComponent("downloads.bookmark"))
        let repository = try openAccountRepository(appSupport: support)
        let account = try #require(repository.accounts().first)
        try repository.remove(account.id)
        let reopened = try openAccountRepository(appSupport: support)
        #expect(try reopened.accounts().count == 1)
        #expect(try reopened.account(account.id).sourceBookmark == nil)
        #expect(try Data(contentsOf: jsonURL) == original)
    }

    @Test func unknownOrCorruptV2NeverFallsBackToJSON() throws {
        let f = try MultiAccountFixture()
        let account = try f.add(0)
        let state = try f.repository.loadState(account.id)
        try JSONEncoder().encode(state).write(to: f.temporary.appendingPathComponent("state.json"))
        try f.repository.execute("PRAGMA user_version=99")
        #expect(throws: (any Error).self) { try openAccountRepository(appSupport: f.temporary) }
        try f.repository.execute("PRAGMA user_version=2")
        #expect(try AccountRepository(url: f.repository.url).account(account.id) == account)
        let corruptSupport = f.temporary.appendingPathComponent("corrupt")
        try FileManager.default.createDirectory(at: corruptSupport, withIntermediateDirectories: true)
        let garbage = Data("not sqlite".utf8)
        try garbage.write(to: corruptSupport.appendingPathComponent("state.sqlite"))
        try JSONEncoder().encode(state).write(to: corruptSupport.appendingPathComponent("state.json"))
        #expect(throws: (any Error).self) { try openAccountRepository(appSupport: corruptSupport) }
        #expect(try Data(contentsOf: corruptSupport.appendingPathComponent("state.sqlite")) == garbage)
    }

    @Test func readerCanListDuringWriterLockButCannotChangeConfig() throws {
        let f = try MultiAccountFixture()
        let account = try f.add(0)
        let lock = try ProcessLock(url: f.temporary.appendingPathComponent("sync.lock"))
        defer { withExtendedLifetime(lock) {} }
        let reader = try AccountRepository(url: f.repository.url, readOnly: true)
        #expect(try reader.accounts() == [account])
        #expect(throws: (any Error).self) { try AccountManager(repository: reader).setPaused(account.id, paused: true) }
        #expect(throws: (any Error).self) { try ProcessLock(url: f.temporary.appendingPathComponent("sync.lock")) }
        #expect(try f.repository.account(account.id) == account)
    }

    @Test func failedAccountStateWriteRollsBackOnlyThatAccountAndStopsCoordinator() throws {
        let f = try MultiAccountFixture()
        let a = try f.add(0); let b = try f.add(1)
        let beforeA = try f.repository.loadState(a.id); let beforeB = try f.repository.loadState(b.id)
        let source = try f.incoming(0)
        try f.repository.execute("CREATE TRIGGER fail_transfer BEFORE INSERT ON transfers BEGIN SELECT RAISE(ABORT,'fake disk failure'); END")
        let coordinator = f.coordinator()
        _ = try coordinator.scan()
        #expect(throws: (any Error).self) { try coordinator.scan() }
        #expect(fileInfo(source.path)?.regular == true)
        #expect(try f.repository.loadState(a.id) == beforeA)
        #expect(try f.repository.loadState(b.id) == beforeB)
    }
}
