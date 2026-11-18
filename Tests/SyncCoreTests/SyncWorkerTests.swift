import Foundation
import Testing
@testable import SyncCore

final class SyncWorkerTests {
    @Test func testDestinationReplacedImmediatelyAfterMoveNeverRelocatesReplacementIntoSource() throws {
        var target: URL?
        var preserved: URL?
        let f = try Fixture(checkpoint: { stage in
            if stage == .fileMoved {
                try FileManager.default.moveItem(at: #require(target), to: #require(preserved))
                try Data("unrelated replacement".utf8).write(to: #require(target))
            }
        })
        target = f.target("report.txt")
        preserved = f.target("original-preserved.txt")
        let source = try f.incoming("report.txt", "original")
        try f.worker.scan()
        try f.worker.scan()
        #expect(fileInfo(source.path) == nil)
        #expect(try String(contentsOf: #require(target)) == "unrelated replacement")
        #expect(try String(contentsOf: #require(preserved)) == "original")
        #expect(f.worker.state.transfers["report.txt"]?.phase == .conflict)
    }

    @Test func testMovedTargetRenamedBeforeRestartStillRestoresSourceLink() throws {
        let f = try Fixture(checkpoint: { stage in
            if stage == .fileMoved { throw SyncError.message("injected interruption") }
        })
        let source = try f.sync("report.txt", "original")
        let folder = f.target("项目资料")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let renamed = folder.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: f.target("report.txt"), to: renamed)
        try f.restart()
        try f.worker.scan()
        try f.worker.scan()
        #expect(linkTarget(source.path) == renamed.path)
        #expect(try String(contentsOf: source) == "original")
        #expect(f.worker.state.transfers["report.txt"]?.phase == .linked)
    }

    @Test func testMovedTargetRenamedAndOldNameReusedBeforeRestartPreservesBothFiles() throws {
        let f = try Fixture(checkpoint: { stage in
            if stage == .fileMoved { throw SyncError.message("injected interruption") }
        })
        let source = try f.sync("report.txt", "original")
        let renamed = f.target("renamed.txt")
        try FileManager.default.moveItem(at: f.target("report.txt"), to: renamed)
        try Data("unrelated".utf8).write(to: f.target("report.txt"))
        try f.restart()
        try f.worker.scan()
        try f.worker.scan()
        #expect(linkTarget(source.path) == renamed.path)
        #expect(try String(contentsOf: source) == "original")
        #expect(try String(contentsOf: f.target("report.txt")) == "unrelated")
    }

    @Test func testSourceRecreatedDuringMovePreservesBothFiles() throws {
        var source: URL?
        let f = try Fixture(checkpoint: { stage in
            if stage == .fileMoved {
                try Data("new source".utf8).write(to: #require(source))
            }
        })
        source = try f.incoming("report.txt", "original")
        try f.worker.scan()
        try f.worker.scan()
        #expect(try String(contentsOf: #require(source)) == "new source")
        #expect(try String(contentsOf: f.target("report.txt")) == "original")
        #expect(f.worker.state.transfers["report.txt"]?.phase == .conflict)
    }

    @Test func testReplacedTargetDuringRestartIsNotAcceptedAsCompleted() throws {
        let f = try Fixture(checkpoint: { stage in
            if stage == .linkInstalled { throw SyncError.message("injected interruption") }
        })
        try f.sync("report.txt")
        try Data("replacement".utf8).write(to: f.target("report.txt"), options: .atomic)
        try f.restart()
        try f.worker.scan()
        #expect(f.worker.state.transfers["report.txt"]?.phase == .conflict)
        #expect(try String(contentsOf: f.target("report.txt")) == "replacement")
    }

    @Test func testSaveFailureAfterLinkInstallRecoversFromDurablePlan() throws {
        var store: CountingStore?
        let f = try Fixture(checkpoint: { stage in
            if stage == .linkInstalled { store?.failNextSave = true }
        })
        store = f.store
        let source = try f.incoming("report.txt")
        try f.worker.scan()
        #expect(throws: (any Error).self) { try f.worker.scan() }
        #expect(try f.store.load().transfers["report.txt"]?.phase == .planned)
        #expect(try String(contentsOf: source) == "original")
        try f.restart()
        try f.worker.scan()
        #expect(f.worker.state.transfers["report.txt"]?.phase == .linked)
        #expect(try String(contentsOf: source) == "original")
    }

    @Test func testCustomRootAndHistoricalFiles() throws {
        let f = try Fixture(existing: ["month/old.txt": "old"])
        let incoming = try f.sync("month/new.txt", "new")
        #expect(linkTarget(incoming.path) == f.target("new.txt").path)
        #expect(try String(contentsOf: incoming) == "new")
        #expect(fileInfo(f.source.appendingPathComponent("month/old.txt").path)?.regular == true)
        #expect(fileInfo(f.target("old.txt").path) == nil)
        #expect(f.worker.report.issues.isEmpty)
    }

    @Test func testExistingFileRenameRemainsInBaseline() throws {
        let f = try Fixture(existing: ["old.txt": "old"])
        let renamed = f.source.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: f.source.appendingPathComponent("old.txt"), to: renamed)
        try f.worker.scan()
        try f.worker.scan()
        #expect(fileInfo(renamed.path)?.regular == true)
        #expect(fileInfo(f.target("renamed.txt").path) == nil)
    }

    @Test func testSameNameDoesNotOverwriteExistingContent() throws {
        let f = try Fixture()
        try Data("unrelated".utf8).write(to: f.target("report.txt"))
        let incoming = try f.sync("report.txt", "wechat")
        #expect(try String(contentsOf: f.target("report.txt")) == "unrelated")
        #expect(linkTarget(incoming.path) == f.target("report (微信 2).txt").path)
        #expect(try String(contentsOf: incoming) == "wechat")
    }

    @Test func testRenameAndOldFilenameReuseTracksOriginalIdentity() throws {
        let f = try Fixture()
        let incoming = try f.sync("report.txt")
        let renamed = f.target("renamed.txt")
        try FileManager.default.moveItem(at: f.target("report.txt"), to: renamed)
        try Data("unrelated".utf8).write(to: f.target("report.txt"))
        try f.worker.scan()
        #expect(linkTarget(incoming.path) == renamed.path)
        #expect(try String(contentsOf: incoming) == "original")
        #expect(try String(contentsOf: f.target("report.txt")) == "unrelated")
        #expect(f.worker.state.transfers["report.txt"]?.identity == fileInfo(renamed.path)?.identity)
    }

    @Test func testSwappedDestinationNamesKeepBothSourceAssociations() throws {
        let f = try Fixture()
        let a = try f.sync("a.txt", "A")
        let b = try f.sync("b.txt", "B")
        let temporary = f.target("swap")
        try FileManager.default.moveItem(at: f.target("a.txt"), to: temporary)
        try FileManager.default.moveItem(at: f.target("b.txt"), to: f.target("a.txt"))
        try FileManager.default.moveItem(at: temporary, to: f.target("b.txt"))
        try f.worker.scan()
        #expect(try String(contentsOf: a) == "A")
        #expect(try String(contentsOf: b) == "B")
        #expect(f.worker.report.managedRootEnumerations == 1)
    }

    @Test func testMissingSourceLinkAndRenamedTargetDoesNotBlockNewFile() throws {
        let f = try Fixture()
        let oldSource = try f.sync("old.txt")
        try FileManager.default.removeItem(at: oldSource)
        try FileManager.default.moveItem(at: f.target("old.txt"), to: f.target("renamed.txt"))
        let incoming = try f.sync("healthy.txt", "healthy")
        #expect(try String(contentsOf: incoming) == "healthy")
        #expect(linkTarget(incoming.path) != nil)
        #expect(try String(contentsOf: f.target("renamed.txt")) == "original")
    }

    @Test func testReusedSourcePathStartsNewLifecycle() throws {
        let f = try Fixture()
        let source = try f.sync("report.txt", "first")
        try FileManager.default.removeItem(at: source)
        try f.incoming("report.txt", "second")
        try f.worker.scan()
        try f.worker.scan()
        #expect(try String(contentsOf: f.target("report.txt")) == "first")
        #expect(linkTarget(source.path) == f.target("report (微信 2).txt").path)
        #expect(try String(contentsOf: source) == "second")
    }

    @Test func testInvalidStoredPathIsIsolated() throws {
        let f = try Fixture()
        let sentinel = f.root.appendingPathComponent("sentinel")
        try Data("keep".utf8).write(to: sentinel)
        let identity = try #require(fileInfo(sentinel.path)?.identity)
        f.worker.state.transfers["../sentinel"] = Transfer(destination: "sentinel", temporary: temporaryPrefix + "test", identity: identity, phase: .linked)
        let healthy = try f.sync("healthy.txt")
        #expect(linkTarget(healthy.path) != nil)
        #expect(try String(contentsOf: sentinel) == "keep")
        #expect(f.worker.report.issues.contains { $0.relative == "../sentinel" })
    }

    @Test func testUnrelatedSourceLinkIsPreservedAndIsolated() throws {
        let f = try Fixture()
        let source = try f.sync("report.txt")
        try FileManager.default.removeItem(at: source)
        let other = f.root.appendingPathComponent("unrelated.txt")
        try Data("unrelated".utf8).write(to: other)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: other)
        let healthy = try f.sync("healthy.txt")
        #expect(linkTarget(source.path) == other.path)
        #expect(f.worker.state.transfers["report.txt"]?.phase == .conflict)
        #expect(linkTarget(healthy.path) != nil)
    }

    @Test func testAtomicReplacementDoesNotSilentlyChangeRecordedIdentity() throws {
        let f = try Fixture()
        try f.sync("report.txt")
        let before = f.worker.state.transfers["report.txt"]?.identity
        try Data("edited".utf8).write(to: f.target("report.txt"), options: .atomic)
        try f.worker.scan()
        #expect(f.worker.state.transfers["report.txt"]?.identity == before)
        #expect(f.worker.state.transfers["report.txt"]?.phase == .conflict)
        #expect(try String(contentsOf: f.target("report.txt")) == "edited")
    }

    @Test func testBatchDeletionBuildsOneIndexAndSavesOnce() throws {
        let f = try Fixture()
        for index in 0..<30 { try f.incoming("file-\(index).txt") }
        try f.worker.scan()
        try f.worker.scan()
        for index in 0..<30 { try FileManager.default.removeItem(at: f.target("file-\(index).txt")) }
        for index in 0..<100 { try Data("other".utf8).write(to: f.target("other-\(index).txt")) }
        f.store.saves = 0
        try f.worker.scan()
        #expect(f.worker.report.managedRootEnumerations == 1)
        #expect(f.store.saves == 1)
        #expect(f.worker.state.transfers.isEmpty)
        #expect(f.worker.report.issues.isEmpty)
    }

    @Test func testRootIdentityReplacementPausesBeforeMovingNewFiles() throws {
        let f = try Fixture()
        let incoming = try f.incoming("new.txt")
        try FileManager.default.moveItem(at: f.managedRoot, to: f.root.appendingPathComponent("previous-root"))
        try FileManager.default.createDirectory(at: f.managedRoot, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try f.worker.scan() }
        #expect(fileInfo(incoming.path)?.regular == true)
        #expect(fileInfo(f.target("new.txt").path) == nil)
    }

    @Test func testChangedFileRestartsStabilityWindow() throws {
        var now = Date(timeIntervalSince1970: 100)
        let f = try Fixture(settleSeconds: 10, clock: { now })
        let incoming = try f.incoming("slow.txt", "partial")
        try f.worker.scan()
        now.addTimeInterval(5)
        try Data("complete content".utf8).write(to: incoming)
        try f.worker.scan()
        now.addTimeInterval(7)
        try f.worker.scan()
        #expect(fileInfo(f.target("slow.txt").path) == nil)
        now.addTimeInterval(4)
        try f.worker.scan()
        #expect(try String(contentsOf: incoming) == "complete content")
        #expect(linkTarget(incoming.path) != nil)
    }

    @Test func testFileChangingAfterPlanIsNotMovedUsingStaleObservation() throws {
        var changed = false
        var incoming: URL?
        let f = try Fixture(checkpoint: { stage in
            if stage == .planSaved && !changed {
                changed = true
                try Data("continued download".utf8).write(to: #require(incoming))
            }
        })
        incoming = try f.incoming("slow.txt", "partial")
        try f.worker.scan()
        try f.worker.scan()
        #expect(fileInfo(f.target("slow.txt").path) == nil)
        #expect(fileInfo(try #require(incoming).path)?.regular == true)
        try f.worker.scan()
        try f.worker.scan()
        #expect(try String(contentsOf: f.target("slow.txt")) == "continued download")
    }

    @Test func testRestartRecoversEachTransferCheckpoint() throws {
        for interrupted in [TransferCheckpoint.planSaved, .fileMoved, .linkInstalled] {
            var injected = false
            let f = try Fixture(checkpoint: { stage in
                if stage == interrupted && !injected {
                    injected = true
                    throw SyncError.message("injected interruption")
                }
            })
            let incoming = try f.sync("recovery.txt", "recover")
            #expect(injected)
            try f.restart()
            try f.worker.scan()
            #expect(linkTarget(incoming.path) == f.target("recovery.txt").path)
            #expect(try String(contentsOf: incoming) == "recover")
            #expect(f.worker.state.transfers["recovery.txt"]?.phase == .linked)
        }
    }

    @Test func testRestartRecoversLinkUpdateBeforeStateCommit() throws {
        var injected = false
        let f = try Fixture(checkpoint: { stage in
            if stage == .linkUpdated && !injected {
                injected = true
                throw SyncError.message("injected interruption")
            }
        })
        let incoming = try f.sync("report.txt")
        let subfolder = f.target("项目资料")
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
        let moved = subfolder.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: f.target("report.txt"), to: moved)
        try f.worker.scan()
        #expect(injected)
        try f.restart()
        try f.worker.scan()
        #expect(linkTarget(incoming.path) == moved.path)
        #expect(f.worker.state.transfers["report.txt"]?.destination == "项目资料/renamed.txt")
    }

    @Test func testSaveFailureStopsBeforeMoveAndCanRetry() throws {
        let f = try Fixture()
        let incoming = try f.incoming("report.txt")
        try f.worker.scan()
        f.store.failNextSave = true
        #expect(throws: (any Error).self) { try f.worker.scan() }
        #expect(fileInfo(incoming.path)?.regular == true)
        #expect(fileInfo(f.target("report.txt").path) == nil)
        try f.worker.scan()
        #expect(linkTarget(incoming.path) == f.target("report.txt").path)
        #expect(try String(contentsOf: incoming) == "original")
    }

    @Test func testRootIndexReadFailureDoesNotDeleteLinkOrBlockNewFiles() throws {
        let f = try Fixture()
        let old = try f.sync("old.txt")
        try FileManager.default.removeItem(at: f.target("old.txt"))
        let managedRootPath = f.managedRoot.path
        f.worker = try SyncWorker(store: f.store, settleSeconds: 0, enumerate: { directory in
            if directory.path == managedRootPath { throw SyncError.message("injected enumeration error") }
            return try allFiles(directory)
        })
        let new = try f.sync("new.txt")
        #expect(linkTarget(old.path) != nil)
        #expect(linkTarget(new.path) != nil)
        #expect(f.worker.report.issues.contains { $0.relative == "old.txt" })
    }
}
