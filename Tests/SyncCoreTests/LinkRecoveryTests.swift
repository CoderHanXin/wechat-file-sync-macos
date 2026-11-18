import Foundation
import Darwin
import Testing
@testable import SyncCore

@Suite("M4 link recovery (temporary samples)")
final class LinkRecoveryTests {
    private func worker(_ f: ContentFixture, checkpoint: ((ContentCheckpoint) throws -> Void)? = nil) -> ContentWorker {
        ContentWorker(store: f.store, accountID: f.a.id, settleSeconds: 0, recoveryInterval: 0, checkpoint: checkpoint)
    }

    private func lost(_ f: ContentFixture) throws -> (ContentEntity, URL, URL) {
        let source = try f.sync("2026-11/a.txt")
        let entity = try #require(f.store.entities(f.a.id).first)
        let saved = f.files.temporary.appendingPathComponent("outside.txt")
        try FileManager.default.moveItem(at: f.files.root.appendingPathComponent(entity.relative), to: saved)
        try worker(f).scan()
        #expect(fileInfo(source.path) == nil)
        return (entity, source, saved)
    }

    @Test func originalReturnsAndSharedSourcesRecoverWhilePaused() throws {
        let f = try ContentFixture()
        let a = try f.sync("a.txt"), b = try f.sync("b.txt")
        let entity = try #require(f.store.entities(f.a.id).first)
        let outside = f.files.temporary.appendingPathComponent("original")
        try FileManager.default.moveItem(at: f.files.root.appendingPathComponent(entity.relative), to: outside)
        try worker(f).scan()
        #expect(fileInfo(a.path) == nil && fileInfo(b.path) == nil)
        try f.files.manager.setPaused(f.a.id, paused: true)
        let back = f.files.root.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: outside, to: back)
        try worker(f).scan()
        #expect(linkTarget(a.path) == back.path && linkTarget(b.path) == back.path)
        #expect(try f.store.sources(f.a.id).allSatisfy { $0.active && $0.endReason == nil })
        #expect(try f.store.operations(f.a.id).isEmpty)
    }

    @Test func externallyRemovedLinkIsNotResurrected() throws {
        let f = try ContentFixture()
        let source = try f.sync("a.txt")
        try FileManager.default.removeItem(at: source)
        try worker(f).scan()
        let entity = try #require(f.store.entities(f.a.id).first)
        let target = f.files.root.appendingPathComponent(entity.relative)
        let outside = f.files.temporary.appendingPathComponent("out")
        try FileManager.default.moveItem(at: target, to: outside)
        try worker(f).scan()
        try FileManager.default.moveItem(at: outside, to: target)
        try worker(f).scan()
        #expect(fileInfo(source.path) == nil)
        #expect(try f.store.sources(f.a.id).first?.endReason == .external)
    }

    @Test func pathReusePermanentlyExcludesOldLifecycle() throws {
        let f = try ContentFixture()
        let (entity, source, outside) = try lost(f)
        try Data("new".utf8).write(to: source)
        let intake = worker(f)
        try intake.scan(); try intake.scan()
        let fresh = try #require(f.store.sources(f.a.id).last)
        #expect(fresh.entityID != entity.id)
        try FileManager.default.removeItem(at: source)
        try worker(f).scan()
        let returned = f.files.root.appendingPathComponent("returned-original.txt")
        try FileManager.default.moveItem(at: outside, to: returned)
        try worker(f).scan()
        #expect(fileInfo(source.path) == nil)
        let preview = try LinkRecovery(store: f.store).preview(accountID: f.a.id, entityID: entity.id, file: returned)
        #expect(preview.choices.first?.skipReason != nil)
    }

    @Test(arguments: ["same", "different"])
    func explicitCopyPreviewAndRebindPreservePermissions(_ contents: String) throws {
        let f = try ContentFixture()
        let (entity, source, _) = try lost(f)
        let candidate = f.files.root.appendingPathComponent("chosen.txt")
        try Data(contents.utf8).write(to: candidate)
        let before = try #require(try readFileInfo(candidate.path))
        let service = LinkRecovery(store: f.store)
        let preview = try service.preview(accountID: f.a.id, entityID: entity.id, file: candidate)
        #expect(preview.choices.count == 1 && preview.choices[0].skipReason == nil)
        #expect(try f.store.operations(f.a.id).isEmpty && fileInfo(source.path) == nil)
        #expect(try service.apply(preview).isEmpty)
        #expect(linkTarget(source.path) == candidate.path)
        let restored = try #require(f.store.sources(f.a.id).first)
        #expect(restored.entityID != entity.id && restored.active)
        #expect(restored.receivedDigest == preview.choices[0].source.receivedDigest)
        #expect(try readFileInfo(candidate.path)?.mode == before.mode)
        #expect(try f.store.entities(f.a.id).first(where: { $0.id == restored.entityID })?.protectionBefore == nil)
    }

    @Test func missingDigestIsExplainedAndCanBeConfirmed() throws {
        let f = try ContentFixture()
        let (entity, _, _) = try lost(f)
        let old = try #require(f.store.sources(f.a.id).first)
        let source = ContentSource(id: old.id, accountID: old.accountID, relative: old.relative, entityID: old.entityID,
            originalName: old.originalName, receivedIdentity: old.receivedIdentity, receivedDigest: nil,
            status: .detached, active: false, linkRelative: old.linkRelative, endReason: .unknown)
        try f.store.atomic { try f.store.put(source) }
        let candidate = f.files.root.appendingPathComponent("copy")
        try Data("chosen".utf8).write(to: candidate)
        let service = LinkRecovery(store: f.store)
        let preview = try service.preview(accountID: f.a.id, entityID: entity.id, file: candidate)
        #expect(preview.choices.first?.comparison.contains("无法核对") == true)
        #expect(try service.apply(preview).isEmpty)
    }

    @Test func stalePreviewNeverWritesLinks() throws {
        let f = try ContentFixture()
        let (entity, source, _) = try lost(f)
        let candidate = f.files.root.appendingPathComponent("copy")
        try Data("copy".utf8).write(to: candidate)
        let service = LinkRecovery(store: f.store)
        let preview = try service.preview(accountID: f.a.id, entityID: entity.id, file: candidate)
        try Data("changed".utf8).write(to: candidate)
        #expect(throws: (any Error).self) { try service.apply(preview) }
        #expect(fileInfo(source.path) == nil)
        #expect(try f.store.operations(f.a.id).isEmpty)
    }

    @Test func previewThenSourceOccupiedIsSkipped() throws {
        let f = try ContentFixture()
        let (entity, source, _) = try lost(f)
        let candidate = f.files.root.appendingPathComponent("copy")
        try Data("copy".utf8).write(to: candidate)
        let service = LinkRecovery(store: f.store)
        let preview = try service.preview(accountID: f.a.id, entityID: entity.id, file: candidate)
        try Data("new source".utf8).write(to: source)
        #expect(try service.apply(preview).count == 1)
        #expect(try String(contentsOf: source, encoding: .utf8) == "new source")
    }

    @Test(arguments: [ContentCheckpoint.planSaved, .recoveryPrepared, .recoveryInstalled])
    func interruptedRestoreReplays(_ stage: ContentCheckpoint) throws {
        let f = try ContentFixture()
        let (entity, source, _) = try lost(f)
        let copy = f.files.root.appendingPathComponent("copy")
        try Data("copy".utf8).write(to: copy)
        let service = LinkRecovery(store: f.store, checkpoint: { if $0 == stage { throw SyncError.message("interrupted") } })
        let preview = try service.preview(accountID: f.a.id, entityID: entity.id, file: copy)
        #expect(try service.apply(preview).count == 1)
        let op = try #require(f.store.operations(f.a.id).first)
        try LinkRecovery(store: f.store).run(op)
        try LinkRecovery(store: f.store).run(op)
        #expect(linkTarget(source.path) == copy.path)
        #expect(try f.store.operations(f.a.id).isEmpty)
    }

    @Test func changedTargetAfterInstallCancelsOnlyOwnedLink() throws {
        let f = try ContentFixture()
        let (entity, source, _) = try lost(f)
        let copy = f.files.root.appendingPathComponent("copy")
        try Data("copy".utf8).write(to: copy)
        let service = LinkRecovery(store: f.store, checkpoint: { if $0 == .recoveryInstalled { throw SyncError.message("stop") } })
        _ = try service.apply(service.preview(accountID: f.a.id, entityID: entity.id, file: copy))
        try Data("changed".utf8).write(to: copy)
        let op = try #require(f.store.operations(f.a.id).first)
        #expect(throws: (any Error).self) { try LinkRecovery(store: f.store).run(op) }
        #expect(fileInfo(source.path) == nil)
        #expect(try String(contentsOf: copy, encoding: .utf8) == "changed")
        #expect(try f.store.operations(f.a.id).isEmpty)
    }

    @Test func cleanupAfterUnlinkInterruptionPreservesReason() throws {
        let f = try ContentFixture()
        let source = try f.sync("a.txt")
        let entity = try #require(f.store.entities(f.a.id).first)
        try FileManager.default.removeItem(at: f.files.root.appendingPathComponent(entity.relative))
        try worker(f, checkpoint: { if $0 == .linkCleared { throw SyncError.message("stop") } }).scan()
        #expect(fileInfo(source.path) == nil)
        #expect(try !f.store.operations(f.a.id).isEmpty)
        try worker(f).scan()
        #expect(try f.store.sources(f.a.id).first?.endReason == .toolCleaned)
        #expect(try f.store.operations(f.a.id).isEmpty)
    }

    @Test func candidatesOutsideRootOrOwnedByOtherAccountAreRejected() throws {
        let f = try ContentFixture()
        let (entity, _, outside) = try lost(f)
        let service = LinkRecovery(store: f.store)
        #expect(throws: (any Error).self) { try service.preview(accountID: f.a.id, entityID: entity.id, file: outside) }
        _ = try f.files.incoming(1, "b.txt")
        let b = ContentWorker(store: f.store, accountID: f.b.id, settleSeconds: 0)
        try b.scan(); try b.scan()
        let target = try #require(f.store.entities(f.b.id).first)
        #expect(throws: (any Error).self) { try service.preview(accountID: f.a.id, entityID: entity.id, file: f.files.root.appendingPathComponent(target.relative)) }
    }

    @Test func rootEnumerationFailurePreservesLinks() throws {
        let f = try ContentFixture()
        let source = try f.sync("a.txt")
        let entity = try #require(f.store.entities(f.a.id).first)
        try FileManager.default.removeItem(at: f.files.root.appendingPathComponent(entity.relative))
        let index = ManagedRootIndex(root: f.files.root, enumerate: { _ in throw SyncError.message("unavailable") })
        try worker(f).scan(index: index)
        #expect(fileInfo(source.path)?.symbolicLink == true)
        #expect(try f.store.sources(f.a.id).first?.active == true)
    }

    @Test(arguments: [DatabaseMigrationCheckpoint.backupCreated, .rowsCopied, .beforeCommit])
    func v4MigrationRollbackAndUnknownReasons(_ stage: DatabaseMigrationCheckpoint) throws {
        let f = try ContentFixture()
        let (_, _, _) = try lost(f)
        var source = try #require(f.store.sources(f.a.id).first)
        source.endReason = nil
        try f.store.atomic { try f.store.put(source); try f.store.accounts.execute("PRAGMA user_version=3") }
        #expect(throws: (any Error).self) { try ContentRepository(url: f.files.repository.url, recoveryCheckpoint: { if $0 == stage { throw SyncError.message("stop") } }) }
        #expect(try f.store.accounts.scalar("PRAGMA user_version") == 3)
        #expect(try f.store.sources(f.a.id).first?.endReason == nil)
        let upgraded = try ContentRepository(url: f.files.repository.url)
        #expect(try upgraded.accounts.scalar("PRAGMA user_version") == 4)
        #expect(try upgraded.sources(f.a.id).first?.endReason == .toolCleaned)
        #expect(try ContentRepository(url: f.files.repository.url, readOnly: true).sources(f.a.id).count == 1)
    }
    @Test func databaseFailureAfterLinkInstallReplaysWithoutDuplicateBinding() throws {
        let f = try ContentFixture()
        let (entity, source, _) = try lost(f)
        let copy = f.files.root.appendingPathComponent("copy")
        try Data("copy".utf8).write(to: copy)
        let service = LinkRecovery(store: f.store)
        let preview = try service.preview(accountID: f.a.id, entityID: entity.id, file: copy)
        try f.store.accounts.execute("CREATE TRIGGER reject_binding BEFORE UPDATE ON sources BEGIN SELECT RAISE(ABORT,'injected failure'); END")
        #expect(throws: (any Error).self) { try service.apply(preview) }
        #expect(linkTarget(source.path) == copy.path)
        #expect(try f.store.sources(f.a.id).first?.entityID == entity.id)
        let op = try #require(f.store.operations(f.a.id).first)
        try f.store.accounts.execute("DROP TRIGGER reject_binding")
        try service.run(op)
        #expect(try f.store.sources(f.a.id).first?.active == true)
        #expect(try f.store.sources(f.a.id).count == 1)
        #expect(try f.store.operations(f.a.id).isEmpty)
    }

    @Test func newReceptionDoesNotReviveOldSources() throws {
        let f = try ContentFixture()
        let (entity, source, _) = try lost(f)
        let fresh = try f.sync("new.txt")
        #expect(fileInfo(fresh.path)?.symbolicLink == true)
        #expect(fileInfo(source.path) == nil)
        #expect(try f.store.sources(f.a.id).first(where: { $0.entityID == entity.id })?.active == false)
    }

    @Test func autoRecoveryAllowsEditedOriginalButInvalidatesHash() throws {
        let f = try ContentFixture(protect: false)
        let (entity, source, outside) = try lost(f)
        try Data("edited original".utf8).write(to: outside)
        let returned = f.files.root.appendingPathComponent("edited")
        try FileManager.default.moveItem(at: outside, to: returned)
        try worker(f).scan()
        #expect(linkTarget(source.path) == returned.path)
        #expect(try f.store.entities(f.a.id).first?.digest == nil)
        #expect(try f.store.entities(f.a.id).first?.identity == entity.identity)
    }

    @Test func removedAccountNeverAccessesRecoverySource() throws {
        let f = try ContentFixture()
        let (entity, source, outside) = try lost(f)
        try f.store.accounts.remove(f.a.id)
        try FileManager.default.moveItem(at: outside, to: f.files.root.appendingPathComponent(entity.relative))
        try worker(f).scan()
        #expect(fileInfo(source.path) == nil)
        #expect(throws: (any Error).self) {
            try LinkRecovery(store: f.store).preview(accountID: f.a.id, entityID: entity.id, file: f.files.root.appendingPathComponent(entity.relative))
        }
    }

    @Test func sourceParentRedirectPreventsInstallAndLeavesOutsideUntouched() throws {
        let f = try ContentFixture()
        let (entity, source, _) = try lost(f)
        let copy = f.files.root.appendingPathComponent("copy")
        try Data("copy".utf8).write(to: copy)
        let service = LinkRecovery(store: f.store)
        let preview = try service.preview(accountID: f.a.id, entityID: entity.id, file: copy)
        let parent = source.deletingLastPathComponent()
        let outside = f.files.temporary.appendingPathComponent("moved-parent")
        try FileManager.default.moveItem(at: parent, to: outside)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
        #expect(try service.apply(preview).count == 1)
        #expect(fileInfo(outside.appendingPathComponent(source.lastPathComponent).path) == nil)
        #expect(try f.store.operations(f.a.id).isEmpty)
    }

    @Test func clearQuarantineInterruptionNeverDeletesReplacementContent() throws {
        let f = try ContentFixture()
        let source = try f.sync("a.txt")
        let entity = try #require(f.store.entities(f.a.id).first)
        try FileManager.default.removeItem(at: f.files.root.appendingPathComponent(entity.relative))
        try worker(f, checkpoint: { if $0 == .linkQuarantined { throw SyncError.message("stop") } }).scan()
        let op = try #require(f.store.operations(f.a.id).first)
        let temp = source.deletingLastPathComponent().appendingPathComponent(op.temporary)
        #expect(fileInfo(temp.path)?.symbolicLink == true)
        try FileManager.default.removeItem(at: temp)
        try Data("replacement preserved".utf8).write(to: temp)
        try LinkRecovery(store: f.store).run(op)
        #expect(try String(contentsOf: source, encoding: .utf8) == "replacement preserved")
        #expect(try f.store.sources(f.a.id).first?.endReason == .reused)
        #expect(try f.store.operations(f.a.id).isEmpty)
    }

}
