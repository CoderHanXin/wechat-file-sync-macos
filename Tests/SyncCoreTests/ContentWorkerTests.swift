import Foundation
import Darwin
import Testing
@testable import SyncCore

struct ContentWorkerTests {
    @Test func sameContentDifferentNamesAndExtensionsShareOneReadOnlyEntity() throws {
        let f = try ContentFixture()
        let a = try f.sync("month/report.txt")
        let b = try f.sync("month/forward.pdf")
        #expect(f.worker.report.issues.isEmpty)
        #expect(linkTarget(a.path) == linkTarget(b.path))
        #expect(try String(contentsOf: b) == "same")
        #expect(try f.store.entities(f.a.id).count == 1)
        #expect(try f.store.sources(f.a.id).map(\.originalName) == ["report.txt", "forward.pdf"])
        let target = try #require(linkTarget(a.path))
        #expect((fileInfo(target)?.mode ?? 0) & 0o222 == 0)
        let fd = open(target, O_WRONLY)
        if fd >= 0 { close(fd) }
        #expect(fd == -1)
        #expect(try f.store.operations(f.a.id).isEmpty)
    }

    @Test func differentContentsSameNameAndDifferentAccountsNeverMerge() throws {
        let f = try ContentFixture(protect: false)
        let a = try f.sync("one/report.txt", "A")
        let b = try f.sync("two/report.txt", "B")
        let other = try f.files.incoming(1, "report.txt", text: "A")
        let worker = ContentWorker(store: f.store, accountID: f.b.id, settleSeconds: 0)
        try worker.scan(); try worker.scan()
        #expect(linkTarget(a.path) != linkTarget(b.path))
        #expect(linkTarget(a.path) != linkTarget(other.path))
        #expect(try f.store.entities(f.a.id).count == 2)
        #expect(try f.store.entities(f.b.id).count == 1)
    }

    @Test func sharedRenameAndSourceCleanupRetainAllHistory() throws {
        let f = try ContentFixture()
        let a = try f.sync("a.txt"); let b = try f.sync("b.txt")
        let target = URL(fileURLWithPath: try #require(linkTarget(a.path)))
        let moved = f.files.target(f.b, "moved.txt")
        try FileManager.default.moveItem(at: target, to: moved)
        try Data("unrelated".utf8).write(to: target)
        try f.worker.scan()
        #expect(linkTarget(a.path) == moved.path && linkTarget(b.path) == moved.path)
        try FileManager.default.removeItem(at: a)
        try f.worker.scan()
        #expect(try f.store.sources(f.a.id).count == 2)
        #expect(try f.store.sources(f.a.id).filter(\.active).count == 1)
        try FileManager.default.removeItem(at: moved)
        try f.worker.scan()
        #expect(fileInfo(b.path) == nil)
        #expect(try f.store.sources(f.a.id).count == 2)
        #expect(try f.store.entities(f.a.id).first?.status == .missing)
        let incoming = try f.sync("again.txt")
        #expect(try String(contentsOf: incoming) == "same")
        #expect(try f.store.entities(f.a.id).count == 2)
        #expect(try f.store.sources(f.a.id).count == 3)
    }

    @Test func defaultChangesDoNotChangeReusedEntityPermissions() throws {
        let f = try ContentFixture(protect: false)
        let a = try f.sync("writable.txt")
        let target = try #require(linkTarget(a.path))
        let mode = fileInfo(target)?.mode
        try f.store.setReadOnly(f.a.id, true)
        let b = try f.sync("duplicate.txt")
        #expect(linkTarget(b.path) == target)
        #expect(fileInfo(target)?.mode == mode)
        let c = try f.sync("protected.txt", "new")
        let protected = try #require(linkTarget(c.path))
        #expect((fileInfo(protected)?.mode ?? 0) & 0o222 == 0)
        try f.store.setReadOnly(f.a.id, false)
        let d = try f.sync("protected-again.bin", "new")
        #expect(linkTarget(d.path) == protected)
        #expect((fileInfo(protected)?.mode ?? 0) & 0o222 == 0)
    }

    @Test(arguments: [ContentCheckpoint.planSaved, .swapped, .associationSaved, .duplicateRemoved])
    func duplicateOperationRecoversAtEveryCheckpoint(_ stage: ContentCheckpoint) throws {
        let f = try ContentFixture()
        let first = try f.sync("first.txt")
        f.restart { if $0 == stage { throw SyncError.message("interruption") } }
        let duplicate = try f.sync("second.txt")
        f.restart()
        try f.worker.scan(); try f.worker.scan()
        #expect(linkTarget(first.path) == linkTarget(duplicate.path))
        #expect(try String(contentsOf: duplicate) == "same")
        #expect(try f.store.entities(f.a.id).count == 1)
        #expect(try f.store.operations(f.a.id).isEmpty)
        #expect(try allFiles(f.files.sources[0]).isEmpty)
    }

    @Test func oldWritableEntitiesAreNotAutomaticallyMergedOrProtected() throws {
        let f = try MultiAccountFixture()
        let a = try f.add(0)
        let old = try f.incoming(0, "old.txt", text: "same")
        let worker = try f.worker(a)
        try worker.scan(); try worker.scan()
        let oldTarget = try #require(linkTarget(old.path))
        let mode = fileInfo(oldTarget)?.mode
        let v3 = try ContentRepository(url: f.repository.url)
        let new = try f.incoming(0, "new.txt", text: "same")
        let newWorker = ContentWorker(store: v3, accountID: a.id, settleSeconds: 0)
        try newWorker.scan(); try newWorker.scan()
        #expect(linkTarget(new.path) == oldTarget)
        #expect(fileInfo(oldTarget)?.mode == mode)
        #expect(try v3.entities(a.id).count == 1)
    }

    @Test func externalEditingInvalidatesDigestAndRetainsReceivedDigest() throws {
        let f = try ContentFixture(protect: false)
        let first = try f.sync("first.txt", "old")
        let received = try #require(f.store.sources(f.a.id).first?.receivedDigest)
        let target = URL(fileURLWithPath: try #require(linkTarget(first.path)))
        let handle = try FileHandle(forWritingTo: target)
        try handle.write(contentsOf: Data("edited".utf8)); try handle.close()
        let next = try f.sync("new-original.txt", "old")
        #expect(linkTarget(next.path) != target.path)
        #expect(try String(contentsOf: first) == "edited")
        #expect(try f.store.sources(f.a.id).first?.receivedDigest == received)
    }

    @Test func sourcePathReuseCreatesANewLifecycle() throws {
        let f = try ContentFixture()
        let first = try f.sync("same.txt", "old")
        try FileManager.default.removeItem(at: first)
        _ = try f.sync("same.txt", "new")
        #expect(try f.store.sources(f.a.id).count == 2)
        #expect(try f.store.sources(f.a.id).filter(\.active).count == 1)
        #expect(try f.store.entities(f.a.id).count == 2)
    }

    @Test func descriptorHashDetectsMutationAndRejectsSymlinks() throws {
        let f = try ContentFixture()
        let file = try f.files.incoming(0, "large.txt", text: String(repeating: "a", count: 100000))
        let content = try OpenedContent(file)
        #expect(throws: (any Error).self) {
            try content.digest { let handle = try FileHandle(forWritingTo: file); try handle.truncate(atOffset: 2); try handle.close() }
        }
        let alias = f.files.sources[0].appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
        #expect(throws: (any Error).self) { try OpenedContent(alias) }
    }

    @Test func explicitPermissionChangesRecoverAndNeverUnlockOriginallyReadOnly() throws {
        let f = try ContentFixture(protect: false)
        let source = try f.sync("file.txt")
        let target = URL(fileURLWithPath: try #require(linkTarget(source.path)))
        let entity = try #require(f.store.entities(f.a.id).first)
        let mode = try #require(fileInfo(target.path)?.mode)
        #expect(throws: (any Error).self) {
            try ReadOnlyPolicy(store: f.store) { if $0 == .permissionChanged { throw SyncError.message("stop") } }.apply(entity, at: target, protect: true)
        }
        try f.worker.scan()
        let protected = try #require(f.store.entities(f.a.id).first)
        try ReadOnlyPolicy(store: f.store).apply(protected, at: target, protect: false)
        #expect(fileInfo(target.path)?.mode == mode)
        try systemCall(chmod(target.path, 0o444), "test chmod")
        try ReadOnlyPolicy(store: f.store).apply(protected, at: target, protect: true)
        try ReadOnlyPolicy(store: f.store).apply(protected, at: target, protect: false)
        #expect((fileInfo(target.path)?.mode ?? 0) & 0o222 == 0)
    }
}
