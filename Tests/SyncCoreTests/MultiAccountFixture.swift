import Foundation
@testable import SyncCore

final class MultiAccountFixture {
    let temporary: URL
    let root: URL
    let sources: [URL]
    let repository: AccountRepository
    let manager: AccountManager
    var now = Date(timeIntervalSince1970: 1000)

    init() throws {
        temporary = try canonicalDirectory(FileManager.default.temporaryDirectory).appendingPathComponent("wechat-multi-tests-" + UUID().uuidString)
        root = temporary.appendingPathComponent("自定义资料")
        sources = [temporary.appendingPathComponent("A/msg/file"), temporary.appendingPathComponent("B/msg/file")]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for source in sources { try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true) }
        repository = try AccountRepository(url: temporary.appendingPathComponent("state.sqlite"))
        manager = AccountManager(repository: repository)
        try manager.configureRoot(root, bookmark: Data("fake-root".utf8))
    }

    deinit { try? FileManager.default.removeItem(at: temporary) }

    func add(_ index: Int, name: String? = nil) throws -> Account {
        try manager.add(source: sources[index], name: name ?? (index == 0 ? "工作" : "私人"), bookmark: Data("fake-source-\(index)".utf8))
    }

    @discardableResult
    func incoming(_ index: Int, _ path: String = "2026-11/report.txt", text: String = "original") throws -> URL {
        let file = sources[index].appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        return file
    }

    func target(_ account: Account, _ name: String = "report.txt") -> URL {
        root.appendingPathComponent(account.archiveRelative).appendingPathComponent(name)
    }

    func worker(_ account: Account, checkpoint: ((TransferCheckpoint) throws -> Void)? = nil) throws -> SyncWorker {
        try SyncWorker(store: AccountStateStore(repository: repository, accountID: account.id), archiveRelative: account.archiveRelative,
                       archiveIdentity: account.archiveIdentity, settleSeconds: 0, checkpoint: checkpoint)
    }

    func coordinator(authorize: ((Account) throws -> DirectoryLease)? = nil,
                     enumerate: @escaping (URL) throws -> [String: FileInfo] = allFiles) -> SyncCoordinator {
        SyncCoordinator(repository: repository, settleSeconds: 0, enumerate: enumerate,
                        authorize: authorize ?? { DirectoryLease(url: $0.sourceURL) })
    }
}
