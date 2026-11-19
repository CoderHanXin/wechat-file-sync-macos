import Foundation
import CryptoKit
import Darwin

private struct ContentSnapshot: Equatable {
    let info: FileInfo
    let changedSeconds: Int64
    let changedNanoseconds: Int64
    let flags: UInt32
    let links: UInt16
}

/// Descriptor-based reads reject symlinks and detect modifications across each read pass.
final class OpenedContent {
    let url: URL
    let fd: Int32
    private let initial: ContentSnapshot
    private let scope: URL?
    private let scopeIdentity: Identity?
    var info: FileInfo { initial.info }
    var token: String { "\(initial.info.identity.key):\(initial.info.size):\(initial.info.modifiedSeconds):\(initial.info.modifiedNanoseconds):\(initial.changedSeconds):\(initial.changedNanoseconds):\(initial.info.mode):\(initial.flags)" }

    init(_ url: URL, identity: Identity? = nil, scope: URL? = nil) throws {
        self.url = url
        self.scope = scope
        if let scope {
            scopeIdentity = try readFileInfo(scope.path)?.identity
            _ = try checkedFile(scope, relative: relativePath(url, in: scope))
        } else { scopeIdentity = nil }
        fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw SyncError.system("打开内容文件", errno) }
        do {
            initial = try Self.snapshot(fd)
            guard initial.info.regular, identity == nil || initial.info.identity == identity else { throw SyncError.message("内容文件身份变化或不是普通文件") }
        } catch { close(fd); throw error }
    }

    deinit { close(fd) }

    private static func snapshot(_ fd: Int32) throws -> ContentSnapshot {
        var value = stat()
        try systemCall(fstat(fd, &value), "读取内容快照")
        let info = FileInfo(identity: Identity(device: UInt64(value.st_dev), inode: UInt64(value.st_ino),
            birthSeconds: Int64(value.st_birthtimespec.tv_sec), birthNanoseconds: Int64(value.st_birthtimespec.tv_nsec)),
            mode: value.st_mode, size: value.st_size, modifiedSeconds: Int64(value.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec))
        return ContentSnapshot(info: info, changedSeconds: Int64(value.st_ctimespec.tv_sec),
                               changedNanoseconds: Int64(value.st_ctimespec.tv_nsec), flags: value.st_flags, links: UInt16(value.st_nlink))
    }

    func validate() throws {
        try validateScope()
        guard try Self.snapshot(fd) == initial, try readFileInfo(url.path) == initial.info else {
            throw SyncError.message("内容读取期间文件发生变化，请重新观察")
        }
    }

    func validateScope() throws {
        if let scope {
            guard let scopeIdentity, try readFileInfo(scope.path)?.identity == scopeIdentity else {
                throw SyncError.message("内容授权根目录已变化")
            }
            _ = try checkedFile(scope, relative: relativePath(url, in: scope))
        }
    }

    func readChunk() throws -> Data {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let count = Darwin.read(fd, &buffer, buffer.count)
        if count < 0 {
            if errno == EINTR { return try readChunk() }
            throw SyncError.system("读取内容", errno)
        }
        return Data(buffer.prefix(Int(count)))
    }

    func digest(checkpoint: (() throws -> Void)? = nil) throws -> String {
        guard lseek(fd, 0, SEEK_SET) >= 0 else { throw SyncError.system("定位文件内容", errno) }
        var hash = SHA256()
        while true {
            let data = try readChunk()
            if data.isEmpty { break }
            hash.update(data: data)
            try checkpoint?()
        }
        try validate()
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func sameBytes(as other: OpenedContent) throws -> Bool {
        guard lseek(fd, 0, SEEK_SET) >= 0, lseek(other.fd, 0, SEEK_SET) >= 0 else { throw SyncError.system("定位待比较内容", errno) }
        var equal = true
        while true {
            let a = try readChunk(), b = try other.readChunk()
            if a != b { equal = false; break }
            if a.isEmpty { break }
        }
        try validate(); try other.validate()
        return equal
    }

    func validatePermissionSupport() throws {
        guard initial.links == 1 else { throw SyncError.message("文件存在其他硬链接，未自动变更共享权限或合并") }
        guard initial.flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND) == 0 else { throw SyncError.message("文件标记不支持自动权限变更") }
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT { return } // No extended ACL on this file.
            throw SyncError.system("读取文件 ACL", errno)
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        let found = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
        guard found == -1 && errno == EINVAL else {
            if found == 0 { throw SyncError.message("文件含扩展 ACL，保留权限等待处理") }
            throw SyncError.system("检查文件 ACL", errno)
        }
    }

    func attributes() throws -> [String: Data] {
        let count = flistxattr(fd, nil, 0, 0)
        guard count >= 0, count <= 64 * 1024 else { throw SyncError.message("扩展属性无法安全校验") }
        if count == 0 { return [:] }
        var names = [CChar](repeating: 0, count: count)
        guard flistxattr(fd, &names, count, 0) == count else { throw SyncError.message("扩展属性在校验期间变化") }
        var result: [String: Data] = [:]
        for bytes in names.split(separator: 0) {
            let name = String(decoding: bytes.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let size = fgetxattr(fd, name, nil, 0, 0, 0)
            guard size >= 0, size + result.values.reduce(0, { $0 + $1.count }) <= 64 * 1024 else { throw SyncError.message("资源叉或扩展属性过大，保留源文件") }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { fgetxattr(fd, name, $0.baseAddress, size, 0, 0) }
            guard read == size else { throw SyncError.message("扩展属性无法稳定读取") }
            result[name] = data
        }
        try validate()
        return result
    }

    static func quarantineOnLink(_ url: URL) throws -> Data? {
        let key = "com.apple.quarantine"
        let size = getxattr(url.path, key, nil, 0, 0, XATTR_NOFOLLOW)
        if size < 0 && errno == ENOATTR { return nil }
        guard size >= 0, size <= 64 * 1024 else { throw SyncError.message("准备链接的隔离属性无法安全读取") }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, key, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        guard read == size else { throw SyncError.message("准备链接的隔离属性在读取时变化") }
        return data
    }

    func compatibleMetadata(with other: OpenedContent, swappedQuarantine: Data? = nil) throws -> Bool {
        try validatePermissionSupport(); try other.validatePermissionSupport()
        guard info.mode & 0o111 == other.info.mode & 0o111 else { return false }
        var incoming = try attributes()
        var archived = try other.attributes()
        // The sandbox may add quarantine to the archived entity during its first move.
        // Keep the archived attribute unchanged. Only accept the exact marker that our own
        // prepared link propagated during RENAME_SWAP, recorded before that swap.
        let key = "com.apple.quarantine"
        if let swappedQuarantine, incoming[key] == swappedQuarantine, archived[key] != nil {
            incoming.removeValue(forKey: key)
        }
        if incoming[key] == nil { archived.removeValue(forKey: key) }
        return incoming == archived
    }
}

/// Only the observation hash spans rounds; destructive-operation verification is one validated pass.
final class ContentHashJob {
    let file: OpenedContent
    private let lease: DirectoryLease?
    private var hash = SHA256()
    private var done: String?
    init(url: URL, identity: Identity, lease: DirectoryLease?, scope: URL? = nil) throws {
        file = try OpenedContent(url, identity: identity, scope: scope)
        self.lease = lease
    }
    func advance(budget: inout Int) throws -> String? {
        try file.validate()
        if let done { return done }
        while budget > 0 {
            let chunk = try file.readChunk()
            budget -= max(1, chunk.count)
            if chunk.isEmpty {
                try file.validate()
                done = hash.finalize().map { String(format: "%02x", $0) }.joined()
                return done
            }
            hash.update(data: chunk)
            try file.validate()
        }
        return nil
    }
}
