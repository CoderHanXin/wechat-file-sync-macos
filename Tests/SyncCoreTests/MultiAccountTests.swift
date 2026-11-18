import Foundation
import Testing
@testable import SyncCore

final class MultiAccountTests {
    @Test(arguments: [false, true])
    func linkInstalledInterruptionThenCrossAccountMoveRecovers(_ reuseOldName: Bool) throws {
        let f = try MultiAccountFixture()
        let a = try f.add(0); let b = try f.add(1)
        let source = try f.incoming(0)
        let interrupted = try f.worker(a) { if $0 == .linkInstalled { throw SyncError.message("stop after link installation") } }
        try interrupted.scan(); try interrupted.scan()
        #expect(try f.repository.loadState(a.id).transfers.values.first?.phase == .planned)
        let moved = f.target(b, "relocated.txt")
        try FileManager.default.moveItem(at: f.target(a), to: moved)
        if reuseOldName { try Data("unrelated".utf8).write(to: f.target(a)) }
        let updateInterrupted = try f.worker(a) { if $0 == .linkUpdated { throw SyncError.message("stop after recovery link update") } }
        try updateInterrupted.scan()
        #expect(linkTarget(source.path) == moved.path)
        let restarted = try f.worker(a)
        try restarted.scan(); try restarted.scan()
        let records = try f.repository.loadState(a.id).transfers
        #expect(records.values.first?.destination == b.archiveRelative + "/relocated.txt")
        #expect(records.values.first?.phase == .linked)
        #expect(try f.repository.loadState(b.id).transfers.isEmpty)
        #expect(try String(contentsOf: source) == "original")
        if reuseOldName { #expect(try String(contentsOf: f.target(a)) == "unrelated") }
    }

    @Test func pauseFlagSurvivesRestartAndReauthorization() throws {
        let f = try MultiAccountFixture()
        let a = try f.add(0)
        try f.manager.setPaused(a.id, paused: true)
        try f.manager.reauthorize(a.id, source: f.sources[0], bookmark: Data("fresh".utf8))
        let reopened = try AccountRepository(url: f.repository.url)
        #expect(try !reopened.account(a.id).intakeEnabled)
        let source = try f.incoming(0)
        let coordinator = SyncCoordinator(repository: reopened, settleSeconds: 0) { DirectoryLease(url: $0.sourceURL) }
        _ = try coordinator.scan(); _ = try coordinator.scan()
        #expect(fileInfo(source.path)?.regular == true)
    }

    @Test func caseVariantsNeverShareAnArchiveDirectory() throws {
        let f = try MultiAccountFixture()
        let a = try f.add(0, name: "Work")
        let b = try f.add(1, name: "work")
        #expect(a.archiveIdentity != b.archiveIdentity)
        #expect(fileInfo(f.root.appendingPathComponent(a.archiveRelative).path)?.identity == a.archiveIdentity)
    }

    @Test func missingSourceDoesNotResetBaselineOrBlockOtherAccount() throws {
        let f = try MultiAccountFixture()
        _ = try f.incoming(0, "old.txt")
        let a = try f.add(0); let b = try f.add(1)
        let state = try f.repository.loadState(a.id)
        try FileManager.default.moveItem(at: f.sources[0], to: f.temporary.appendingPathComponent("source-away"))
        let sourceB = try f.incoming(1)
        let coordinator = f.coordinator()
        _ = try coordinator.scan(); let report = try coordinator.scan()
        #expect(report.accounts.first(where: { $0.accountID == a.id })?.error != nil)
        #expect(try f.repository.loadState(a.id) == state)
        #expect(linkTarget(sourceB.path) == f.target(b).path)
    }

    @Test func movingIntoOtherAccountFolderDoesNotOverwriteLaterSameName() throws {
        let f = try MultiAccountFixture()
        let a = try f.add(0); let b = try f.add(1)
        let sourceA = try f.incoming(0, text: "A")
        let coordinator = f.coordinator()
        _ = try coordinator.scan(); _ = try coordinator.scan()
        try FileManager.default.moveItem(at: f.target(a), to: f.target(b))
        let sourceB = try f.incoming(1, text: "B")
        _ = try coordinator.scan(); _ = try coordinator.scan()
        #expect(linkTarget(sourceA.path) == f.target(b).path)
        #expect(linkTarget(sourceB.path) == f.target(b, "report (微信 2).txt").path)
        #expect(try String(contentsOf: sourceA) == "A" && String(contentsOf: sourceB) == "B")
    }

    @Test func plannedCollisionRetryStaysInTheOriginalAccountArchive() throws {
        let f = try MultiAccountFixture()
        let a = try f.add(0)
        let source = try f.incoming(0)
        let stopped = try f.worker(a) { if $0 == .planSaved { throw SyncError.message("stop") } }
        try stopped.scan(); try stopped.scan()
        try Data("unrelated".utf8).write(to: f.target(a))
        let resumed = try f.worker(a)
        try resumed.scan(); try resumed.scan()
        #expect(linkTarget(source.path) == f.target(a, "report (微信 2).txt").path)
        #expect(try String(contentsOf: f.target(a)) == "unrelated")
        #expect(fileInfo(f.root.appendingPathComponent("report (微信 2).txt").path) == nil)
    }

    @Test func pausedPlanNeverMovesNewContentIntoAReplacedArchive() throws {
        let f = try MultiAccountFixture()
        let a = try f.add(0)
        let source = try f.incoming(0)
        let stopped = try f.worker(a) { if $0 == .planSaved { throw SyncError.message("stop") } }
        try stopped.scan(); try stopped.scan()
        let archive = f.root.appendingPathComponent(a.archiveRelative)
        try FileManager.default.moveItem(at: archive, to: f.root.appendingPathComponent("original-archive"))
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let resumed = try f.worker(a)
        try resumed.scan(acceptNewFiles: false)
        #expect(fileInfo(source.path)?.regular == true)
        #expect(fileInfo(f.target(a).path) == nil)
        #expect(!resumed.report.issues.isEmpty)
    }

    @Test func independentBaselinesAndSameNames() throws {
        let f = try MultiAccountFixture()
        let oldA = try f.incoming(0, "old.txt")
        let a = try f.add(0)
        let oldB = try f.incoming(1, "old.txt")
        let b = try f.add(1)
        let newA = try f.incoming(0, text: "A")
        let newB = try f.incoming(1, text: "B")
        let coordinator = f.coordinator()
        _ = try coordinator.scan(); _ = try coordinator.scan()
        #expect(linkTarget(newA.path) == f.target(a).path)
        #expect(linkTarget(newB.path) == f.target(b).path)
        #expect(try String(contentsOf: newA) == "A")
        #expect(try String(contentsOf: newB) == "B")
        #expect(fileInfo(oldA.path)?.regular == true && fileInfo(oldB.path)?.regular == true)
        #expect(try f.repository.loadState(a.id).baseline.count == 1)
        #expect(try f.repository.loadState(b.id).baseline.count == 1)
    }

    @Test func scopedSaveCannotDeleteAnotherAccountsRecords() throws {
        let f = try MultiAccountFixture()
        _ = try f.incoming(0, "old.txt"); _ = try f.incoming(1, "old.txt")
        let a = try f.add(0); let b = try f.add(1)
        _ = try f.incoming(0); _ = try f.incoming(1)
        let coordinator = f.coordinator()
        _ = try coordinator.scan(); _ = try coordinator.scan()
        let bState = try f.repository.loadState(b.id)
        let store = AccountStateStore(repository: f.repository, accountID: a.id)
        var aState = try store.load()
        aState.baseline = [:]; aState.transfers = [:]
        try store.save(aState)
        #expect(try f.repository.loadState(b.id) == bState)
        #expect(try f.repository.account(b.id) == b)
        var wrong = bState
        wrong.baseline = [:]
        #expect(throws: (any Error).self) { try store.save(wrong) }
        #expect(try f.repository.loadState(b.id) == bState)
    }

    @Test func duplicateSourceAndSymlinkAliasRejected() throws {
        let f = try MultiAccountFixture()
        _ = try f.add(0)
        #expect(throws: (any Error).self) { try f.add(0, name: "重复") }
        let alias = f.temporary.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.sources[0])
        #expect(throws: (any Error).self) { try f.manager.add(source: alias, name: "别名", bookmark: nil) }
        #expect(try f.repository.accounts().count == 1)
    }

    @Test func archiveNamesReserveExistingAndRemovedDirectories() throws {
        let f = try MultiAccountFixture()
        let occupied = f.root.appendingPathComponent("微信文件/同名")
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        let marker = occupied.appendingPathComponent("user.txt")
        try Data("user".utf8).write(to: marker)
        let a = try f.add(0, name: "同名")
        try f.repository.remove(a.id)
        let b = try f.add(1, name: "同名")
        #expect(a.archiveRelative == "微信文件/同名 (2)")
        #expect(b.archiveRelative == "微信文件/同名 (3)")
        #expect(try String(contentsOf: marker) == "user")
    }

    @Test func nestedAndUnsafeSourcesOrNamesRejectedWithoutBaseline() throws {
        let f = try MultiAccountFixture()
        _ = try f.add(0)
        #expect(throws: (any Error).self) { try f.manager.add(source: f.sources[0].deletingLastPathComponent(), name: "父目录", bookmark: nil) }
        #expect(throws: (any Error).self) { try f.manager.add(source: f.root, name: "根", bookmark: nil) }
        #expect(throws: (any Error).self) { try f.add(1, name: "../错误") }
        #expect(try f.repository.accounts().count == 1)
        #expect(try f.repository.pendingSetups().isEmpty)
    }

    @Test func pauseMaintainsLinksAndResumeObservesBacklogAgain() throws {
        let f = try MultiAccountFixture()
        let a = try f.add(0)
        let worker = try SyncWorker(store: AccountStateStore(repository: f.repository, accountID: a.id),
            archiveRelative: a.archiveRelative, archiveIdentity: a.archiveIdentity, settleSeconds: 10, clock: { [unowned f] in f.now })
        let incoming = try f.incoming(0)
        try worker.scan(); f.now.addTimeInterval(10); try worker.scan()
        let renamed = f.root.appendingPathComponent("改名.txt")
        try FileManager.default.moveItem(at: f.target(a), to: renamed)
        let backlog = try f.incoming(0, "backlog.txt")
        try worker.scan() // Intake sees backlog, but it is not stable yet.
        try f.manager.setPaused(a.id, paused: true)
        try worker.scan(acceptNewFiles: false)
        #expect(linkTarget(incoming.path) == renamed.path)
        f.now.addTimeInterval(100)
        try worker.scan(acceptNewFiles: false)
        #expect(fileInfo(backlog.path)?.regular == true)
        try f.manager.setPaused(a.id, paused: false)
        try worker.scan()
        #expect(fileInfo(backlog.path)?.regular == true)
        f.now.addTimeInterval(10); try worker.scan()
        #expect(linkTarget(backlog.path) == f.target(a, "backlog.txt").path)
        #expect(try f.repository.loadState(a.id).baseline.isEmpty)
    }

    @Test func pausedPendingOperationStillCompletes() throws {
        let f = try MultiAccountFixture()
        let a = try f.add(0)
        let source = try f.incoming(0)
        let interrupted = try f.worker(a) { if $0 == .fileMoved { throw SyncError.message("injected crash") } }
        try interrupted.scan(); try interrupted.scan()
        #expect(fileInfo(source.path) == nil)
        try f.manager.setPaused(a.id, paused: true)
        let recovered = try f.worker(a)
        try recovered.scan(acceptNewFiles: false)
        #expect(linkTarget(source.path) == f.target(a).path)
        #expect(try f.repository.loadState(a.id).transfers.values.first?.phase == .linked)
    }

    @Test func labelsDoNotRenameFoldersOrAffectBaseline() throws {
        let f = try MultiAccountFixture()
        _ = try f.incoming(0, "old.txt")
        let a = try f.add(0)
        let before = try f.repository.loadState(a.id)
        try f.manager.rename(a.id, name: "新备注")
        let changed = try f.repository.account(a.id)
        #expect(changed.name == "新备注" && changed.archiveRelative == a.archiveRelative)
        #expect(changed.archiveIdentity == a.archiveIdentity)
        #expect(try f.repository.loadState(a.id) == before)
    }

    @Test func removePreservesFilesLinksRecordsAndRequiresExplicitReauthorization() throws {
        let f = try MultiAccountFixture()
        _ = try f.incoming(0, "old.txt")
        let a = try f.add(0); let b = try f.add(1)
        let incoming = try f.incoming(0)
        let worker = try f.worker(a)
        try worker.scan(); try worker.scan()
        let before = try f.repository.loadState(a.id)
        try f.repository.remove(a.id)
        #expect(try f.repository.account(a.id).sourceBookmark == nil)
        #expect(try f.repository.loadState(a.id) == before)
        #expect(linkTarget(incoming.path) == f.target(a).path)
        let target = f.root.appendingPathComponent("移除后改名.txt")
        try FileManager.default.moveItem(at: f.target(a), to: target)
        #expect(try f.coordinator().scan().accounts.map(\.accountID) == [b.id])
        #expect(linkTarget(incoming.path) != target.path)
        #expect(throws: (any Error).self) { try f.add(0) }
        #expect(throws: (any Error).self) { try f.manager.reauthorize(a.id, source: f.sources[0], bookmark: Data("new".utf8)) }
        #expect(throws: (any Error).self) { try f.manager.reauthorize(a.id, source: f.sources[1], bookmark: Data("new".utf8), restoring: true) }
        try f.manager.reauthorize(a.id, source: f.sources[0], bookmark: Data("new".utf8), restoring: true)
        #expect(try f.repository.loadState(a.id) == before)
        _ = try f.coordinator().scan()
        #expect(linkTarget(incoming.path) == target.path)
        #expect(try f.repository.account(a.id).sourceBookmark == Data("new".utf8))
    }

    @Test func replacedSourceNeverInheritsOldAccount() throws {
        let f = try MultiAccountFixture()
        let a = try f.add(0)
        let moved = f.temporary.appendingPathComponent("old-source")
        try FileManager.default.moveItem(at: f.sources[0], to: moved)
        try FileManager.default.createDirectory(at: f.sources[0], withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try f.manager.reauthorize(a.id, source: f.sources[0], bookmark: Data("new".utf8)) }
        #expect(throws: (any Error).self) { try f.add(0) }
        #expect(try f.repository.account(a.id) == a)
    }

    @Test func oneUnavailableAccountDoesNotBlockAnotherAndLeaseIsReleased() throws {
        let f = try MultiAccountFixture()
        let a = try f.add(0); let b = try f.add(1)
        let incoming = try f.incoming(1)
        var releases = 0
        let coordinator = f.coordinator { account in
            if account.id == a.id { throw SyncError.message("fake expired bookmark") }
            return DirectoryLease(url: account.sourceURL) { releases += 1 }
        }
        let first = try coordinator.scan(); _ = try coordinator.scan()
        #expect(first.accounts.first(where: { $0.accountID == a.id })?.error != nil)
        #expect(linkTarget(incoming.path) == f.target(b).path)
        #expect(releases == 2)
    }

    @Test func replacedArchiveStopsIntakeButMaintainsExistingElsewhere() throws {
        let f = try MultiAccountFixture()
        let a = try f.add(0)
        let incoming = try f.incoming(0)
        let worker = try f.worker(a)
        try worker.scan(); try worker.scan()
        let moved = f.root.appendingPathComponent("跨文件夹.txt")
        try FileManager.default.moveItem(at: f.target(a), to: moved)
        let oldArchive = f.root.appendingPathComponent(a.archiveRelative)
        try FileManager.default.removeItem(at: oldArchive)
        try FileManager.default.createDirectory(at: oldArchive, withIntermediateDirectories: true)
        let fresh = try f.incoming(0, "fresh.txt")
        try worker.scan(); try worker.scan()
        #expect(linkTarget(incoming.path) == moved.path)
        #expect(fileInfo(fresh.path)?.regular == true)
        #expect(worker.report.issues.contains(where: { $0.relative == a.archiveRelative }))
    }

    @Test func sharedRootIndexOnceAndOwnershipSurvivesMoveIntoOtherAccountFolder() throws {
        let f = try MultiAccountFixture()
        let a = try f.add(0); let b = try f.add(1)
        let sourceA = try f.incoming(0); let sourceB = try f.incoming(1)
        let coordinator = f.coordinator()
        _ = try coordinator.scan(); _ = try coordinator.scan()
        let movedA = f.target(b, "from-A.txt")
        let movedB = f.root.appendingPathComponent("from-B.txt")
        try FileManager.default.moveItem(at: f.target(a), to: movedA)
        try FileManager.default.moveItem(at: f.target(b), to: movedB)
        let result = try coordinator.scan()
        #expect(result.managedRootEnumerations == 1)
        #expect(linkTarget(sourceA.path) == movedA.path && linkTarget(sourceB.path) == movedB.path)
        #expect(try f.repository.loadState(a.id).transfers.values.first?.destination == b.archiveRelative + "/from-A.txt")
        #expect(try f.repository.loadState(b.id).transfers.count == 1)
    }

    @Test func sharedRootFailureIsGlobalAndDoesNotRetireRecords() throws {
        let f = try MultiAccountFixture()
        let a = try f.add(0); _ = try f.add(1)
        _ = try f.incoming(0)
        let coordinator = f.coordinator()
        _ = try coordinator.scan(); _ = try coordinator.scan()
        let state = try f.repository.loadState(a.id)
        try FileManager.default.moveItem(at: f.root, to: f.temporary.appendingPathComponent("root-away"))
        #expect(throws: (any Error).self) { try coordinator.scan() }
        #expect(try f.repository.loadState(a.id) == state)
    }
}
