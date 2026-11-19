import Foundation
import Darwin
import Testing
@testable import SyncCore

@Suite("Account directory discovery")
final class WeChatDirectoriesTests {
    private func parent(_ f: MultiAccountFixture) throws -> URL {
        let root = f.temporary.appendingPathComponent("xwechat_files")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func make(_ parent: URL, _ name: String) throws -> URL {
        let source = parent.appendingPathComponent(name + "/msg/file")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        return source
    }

    @Test func listsOnlyInitializedAccountsAndPreservesFullNames() throws {
        let f = try MultiAccountFixture(), root = try parent(f)
        for name in ["sample_user_2070", "wxid_sample_001", "all_users", "ALL_USERS", "Backup", "backup", ".hidden"] { _ = try make(root, name) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("not_initialized"), withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: root.appendingPathComponent("ordinary.txt"))
        let accounts = try WeChatDirectories.discover(in: root)
        #expect(accounts.map(\.name) == ["sample_user_2070", "wxid_sample_001"])
        #expect(WeChatDirectories.displayName(source: accounts[0].source) == "sample_user_2070")
        #expect(throws: (any Error).self) { try WeChatDirectories.discover(in: f.root) }
    }

    @Test func rejectsRedirectedAccountMsgAndFileDirectories() throws {
        let f = try MultiAccountFixture(), root = try parent(f)
        let external = try make(f.temporary, "external")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("account_link"), withDestinationURL: external.deletingLastPathComponent().deletingLastPathComponent())
        let msgAccount = root.appendingPathComponent("msg_link")
        try FileManager.default.createDirectory(at: msgAccount, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: msgAccount.appendingPathComponent("msg"), withDestinationURL: external.deletingLastPathComponent())
        let fileAccount = root.appendingPathComponent("file_link/msg")
        try FileManager.default.createDirectory(at: fileAccount, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fileAccount.appendingPathComponent("file"), withDestinationURL: external)
        #expect(try WeChatDirectories.discover(in: root).isEmpty)
    }

    @Test func discoveryDoesNotReadReceiptsOrRegisterAccounts() throws {
        let f = try MultiAccountFixture(), root = try parent(f)
        let source = try make(root, "sample_001")
        let receipt = source.appendingPathComponent("untouched.txt")
        try Data("history".utf8).write(to: receipt)
        let before = try readFileInfo(receipt.path)
        _ = try WeChatDirectories.discover(in: root)
        #expect(try readFileInfo(receipt.path) == before)
        #expect(try f.repository.accounts().isEmpty)
        #expect(try f.repository.pendingSetups().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.root.path).isEmpty)
    }

    @Test func parentAndLegacyExactGrantBindSameSourceIdentity() throws {
        let f = try MultiAccountFixture(), root = try parent(f)
        let source = try make(root, "sample_001")
        let identity = try #require(readFileInfo(source.path)?.identity)
        #expect(try WeChatDirectories.authorizedSource(grant: root, expected: source, identity: identity).path == source.path)
        #expect(try WeChatDirectories.authorizedSource(grant: source, expected: source, identity: identity).path == source.path)
        let other = try make(root, "sample_002")
        #expect(throws: (any Error).self) { try WeChatDirectories.authorizedSource(grant: other, expected: source, identity: identity) }
        #expect(throws: (any Error).self) { try WeChatDirectories.authorizedSource(grant: f.temporary, expected: source, identity: identity) }
        #expect(throws: (any Error).self) { try WeChatDirectories.authorizedSource(grant: root, expected: other, identity: identity) }
    }

    @Test func replacedAndRedirectedSourceCannotReuseParentGrant() throws {
        let f = try MultiAccountFixture(), root = try parent(f)
        let source = try make(root, "sample_001")
        let identity = try #require(readFileInfo(source.path)?.identity)
        let moved = root.appendingPathComponent("kept-original")
        try FileManager.default.moveItem(at: source, to: moved)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try WeChatDirectories.authorizedSource(grant: root, expected: source, identity: identity) }
        try FileManager.default.removeItem(at: source)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: moved)
        #expect(throws: (any Error).self) { try WeChatDirectories.authorizedSource(grant: root, expected: source, identity: identity) }
    }

    @Test func selectingOneAccountDoesNotManageOthersAndRemovalStaysExplicit() throws {
        let f = try MultiAccountFixture(), root = try parent(f)
        let a = try make(root, "sample_001"), b = try make(root, "sample_002")
        _ = try WeChatDirectories.discover(in: root)
        let grant = Data("fake-parent-grant".utf8)
        let selected = try f.manager.add(source: a, name: "sample_001", bookmark: grant)
        let store = try ContentRepository(url: f.repository.url)
        let incoming = b.appendingPathComponent("unselected.txt")
        try Data("do not touch".utf8).write(to: incoming)
        var accessed: [String] = []
        let coordinator = ContentCoordinator(store: store, settleSeconds: 0, authorize: { account in
            accessed.append(account.id)
            return DirectoryLease(url: try WeChatDirectories.authorizedSource(grant: root, expected: account.sourceURL, identity: account.sourceIdentity))
        })
        _ = try coordinator.scan(); _ = try coordinator.scan()
        #expect(Set(accessed) == [selected.id])
        #expect(try readFileInfo(incoming.path)?.regular == true)
        #expect(try store.accounts.accounts().count == 1)
        try store.accounts.remove(selected.id)
        accessed.removeAll()
        _ = try coordinator.scan()
        #expect(accessed.isEmpty)
        #expect(try store.accounts.account(selected.id).sourceBookmark == nil)
        _ = try WeChatDirectories.discover(in: root)
        #expect(try store.accounts.account(selected.id).removed)
        try f.manager.reauthorize(selected.id, source: a, bookmark: grant, restoring: true)
        #expect(try store.accounts.account(selected.id).id == selected.id)
        #expect(try store.accounts.account(selected.id).removed == false)
    }
    @Test func sharedParentGrantStillIsolatesAccountsPauseAndRemoval() throws {
        let f = try MultiAccountFixture(), root = try parent(f)
        let sourceA = try make(root, "sample_001"), sourceB = try make(root, "sample_002")
        let grant = Data("shared fake parent bookmark".utf8)
        let a = try f.manager.add(source: sourceA, name: "sample_001", bookmark: grant)
        let b = try f.manager.add(source: sourceB, name: "sample_002", bookmark: grant)
        let store = try ContentRepository(url: f.repository.url)
        var accessed: [String] = []
        let coordinator = ContentCoordinator(store: store, settleSeconds: 0, authorize: { account in
            accessed.append(account.id)
            return DirectoryLease(url: try WeChatDirectories.authorizedSource(grant: root, expected: account.sourceURL, identity: account.sourceIdentity))
        })
        let incomingA = sourceA.appendingPathComponent("same.txt"), incomingB = sourceB.appendingPathComponent("same.txt")
        try Data("same content".utf8).write(to: incomingA); try Data("same content".utf8).write(to: incomingB)
        _ = try coordinator.scan(); _ = try coordinator.scan()
        let entityA = try #require(store.entities(a.id).first), entityB = try #require(store.entities(b.id).first)
        #expect(entityA.identity != entityB.identity)
        #expect(try readFileInfo(incomingA.path)?.symbolicLink == true)
        #expect(try readFileInfo(incomingB.path)?.symbolicLink == true)
        try f.manager.setPaused(a.id, paused: true)
        let moved = f.root.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: f.root.appendingPathComponent(entityA.relative), to: moved)
        let pausedReceipt = sourceA.appendingPathComponent("paused.txt")
        try Data("wait".utf8).write(to: pausedReceipt)
        _ = try coordinator.scan(); _ = try coordinator.scan()
        #expect(linkTarget(incomingA.path) == moved.path)
        #expect(try readFileInfo(pausedReceipt.path)?.regular == true)
        try store.accounts.remove(a.id)
        accessed.removeAll(); _ = try coordinator.scan()
        #expect(Set(accessed) == [b.id])
        #expect(try store.accounts.account(b.id).sourceBookmark == grant)
        #expect(try store.accounts.account(a.id).sourceBookmark == nil)
        let baseline = try store.accounts.loadState(a.id).baseline
        try f.manager.reauthorize(a.id, source: sourceA, bookmark: grant, restoring: true)
        #expect(try store.accounts.loadState(a.id).baseline == baseline)
        #expect(try store.accounts.account(a.id).intakeEnabled == false)
    }

    @Test(.enabled(if: getuid() != 0))
    func inaccessibleChildDoesNotHideOtherAccounts() throws {
        let f = try MultiAccountFixture(), root = try parent(f)
        let blocked = try make(root, "blocked_001")
        _ = try make(root, "available_002")
        let accountDirectory = blocked.deletingLastPathComponent().deletingLastPathComponent()
        try systemCall(chmod(accountDirectory.path, 0), "限制临时样本权限")
        defer { _ = chmod(accountDirectory.path, 0o700) }
        #expect(throws: (any Error).self) { try WeChatDirectories.candidate(root: root, name: "blocked_001") }
        #expect(try WeChatDirectories.discover(in: root).map(\.name) == ["available_002"])
        #expect(try f.repository.accounts().isEmpty)
    }

    @Test(.enabled(if: getuid() != 0))
    func inaccessibleParentReportsFailureRatherThanAnEmptyList() throws {
        let f = try MultiAccountFixture(), root = try parent(f)
        _ = try make(root, "sample_001")
        try systemCall(chmod(root.path, 0), "限制临时样本父目录权限")
        defer { _ = chmod(root.path, 0o700) }
        #expect(throws: (any Error).self) { try WeChatDirectories.discover(in: root) }
    }

    @Test func sourceLeaseRetainsAndReleasesParentGrant() throws {
        let f = try MultiAccountFixture(), root = try parent(f)
        let source = try make(root, "sample_001")
        let identity = try #require(readFileInfo(source.path)?.identity)
        var released = false
        var parentLease: DirectoryLease? = DirectoryLease(url: root) { released = true }
        var sourceLease: DirectoryLease? = try WeChatDirectories.sourceLease(grant: #require(parentLease), expected: source, identity: identity)
        parentLease = nil
        #expect(!released)
        #expect(sourceLease?.url.path == source.path)
        sourceLease = nil
        #expect(released)
    }

    @Test func rejectedSourceLeaseDoesNotRetainParentGrant() throws {
        let f = try MultiAccountFixture(), root = try parent(f)
        let source = try make(root, "sample_001"), other = try make(root, "sample_002")
        let otherIdentity = try #require(readFileInfo(other.path)?.identity)
        var released = false
        var parentLease: DirectoryLease? = DirectoryLease(url: root) { released = true }
        #expect(throws: (any Error).self) {
            try WeChatDirectories.sourceLease(grant: #require(parentLease), expected: source, identity: otherIdentity)
        }
        parentLease = nil
        #expect(released)
    }

}
