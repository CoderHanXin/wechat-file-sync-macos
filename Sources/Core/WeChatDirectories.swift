import Foundation
import Darwin

struct DiscoveredAccount: Equatable {
    let name: String
    let source: URL
    let identity: Identity
}

/// Structural discovery only: never enumerates msg/file or builds a receipt baseline.
enum WeChatDirectories {
    static func displayName(source: URL) -> String {
        source.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
    }

    private static func directory(_ url: URL) throws -> Bool {
        // lstat deliberately refuses a redirected account, msg or file directory.
        try readFileInfo(url.path)?.directory == true
    }

    static func candidate(root: URL, name: String) throws -> DiscoveredAccount? {
        guard validRelativePath(name), !name.contains("/"), !name.hasPrefix("."),
              !["all_users", "backup"].contains(name.lowercased()) else { return nil }
        let account = root.appendingPathComponent(name, isDirectory: true)
        let msg = account.appendingPathComponent("msg", isDirectory: true)
        let source = msg.appendingPathComponent("file", isDirectory: true)
        guard try directory(account), try directory(msg), try directory(source),
              try canonicalDirectory(source).path == source.path,
              let info = try readFileInfo(source.path) else { return nil }
        return DiscoveredAccount(name: name, source: source, identity: info.identity)
    }

    static func discover(in selected: URL) throws -> [DiscoveredAccount] {
        guard try directory(selected), selected.lastPathComponent == "xwechat_files" else {
            throw SyncError.message("请选择 xwechat_files 文件夹")
        }
        let root = try canonicalDirectory(selected)
        let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        return try children.compactMap { child -> DiscoveredAccount? in
            do { return try candidate(root: root, name: child.lastPathComponent) }
            catch SyncError.system(_, let code) where code == EACCES || code == EPERM {
                // One inaccessible child must not hide the other available accounts.
                return nil
            }
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func sourceLease(grant: DirectoryLease, expected: URL, identity: Identity) throws -> DirectoryLease {
        let source = try authorizedSource(grant: grant.url, expected: expected, identity: identity)
        return DirectoryLease(url: source) { withExtendedLifetime(grant) {} }
    }

    /// A grant may be the old exact msg/file bookmark, or the explicitly chosen parent.
    /// Both forms remain bound to the registered source identity; a parent never enables an account.
    static func authorizedSource(grant: URL, expected: URL, identity: Identity) throws -> URL {
        let root = try canonicalDirectory(grant)
        let source: URL
        if root.path == expected.path {
            guard try directory(expected) else { throw SyncError.message("找不到原微信文件夹") }
            source = expected
        } else {
            guard root.lastPathComponent == "xwechat_files",
                  let item = try candidate(root: root, name: displayName(source: expected)),
                  item.source.path == expected.path else {
                throw SyncError.message("所选文件夹不包含原微信账号，请重新选择原 xwechat_files")
            }
            source = item.source
        }
        guard try readFileInfo(source.path)?.identity == identity else {
            throw SyncError.message("微信账号文件夹已被替换，不能继承原记录")
        }
        return source
    }
}
