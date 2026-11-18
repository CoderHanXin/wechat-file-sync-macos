import Foundation
import SQLite3
import Testing
@testable import SyncCore

final class StateStoreTests {
    @Test func testMissingConfigurationWithRemainingRecordsNeverReimportsLegacyState() throws {
        let f = try Fixture()
        let source = try f.sync("report.txt")
        try JSONEncoder().encode(f.worker.state).write(to: f.root.appendingPathComponent("state.json"))
        try sql(f.databaseURL, "DELETE FROM configuration")
        #expect(throws: (any Error).self) { try openConfiguredStore(appSupport: f.root) }
        #expect(try String(contentsOf: source) == "original")
        #expect(try String(contentsOf: f.target("report.txt")) == "original")
    }

    @Test func testDiagnosticConnectionReadsButCannotWrite() throws {
        let f = try Fixture()
        let lock = try ProcessLock(url: f.root.appendingPathComponent("sync.lock"))
        defer { withExtendedLifetime(lock) {} }
        let reader = try SQLiteStateStore(url: f.databaseURL, readOnly: true)
        #expect(try reader.load() == f.worker.state)
        #expect(throws: (any Error).self) { try reader.save(f.worker.state) }
        #expect(try f.store.load() == f.worker.state)
    }

    private func sql(_ url: URL, _ command: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw SyncError.message("test database open failed")
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, command, nil, nil, nil) == SQLITE_OK else {
            throw SyncError.message("test SQL failed: \(String(cString: sqlite3_errmsg(database)))")
        }
    }

    @Test func testRoundTripUpdatesAndRemovalsPersist() throws {
        let f = try Fixture(existing: ["old.txt": "old"])
        let incoming = try f.sync("month/new.txt")
        let initial = f.worker.state
        #expect(try SQLiteStateStore(url: f.databaseURL).load() == initial)
        #expect(try String(contentsOf: incoming) == "original")
        var changed = initial
        changed.baseline = [:]
        changed.transfers["month/new.txt"]?.phase = .conflict
        try f.store.save(changed)
        #expect(try SQLiteStateStore(url: f.databaseURL).load() == changed)
        changed.transfers = [:]
        try f.store.save(changed)
        #expect(try SQLiteStateStore(url: f.databaseURL).load().transfers.isEmpty)
    }

    @Test func testSQLiteFailureRollsBackStateAndBookmarksTogether() throws {
        let f = try Fixture()
        let oldBookmarks = DirectoryBookmarks(source: Data("A".utf8), managedRoot: Data("root-A".utf8))
        try f.store.base.configure(f.worker.state, bookmarks: oldBookmarks)
        let before = try f.store.load()
        var changed = before
        changed.baseline["extra"] = before.sourceIdentity
        let source = try f.incoming("pending.txt")
        changed.transfers["pending.txt"] = Transfer(destination: "pending.txt", temporary: temporaryPrefix + "pending",
            identity: try #require(fileInfo(source.path)?.identity), phase: .planned,
            observedInfo: fileInfo(source.path))
        try sql(f.databaseURL, "CREATE TRIGGER fail_bookmark BEFORE INSERT ON bookmarks BEGIN SELECT RAISE(ABORT, 'injected failure'); END")
        #expect(throws: (any Error).self) { try f.store.base.configure(changed,
            bookmarks: DirectoryBookmarks(source: Data("B".utf8), managedRoot: Data("root-B".utf8))) }
        let reopened = try SQLiteStateStore(url: f.databaseURL)
        #expect(try reopened.load() == before)
        #expect(try reopened.bookmarks() == oldBookmarks)
        #expect(fileInfo(source.path)?.regular == true)
        try sql(f.databaseURL, "DROP TRIGGER fail_bookmark")
        try f.store.base.save(changed)
        #expect(try f.store.load() == changed)
    }

    @Test func testWrongAccountConfigurationPreservesOriginalAuthorization() throws {
        let f = try Fixture()
        let bookmarks = DirectoryBookmarks(source: Data("source-A".utf8), managedRoot: Data("root".utf8))
        try configureDirectories(store: f.store.base, source: f.source, managedRoot: f.managedRoot, bookmarks: bookmarks)
        let before = try f.store.load()
        let other = f.root.appendingPathComponent("other-account")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try configureDirectories(store: f.store.base, source: other, managedRoot: f.managedRoot,
            bookmarks: DirectoryBookmarks(source: Data("source-B".utf8), managedRoot: Data("root-B".utf8))) }
        let reopened = try SQLiteStateStore(url: f.databaseURL)
        #expect(try reopened.load() == before)
        #expect(try reopened.bookmarks() == bookmarks)
    }

    @Test func testLegacyJSONMigrationIsIdempotentAndKeepsOriginalFiles() throws {
        let f = try Fixture(existing: ["old.txt": "old"])
        let support = f.root.appendingPathComponent("legacy-support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let state = f.worker.state
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        json["downloads"] = json.removeValue(forKey: "managedRoot")
        json["downloadsIdentity"] = json.removeValue(forKey: "managedRootIdentity")
        let original = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        let legacy = support.appendingPathComponent("state.json")
        try original.write(to: legacy)
        let sourceBookmark = Data("source-bookmark".utf8)
        let rootBookmark = Data("root-bookmark".utf8)
        try sourceBookmark.write(to: support.appendingPathComponent("source.bookmark"))
        try rootBookmark.write(to: support.appendingPathComponent("downloads.bookmark"))
        let store = try openConfiguredStore(appSupport: support)
        #expect(try store.load() == state)
        #expect(try store.bookmarks() == DirectoryBookmarks(source: sourceBookmark, managedRoot: rootBookmark))
        #expect(try Data(contentsOf: legacy) == original)
        var updated = state
        updated.baseline = [:]
        try store.save(updated)
        #expect(try openConfiguredStore(appSupport: support).load() == updated)
        #expect(try Data(contentsOf: legacy) == original)
    }

    @Test func testCorruptDatabaseNeverFallsBackToLegacyJSON() throws {
        let f = try Fixture()
        let support = f.root.appendingPathComponent("corrupt-support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let legacy = try JSONEncoder().encode(f.worker.state)
        try legacy.write(to: support.appendingPathComponent("state.json"))
        let corrupt = Data("not a sqlite database".utf8)
        let database = support.appendingPathComponent("state.sqlite")
        try corrupt.write(to: database)
        #expect(throws: (any Error).self) { try openConfiguredStore(appSupport: support) }
        #expect(try Data(contentsOf: database) == corrupt)
        #expect(try Data(contentsOf: support.appendingPathComponent("state.json")) == legacy)
    }

    @Test func testUnsupportedDatabaseVersionIsPreserved() throws {
        let f = try Fixture()
        try sql(f.databaseURL, "PRAGMA user_version = 99")
        #expect(throws: (any Error).self) { try SQLiteStateStore(url: f.databaseURL) }
        try sql(f.databaseURL, "PRAGMA user_version = 1")
        #expect(try SQLiteStateStore(url: f.databaseURL).load() == f.worker.state)
    }

    @Test func testLegacyPlannedTransferResumesAfterFileMove() throws {
        let f = try Fixture()
        let source = try f.incoming("recovery.txt")
        let identity = try #require(fileInfo(source.path)?.identity)
        f.worker.state.transfers["recovery.txt"] = Transfer(destination: "recovery.txt", temporary: temporaryPrefix + "recovery",
                                                         identity: identity, phase: .planned)
        try f.worker.save()
        try FileManager.default.moveItem(at: source, to: f.target("recovery.txt"))
        try f.restart()
        try f.worker.scan()
        #expect(linkTarget(source.path) == f.target("recovery.txt").path)
        #expect(try String(contentsOf: source) == "original")
    }

    @Test func testLegacyPlannedSourceWaitsForStabilityBeforeMoving() throws {
        let f = try Fixture()
        let source = try f.incoming("recovery.txt")
        f.worker.state.transfers["recovery.txt"] = Transfer(destination: "recovery.txt", temporary: temporaryPrefix + "recovery",
            identity: try #require(fileInfo(source.path)?.identity), phase: .planned)
        try f.worker.save()
        var now = Date(timeIntervalSince1970: 100)
        f.worker = try SyncWorker(store: f.store, settleSeconds: 10, clock: { now })
        try f.worker.scan()
        #expect(fileInfo(source.path)?.regular == true)
        now.addTimeInterval(11)
        try f.worker.scan()
        #expect(linkTarget(source.path) != nil)
    }
}
