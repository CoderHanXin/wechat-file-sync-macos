import Foundation
import Testing
@testable import SyncCore

@Suite("M4-M6 review regressions")
final class RecoveryReviewTests {
    @Test func returningIdentityRecoversAfterOldArchivePathWasReused() throws {
        let f = try ContentFixture()
        let source = try f.sync("a.txt")
        let entity = try #require(f.store.entities(f.a.id).first)
        let archive = f.files.root.appendingPathComponent(entity.relative)
        let outside = f.files.temporary.appendingPathComponent("outside")
        try FileManager.default.moveItem(at: archive, to: outside)
        let worker = ContentWorker(store: f.store, accountID: f.a.id, settleSeconds: 0, recoveryInterval: 0)
        try worker.scan()
        try Data("occupant".utf8).write(to: archive)
        try worker.scan()
        #expect(try f.store.entities(f.a.id).first?.status == .conflict)
        let returned = f.files.root.appendingPathComponent("returned.txt")
        try FileManager.default.moveItem(at: outside, to: returned)
        try worker.scan()
        #expect(linkTarget(source.path) == returned.path)
        #expect(try String(contentsOf: archive, encoding: .utf8) == "occupant")
    }

    @Test func emptyFirstSetupCanChooseAnotherRootWithoutMovingFiles() throws {
        let f = try MultiAccountFixture()
        let marker = f.root.appendingPathComponent("user.txt")
        try Data("untouched".utf8).write(to: marker)
        let fresh = f.temporary.appendingPathComponent("correct-root")
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        try f.manager.configureRoot(fresh, bookmark: Data("new-root".utf8))
        #expect(try f.repository.root()?.path == fresh.path)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "untouched")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fresh.path).isEmpty)
    }

    @Test func unfinishedAccountStillPreventsRootChange() throws {
        let f = try MultiAccountFixture()
        let interrupted = AccountManager(repository: f.repository) { if $0 == .reserved { throw SyncError.message("stop") } }
        #expect(throws: (any Error).self) { try interrupted.add(source: f.sources[0], name: "pending", bookmark: nil) }
        #expect(try f.repository.accounts().isEmpty)
        #expect(throws: (any Error).self) { try f.manager.configureRoot(f.sources[1], bookmark: nil) }
        #expect(try f.repository.root()?.path == f.root.path)
    }
    @Test func emptyMissingRootCanBeReselectedButBoundOrRemovedAccountsCannot() throws {
        let f = try MultiAccountFixture()
        try FileManager.default.removeItem(at: f.root)
        let fresh = f.temporary.appendingPathComponent("new-root")
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        try f.manager.configureRoot(fresh, bookmark: nil)
        let account = try f.add(0)
        try f.repository.remove(account.id)
        #expect(try !f.repository.canChooseRoot())
        #expect(throws: (any Error).self) { try f.manager.configureRoot(f.sources[1], bookmark: nil) }
        #expect(try f.repository.root()?.path == fresh.path)
    }

    @Test func rootReselectionFailurePreservesPreviousAuthorization() throws {
        let f = try MultiAccountFixture()
        let before = try f.repository.root()
        try f.repository.execute("CREATE TRIGGER reject_root BEFORE UPDATE ON managed_roots BEGIN SELECT RAISE(ABORT,'injected failure'); END")
        #expect(throws: (any Error).self) { try f.manager.configureRoot(f.sources[1], bookmark: Data("new".utf8)) }
        #expect(try f.repository.root() == before)
    }

    @Test func conflictedReturnChecksStillUseTheRecoveryInterval() throws {
        let f = try ContentFixture()
        let source = try f.sync("a.txt")
        let entity = try #require(f.store.entities(f.a.id).first)
        let archive = f.files.root.appendingPathComponent(entity.relative)
        let outside = f.files.temporary.appendingPathComponent("outside")
        try FileManager.default.moveItem(at: archive, to: outside)
        let worker = ContentWorker(store: f.store, accountID: f.a.id, settleSeconds: 0, clock: { f.files.now }, recoveryInterval: 30)
        try worker.scan()
        try Data("occupied".utf8).write(to: archive)
        f.files.now.addTimeInterval(31)
        try worker.scan()
        let returned = f.files.root.appendingPathComponent("returned")
        try FileManager.default.moveItem(at: outside, to: returned)
        let early = ManagedRootIndex(root: f.files.root)
        try worker.scan(index: early)
        #expect(early.enumerations == 0 && fileInfo(source.path) == nil)
        f.files.now.addTimeInterval(31)
        let due = ManagedRootIndex(root: f.files.root)
        try worker.scan(index: due)
        #expect(due.enumerations == 1 && linkTarget(source.path) == returned.path)
    }

    @Test(arguments: [ContentCheckpoint.recoveryPrepared, .recoveryInstalled])
    func recoveryInterruptedBySourceParentRedirectNeverWritesOutside(_ stage: ContentCheckpoint) throws {
        let f = try ContentFixture()
        let source = try f.sync("month/a.txt")
        let entity = try #require(f.store.entities(f.a.id).first)
        try FileManager.default.removeItem(at: f.files.root.appendingPathComponent(entity.relative))
        try ContentWorker(store: f.store, accountID: f.a.id, settleSeconds: 0).scan()
        let copy = f.files.root.appendingPathComponent("copy")
        try Data("copy".utf8).write(to: copy)
        let outside = f.files.temporary.appendingPathComponent("redirect")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("a.txt")
        try Data("untouched".utf8).write(to: sentinel)
        let parent = source.deletingLastPathComponent(), saved = f.files.temporary.appendingPathComponent("original-parent")
        let recovery = LinkRecovery(store: f.store, checkpoint: { point in
            if point == stage {
                try FileManager.default.moveItem(at: parent, to: saved)
                try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
            }
        })
        let preview = try recovery.preview(accountID: f.a.id, entityID: entity.id, file: copy)
        #expect(try recovery.apply(preview).count == 1)
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "untouched")
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["a.txt"])
        let op = try #require(f.store.operations(f.a.id).first)
        try FileManager.default.removeItem(at: parent)
        try FileManager.default.moveItem(at: saved, to: parent)
        try LinkRecovery(store: f.store).run(op)
        #expect(linkTarget(source.path) == copy.path)
    }

}
