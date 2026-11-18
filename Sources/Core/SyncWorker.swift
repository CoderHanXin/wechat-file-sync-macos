import Foundation
import Darwin

enum TransferCheckpoint { case planSaved, fileMoved, linkInstalled, linkUpdated }

struct ScanIssue: Equatable {
    let relative: String
    let message: String
}

struct ScanReport {
    var issues: [ScanIssue] = []
    var managedRootEnumerations = 0
}

final class SyncWorker {
    let source: URL
    let managedRoot: URL
    let store: StateStore
    var state: SyncState
    private var lastPersisted: SyncState
    private var observations: [String: Observation] = [:]
    private let settleSeconds: TimeInterval
    private let clock: () -> Date
    private let enumerate: (URL) throws -> [String: FileInfo]
    let checkpoint: ((TransferCheckpoint) throws -> Void)?
    private(set) var report = ScanReport()

    init(store: StateStore, settleSeconds: TimeInterval = 15, clock: @escaping () -> Date = Date.init,
         enumerate: @escaping (URL) throws -> [String: FileInfo] = allFiles,
         checkpoint: ((TransferCheckpoint) throws -> Void)? = nil) throws {
        self.store = store
        state = try store.load()
        lastPersisted = state
        source = URL(fileURLWithPath: state.source, isDirectory: true)
        managedRoot = URL(fileURLWithPath: state.managedRoot, isDirectory: true)
        self.settleSeconds = settleSeconds
        self.clock = clock
        self.enumerate = enumerate
        self.checkpoint = checkpoint
    }

    func save() throws {
        guard state != lastPersisted else { return }
        do {
            try store.save(state)
            lastPersisted = state
        } catch {
            throw SyncError.persistence(String(describing: error))
        }
    }

    private func issue(_ relative: String, _ message: String) {
        report.issues.append(ScanIssue(relative: relative, message: message))
        NSLog("同步文件需要检查：%@（%@）", relative, message)
    }

    private func conflict(_ relative: String, _ message: String) {
        state.transfers[relative]?.phase = .conflict
        issue(relative, message)
    }

    private func stable(_ relative: String, info: FileInfo) -> Bool {
        let now = clock()
        guard let observation = observations[relative], observation.info == info else {
            observations[relative] = Observation(info: info, firstSeen: now)
            return false
        }
        return now.timeIntervalSince(observation.firstSeen) >= settleSeconds
    }

    private func process(_ relative: String, operation: () throws -> Void) throws {
        do { try operation() }
        catch let error as SyncError {
            if case .persistence = error { throw error }
            issue(relative, error.description)
        } catch {
            issue(relative, String(describing: error))
        }
    }

    func scan() throws {
        report = ScanReport()
        // A previous persistence failure must be repaired before touching any more files.
        try save()
        guard try readFileInfo(source.path)?.identity == state.sourceIdentity,
              try readFileInfo(managedRoot.path)?.identity == state.managedRootIdentity else {
            throw SyncError.message("微信目录或管理根目录不可用，同步已暂停")
        }

        var rootIndex: Result<[Identity: [String]], Error>?
        func movedPath(_ identity: Identity) throws -> String? {
            if rootIndex == nil {
                report.managedRootEnumerations += 1
                rootIndex = Result {
                    var index: [Identity: [String]] = [:]
                    for (relative, info) in try enumerate(managedRoot) {
                        index[info.identity, default: []].append(relative)
                    }
                    return index
                }
            }
            let index = try rootIndex?.get() ?? [:]
            for relative in (index[identity] ?? []).sorted() {
                let file = try checkedFile(managedRoot, relative: relative)
                if try readFileInfo(file.path)?.identity == identity { return relative }
            }
            return nil
        }

        for relative in state.transfers.keys.sorted() {
            try process(relative) {
                guard let record = state.transfers[relative] else { return }
                if record.phase == .planned {
                    try finish(relative, movedPath: movedPath)
                } else if record.phase == .linked {
                    try reconcile(relative, record: record, movedPath: movedPath)
                }
            }
        }

        let current = try enumerate(source)
        let originalIdentities = Set(state.baseline.values)
        for (relative, info) in current {
            if state.baseline[relative] != nil || originalIdentities.contains(info.identity) {
                state.baseline[relative] = info.identity
            }
        }
        for relative in Array(state.baseline.keys) where current[relative] == nil {
            if try readFileInfo(source.appendingPathComponent(relative).path) == nil {
                state.baseline.removeValue(forKey: relative)
            }
        }
        try save()

        for relative in current.keys.sorted() {
            guard let info = current[relative] else { continue }
            if state.baseline[relative] != nil || state.transfers[relative] != nil {
                // Old planned records without observations must still be allowed to settle.
                if state.transfers[relative]?.phase != .planned { observations.removeValue(forKey: relative) }
                continue
            }
            guard stable(relative, info: info) else { continue }
            try process(relative) {
                let original = try checkedFile(source, relative: relative)
                let target = try unusedDestination(managedRoot, name: original.lastPathComponent)
                state.transfers[relative] = Transfer(destination: target.lastPathComponent,
                    temporary: temporaryPrefix + UUID().uuidString, identity: info.identity,
                    phase: .planned, observedInfo: info)
                try save()
                try checkpoint?(.planSaved)
                try finish(relative, movedPath: movedPath)
            }
            observations.removeValue(forKey: relative)
        }
        for relative in Array(observations.keys) where current[relative] == nil {
            observations.removeValue(forKey: relative)
        }
        try save()
    }

    private func reconcile(_ relative: String, record: Transfer,
                           movedPath: (Identity) throws -> String?) throws {
        let file = try checkedFile(source, relative: relative)
        let destination = try checkedFile(managedRoot, relative: record.destination)
        guard let sourceInfo = try readFileInfo(file.path) else {
            // WeChat-side cleanup never deletes an archived file.
            state.transfers.removeValue(forKey: relative)
            return
        }
        if sourceInfo.regular {
            // The old source lifecycle ended. Observe the new ordinary file afresh.
            state.transfers.removeValue(forKey: relative)
            observations.removeValue(forKey: relative)
            return
        }
        guard sourceInfo.symbolicLink, let actualTarget = linkTarget(file.path) else {
            conflict(relative, "微信源路径已被其他对象占用")
            return
        }
        if actualTarget != destination.path {
            // Recover a crash after the link swap but before the database commit.
            let prefix = managedRoot.path + "/"
            if actualTarget.hasPrefix(prefix) {
                let candidate = String(actualTarget.dropFirst(prefix.count))
                let verified = try checkedFile(managedRoot, relative: candidate)
                if try readFileInfo(verified.path)?.identity == record.identity {
                    state.transfers[relative]?.destination = candidate
                    return
                }
            }
            conflict(relative, "微信文件链接已被修改")
            return
        }

        let actual = try readFileInfo(destination.path)
        if actual?.regular == true && actual?.identity == record.identity { return }
        // Look for the old identity even if its former filename has already been reused.
        if let moved = try movedPath(record.identity) {
            let updated = try checkedFile(managedRoot, relative: moved)
            try updateLink(file, oldTarget: destination, newTarget: updated)
            try checkpoint?(.linkUpdated)
            state.transfers[relative]?.destination = moved
        } else if actual == nil {
            if linkTarget(file.path) == destination.path {
                try systemCall(unlink(file.path), "移除失联文件的微信链接")
            }
            // M4 adds retained content/source history and a manual restore workflow.
            state.transfers.removeValue(forKey: relative)
        } else {
            // Atomic saves and unrelated replacements cannot be distinguished by inode alone.
            conflict(relative, "目标文件已被替换，保留文件等待检查")
        }
    }
    private func finish(_ relative: String, movedPath: (Identity) throws -> String?) throws {
        guard var record = state.transfers[relative] else { return }
        let file = try checkedFile(source, relative: relative)
        guard record.temporary.hasPrefix(temporaryPrefix), !record.temporary.contains("/"), !record.temporary.contains("\0") else {
            conflict(relative, "文件名无效")
            return
        }
        let destination = try checkedFile(managedRoot, relative: record.destination)
        let temporary = file.deletingLastPathComponent().appendingPathComponent(record.temporary)

        if linkTarget(file.path) == destination.path {
            guard let moved = try readFileInfo(destination.path), moved.regular, moved.identity == record.identity else {
                conflict(relative, "中断后的目标文件缺失或已被替换")
                return
            }
            if let tempInfo = try readFileInfo(temporary.path) {
                guard tempInfo.symbolicLink, linkTarget(temporary.path) == destination.path else {
                    conflict(relative, "中断后的临时文件需要检查")
                    return
                }
                try systemCall(unlink(temporary.path), "清理临时链接")
            }
            record.phase = .linked
            state.transfers[relative] = record
            try save()
            return
        }
        if let original = try readFileInfo(file.path) {
            if let expected = record.observedInfo, expected != original {
                if linkTarget(temporary.path) == destination.path {
                    try systemCall(unlink(temporary.path), "清理临时链接")
                }
                state.transfers.removeValue(forKey: relative)
                observations.removeValue(forKey: relative)
                try save()
                return
            }
            if record.observedInfo == nil {
                guard stable(relative, info: original) else { return }
                record.observedInfo = original
                state.transfers[relative] = record
                try save()
            }
            guard original.regular, original.identity == record.identity else {
                conflict(relative, "微信文件在同步期间发生变化")
                return
            }
            if try readFileInfo(destination.path) != nil {
                if linkTarget(temporary.path) == destination.path {
                    try systemCall(unlink(temporary.path), "清理临时链接")
                }
                record.destination = try unusedDestination(managedRoot, name: file.lastPathComponent).lastPathComponent
                record.temporary = temporaryPrefix + UUID().uuidString
                state.transfers[relative] = record
                try save()
                return
            }
            if try readFileInfo(temporary.path) != nil {
                guard linkTarget(temporary.path) == destination.path else {
                    conflict(relative, "临时路径已被占用")
                    return
                }
            } else {
                try systemCall(symlink(destination.path, temporary.path), "建立微信文件链接")
            }
            guard try readFileInfo(file.path) == original else {
                conflict(relative, "微信文件在同步期间发生变化")
                return
            }
            if renamex_np(file.path, destination.path, UInt32(RENAME_EXCL)) != 0 {
                if errno == EEXIST {
                    try systemCall(unlink(temporary.path), "清理临时链接")
                    record.destination = try unusedDestination(managedRoot, name: file.lastPathComponent).lastPathComponent
                    record.temporary = temporaryPrefix + UUID().uuidString
                    state.transfers[relative] = record
                    try save()
                    return
                }
                throw SyncError.system("移动归档文件", errno)
            }
            try checkpoint?(.fileMoved)
            guard try readFileInfo(destination.path)?.identity == record.identity else {
                // The destination may now be an unrelated replacement. Never move it back blindly.
                conflict(relative, "文件在移动时发生变化")
                return
            }
        } else {
            let moved = try readFileInfo(destination.path)
            if moved?.regular != true || moved?.identity != record.identity,
               let relocated = try movedPath(record.identity), relocated != record.destination {
                // The file was moved successfully before interruption, then renamed by the user.
                // Retarget the durable plan first; the next scan completes its new link.
                if let temporaryInfo = try readFileInfo(temporary.path) {
                    guard temporaryInfo.symbolicLink, linkTarget(temporary.path) == destination.path else {
                        conflict(relative, "中断后的临时路径已被占用")
                        return
                    }
                    try systemCall(unlink(temporary.path), "清理改名前的临时链接")
                }
                record.destination = relocated
                state.transfers[relative] = record
                try save()
                return
            }
            guard let moved else {
                if linkTarget(temporary.path) == destination.path {
                    try systemCall(unlink(temporary.path), "清理临时链接")
                }
                state.transfers.removeValue(forKey: relative)
                try save()
                return
            }
            guard moved.regular, moved.identity == record.identity else {
                conflict(relative, "移动后的归档文件已改变")
                return
            }
        }
        if try readFileInfo(temporary.path) != nil {
            guard linkTarget(temporary.path) == destination.path else {
                conflict(relative, "临时路径已被占用")
                return
            }
        } else {
            try systemCall(symlink(destination.path, temporary.path), "建立微信文件链接")
        }
        guard try readFileInfo(file.path) == nil else {
            conflict(relative, "微信文件路径已被占用")
            return
        }
        try systemCall(renamex_np(temporary.path, file.path, UInt32(RENAME_EXCL)), "启用微信文件链接")
        try checkpoint?(.linkInstalled)
        record.phase = .linked
        state.transfers[relative] = record
        try save()
        NSLog("已放入管理目录：%@", destination.lastPathComponent)
    }

}
