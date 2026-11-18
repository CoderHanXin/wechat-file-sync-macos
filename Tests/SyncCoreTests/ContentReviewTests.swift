import Foundation
import Darwin
import Testing
@testable import SyncCore

struct ContentReviewTests {
    @Test func permissionScopeChangeAfterChmodLeavesARecoverableTask() throws {
        let f = try ContentFixture(protect: false)
        let source = try f.sync("file.txt")
        let target = URL(fileURLWithPath: try #require(linkTarget(source.path)))
        let parent = target.deletingLastPathComponent()
        let outside = f.files.temporary.appendingPathComponent("permission-move")
        let before = fileInfo(target.path)?.mode
        let entity = try #require(f.store.entities(f.a.id).first)
        #expect(throws: (any Error).self) {
            try ReadOnlyPolicy(store: f.store) { stage in
                if stage == .permissionChanged {
                    try FileManager.default.moveItem(at: parent, to: outside)
                    try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
                }
            }.apply(entity, at: target, protect: true)
        }
        #expect(try f.store.entities(f.a.id).first?.protectionBefore == nil)
        #expect(try f.store.operations(f.a.id).first?.kind == .permission)
        try FileManager.default.removeItem(at: parent)
        try FileManager.default.moveItem(at: outside, to: parent)
        try ReadOnlyPolicy(store: f.store).apply(entity, at: target, protect: true)
        try ReadOnlyPolicy(store: f.store).apply(entity, at: target, protect: false)
        #expect(fileInfo(target.path)?.mode == before)
        #expect(try f.store.operations(f.a.id).isEmpty)
    }

    @Test func incompatibleOldCandidateDoesNotHideACompatibleHistoricalCopy() throws {
        let f = try MultiAccountFixture()
        let account = try f.add(0)
        let first = try f.incoming(0, "a.txt", text: "same")
        let second = try f.incoming(0, "b.txt", text: "same")
        let old = try f.worker(account)
        try old.scan(); try old.scan()
        let a = try #require(linkTarget(first.path)), b = try #require(linkTarget(second.path))
        func setAttribute(_ path: String, _ value: String) throws {
            let data = Data(value.utf8)
            try systemCall(data.withUnsafeBytes { setxattr(path, "com.example.wechat-review", $0.baseAddress, data.count, 0, 0) }, "test attribute")
        }
        try setAttribute(a, "A"); try setAttribute(b, "B")
        let store = try ContentRepository(url: f.repository.url)
        let incoming = try f.incoming(0, "new.txt", text: "same")
        try setAttribute(incoming.path, "B")
        let worker = ContentWorker(store: store, accountID: account.id, settleSeconds: 0)
        try worker.scan(); try worker.scan()
        #expect(linkTarget(incoming.path) == b)
        #expect(try store.entities(account.id).count == 2)
    }

    @Test func missingEntityRetriesLinkCleanupAfterTheDirectoryBecomesWritable() throws {
        let f = try ContentFixture()
        let source = try f.sync("month/first.txt")
        let target = try #require(linkTarget(source.path))
        let parent = source.deletingLastPathComponent()
        let mode = try #require(fileInfo(parent.path)?.mode)
        defer { _ = chmod(parent.path, mode & 0o7777) }
        try FileManager.default.removeItem(atPath: target)
        try systemCall(chmod(parent.path, 0o500), "test deny unlink")
        try f.worker.scan()
        #expect(linkTarget(source.path) == target)
        #expect(try f.store.entities(f.a.id).first?.status == .missing)
        try systemCall(chmod(parent.path, mode & 0o7777), "test restore directory")
        try f.worker.scan()
        #expect(fileInfo(source.path) == nil)
        #expect(try f.store.sources(f.a.id).first?.status == .missing)
        #expect(try f.store.sources(f.a.id).first?.active == false)
    }

    @Test func clearedDuplicateCanFollowACanonicalMoveAfterCleanupInterruption() throws {
        let f = try ContentFixture()
        let first = try f.sync("first.txt")
        let oldTarget = URL(fileURLWithPath: try #require(linkTarget(first.path)))
        f.restart { if $0 == .duplicateRemoved { throw SyncError.message("stop") } }
        let second = try f.sync("second.txt")
        let moved = f.files.root.appendingPathComponent("moved.txt")
        try FileManager.default.moveItem(at: oldTarget, to: moved)
        f.restart(); try f.worker.scan()
        #expect(linkTarget(second.path) == moved.path)
        #expect(try f.store.sources(f.a.id).last?.status == .linked)
        #expect(try f.store.operations(f.a.id).isEmpty)
    }

    @Test(arguments: [ContentCheckpoint.rollbackSwapped, .rollbackLinkRemoved])
    func rollbackItselfCanBeInterruptedAndResumed(_ stage: ContentCheckpoint) throws {
        let f = try ContentFixture()
        let first = try f.sync("first.txt")
        let target = try #require(linkTarget(first.path))
        f.restart { if $0 == .swapped { throw SyncError.message("stop") } }
        let second = try f.sync("second.txt")
        try FileManager.default.removeItem(atPath: target)
        f.restart { if $0 == stage { throw SyncError.message("stop rollback") } }
        try f.worker.scan()
        #expect(try f.store.operations(f.a.id).first?.phase == .rollback)
        f.restart(); try f.worker.scan()
        #expect(fileInfo(second.path)?.regular == true)
        #expect(try String(contentsOf: second) == "same")
        #expect(try f.store.operations(f.a.id).isEmpty)
    }

    @Test func cleanupRechecksScopeWhenSourceParentIsRedirectedAfterAssociation() throws {
        let f = try ContentFixture()
        _ = try f.sync("month/first.txt")
        let parent = f.a.sourceURL.appendingPathComponent("month")
        let outside = f.files.temporary.appendingPathComponent("outside-source")
        var redirected = false
        f.restart { stage in
            if stage == .associationSaved && !redirected {
                redirected = true
                try FileManager.default.moveItem(at: parent, to: outside)
                try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
            }
        }
        _ = try f.sync("month/second.txt")
        let op = try #require(f.store.operations(f.a.id).first)
        let working = outside.appendingPathComponent(op.temporary)
        #expect(try String(contentsOf: working) == "same")
        #expect(op.phase == .cleanup)
        #expect(!f.worker.report.issues.isEmpty)
    }

    @Test func permissionDoesNotFollowAnArchiveParentOutsideTheManagedRoot() throws {
        let f = try ContentFixture(protect: false)
        let source = try f.sync("file.txt")
        let target = URL(fileURLWithPath: try #require(linkTarget(source.path)))
        let parent = target.deletingLastPathComponent()
        let outside = f.files.temporary.appendingPathComponent("outside-archive")
        let before = fileInfo(target.path)?.mode
        try FileManager.default.moveItem(at: parent, to: outside)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
        let entity = try #require(f.store.entities(f.a.id).first)
        #expect(throws: (any Error).self) { try ReadOnlyPolicy(store: f.store).apply(entity, at: target, protect: true) }
        #expect(fileInfo(outside.appendingPathComponent(target.lastPathComponent).path)?.mode == before)
        #expect(try f.store.operations(f.a.id).isEmpty)
    }

    @Test func retargetedLinkSurvivesCommitFailureAndCanStillRollBack() throws {
        let f = try ContentFixture()
        let first = try f.sync("first.txt")
        let oldTarget = URL(fileURLWithPath: try #require(linkTarget(first.path)))
        f.restart { if $0 == .swapped { throw SyncError.message("stop") } }
        let second = try f.sync("second.txt")
        let op = try #require(f.store.operations(f.a.id).first)
        var entity = try #require(f.store.entities(f.a.id).first)
        let moved = f.files.root.appendingPathComponent("moved.txt")
        try FileManager.default.moveItem(at: oldTarget, to: moved)
        entity.relative = "moved.txt"
        try f.store.atomic { try f.store.put(entity) }
        try f.store.accounts.execute("CREATE TRIGGER fail_source_commit BEFORE UPDATE ON sources BEGIN SELECT RAISE(ABORT,'fake failure'); END")
        let runner = ContentOperationRunner(store: f.store)
        #expect(throws: (any Error).self) { try runner.attach(op, root: f.files.root, sourceRoot: f.a.sourceURL) }
        #expect(linkTarget(second.path) == moved.path)
        try f.store.accounts.execute("DROP TRIGGER fail_source_commit")
        try FileManager.default.removeItem(at: moved)
        do { try runner.attach(op, root: f.files.root, sourceRoot: f.a.sourceURL) } catch {}
        #expect(fileInfo(second.path)?.regular == true)
        #expect(try String(contentsOf: second) == "same")
        #expect(try f.store.operations(f.a.id).isEmpty)
    }

    @Test func preparedTemporaryLinkCanFollowACanonicalMoveBeforeSwap() throws {
        let f = try ContentFixture()
        let first = try f.sync("first.txt")
        let oldTarget = URL(fileURLWithPath: try #require(linkTarget(first.path)))
        f.restart { if $0 == .planSaved { throw SyncError.message("stop") } }
        let second = try f.sync("second.txt")
        let op = try #require(f.store.operations(f.a.id).first)
        let temporary = second.deletingLastPathComponent().appendingPathComponent(op.temporary)
        try FileManager.default.createSymbolicLink(at: temporary, withDestinationURL: oldTarget)
        var entity = try #require(f.store.entities(f.a.id).first)
        let moved = f.files.root.appendingPathComponent("moved.txt")
        try FileManager.default.moveItem(at: oldTarget, to: moved)
        entity.relative = "moved.txt"
        try f.store.atomic { try f.store.put(entity) }
        try ContentOperationRunner(store: f.store).attach(op, root: f.files.root, sourceRoot: f.a.sourceURL)
        #expect(linkTarget(second.path) == moved.path)
        #expect(fileInfo(temporary.path) == nil)
        #expect(try f.store.operations(f.a.id).isEmpty)
    }

    @Test(arguments: [true, false])
    func oppositePermissionRequestFinishesTheOldOperationThenAppliesTheNewRequest(_ initialProtect: Bool) throws {
        let f = try ContentFixture(protect: !initialProtect)
        let source = try f.sync("file.txt")
        let target = URL(fileURLWithPath: try #require(linkTarget(source.path)))
        let before = fileInfo(target.path)?.mode
        let entity = try #require(f.store.entities(f.a.id).first)
        #expect(throws: (any Error).self) {
            try ReadOnlyPolicy(store: f.store) { if $0 == .permissionChanged { throw SyncError.message("stop") } }.apply(entity, at: target, protect: initialProtect)
        }
        try ReadOnlyPolicy(store: f.store).apply(entity, at: target, protect: !initialProtect)
        #expect(fileInfo(target.path)?.mode == before)
        #expect(try (f.store.entities(f.a.id).first?.protectionBefore != nil) == !initialProtect)
        #expect(try f.store.operations(f.a.id).isEmpty)
    }

    @Test func migratingSharedTargetDoesNotSilentlyResolveAConflictSource() throws {
        let f = try MultiAccountFixture()
        let account = try f.add(0)
        let linked = try f.incoming(0, "a-linked.txt", text: "same")
        let worker = try f.worker(account)
        try worker.scan(); try worker.scan()
        let target = URL(fileURLWithPath: try #require(linkTarget(linked.path)))
        let other = f.sources[0].appendingPathComponent("b-conflict.txt")
        try FileManager.default.createSymbolicLink(at: other, withDestinationURL: target)
        let adapter = AccountStateStore(repository: f.repository, accountID: account.id)
        var state = try adapter.load()
        var conflict = try #require(state.transfers["a-linked.txt"])
        conflict.phase = .conflict
        state.transfers["b-conflict.txt"] = conflict
        try adapter.save(state)
        let store = try ContentRepository(url: f.repository.url)
        try ContentWorker(store: store, accountID: account.id, settleSeconds: 0).scan()
        #expect(try store.sources(account.id).first { $0.relative == "b-conflict.txt" }?.status == .conflict)
        #expect(try store.accounts.loadState(account.id).transfers["b-conflict.txt"]?.phase == .conflict)
        #expect(linkTarget(other.path) == target.path)
    }
}
