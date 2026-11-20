import Foundation
import Testing
@testable import SyncCore

struct ForwardedLinkTests {
    @Test func forwardedLinkFollowsAnotherRenameAfterRestart() throws {
        let f = try ContentFixture()
        let original = try f.sync("2026-11/device.txt", "forwarded sample")
        let firstTarget = URL(fileURLWithPath: try #require(linkTarget(original.path)))
        let renamed = f.files.target(f.a, "改名后.txt")
        try FileManager.default.moveItem(at: firstTarget, to: renamed)
        try f.worker.scan()
        #expect(linkTarget(original.path) == renamed.path)

        let forwarded = original.deletingLastPathComponent().appendingPathComponent("device(1).txt")
        try FileManager.default.createSymbolicLink(at: forwarded, withDestinationURL: renamed)
        try f.worker.scan()
        let sources = try f.store.sources(f.a.id)
        #expect(sources.count == 2)
        #expect(Set(sources.map(\.entityID)).count == 1)
        #expect(try f.store.entities(f.a.id).count == 1)

        let final = f.files.target(f.a, "再次改名.txt")
        try FileManager.default.moveItem(at: renamed, to: final)
        f.restart()
        try f.worker.scan()
        #expect(linkTarget(original.path) == final.path)
        #expect(linkTarget(forwarded.path) == final.path)
        #expect(try String(contentsOf: forwarded, encoding: .utf8) == "forwarded sample")
    }

    @Test func linksOutsideTheKnownAccountAndHistoricalPathsStayUntouched() throws {
        let f = try ContentFixture()
        let original = try f.sync("original.txt")
        let target = URL(fileURLWithPath: try #require(linkTarget(original.path)))
        let detached = try f.sync("detached.txt")
        try FileManager.default.removeItem(at: detached)
        try f.worker.scan()
        try FileManager.default.createSymbolicLink(at: detached, withDestinationURL: target)

        let unregistered = f.files.root.appendingPathComponent("unregistered.txt")
        try Data("unmanaged".utf8).write(to: unregistered)
        let missing = f.files.target(f.a, "missing.txt")
        let linkChain = f.files.sources[0].appendingPathComponent("chain.txt")
        let unmanagedLink = f.files.sources[0].appendingPathComponent("unmanaged-link.txt")
        let danglingLink = f.files.sources[0].appendingPathComponent("dangling.txt")
        let otherAccountLink = f.files.sources[1].appendingPathComponent("cross-account.txt")
        for (link, destination) in [(linkChain, original), (unmanagedLink, unregistered),
                                    (danglingLink, missing), (otherAccountLink, target)] {
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        }
        try f.worker.scan()
        try ContentWorker(store: f.store, accountID: f.b.id, settleSeconds: 0).scan()
        #expect(try f.store.sources(f.a.id).filter(\.active).map(\.relative) == ["original.txt"])
        #expect(try f.store.sources(f.b.id).isEmpty)
        #expect(linkTarget(detached.path) == target.path)
        #expect(linkTarget(linkChain.path) == original.path)
        #expect(linkTarget(unmanagedLink.path) == unregistered.path)
        #expect(linkTarget(danglingLink.path) == missing.path)
        #expect(linkTarget(otherAccountLink.path) == target.path)
    }

    @Test func pausedAccountAndLinksWithoutAnActiveSourceRemainUnregistered() throws {
        let f = try ContentFixture()
        let original = try f.sync("original.txt")
        let target = URL(fileURLWithPath: try #require(linkTarget(original.path)))
        let forwarded = f.files.sources[0].appendingPathComponent("forwarded.txt")
        try FileManager.default.createSymbolicLink(at: forwarded, withDestinationURL: target)
        try f.files.manager.setPaused(f.a.id, paused: true)
        try f.worker.scan()
        #expect(try f.store.sources(f.a.id).filter(\.active).map(\.relative) == ["original.txt"])

        try FileManager.default.removeItem(at: original)
        try f.files.manager.setPaused(f.a.id, paused: false)
        try f.worker.scan()
        #expect(try f.store.sources(f.a.id).allSatisfy { !$0.active })
        #expect(linkTarget(forwarded.path) == target.path)
    }
}
