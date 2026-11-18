import Foundation
import Darwin

let temporaryPrefix = ".wechat-download-sync-"

func readFileInfo(_ path: String) throws -> FileInfo? {
    var value = stat()
    guard lstat(path, &value) == 0 else {
        if errno == ENOENT || errno == ENOTDIR { return nil }
        throw SyncError.system("读取文件信息", errno)
    }
    return FileInfo(
        identity: Identity(device: UInt64(value.st_dev), inode: UInt64(value.st_ino),
                           birthSeconds: Int64(value.st_birthtimespec.tv_sec),
                           birthNanoseconds: Int64(value.st_birthtimespec.tv_nsec)),
        mode: value.st_mode, size: Int64(value.st_size),
        modifiedSeconds: Int64(value.st_mtimespec.tv_sec),
        modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec))
}

func fileInfo(_ path: String) -> FileInfo? { try? readFileInfo(path) }

func linkTarget(_ path: String) -> String? {
    guard fileInfo(path)?.symbolicLink == true else { return nil }
    return try? FileManager.default.destinationOfSymbolicLink(atPath: path)
}

func allFiles(_ source: URL) throws -> [String: FileInfo] {
    var walkError: Error?
    guard let resolved = realpath(source.path, nil) else {
        throw SyncError.system("解析文件目录", errno)
    }
    let canonicalPath = String(cString: resolved)
    free(resolved)
    let canonicalSource = URL(fileURLWithPath: canonicalPath, isDirectory: true)
    guard let enumerator = FileManager.default.enumerator(at: canonicalSource, includingPropertiesForKeys: nil,
        options: [], errorHandler: { _, error in walkError = error; return false }) else {
        throw SyncError.message("无法读取文件目录")
    }
    var files: [String: FileInfo] = [:]
    let prefix = canonicalSource.path + "/"
    for case let nativeURL as NSURL in enumerator {
        let url = nativeURL as URL
        guard url.path.hasPrefix(prefix) else { continue }
        let name = url.lastPathComponent
        if name == ".DS_Store" || name.hasPrefix(temporaryPrefix) {
            if try readFileInfo(url.path)?.directory == true { enumerator.skipDescendants() }
            continue
        }
        guard let info = try readFileInfo(url.path), info.regular else { continue }
        files[String(url.path.dropFirst(prefix.count))] = info
    }
    if let error = walkError { throw error }
    return files
}

func checkedFile(_ source: URL, relative: String) throws -> URL {
    guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\0"),
          !relative.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
        throw SyncError.message("文件相对路径无效")
    }
    let file = source.appendingPathComponent(relative)
    let root = source.resolvingSymlinksInPath().path
    let parent = file.deletingLastPathComponent().resolvingSymlinksInPath().path
    guard parent == root || parent.hasPrefix(root + "/") else {
        throw SyncError.message("文件路径超出授权范围")
    }
    return file
}

func unusedDestination(_ managedRoot: URL, name: String) throws -> URL {
    let original = managedRoot.appendingPathComponent(name)
    if try readFileInfo(original.path) == nil { return original }
    let stem = original.deletingPathExtension().lastPathComponent
    let suffix = original.pathExtension
    var number = 2
    while true {
        let fileName = suffix.isEmpty ? "\(stem) (微信 \(number))" : "\(stem) (微信 \(number)).\(suffix)"
        let candidate = managedRoot.appendingPathComponent(fileName)
        if try readFileInfo(candidate.path) == nil { return candidate }
        number += 1
    }
}

func systemCall(_ result: Int32, _ operation: String) throws {
    if result != 0 { throw SyncError.system(operation, errno) }
}

func updateLink(_ file: URL, oldTarget: URL, newTarget: URL) throws {
    if linkTarget(file.path) == newTarget.path { return }
    guard linkTarget(file.path) == oldTarget.path else {
        throw SyncError.message("微信文件链接已被修改")
    }
    let temporary = file.deletingLastPathComponent()
        .appendingPathComponent(temporaryPrefix + UUID().uuidString)
    try systemCall(symlink(newTarget.path, temporary.path), "创建更新后的微信链接")
    guard linkTarget(file.path) == oldTarget.path else {
        _ = unlink(temporary.path)
        throw SyncError.message("微信文件链接在更新期间发生变化")
    }
    try systemCall(renamex_np(file.path, temporary.path, UInt32(RENAME_SWAP)), "更新微信文件链接")
    guard linkTarget(temporary.path) == oldTarget.path else {
        if linkTarget(file.path) == newTarget.path {
            _ = renamex_np(file.path, temporary.path, UInt32(RENAME_SWAP))
        }
        throw SyncError.message("微信文件链接在切换期间发生变化")
    }
    try systemCall(unlink(temporary.path), "清理旧微信链接")
}
