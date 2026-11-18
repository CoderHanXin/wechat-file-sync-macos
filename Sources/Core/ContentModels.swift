import Foundation

enum EntityStatus: String, Codable { case unchecked, pending, ready, modified, missing, conflict }
enum SourceStatus: String, Codable { case pending, linked, detached, missing, conflict }
enum ContentOperationKind: String, Codable { case create, attach, legacy, permission }
enum ContentOperationPhase: String, Codable { case planned, cleanup, rollback, conflict }
enum ContentCheckpoint { case planSaved, swapped, associationSaved, duplicateRemoved, permissionChanged, rollbackSwapped, rollbackLinkRemoved, completed }

struct ContentEntity: Codable, Equatable {
    let id: String
    let accountID: String
    var relative: String
    let identity: Identity
    var info: FileInfo?
    var digest: String?
    var status: EntityStatus
    var protectionBefore: UInt16? = nil
    var protectionAfter: UInt16? = nil
    var verifiedToken: String? = nil
}

struct ContentSource: Codable, Equatable {
    let id: String // Each reuse of a path creates a new source lifecycle.
    let accountID: String
    let relative: String
    let entityID: String
    let originalName: String
    let receivedIdentity: Identity
    let receivedDigest: String?
    var status: SourceStatus
    var active: Bool
    var linkRelative: String
}

struct ContentOperation: Codable, Equatable {
    let id: String
    let accountID: String
    let entityID: String
    let sourceID: String?
    let kind: ContentOperationKind
    var phase: ContentOperationPhase = .planned
    let temporary: String
    let expected: FileInfo?
    let digest: String?
    let protect: Bool
    var beforeMode: UInt16? = nil
    var afterMode: UInt16? = nil
    var error: String? = nil
    var linkTargets: [String]? = nil // Durable intended link destinations, including interrupted retargets.
}
