import Foundation
@testable import SyncCore

final class ContentFixture {
    let files: MultiAccountFixture
    let store: ContentRepository
    let a: Account
    let b: Account
    var worker: ContentWorker
    init(protect: Bool = true, checkpoint: ((ContentCheckpoint) throws -> Void)? = nil,
         transferCheckpoint: ((TransferCheckpoint) throws -> Void)? = nil) throws {
        files = try MultiAccountFixture()
        a = try files.add(0); b = try files.add(1)
        store = try ContentRepository(url: files.repository.url)
        if !protect { try store.setReadOnly(a.id, false) }
        worker = ContentWorker(store: store, accountID: a.id, settleSeconds: 0, checkpoint: checkpoint, transferCheckpoint: transferCheckpoint)
    }
    func restart(checkpoint: ((ContentCheckpoint) throws -> Void)? = nil) {
        worker = ContentWorker(store: store, accountID: a.id, settleSeconds: 0, checkpoint: checkpoint)
    }
    @discardableResult func sync(_ name: String, _ text: String = "same") throws -> URL {
        let file = try files.incoming(0, name, text: text)
        try worker.scan(); try worker.scan()
        return file
    }
}
