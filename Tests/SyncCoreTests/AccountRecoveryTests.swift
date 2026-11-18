import Foundation
import Testing
@testable import SyncCore

final class AccountRecoveryTests {
    @Test func pendingRemovalFailureRollsBackRegistrationBaselineAndAuthorization() throws {
        let f = try MultiAccountFixture()
        _ = try f.incoming(0, "old.txt")
        let interrupted = AccountManager(repository: f.repository) { if $0 == .reserved { throw SyncError.message("stop") } }
        #expect(throws: (any Error).self) { try interrupted.add(source: f.sources[0], name: "工作", bookmark: Data("fake-source".utf8)) }
        let before = try #require(f.repository.pendingSetups().first)
        try f.repository.execute("CREATE TRIGGER fail_pending_update BEFORE UPDATE ON account_operations BEGIN SELECT RAISE(ABORT,'fake failure'); END")
        #expect(throws: (any Error).self) { try f.repository.remove(before.account.id) }
        #expect(try f.repository.accounts().isEmpty)
        #expect(try f.repository.pendingSetups() == [before])
        #expect(try f.repository.scalar("SELECT count(*) FROM baseline") == 0)
        #expect(fileInfo(f.root.appendingPathComponent(before.account.archiveRelative).path) == nil)
    }

    @Test func replayingAnOldSetupAfterActivationDoesNotCreateOrRebindDirectory() throws {
        let f = try MultiAccountFixture()
        let interrupted = AccountManager(repository: f.repository) { if $0 == .reserved { throw SyncError.message("stop") } }
        #expect(throws: (any Error).self) { try interrupted.add(source: f.sources[0], name: "工作", bookmark: nil) }
        let oldPlan = try #require(f.repository.pendingSetups().first)
        try f.manager.recover(oldPlan)
        let account = try f.repository.account(oldPlan.account.id)
        let directories = try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("微信文件").path)
        try f.manager.recover(oldPlan)
        #expect(try f.repository.account(account.id) == account)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("微信文件").path) == directories)
    }

    @Test func pendingNewAccountRemovalClearsAuthorizationAndPreservesItsBaselineForRestore() throws {
        let f = try MultiAccountFixture()
        _ = try f.incoming(0, "old.txt")
        let interrupted = AccountManager(repository: f.repository) { if $0 == .reserved { throw SyncError.message("stop") } }
        #expect(throws: (any Error).self) { try interrupted.add(source: f.sources[0], name: "工作", bookmark: Data("fake-source".utf8)) }
        let oldPlan = try #require(f.repository.pendingSetups().first)
        try f.repository.remove(oldPlan.account.id)
        let removed = try f.repository.account(oldPlan.account.id)
        #expect(removed.removed && removed.sourceBookmark == nil)
        #expect(try f.repository.pendingSetups().first?.account.sourceBookmark == nil)
        try f.manager.recover(oldPlan)
        #expect(fileInfo(f.root.appendingPathComponent(oldPlan.account.archiveRelative).path) == nil)
        try f.manager.reauthorize(removed.id, source: f.sources[0], bookmark: Data("fresh".utf8), restoring: true)
        try f.manager.recover(oldPlan)
        let restored = try f.repository.account(removed.id)
        #expect(!restored.removed && restored.sourceBookmark == Data("fresh".utf8))
        #expect(try f.repository.loadState(removed.id).baseline == oldPlan.baseline)
        #expect(try f.repository.pendingSetups().isEmpty)
    }

    @Test func pendingNewAccountCanBeReauthorizedWithoutResettingItsBaseline() throws {
        let f = try MultiAccountFixture()
        _ = try f.incoming(0, "old.txt")
        let interrupted = AccountManager(repository: f.repository) { if $0 == .reserved { throw SyncError.message("stop") } }
        #expect(throws: (any Error).self) { try interrupted.add(source: f.sources[0], name: "工作", bookmark: nil) }
        let pending = try #require(f.repository.pendingSetups().first)
        _ = try f.incoming(0, "after-reservation.txt")
        try f.manager.reauthorize(pending.account.id, source: f.sources[0], bookmark: Data("fresh-pending".utf8))
        let updated = try #require(f.repository.pendingSetups().first)
        #expect(updated.account.sourceBookmark == Data("fresh-pending".utf8))
        #expect(updated.baseline == pending.baseline)
        try f.manager.recover(updated)
        #expect(try f.repository.account(pending.account.id).sourceBookmark == Data("fresh-pending".utf8))
        #expect(try f.repository.loadState(pending.account.id).baseline.keys.sorted() == ["old.txt"])
    }

    @Test func failedReauthorizationAndRemovalRollBackBookmarksAndFlags() throws {
        let f = try MultiAccountFixture()
        let a = try f.add(0)
        try f.repository.execute("CREATE TRIGGER fail_account_update BEFORE UPDATE ON accounts BEGIN SELECT RAISE(ABORT,'fake authorization write failure'); END")
        #expect(throws: (any Error).self) { try f.manager.reauthorize(a.id, source: f.sources[0], bookmark: Data("new".utf8)) }
        #expect(throws: (any Error).self) { try f.repository.remove(a.id) }
        #expect(try f.repository.account(a.id) == a)
    }

    @Test(arguments: [AccountSetupCheckpoint.reserved, .directoryCreated, .directoryRenamed, .activated])
    func interruptedSetupRecoversWithoutLosingBaseline(_ stage: AccountSetupCheckpoint) throws {
        let f = try MultiAccountFixture()
        let existing = try f.incoming(0, "old.txt")
        let manager = AccountManager(repository: f.repository) { if $0 == stage { throw SyncError.message("injected configuration interruption") } }
        #expect(throws: (any Error).self) { try manager.add(source: f.sources[0], name: "恢复", bookmark: Data("fake".utf8)) }
        let arrivingAfterReservation = try f.incoming(0, "after.txt")
        for setup in try f.repository.pendingSetups() { try f.manager.recover(setup) }
        #expect(try f.repository.pendingSetups().isEmpty)
        let account = try #require(f.repository.accounts().first)
        let worker = try f.worker(account)
        try worker.scan(); try worker.scan()
        #expect(fileInfo(existing.path)?.regular == true)
        #expect(linkTarget(arrivingAfterReservation.path) == f.target(account, "after.txt").path)
        #expect(try f.repository.loadState(account.id).baseline.keys.sorted() == ["old.txt"])
        let directories = try FileManager.default.contentsOfDirectory(at: f.root.appendingPathComponent("微信文件"), includingPropertiesForKeys: nil)
        #expect(directories.count == 1)
    }

    @Test func failedActivationLeavesOtherAccountAndRecoversSameUUID() throws {
        let f = try MultiAccountFixture()
        let other = try f.add(1)
        try f.repository.execute("CREATE TRIGGER injected_activation BEFORE INSERT ON accounts BEGIN SELECT RAISE(ABORT,'fake full disk'); END")
        #expect(throws: (any Error).self) { try f.add(0) }
        let setup = try #require(f.repository.pendingSetups().first)
        #expect(try f.repository.accounts() == [other])
        #expect(fileInfo(f.root.appendingPathComponent(setup.account.archiveRelative).path)?.directory == true)
        try f.repository.execute("DROP TRIGGER injected_activation")
        try f.manager.recover(setup)
        #expect(try f.repository.account(setup.account.id).id == setup.account.id)
        #expect(try f.repository.account(other.id) == other)
    }

    @Test func destinationOccupiedAfterReservationUsesFreshDirectory() throws {
        let f = try MultiAccountFixture()
        let manager = AccountManager(repository: f.repository) { if $0 == .reserved { throw SyncError.message("stop") } }
        #expect(throws: (any Error).self) { try manager.add(source: f.sources[0], name: "工作", bookmark: nil) }
        let setup = try #require(f.repository.pendingSetups().first)
        let occupied = f.root.appendingPathComponent(setup.account.archiveRelative)
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        let userFile = occupied.appendingPathComponent("user.txt")
        try Data("user data".utf8).write(to: userFile)
        try f.manager.recover(setup)
        #expect(try f.repository.account(setup.account.id).archiveRelative == "微信文件/工作 (2)")
        #expect(try String(contentsOf: userFile) == "user data")
    }

    @Test func unrecordedTemporaryDirectoryIsNeverAdoptedOrDeleted() throws {
        let f = try MultiAccountFixture()
        let manager = AccountManager(repository: f.repository) { if $0 == .reserved { throw SyncError.message("stop") } }
        #expect(throws: (any Error).self) { try manager.add(source: f.sources[0], name: "工作", bookmark: nil) }
        let setup = try #require(f.repository.pendingSetups().first)
        let temporary = f.root.appendingPathComponent(setup.temporaryRelative)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let marker = temporary.appendingPathComponent("user.txt")
        try Data("keep".utf8).write(to: marker)
        let identity = try #require(fileInfo(temporary.path)?.identity)
        try f.manager.recover(setup)
        #expect(try String(contentsOf: marker) == "keep")
        #expect(try f.repository.account(setup.account.id).archiveIdentity != identity)
    }

    @Test func replacedOwnedTemporaryDirectoryBlocksRecoveryWithoutOverwriting() throws {
        let f = try MultiAccountFixture()
        let manager = AccountManager(repository: f.repository) { if $0 == .directoryCreated { throw SyncError.message("stop") } }
        #expect(throws: (any Error).self) { try manager.add(source: f.sources[0], name: "工作", bookmark: nil) }
        let setup = try #require(f.repository.pendingSetups().first)
        let temporary = f.root.appendingPathComponent(setup.temporaryRelative)
        try FileManager.default.moveItem(at: temporary, to: f.root.appendingPathComponent("原临时目录"))
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let marker = temporary.appendingPathComponent("user.txt")
        try Data("keep".utf8).write(to: marker)
        #expect(throws: (any Error).self) { try f.manager.recover(setup) }
        #expect(try f.repository.accounts().isEmpty)
        #expect(try String(contentsOf: marker) == "keep")
    }

    @Test func configurationReservationFailureDoesNotCreateArchiveOrAlterExistingAccounts() throws {
        let f = try MultiAccountFixture()
        let other = try f.add(1)
        try f.repository.execute("CREATE TRIGGER fail_reserve BEFORE INSERT ON account_operations BEGIN SELECT RAISE(ABORT,'fake full disk'); END")
        #expect(throws: (any Error).self) { try f.add(0) }
        #expect(try f.repository.accounts() == [other])
        #expect(try f.repository.pendingSetups().isEmpty)
        #expect(fileInfo(f.root.appendingPathComponent("微信文件/工作").path) == nil)
    }

    @Test func failedRootReauthorizationKeepsBookmarkAndNeverRebinds() throws {
        let f = try MultiAccountFixture()
        let root = try f.repository.root()
        #expect(throws: (any Error).self) { try f.manager.configureRoot(f.sources[0], bookmark: Data("wrong".utf8)) }
        #expect(try f.repository.root() == root)
    }
}
