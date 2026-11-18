import Foundation
import Testing
@testable import SyncCore

final class CountingStore: StateStore {
    let base: SQLiteStateStore
    var saves = 0
    var failNextSave = false

    init(_ base: SQLiteStateStore) { self.base = base }
    func load() throws -> SyncState { try base.load() }
    func save(_ state: SyncState) throws {
        saves += 1
        if failNextSave {
            failNextSave = false
            throw SyncError.message("injected save failure")
        }
        try base.save(state)
    }
}

final class Fixture {
    let root: URL
    let source: URL
    let managedRoot: URL
    let databaseURL: URL
    let store: CountingStore
    var worker: SyncWorker

    init(existing: [String: String] = [:], settleSeconds: TimeInterval = 0,
         clock: @escaping () -> Date = Date.init,
         checkpoint: ((TransferCheckpoint) throws -> Void)? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wechat-core-tests-" + UUID().uuidString)
        source = root.appendingPathComponent("wechat-file")
        // Deliberately use a name and location unrelated to Downloads.
        managedRoot = root.appendingPathComponent("自定义资料目录")
        databaseURL = root.appendingPathComponent("state.sqlite")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: managedRoot, withIntermediateDirectories: true)
        for (relative, text) in existing {
            let url = source.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let base = try SQLiteStateStore(url: databaseURL)
        try base.save(initialState(source: source, managedRoot: managedRoot))
        store = CountingStore(base)
        worker = try SyncWorker(store: store, settleSeconds: settleSeconds, clock: clock, checkpoint: checkpoint)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func incoming(_ name: String, _ text: String = "original") throws -> URL {
        let file = source.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        return file
    }

    func target(_ name: String) -> URL { managedRoot.appendingPathComponent(name) }

    @discardableResult
    func sync(_ name: String, _ text: String = "original") throws -> URL {
        let file = try incoming(name, text)
        try worker.scan()
        try worker.scan()
        return file
    }

    func restart() throws {
        worker = try SyncWorker(store: SQLiteStateStore(url: databaseURL), settleSeconds: 0)
    }
}
