import Foundation
import Testing
@testable import SyncCore

struct ContentMigrationTests {
    @Test(arguments: ["sqlite-v1", "legacy-json"])
    func oldFormatsUpgradeInStagesWithoutMovingFiles(_ format: String) throws {
        let f = try Fixture(existing: ["old.txt": "old"])
        let source = try f.sync("linked.txt")
        let before = try f.store.load()
        let database: URL
        if format == "legacy-json" {
            let support = f.root.appendingPathComponent("legacy-import")
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            try JSONEncoder().encode(before).write(to: support.appendingPathComponent("state.json"))
            database = support.appendingPathComponent("state.sqlite")
        } else { database = f.databaseURL }
        let store = try ContentRepository(url: database)
        let account = try #require(store.accounts.accounts().first)
        #expect(try store.accounts.scalar("PRAGMA user_version") == 4)
        #expect(try store.accounts.loadState(account.id).baseline == before.baseline)
        #expect(try store.entities(account.id).first?.relative == "linked.txt")
        #expect(linkTarget(source.path) == f.target("linked.txt").path)
        #expect(try store.accounts.account(account.id).sourceBookmark == nil)
        try store.accounts.execute("PRAGMA user_version=99")
        #expect(throws: (any Error).self) { try ContentRepository(url: database) }
        #expect(try store.accounts.scalar("PRAGMA user_version") == 99)
        try store.accounts.execute("PRAGMA user_version=4")
        #expect(try ContentRepository(url: database, readOnly: true).sources(account.id).count == 1)
    }

    @Test func migrationNeverCombinesOldDuplicateFilesAndPreservesRemovedAuthorization() throws {
        let f = try MultiAccountFixture()
        let a = try f.add(0); let b = try f.add(1)
        let oldA = try f.incoming(0, "one.txt", text: "same")
        let oldB = try f.incoming(0, "two.txt", text: "same")
        let worker = try f.worker(a)
        try worker.scan(); try worker.scan()
        let firstTarget = try #require(linkTarget(oldA.path)), secondTarget = try #require(linkTarget(oldB.path))
        try f.repository.remove(b.id)
        let v3 = try ContentRepository(url: f.repository.url)
        #expect(try v3.accounts.account(b.id).sourceBookmark == nil)
        #expect(try v3.entities(a.id).count == 2)
        let fresh = try f.incoming(0, "new.txt", text: "same")
        let next = ContentWorker(store: v3, accountID: a.id, settleSeconds: 0)
        try next.scan(); try next.scan()
        #expect(try v3.entities(a.id).count == 2)
        #expect(linkTarget(oldA.path) == firstTarget && linkTarget(oldB.path) == secondTarget)
        #expect([firstTarget, secondTarget].contains(linkTarget(fresh.path) ?? ""))
    }

    @Test func legacyMovedOperationCompletesWithoutRetroactiveReadOnly() throws {
        let f = try MultiAccountFixture()
        let a = try f.add(0)
        let source = try f.incoming(0)
        let stopped = try f.worker(a) { if $0 == .fileMoved { throw SyncError.message("stop") } }
        try stopped.scan(); try stopped.scan()
        let mode = fileInfo(f.target(a).path)?.mode
        let v3 = try ContentRepository(url: f.repository.url)
        let worker = ContentWorker(store: v3, accountID: a.id, settleSeconds: 0)
        try worker.scan()
        #expect(linkTarget(source.path) == f.target(a).path)
        #expect(fileInfo(f.target(a).path)?.mode == mode)
        #expect(try v3.operations(a.id).isEmpty)
        #expect(try v3.sources(a.id).first?.receivedDigest == nil)
    }

    @Test func malformedV2TransferRollsBackInsteadOfCommittingInvalidV3() throws {
        let f = try MultiAccountFixture()
        let a = try f.add(0)
        let adapter = AccountStateStore(repository: f.repository, accountID: a.id)
        var state = try adapter.load()
        state.transfers["../outside"] = Transfer(destination: "file.txt", temporary: temporaryPrefix + "old", identity: a.sourceIdentity, phase: .conflict)
        try adapter.save(state)
        #expect(throws: (any Error).self) { try ContentRepository(url: f.repository.url) }
        #expect(try AccountRepository(url: f.repository.url).loadState(a.id) == state)
        #expect(try f.repository.scalar("PRAGMA user_version") == 2)
    }

    @Test func migrationPreservesFilesPermissionsSettingsAndPendingRecords() throws {
        let f = try MultiAccountFixture()
        _ = try f.incoming(0, "old.txt")
        let a = try f.add(0); let b = try f.add(1)
        let incoming = try f.incoming(0)
        let worker = try f.worker(a)
        try worker.scan(); try worker.scan()
        let pending = try f.incoming(1)
        let stopped = try f.worker(b) { if $0 == .fileMoved { throw SyncError.message("stop") } }
        try stopped.scan(); try stopped.scan()
        try f.manager.setPaused(b.id, paused: true)
        let before = try f.repository.loadState(b.id)
        let mode = try #require(fileInfo(f.target(a).path)?.mode)
        let v3 = try ContentRepository(url: f.repository.url)
        #expect(try v3.accounts.scalar("PRAGMA user_version") == 4)
        #expect(try v3.entities(a.id).count == 1)
        #expect(try v3.sources(a.id).first?.status == .linked)
        #expect(try v3.sources(a.id).first?.receivedDigest == nil)
        #expect(try v3.operations(b.id).first?.kind == .legacy)
        #expect(try v3.accounts.loadState(b.id) == before)
        #expect(try !v3.accounts.account(b.id).intakeEnabled)
        #expect(linkTarget(incoming.path) == f.target(a).path)
        #expect(fileInfo(f.target(a).path)?.mode == mode)
        #expect(fileInfo(pending.path) == nil)
        #expect(try v3.readOnlyDefault(a.id))
        #expect(try v3.accounts.loadState(a.id).baseline.keys.sorted() == ["old.txt"])
        #expect(try ContentRepository(url: f.repository.url).sources(a.id) == v3.sources(a.id))
    }

    @Test(arguments: [DatabaseMigrationCheckpoint.backupCreated, .rowsCopied, .beforeCommit])
    func failedMigrationRollsBackAndRetainsPrivateV2Backup(_ stage: DatabaseMigrationCheckpoint) throws {
        let f = try MultiAccountFixture()
        let a = try f.add(0)
        _ = try f.incoming(0)
        let worker = try f.worker(a)
        try worker.scan(); try worker.scan()
        let before = try f.repository.loadState(a.id)
        #expect(throws: (any Error).self) {
            try ContentRepository(url: f.repository.url, checkpoint: { if $0 == stage { throw SyncError.message("stop") } })
        }
        #expect(try AccountRepository(url: f.repository.url).loadState(a.id) == before)
        let backup = try #require(FileManager.default.contentsOfDirectory(at: f.temporary, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("state.v2-backup-") })
        #expect(try AccountRepository(url: backup, readOnly: true).loadState(a.id) == before)
        #expect((try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func readonlyDoesNotMigrateAndCrossAccountRelationshipIsRejected() throws {
        let f = try MultiAccountFixture()
        let a = try f.add(0); let b = try f.add(1)
        #expect(throws: (any Error).self) { try ContentRepository(url: f.repository.url, readOnly: true) }
        #expect(try f.repository.scalar("PRAGMA user_version") == 2)
        let v3 = try ContentRepository(url: f.repository.url)
        let entity = ContentEntity(id: UUID().uuidString, accountID: a.id, relative: "a.txt", identity: a.sourceIdentity, info: nil, digest: nil, status: .unchecked)
        try v3.atomic { try v3.put(entity) }
        let wrong = ContentSource(id: UUID().uuidString, accountID: b.id, relative: "b.txt", entityID: entity.id, originalName: "b.txt",
            receivedIdentity: b.sourceIdentity, receivedDigest: nil, status: .pending, active: true, linkRelative: "a.txt")
        #expect(throws: (any Error).self) { try v3.atomic { try v3.put(wrong) } }
        #expect(try v3.sources(b.id).isEmpty)
        let reader = try ContentRepository(url: f.repository.url, readOnly: true)
        #expect(throws: (any Error).self) { try reader.setReadOnly(a.id, false) }
    }
}
