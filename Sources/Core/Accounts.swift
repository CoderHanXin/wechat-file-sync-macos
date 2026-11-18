import Foundation
import Darwin

extension Identity {
    var key: String { "\(device):\(inode):\(birthSeconds):\(birthNanoseconds)" }
}

struct ManagedRoot: Codable, Equatable {
    let id: String
    let path: String
    let identity: Identity
    var bookmark: Data?
    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

struct Account: Codable, Equatable {
    let id: String
    let rootID: String
    var name: String
    var source: String
    let sourceIdentity: Identity
    var sourceBookmark: Data?
    var archiveRelative: String
    var archiveIdentity: Identity?
    var intakeEnabled: Bool
    var removedAt: Int64?
    let createdAt: Int64

    var sourceURL: URL { URL(fileURLWithPath: source, isDirectory: true) }
    var removed: Bool { removedAt != nil }
}

struct AccountSetup: Codable, Equatable {
    var account: Account
    let baseline: [String: Identity]
    var temporaryRelative: String
    var directoryIdentity: Identity?
}

enum AccountSetupCheckpoint { case reserved, directoryCreated, directoryRenamed, activated }
enum DatabaseMigrationCheckpoint { case backupCreated, rowsCopied, beforeCommit }

func canonicalDirectory(_ url: URL) throws -> URL {
    guard let path = realpath(url.path, nil) else { throw SyncError.system("解析目录", errno) }
    defer { free(path) }
    return URL(fileURLWithPath: String(cString: path), isDirectory: true)
}

func validRelativePath(_ relative: String) -> Bool {
    !relative.isEmpty && !relative.hasPrefix("/") && !relative.contains("\0")
        && !relative.split(separator: "/", omittingEmptySubsequences: false)
            .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
}

func relativePath(_ file: URL, in root: URL) throws -> String {
    let prefix = root.path + "/"
    guard file.path.hasPrefix(prefix) else { throw SyncError.message("归档位置不在管理根目录内") }
    let relative = String(file.path.dropFirst(prefix.count))
    guard validRelativePath(relative) else { throw SyncError.message("归档相对路径无效") }
    return relative
}
