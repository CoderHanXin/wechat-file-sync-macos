import Foundation
import Darwin

/// One account worker; relationships live in v3, old transfer machinery only finishes durable moves.
final class ContentWorker {
    let store: ContentRepository
    let accountID: String
    let settleSeconds: TimeInterval
    let clock: () -> Date
    let checkpoint: ((ContentCheckpoint) throws -> Void)?
    let transferCheckpoint: ((TransferCheckpoint) throws -> Void)?
    private var nextRecoveryScan = Date.distantPast
    let recoveryInterval: TimeInterval
    private var observations: [String: Observation] = [:]
    private var hashes: [String: ContentHashJob] = [:]
    let hashBudget: Int
    private(set) var report = ScanReport()

    init(store: ContentRepository, accountID: String, settleSeconds: TimeInterval = 15,
         clock: @escaping () -> Date = Date.init, hashBudget: Int = 4 * 1024 * 1024, recoveryInterval: TimeInterval = 30,
         checkpoint: ((ContentCheckpoint) throws -> Void)? = nil,
         transferCheckpoint: ((TransferCheckpoint) throws -> Void)? = nil) {
        self.store = store; self.accountID = accountID; self.settleSeconds = settleSeconds
        self.clock = clock; self.checkpoint = checkpoint; self.transferCheckpoint = transferCheckpoint
        self.hashBudget = max(64 * 1024, hashBudget); self.recoveryInterval = recoveryInterval
    }

    private func process(_ relative: String, _ body: () throws -> Void) throws {
        do { try body(); try store.recordIssue(accountID, relative: relative, message: nil) }
        catch let error as SyncError {
            if case .persistence = error { throw error }
            try issue(relative, error.description)
        } catch let error as SQLiteStoreError { throw SyncError.persistenceFailure(error) }
        catch { try issue(relative, String(describing: error)) }
    }

    private func issue(_ relative: String, _ message: String) throws {
        report.issues.append(ScanIssue(relative: relative, message: message))
        try store.recordIssue(accountID, relative: relative, message: message)
        if var op = try store.operations(accountID).first(where: { $0.id == relative }) {
            op.error = message
            try store.atomic { try store.put(op) }
        }
    }

    func scan(index: ManagedRootIndex? = nil, acceptNewFiles: Bool? = nil, lease: DirectoryLease? = nil) throws {
        report = ScanReport()
        let account = try store.accounts.account(accountID)
        guard !account.removed else { observations = [:]; hashes = [:]; return }
        let root = try AccountManager(repository: store.accounts).validatedRoot()
        guard try readFileInfo(account.source)?.identity == account.sourceIdentity else { throw SyncError.message("微信账号源目录不可用") }
        let index = index ?? ManagedRootIndex(root: root.url)
        let before = index.enumerations
        defer { report.managedRootEnumerations = index.enumerations - before }

        try recover(account: account, root: root.url, index: index)
        let pendingSources = Set(try store.operations(accountID).compactMap(\.sourceID))
        for var source in try store.sources(accountID) where !source.active && source.endReason == .toolCleaned && !pendingSources.contains(source.id) {
            try process(source.relative) {
                let path = try checkedFile(account.sourceURL, relative: source.relative)
                if let actual = try readFileInfo(path.path) {
                    source.endReason = actual.regular ? .reused : .external
                    try store.atomic { try store.put(source) }
                }
            }
        }
        let checkReturned = clock() >= nextRecoveryScan
        if checkReturned { nextRecoveryScan = clock().addingTimeInterval(recoveryInterval) }
        let recoverySources = try store.sources(accountID).filter { !$0.active && $0.endReason == .toolCleaned }
        let activeSources = try store.sources(accountID).filter { $0.active && $0.status != .conflict && $0.status != .pending }
        for entity in try store.entities(accountID) where entity.status != .pending
            && ((entity.status != .missing && entity.status != .conflict) || activeSources.contains(where: { $0.entityID == entity.id })
                || (checkReturned && recoverySources.contains(where: { $0.entityID == entity.id }))) {
            try process(entity.relative) { try reconcile(entity, account: account, root: root.url, index: index) }
        }
        guard acceptNewFiles ?? account.intakeEnabled else { observations = [:]; hashes = [:]; return }
        let archive = try checkedFile(root.url, relative: account.archiveRelative)
        guard let expected = account.archiveIdentity, try readFileInfo(archive.path)?.identity == expected else {
            observations = [:]; hashes = [:]
            report.issues.append(ScanIssue(relative: account.archiveRelative, message: "账号归档目录不可用，新文件同步暂停"))
            return
        }
        let entries = try fileEntries(account.sourceURL, includingLinks: true)
        let current = entries.filter { $0.value.regular }
        let old = try store.accounts.loadState(accountID)
        var baseline = old
        let identities = Set(old.baseline.values)
        for (path, info) in current where old.baseline[path] != nil || identities.contains(info.identity) { baseline.baseline[path] = info.identity }
        for path in Array(baseline.baseline.keys) where current[path] == nil {
            if try readFileInfo(account.sourceURL.appendingPathComponent(path).path) == nil { baseline.baseline.removeValue(forKey: path) }
        }
        if baseline != old {
            let adapter = AccountStateStore(repository: store.accounts, accountID: accountID)
            _ = try adapter.load()
            do { try adapter.save(baseline) } catch { throw SyncError.persistenceFailure(error) }
        }
        try trackForwardedLinks(entries.filter { $0.value.symbolicLink && baseline.baseline[$0.key] == nil },
                                account: account, root: root.url)
        var budget = hashBudget
        for path in current.keys.sorted() {
            guard let info = current[path], baseline.baseline[path] == nil else { continue }
            if try store.sources(accountID).contains(where: { $0.active && $0.relative == path }) { continue }
            guard let observation = observations[path], observation.info == info else {
                hashes.removeValue(forKey: path)
                observations[path] = Observation(info: info, firstSeen: clock())
                report.hasPendingIntake = true
                continue
            }
            guard clock().timeIntervalSince(observation.firstSeen) >= settleSeconds,
                  budget > 0, hashes.isEmpty || hashes[path] != nil else {
                report.hasPendingIntake = true
                continue
            }
            // The hash job is reused across scans until the file has been read completely.
            var keepHash = false
            try process(path) {
                if hashes[path] == nil {
                    hashes[path] = try ContentHashJob(url: checkedFile(account.sourceURL, relative: path), identity: info.identity, lease: lease, scope: account.sourceURL)
                }
                guard let job = hashes[path] else { return }
                guard let digest = try job.advance(budget: &budget) else { keepHash = true; return }
                try intake(path, info: info, account: account, root: root.url, archive: archive, index: index, incoming: job.file, digest: digest)
            }
            if keepHash {
                report.hasPendingIntake = true
            } else {
                hashes.removeValue(forKey: path)
                observations.removeValue(forKey: path)
            }
        }
        observations = observations.filter { current[$0.key] != nil }
        hashes = hashes.filter { current[$0.key] != nil }
        // A retained source is still unresolved while it waits for the next stability pass.
        // Don't alternate between an error and "healthy" simply because observation restarted.
        for issue in try store.issues(accountID) where current[issue.relative]?.regular == true {
            if !report.issues.contains(where: { $0.relative == issue.relative && $0.message == issue.message }) {
                report.issues.append(issue)
            }
        }
    }

    private func trackForwardedLinks(_ links: [String: FileInfo], account: Account, root: URL) throws {
        guard !links.isEmpty else { return }
        let sources = try store.sources(accountID)
        let seenPaths = Set(sources.map(\.relative))
        let newLinks = links.filter { !seenPaths.contains($0.key) }
        guard !newLinks.isEmpty else { return }

        // WeChat can copy an existing link when forwarding instead of writing a new regular file.
        // Only take on new paths when a tracked link in this account proves the same live target.
        let linkedSources = Dictionary(grouping: sources.filter { $0.active && $0.status == .linked }, by: \.entityID)
        let entities = try store.entities(accountID).filter {
            linkedSources[$0.id] != nil && ($0.status == .unchecked || $0.status == .ready || $0.status == .modified)
        }
        let entitiesByTarget = Dictionary(grouping: entities, by: { root.appendingPathComponent($0.relative).path })
        for (relative, observed) in newLinks {
            guard let file = try? checkedFile(account.sourceURL, relative: relative),
                  let destination = linkTarget(file.path),
                  let matches = entitiesByTarget[destination], matches.count == 1,
                  let entity = matches.first,
                  let target = try? checkedFile(root, relative: entity.relative),
                  let info = try readFileInfo(target.path), info.regular, info.identity == entity.identity else { continue }
            let hasTrackedLink = linkedSources[entity.id, default: []].contains { source in
                guard source.linkRelative == entity.relative,
                      let tracked = try? checkedFile(account.sourceURL, relative: source.relative) else { return false }
                return linkTarget(tracked.path) == destination
            }
            guard hasTrackedLink, try readFileInfo(file.path) == observed,
                  linkTarget(file.path) == destination else { continue }
            // No independent received bytes exist at this path, so leave its receipt digest absent.
            let source = ContentSource(id: UUID().uuidString, accountID: accountID, relative: relative,
                entityID: entity.id, originalName: file.lastPathComponent, receivedIdentity: observed.identity,
                receivedDigest: nil, status: .linked, active: true, linkRelative: entity.relative)
            try store.atomic { try store.put(source) }
        }
    }

    private func locate(_ original: ContentEntity, root: URL, index: ManagedRootIndex) throws -> ContentEntity {
        var entity = original
        let target = try checkedFile(root, relative: entity.relative)
        if try readFileInfo(target.path)?.identity != entity.identity,
           let moved = try index.find(entity.identity) {
            entity.relative = moved
            try store.atomic { try store.put(entity) }
        }
        return entity
    }

    private func reconcile(_ original: ContentEntity, account: Account, root: URL, index: ManagedRootIndex) throws {
        if original.status == .conflict {
            guard try store.sources(accountID).contains(where: { $0.entityID == original.id && !$0.active && $0.endReason == .toolCleaned }) else { return }
        }
        var entity = try locate(original, root: root, index: index)
        let target = try checkedFile(root, relative: entity.relative)
        let info = try readFileInfo(target.path)
        let available = info?.regular == true && info?.identity == entity.identity
        if available {
            let current = try OpenedContent(target, identity: entity.identity, scope: root)
            if entity.status == .missing || entity.status == .conflict || entity.info != info || entity.verifiedToken != current.token {
                entity.digest = nil; entity.verifiedToken = nil; entity.info = info; entity.status = .unchecked
            }
        } else {
            entity.status = info == nil ? .missing : .conflict
            entity.digest = nil
        }
        try store.atomic { try store.put(entity) }
        let operating = Set(try store.operations(accountID).compactMap(\.sourceID))
        for originalSource in try store.sources(accountID) where originalSource.entityID == entity.id && originalSource.active && originalSource.status != .pending && originalSource.status != .conflict && !operating.contains(originalSource.id) {
            try process(originalSource.relative) {
                var source = originalSource
                let file = try checkedFile(account.sourceURL, relative: source.relative)
                let oldTarget = try checkedFile(root, relative: source.linkRelative)
                let actual = try readFileInfo(file.path)
                if actual == nil || actual?.regular == true {
                    source.active = false; source.status = .detached; source.endReason = actual?.regular == true ? .reused : .external
                } else if actual?.symbolicLink == true, let link = linkTarget(file.path) {
                    if available {
                        if link == oldTarget.path {
                            if oldTarget.path != target.path {
                                try updateLink(file, oldTarget: oldTarget, newTarget: target)
                                try transferCheckpoint?(.linkUpdated)
                            }
                            source.linkRelative = entity.relative; source.status = .linked
                        } else if link == target.path {
                            source.linkRelative = entity.relative; source.status = .linked
                        } else { source.status = .conflict }
                    } else if entity.status == .missing && link == oldTarget.path {
                        try LinkRecovery(store: store, checkpoint: checkpoint).clear(source)
                        return
                    } else { source.status = .conflict }
                } else { source.status = .conflict }
                try store.atomic { try store.put(source) }
            }
        }
        if available {
            for source in try store.sources(accountID) where source.entityID == entity.id && !source.active && source.endReason == .toolCleaned {
                guard !operating.contains(source.id) else { continue }
                try process(source.relative) { try LinkRecovery(store: store, checkpoint: checkpoint).automatic(source, entity: entity) }
            }
        }
    }

    private func intake(_ relative: String, info: FileInfo, account: Account, root: URL, archive: URL, index: ManagedRootIndex,
                        incoming: OpenedContent, digest: String) throws {
        let file = try checkedFile(account.sourceURL, relative: relative)
        guard incoming.info == info else { throw SyncError.message("候选文件已变化") }
        try incoming.validate()
        var incompatibleCandidate = false
        for var entity in try store.entities(accountID) where entity.status == .ready || entity.status == .unchecked || entity.status == .modified {
            let target = try checkedFile(root, relative: entity.relative)
            guard let current = try readFileInfo(target.path), current.identity == entity.identity, current.size == info.size else { continue }
            let archived = try OpenedContent(target, identity: entity.identity, scope: root)
            if entity.verifiedToken == archived.token, let cached = entity.digest, cached != digest { continue }
            let currentDigest = try archived.digest()
            entity.digest = currentDigest; entity.info = archived.info; entity.verifiedToken = archived.token
            let modified = try store.sources(accountID).contains { $0.entityID == entity.id && $0.receivedDigest != nil && $0.receivedDigest != currentDigest }
            entity.status = modified ? .modified : .ready
            try store.atomic { try store.put(entity) }
            guard currentDigest == digest, try incoming.sameBytes(as: archived) else { continue }
            guard try incoming.compatibleMetadata(with: archived) else { incompatibleCandidate = true; continue }
            let source = ContentSource(id: UUID().uuidString, accountID: accountID, relative: relative, entityID: entity.id,
                originalName: file.lastPathComponent, receivedIdentity: info.identity, receivedDigest: digest,
                status: .pending, active: true, linkRelative: entity.relative)
            let op = ContentOperation(id: UUID().uuidString, accountID: accountID, entityID: entity.id, sourceID: source.id,
                kind: .attach, temporary: temporaryPrefix + UUID().uuidString, expected: info, digest: digest, protect: false)
            try store.atomic { try store.put(source); try store.put(op) }
            try checkpoint?(.planSaved)
            try ContentOperationRunner(store: store, checkpoint: checkpoint).attach(op, root: root, sourceRoot: account.sourceURL)
            return
        }
        if incompatibleCandidate { throw SyncError.message("相同内容的附加属性不兼容，保留源文件") }
        try incoming.validate()
        let protect = try store.readOnlyDefault(accountID)
        if protect { try incoming.validatePermissionSupport() }
        let destination = try unusedDestination(archive, name: file.lastPathComponent)
        let entity = ContentEntity(id: UUID().uuidString, accountID: accountID, relative: try relativePath(destination, in: root),
            identity: info.identity, info: info, digest: digest, status: .pending)
        let source = ContentSource(id: UUID().uuidString, accountID: accountID, relative: relative, entityID: entity.id,
            originalName: file.lastPathComponent, receivedIdentity: info.identity, receivedDigest: digest, status: .pending,
            active: true, linkRelative: entity.relative)
        let temporary = temporaryPrefix + UUID().uuidString
        let op = ContentOperation(id: UUID().uuidString, accountID: accountID, entityID: entity.id, sourceID: source.id,
            kind: .create, temporary: temporary, expected: info, digest: digest, protect: protect)
        let transfer = Transfer(destination: entity.relative, temporary: temporary, identity: info.identity, phase: .planned, observedInfo: info)
        try store.atomic {
            try store.put(entity); try store.put(source); try store.put(op)
            try store.accounts.execute("INSERT INTO transfers VALUES(?,?,?,?,?,?,?)", [.text(accountID), .text(relative),
                .text(transfer.destination), .text(temporary), .blob(try JSONEncoder().encode(info.identity)), .text("planned"), .blob(try JSONEncoder().encode(info))])
        }
        try checkpoint?(.planSaved)
        try recoverMoves(account: account, root: root, index: index)
    }

    private func protectMoved(_ op: ContentOperation, source: ContentSource, account: Account, root: URL, index: ManagedRootIndex) throws {
        guard op.kind == .create,
              try readFileInfo(account.sourceURL.appendingPathComponent(source.relative).path)?.regular != true,
              let original = try store.entities(accountID).first(where: { $0.id == op.entityID }) else { return }
        let entity = try locate(original, root: root, index: index)
        let target = try checkedFile(root, relative: entity.relative)
        if try readFileInfo(target.path)?.identity == entity.identity {
            let file = try OpenedContent(target, identity: entity.identity, scope: root)
            guard try file.digest() == op.digest else { throw SyncError.message("移动后内容与接收快照不符，保留归档等待检查") }
            if op.protect && entity.protectionBefore == nil {
                try ReadOnlyPolicy(store: store, checkpoint: checkpoint).apply(entity, at: target, protect: true)
            }
        }
    }

    private func recoverMoves(account: Account, root: URL, index: ManagedRootIndex) throws {
        let operations = try store.operations(accountID).filter { ($0.kind == .create || $0.kind == .legacy) && $0.phase != .conflict }
        for op in operations {
            try process(op.id) {
                guard let sourceID = op.sourceID, var source = try store.sources(accountID).first(where: { $0.id == sourceID }),
                      var entity = try store.entities(accountID).first(where: { $0.id == op.entityID }) else { throw SyncError.persistence("移动操作关系缺失") }
                try protectMoved(op, source: source, account: account, root: root, index: index)
                let worker = try SyncWorker(store: LegacyTransferStore(repository: store.accounts, accountID: accountID, relative: source.relative),
                    archiveRelative: account.archiveRelative, archiveIdentity: account.archiveIdentity, settleSeconds: settleSeconds, clock: clock, checkpoint: { stage in
                        if stage == .fileMoved { try self.protectMoved(op, source: source, account: account, root: root, index: index) }
                        try self.transferCheckpoint?(stage)
                    })
                try worker.scan(acceptNewFiles: false, sharedIndex: index)
                report.issues += worker.report.issues
                let record = worker.state.transfers[source.relative]
                if record?.phase == .planned { return }
                // Permission changes may have updated the entity while finishing the move.
                entity = try store.entities(accountID).first(where: { $0.id == op.entityID }) ?? entity
                if record?.phase == .linked, let record {
                    entity.relative = record.destination
                    entity.info = try readFileInfo(root.appendingPathComponent(record.destination).path)
                    entity.status = .unchecked
                    source.status = .linked; source.linkRelative = record.destination
                } else if record?.phase == .conflict {
                    entity.status = .conflict; source.status = .conflict
                } else {
                    entity.status = .missing; source.status = .detached; source.active = false
                }
                try store.atomic {
                    try store.put(entity); try store.put(source)
                    if record?.phase != .conflict {
                        try store.accounts.execute("DELETE FROM transfers WHERE account_id=? AND relative=?", [.text(accountID), .text(source.relative)])
                        try store.finish(op)
                    } else {
                        var conflict = op; conflict.phase = .conflict; conflict.error = "旧移动操作需要检查"; try store.put(conflict)
                    }
                }
                if source.status == .linked { try store.recordIssue(accountID, relative: source.relative, message: nil) }
            }
        }
    }

    private func recover(account: Account, root: URL, index: ManagedRootIndex) throws {
        try recoverMoves(account: account, root: root, index: index)
        for op in try store.operations(accountID) where op.kind == .clearLink || op.kind == .restoreLink {
            try process(op.id) { try LinkRecovery(store: store, checkpoint: checkpoint).run(op) }
        }
        for op in try store.operations(accountID) where op.kind == .attach || op.kind == .permission {
            try process(op.id) {
                guard let original = try store.entities(accountID).first(where: { $0.id == op.entityID }) else { throw SyncError.persistence("操作实体缺失") }
                let entity = try locate(original, root: root, index: index)
                if op.kind == .permission {
                    try ReadOnlyPolicy(store: store, checkpoint: checkpoint).apply(entity, at: checkedFile(root, relative: entity.relative), protect: op.protect)
                } else {
                    try ContentOperationRunner(store: store, checkpoint: checkpoint).attach(op, root: root, sourceRoot: account.sourceURL)
                    if let source = try store.sources(accountID).first(where: { $0.id == op.sourceID }), source.status != .pending {
                        try store.recordIssue(accountID, relative: source.relative, message: nil)
                    }
                }
            }
        }
    }
}
