import Foundation
import Testing
@testable import SyncCore

@Suite("Desktop session isolation")
final class ApplicationSessionTests {
    @Test func exclusiveSessionAndRelease() throws {
        let f = try MultiAccountFixture()
        var session: ApplicationSession? = try ApplicationSession(database: f.repository.url,
            rootAuthorization: { DirectoryLease(url: $0.url) }, sourceAuthorization: { DirectoryLease(url: $0.sourceURL) })
        #expect(throws: (any Error).self) {
            try ApplicationSession(database: f.repository.url, rootAuthorization: { DirectoryLease(url: $0.url) }, sourceAuthorization: { DirectoryLease(url: $0.sourceURL) })
        }
        try session?.scan()
        #expect(try session?.snapshot().accounts.isEmpty == true)
        session = nil
        let fresh = try ApplicationSession(database: f.repository.url, rootAuthorization: { DirectoryLease(url: $0.url) }, sourceAuthorization: { DirectoryLease(url: $0.sourceURL) })
        let rootInfo = try readFileInfo(f.root.path)
        #expect(try fresh.snapshot().root?.identity == rootInfo?.identity)
    }

    @Test func configurationAndScansUseSameStoreAndRespectRemovedAccount() throws {
        let f = try MultiAccountFixture()
        let a = try f.add(0), b = try f.add(1)
        var authorized: [String] = []
        let session = try ApplicationSession(database: f.repository.url,
            rootAuthorization: { DirectoryLease(url: $0.url) }, sourceAuthorization: { authorized.append($0.id); return DirectoryLease(url: $0.sourceURL) })
        try session.change { store in
            try AccountManager(repository: store.accounts).setPaused(a.id, paused: true)
            try store.accounts.remove(b.id)
            try store.setReadOnly(a.id, false)
        }
        try session.scan()
        let snapshot = try session.snapshot()
        #expect(snapshot.accounts.first(where: { $0.id == a.id })?.intakeEnabled == false)
        #expect(snapshot.readOnly[a.id] == false)
        #expect(authorized == [a.id])
    }

    @Test func sourceFailureDoesNotHideOtherAccountOrReportEverythingHealthy() throws {
        let f = try MultiAccountFixture()
        let a = try f.add(0), b = try f.add(1)
        let session = try ApplicationSession(database: f.repository.url,
            rootAuthorization: { DirectoryLease(url: $0.url) }, sourceAuthorization: { account in
                if account.id == a.id { throw SyncError.message("fake permission expired") }
                return DirectoryLease(url: account.sourceURL)
            })
        try session.scan()
        #expect(try session.snapshot().syncStatus == .needsAttention)
        #expect(try session.snapshot().message.contains("fake permission expired"))
        #expect(try session.snapshot().accounts.contains { $0.id == b.id })
        #expect(try session.snapshot().unavailableSources == [a.id])
        #expect(try session.snapshot().accountIssues == [a.id: "fake permission expired"])
    }

    @Test func statusFollowsIntakeAndPause() throws {
        let f = try MultiAccountFixture()
        try f.incoming(0, "historical.txt")
        let a = try f.add(0)
        let session = try ApplicationSession(database: f.repository.url,
            rootAuthorization: { DirectoryLease(url: $0.url) }, sourceAuthorization: { DirectoryLease(url: $0.sourceURL) }, settleSeconds: 0)
        #expect(try session.snapshot().syncStatus == .waiting)
        try session.scan()
        #expect(try session.snapshot().syncStatus == .idle)

        let incoming = f.sources[0].appendingPathComponent("new.bin")
        try Data(repeating: 1, count: 4 * 1024 * 1024 + 1).write(to: incoming)
        try session.scan()
        #expect(try session.snapshot().syncStatus == .processing)
        try session.scan()
        #expect(try session.snapshot().syncStatus == .processing)
        try session.scan()
        #expect(linkTarget(incoming.path) == f.target(a, "new.bin").path)
        #expect(try session.snapshot().syncStatus == .idle)

        try f.incoming(0, "while-paused.txt")
        try session.change { try AccountManager(repository: $0.accounts).setPaused(a.id, paused: true) }
        try session.scan()
        #expect(try session.snapshot().syncStatus == .paused)
        #expect(fileInfo(f.sources[0].appendingPathComponent("while-paused.txt").path)?.regular == true)
    }

    @Test func savingLocationFailureIsReportedSeparatelyAndClearsAfterRecovery() throws {
        let f = try MultiAccountFixture()
        _ = try f.add(0)
        var accessAllowed = false
        let session = try ApplicationSession(database: f.repository.url, rootAuthorization: { root in
            guard accessAllowed else { throw SyncError.message("保存位置访问失效") }
            return DirectoryLease(url: root.url)
        }, sourceAuthorization: { DirectoryLease(url: $0.sourceURL) })
        #expect(throws: (any Error).self) { try session.scan() }
        #expect(try session.snapshot().syncStatus == .savingLocationUnavailable)
        #expect(try session.snapshot().accountIssues.isEmpty)
        accessAllowed = true
        try session.scan()
        #expect(try session.snapshot().syncStatus == .idle)
    }
    @Test func pendingSourceIssueRemainsVisibleBetweenRetries() throws {
        let f = try MultiAccountFixture()
        let a = try f.add(0)
        let incoming = try f.incoming(0, "pending.txt")
        let session = try ApplicationSession(database: f.repository.url,
            rootAuthorization: { DirectoryLease(url: $0.url) }, sourceAuthorization: { DirectoryLease(url: $0.sourceURL) })
        try session.store.recordIssue(a.id, relative: "pending.txt", message: "附加属性不兼容，保留源文件")
        try session.scan()
        #expect(try session.snapshot().message.contains("附加属性不兼容"))
        try FileManager.default.removeItem(at: incoming)
        try session.scan()
        #expect(try !session.snapshot().message.contains("附加属性不兼容"))
    }

    @Test func occupiedCommitResumesLinkMaintenanceWithoutRestart() throws {
        let f = try ContentFixture()
        let source = try f.sync("before.txt", "test content")
        let original = try #require(linkTarget(source.path))
        let renamed = f.files.target(f.a, "after.txt")
        try FileManager.default.moveItem(at: URL(fileURLWithPath: original), to: renamed)
        let database = f.store.accounts.url
        let session = try ApplicationSession(database: database,
            rootAuthorization: { DirectoryLease(url: $0.url) }, sourceAuthorization: { DirectoryLease(url: $0.sourceURL) })
        _ = try session.store.accounts.scalar("PRAGMA busy_timeout = 0")
        let reader = try SQLiteConnection(url: database)
        try reader.execute("PRAGMA query_only = ON")
        try reader.execute("BEGIN DEFERRED TRANSACTION")
        do {
            defer { try? reader.execute("ROLLBACK") }
            _ = try reader.scalar("SELECT count(*) FROM entities")
            // A reader can prevent COMMIT after BEGIN IMMEDIATE has already succeeded.
            let error = #expect(throws: (any Error).self, performing: { try session.scan() })
            #expect(error.map(isDatabaseBusy) == true)
            let status = try session.snapshot()
            #expect(status.syncStatus == .retrying)
            #expect(status.message == ApplicationSession.databaseBusyMessage)
            #expect(try session.store.entities(f.a.id).first?.relative == f.a.archiveRelative + "/before.txt")
            #expect(linkTarget(source.path) == original)
            #expect(try String(contentsOf: renamed, encoding: .utf8) == "test content")
        }
        try session.scan()
        #expect(linkTarget(source.path) == renamed.path)
        #expect(try String(contentsOf: source, encoding: .utf8) == "test content")
        #expect(try session.snapshot().syncStatus == .idle)
    }

    @Test func occupiedDatabaseResumesPendingIntake() throws {
        let f = try ContentFixture()
        f.restart { if $0 == .planSaved { throw SyncError.message("临时中断") } }
        let source = try f.sync("pending-intake.txt", "pending content")
        #expect(fileInfo(source.path)?.regular == true)
        #expect(try f.store.operations(f.a.id).count == 1)
        let database = f.store.accounts.url
        let session = try ApplicationSession(database: database,
            rootAuthorization: { DirectoryLease(url: $0.url) }, sourceAuthorization: { DirectoryLease(url: $0.sourceURL) })
        _ = try session.store.accounts.scalar("PRAGMA busy_timeout = 0")
        let writer = try SQLiteConnection(url: database)
        try writer.execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            defer { try? writer.execute("ROLLBACK") }
            let error = #expect(throws: (any Error).self, performing: { try session.scan() })
            #expect(error.map(isDatabaseBusy) == true)
            #expect(try session.store.operations(f.a.id).contains { $0.kind == .create })
        }
        try session.scan()
        #expect(linkTarget(source.path) == f.files.target(f.a, "pending-intake.txt").path)
        #expect(try String(contentsOf: source, encoding: .utf8) == "pending content")
        #expect(try session.store.operations(f.a.id).isEmpty)
        #expect(try session.store.accounts.loadState(f.a.id).transfers.isEmpty)
    }

    @Test func nonBusyWriteFailureStillHaltsEvenWhenMessageMentionsLock() throws {
        let f = try ContentFixture()
        let source = try f.sync("before.txt")
        let original = try #require(linkTarget(source.path))
        try FileManager.default.moveItem(at: URL(fileURLWithPath: original), to: f.files.target(f.a, "after.txt"))
        let session = try ApplicationSession(database: f.store.accounts.url,
            rootAuthorization: { DirectoryLease(url: $0.url) }, sourceAuthorization: { DirectoryLease(url: $0.sourceURL) })
        try session.store.accounts.execute("""
            CREATE TRIGGER reject_entity_update BEFORE UPDATE ON entities
            BEGIN SELECT RAISE(ABORT, 'database is locked'); END
            """)
        let error = #expect(throws: (any Error).self, performing: { try session.scan() })
        #expect(error.map(isDatabaseBusy) == false)
        try session.store.accounts.execute("DROP TRIGGER reject_entity_update")
        try session.scan()
        #expect(linkTarget(source.path) == original)
        #expect(try session.snapshot().message.contains("状态保存失败"))
    }

}
