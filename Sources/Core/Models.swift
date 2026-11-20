import Foundation
import Darwin

struct Identity: Codable, Equatable, Hashable {
    let device: UInt64
    let inode: UInt64
    let birthSeconds: Int64
    let birthNanoseconds: Int64
}

struct FileInfo: Codable, Equatable {
    let identity: Identity
    let mode: mode_t
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64

    var regular: Bool { mode & mode_t(S_IFMT) == mode_t(S_IFREG) }
    var symbolicLink: Bool { mode & mode_t(S_IFMT) == mode_t(S_IFLNK) }
    var directory: Bool { mode & mode_t(S_IFMT) == mode_t(S_IFDIR) }
}

enum TransferPhase: String, Codable {
    case planned, linked, conflict
}

struct Transfer: Codable, Equatable {
    var destination: String
    var temporary: String
    var identity: Identity
    var phase: TransferPhase
    var observedInfo: FileInfo? = nil
}

struct SyncState: Codable, Equatable {
    let version: Int
    let source: String
    let managedRoot: String
    let sourceIdentity: Identity
    let managedRootIdentity: Identity
    var baseline: [String: Identity]
    var transfers: [String: Transfer]
}

extension SyncState {
    private enum CodingKeys: String, CodingKey {
        case version, source, managedRoot, sourceIdentity, managedRootIdentity, baseline, transfers
        case downloads, downloadsIdentity
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        source = try values.decode(String.self, forKey: .source)
        managedRoot = try values.decodeIfPresent(String.self, forKey: .managedRoot)
            ?? values.decode(String.self, forKey: .downloads)
        sourceIdentity = try values.decode(Identity.self, forKey: .sourceIdentity)
        managedRootIdentity = try values.decodeIfPresent(Identity.self, forKey: .managedRootIdentity)
            ?? values.decode(Identity.self, forKey: .downloadsIdentity)
        baseline = try values.decode([String: Identity].self, forKey: .baseline)
        transfers = try values.decode([String: Transfer].self, forKey: .transfers)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(source, forKey: .source)
        try values.encode(managedRoot, forKey: .managedRoot)
        try values.encode(sourceIdentity, forKey: .sourceIdentity)
        try values.encode(managedRootIdentity, forKey: .managedRootIdentity)
        try values.encode(baseline, forKey: .baseline)
        try values.encode(transfers, forKey: .transfers)
    }
}

struct Observation {
    let info: FileInfo
    let firstSeen: Date
}

enum SyncError: Error, CustomStringConvertible {
    case message(String)
    case system(String, Int32)
    case persistence(String, sqliteCode: Int32? = nil)

    static func persistenceFailure(_ error: Error) -> SyncError {
        if let error = error as? SyncError, case .persistence = error { return error }
        return .persistence(String(describing: error), sqliteCode: (error as? SQLiteStoreError)?.code)
    }

    var description: String {
        switch self {
        case .message(let text): return text
        case .persistence(let text, _): return "状态保存失败：\(text)"
        case .system(let operation, let number):
            return "\(operation)：\(String(cString: strerror(number)))"
        }
    }
}
