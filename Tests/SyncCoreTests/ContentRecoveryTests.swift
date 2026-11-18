import Foundation
import Darwin
import Testing
@testable import SyncCore

struct ContentRecoveryTests {
    @Test func hardLinkedFileDoesNotChangeUnmanagedAliasesPermissions() throws {
        let f = try ContentFixture()
        let source = try f.files.incoming(0, "hardlinked.txt", text: "sample")
        let alias = f.files.temporary.appendingPathComponent("unmanaged-alias.txt")
        try systemCall(link(source.path, alias.path), "test hardlink")
        let before = fileInfo(alias.path)?.mode
        try f.worker.scan(); try f.worker.scan()
        #expect(fileInfo(source.path)?.regular == true)
        #expect(fileInfo(alias.path)?.mode == before)
        #expect(f.worker.report.issues.contains { $0.message.contains("硬链接") })
    }

    @Test func idleRoundDoesNotRewriteUnchangedContentState() throws {
        let f = try ContentFixture()
        _ = try f.sync("first.txt"); _ = try f.sync("duplicate.txt")
        try f.worker.scan()
        let before = try f.store.accounts.scalar("SELECT total_changes()")
        try f.worker.scan()
        #expect(try f.store.accounts.scalar("SELECT total_changes()") == before)
    }

    @Test func cachedDigestCannotCauseEqualSizedDifferentBytesToMerge() throws {
        let f = try ContentFixture(protect: false)
        let first = try f.sync("first.txt", "AAAA")
        let target = URL(fileURLWithPath: try #require(linkTarget(first.path)))
        let source = try f.files.incoming(0, "second.txt", text: "BBBB")
        var entity = try #require(f.store.entities(f.a.id).first)
        entity.digest = try OpenedContent(source).digest()
        entity.verifiedToken = try OpenedContent(target).token
        try f.store.atomic { try f.store.put(entity) }
        #expect(try !OpenedContent(source).sameBytes(as: OpenedContent(target)))
        try f.worker.scan(); try f.worker.scan()
        #expect(linkTarget(first.path) != linkTarget(source.path))
        #expect(try String(contentsOf: first) == "AAAA" && String(contentsOf: source) == "BBBB")
    }

    @Test func cleanupRecoveryNeverRecreatesACleanedWechatSource() throws {
        let f = try ContentFixture()
        _ = try f.sync("first.txt")
        f.restart { if $0 == .duplicateRemoved { throw SyncError.message("stop") } }
        let second = try f.sync("second.txt")
        try FileManager.default.removeItem(at: second)
        f.restart(); try f.worker.scan()
        #expect(fileInfo(second.path) == nil)
        #expect(try f.store.operations(f.a.id).isEmpty)
        #expect(try f.store.sources(f.a.id).last?.status == .detached)
    }

    @Test func pausedAttachStillFinishesButNewCandidateWaitsUntilResume() throws {
        let f = try ContentFixture()
        let first = try f.sync("first.txt")
        f.restart { if $0 == .swapped { throw SyncError.message("stop") } }
        let second = try f.sync("second.txt")
        let backlog = try f.files.incoming(0, "backlog.txt", text: "new")
        try AccountManager(repository: f.store.accounts).setPaused(f.a.id, paused: true)
        f.restart(); try f.worker.scan(); try f.worker.scan()
        #expect(linkTarget(first.path) == linkTarget(second.path))
        #expect(fileInfo(backlog.path)?.regular == true)
        try AccountManager(repository: f.store.accounts).setPaused(f.a.id, paused: false)
        try f.worker.scan()
        #expect(fileInfo(backlog.path)?.regular == true)
        try f.worker.scan()
        #expect(linkTarget(backlog.path) != nil)
    }

    @Test func multipleAccountsShareOneRootIdentityWalk() throws {
        let f = try ContentFixture()
        let a = try f.sync("a.txt")
        let b = try f.files.incoming(1, "b.txt", text: "B")
        let coordinator = ContentCoordinator(store: f.store, settleSeconds: 0) { DirectoryLease(url: $0.sourceURL) }
        _ = try coordinator.scan(); _ = try coordinator.scan()
        let oldA = URL(fileURLWithPath: try #require(linkTarget(a.path))), oldB = URL(fileURLWithPath: try #require(linkTarget(b.path)))
        try FileManager.default.moveItem(at: oldA, to: f.files.root.appendingPathComponent("moved-A"))
        try FileManager.default.moveItem(at: oldB, to: f.files.root.appendingPathComponent("moved-B"))
        #expect(try coordinator.scan().managedRootEnumerations == 1)
        #expect(try String(contentsOf: a) == "same" && String(contentsOf: b) == "B")
    }

    @Test func lostCanonicalBeforeCleanupRollsBackTheDuplicateWithoutLosingBytes() throws {
        let f = try ContentFixture()
        let first = try f.sync("first.txt")
        let target = try #require(linkTarget(first.path))
        f.restart { if $0 == .swapped { throw SyncError.message("stop") } }
        let second = try f.sync("second.txt")
        try FileManager.default.removeItem(atPath: target)
        f.restart()
        try f.worker.scan()
        #expect(fileInfo(second.path)?.regular == true)
        #expect(try String(contentsOf: second) == "same")
        #expect(try f.store.operations(f.a.id).isEmpty)
        #expect(try f.store.sources(f.a.id).count == 2)
    }

    @Test func cleanupCommitFailureRecoversFromAnAlreadyRemovedDuplicate() throws {
        let f = try ContentFixture()
        let first = try f.sync("first.txt")
        try f.store.accounts.execute("CREATE TRIGGER fail_cleanup BEFORE DELETE ON content_operations BEGIN SELECT RAISE(ABORT,'disk failure'); END")
        let second = try f.files.incoming(0, "second.txt", text: "same")
        try f.worker.scan()
        #expect(throws: (any Error).self) { try f.worker.scan() }
        #expect(linkTarget(first.path) == linkTarget(second.path))
        #expect(try f.store.operations(f.a.id).first?.phase == .cleanup)
        try f.store.accounts.execute("DROP TRIGGER fail_cleanup")
        f.restart(); try f.worker.scan()
        #expect(try f.store.operations(f.a.id).isEmpty)
        #expect(try String(contentsOf: second) == "same")
    }

    @Test func unknownSourceOccupantAndTemporaryBytesArePreservedAfterSwap() throws {
        let f = try ContentFixture()
        _ = try f.sync("first.txt")
        f.restart { if $0 == .swapped { throw SyncError.message("stop") } }
        let second = try f.sync("second.txt")
        let op = try #require(f.store.operations(f.a.id).first)
        let temp = second.deletingLastPathComponent().appendingPathComponent(op.temporary)
        try FileManager.default.removeItem(at: second)
        try Data("user replacement".utf8).write(to: second)
        f.restart(); try f.worker.scan()
        #expect(try String(contentsOf: second) == "user replacement")
        #expect(try String(contentsOf: temp) == "same")
        #expect(try f.store.operations(f.a.id).first?.error != nil)
        let other = try f.sync("unrelated.txt", "different")
        #expect(linkTarget(other.path) != nil)
    }

    @Test func changedSourceBeforeSwapIsObservedAsANewLifecycle() throws {
        let f = try ContentFixture()
        let first = try f.sync("first.txt")
        f.restart { if $0 == .planSaved { throw SyncError.message("stop") } }
        let second = try f.sync("second.txt")
        try Data("changed".utf8).write(to: second)
        f.restart(); try f.worker.scan(); try f.worker.scan(); try f.worker.scan()
        #expect(try String(contentsOf: second) == "changed")
        #expect(linkTarget(first.path) != linkTarget(second.path))
        #expect(try f.store.operations(f.a.id).isEmpty)
        #expect(try f.store.sources(f.a.id).count == 3)
    }

    @Test(arguments: [TransferCheckpoint.planSaved, .fileMoved, .linkInstalled])
    func createMoveAndReadOnlyRecoveryPreserveContent(_ stage: TransferCheckpoint) throws {
        let f = try ContentFixture(transferCheckpoint: { if $0 == stage { throw SyncError.message("stop") } })
        let file = try f.sync("new.txt")
        f.restart(); try f.worker.scan(); try f.worker.scan()
        let target = try #require(linkTarget(file.path))
        #expect((fileInfo(target)?.mode ?? 0) & 0o222 == 0)
        #expect(try String(contentsOf: file) == "same")
        #expect(try f.store.operations(f.a.id).isEmpty)
    }

    @Test func permissionFailureOnOneMovedFileDoesNotBlockAnotherFile() throws {
        let f = try ContentFixture(checkpoint: { if $0 == .permissionChanged { throw SyncError.message("stop chmod") } })
        let first = try f.sync("first.txt", "one")
        let entity = try #require(f.store.entities(f.a.id).first)
        // A mismatched external permission prevents automatic permission recovery for this entity.
        try systemCall(chmod(f.files.root.appendingPathComponent(entity.relative).path, 0o400), "test chmod")
        f.restart()
        let second = try f.sync("second.txt", "two")
        #expect(linkTarget(first.path) == nil)
        #expect(linkTarget(second.path) != nil)
        #expect(try String(contentsOf: second) == "two")
        #expect(!f.worker.report.issues.isEmpty)
    }

    @Test func repeatingProtectionDoesNotLoseOriginalWriteBits() throws {
        let f = try ContentFixture(protect: false)
        let file = try f.sync("script", "script")
        let target = URL(fileURLWithPath: try #require(linkTarget(file.path)))
        try systemCall(chmod(target.path, 0o750), "test chmod")
        let entity = try #require(f.store.entities(f.a.id).first)
        let policy = ReadOnlyPolicy(store: f.store)
        try policy.apply(entity, at: target, protect: true)
        try policy.apply(entity, at: target, protect: true)
        #expect((fileInfo(target.path)?.mode ?? 0) & 0o777 == 0o550)
        try policy.apply(entity, at: target, protect: false)
        #expect((fileInfo(target.path)?.mode ?? 0) & 0o777 == 0o750)
    }

    @Test func externallyChangedModesCannotBeForceUnlocked() throws {
        let f = try ContentFixture()
        let source = try f.sync("file.txt")
        let target = URL(fileURLWithPath: try #require(linkTarget(source.path)))
        try systemCall(chmod(target.path, 0o400), "test chmod")
        let entity = try #require(f.store.entities(f.a.id).first)
        #expect(throws: (any Error).self) { try ReadOnlyPolicy(store: f.store).apply(entity, at: target, protect: false) }
        #expect((fileInfo(target.path)?.mode ?? 0) & 0o777 == 0o400)
    }

    @Test(arguments: ["com.example.wechat-test", "com.apple.quarantine", "com.apple.ResourceFork"])
    func mismatchedAttributesDoNotDiscardSourceMetadata(_ attribute: String) throws {
        let f = try ContentFixture()
        _ = try f.sync("first.txt")
        let second = try f.files.incoming(0, "second.txt", text: "same")
        let data = Data("metadata".utf8)
        let result = data.withUnsafeBytes { setxattr(second.path, attribute, $0.baseAddress, data.count, 0, 0) }
        try systemCall(result, "test xattr")
        try f.worker.scan(); try f.worker.scan()
        #expect(fileInfo(second.path)?.regular == true)
        #expect(try f.store.entities(f.a.id).count == 1)
        #expect(f.worker.report.issues.contains { $0.message.contains("附加属性") })
    }

    @Test func extendedACLIsReportedWithoutClaimingReadOnlySuccess() throws {
        let f = try ContentFixture()
        let file = try f.files.incoming(0, "acl.txt", text: "sample")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", "everyone allow write", file.path]
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        try f.worker.scan(); try f.worker.scan()
        #expect(fileInfo(file.path)?.regular == true)
        #expect(f.worker.report.issues.contains { $0.message.contains("ACL") })
        #expect(try f.store.entities(f.a.id).isEmpty)
    }

    @Test func hashingSpansRoundsAndPauseReleasesItsScope() throws {
        let f = try ContentFixture()
        let file = try f.files.incoming(0, "large.bin", text: String(repeating: "x", count: 400000))
        let worker = ContentWorker(store: f.store, accountID: f.a.id, settleSeconds: 0, hashBudget: 65536)
        var released = 0
        try worker.scan()
        var lease: DirectoryLease? = DirectoryLease(url: f.a.sourceURL) { released += 1 }
        try worker.scan(lease: lease)
        lease = nil
        #expect(released == 0 && fileInfo(file.path)?.regular == true)
        try worker.scan(acceptNewFiles: false)
        #expect(released == 1)
        for _ in 0..<10 { try worker.scan() }
        #expect(linkTarget(file.path) != nil)
    }

    @Test func unavailableIndexDoesNotRemoveLinksOrHistory() throws {
        let f = try ContentFixture()
        let source = try f.sync("first.txt")
        let target = URL(fileURLWithPath: try #require(linkTarget(source.path)))
        try FileManager.default.moveItem(at: target, to: f.files.root.appendingPathComponent("renamed.txt"))
        let broken = ManagedRootIndex(root: f.files.root) { _ in throw SyncError.message("denied") }
        try f.worker.scan(index: broken)
        #expect(linkTarget(source.path) == target.path)
        #expect(try f.store.sources(f.a.id).first?.active == true)
        #expect(try f.store.entities(f.a.id).first?.status != .missing)
    }

    @Test func removedAccountsAreNeverAuthorizedAndOneFailedAccountDoesNotBlockAnother() throws {
        let f = try ContentFixture()
        let a = try f.files.incoming(0, "a.txt", text: "A")
        let b = try f.files.incoming(1, "b.txt", text: "B")
        let coordinator = ContentCoordinator(store: f.store, settleSeconds: 0) { account in
            if account.id == f.a.id { throw SyncError.message("fake expired") }
            return DirectoryLease(url: account.sourceURL)
        }
        _ = try coordinator.scan(); _ = try coordinator.scan()
        #expect(fileInfo(a.path)?.regular == true && linkTarget(b.path) != nil)
        try f.store.accounts.remove(f.a.id)
        var authorized: [String] = []
        let next = ContentCoordinator(store: f.store, settleSeconds: 0) { account in
            authorized.append(account.id); return DirectoryLease(url: account.sourceURL)
        }
        _ = try next.scan()
        #expect(authorized == [f.b.id])
    }

    @Test func contentCommandsAreStrictAndQueriesRemainReadonly() throws {
        #expect(try Command.parse(["--set-read-only", "id", "on"]) == .setReadOnly("id", true))
        #expect(try Command.parse(["--apply-read-only", "id", "off"]) == .applyReadOnly("id", false))
        #expect(try Command.parse(["--list-file-issues"]).readOnly)
        #expect(try Command.parse(["--recover-operations", "id"]) == .recoverOperations("id"))
        for args in [["--set-read-only", "id", "yes"], ["--apply-read-only"], ["--list-file-issues", "--configure"]] {
            #expect(throws: (any Error).self) { try Command.parse(args) }
        }
    }
}
