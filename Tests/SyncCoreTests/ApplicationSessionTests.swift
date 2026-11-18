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
        #expect(try session.snapshot().message.contains("fake permission expired"))
        #expect(try session.snapshot().accounts.contains { $0.id == b.id })
    }
}
