import Foundation

/// Lazy snapshot shared by all accounts in one serial round. Failed walks are cached too.
final class ManagedRootIndex {
    let root: URL
    private let enumerate: (URL) throws -> [String: FileInfo]
    private var snapshot: Result<[Identity: [String]], Error>?
    private(set) var enumerations = 0

    init(root: URL, enumerate: @escaping (URL) throws -> [String: FileInfo] = allFiles) {
        self.root = root
        self.enumerate = enumerate
    }

    func find(_ identity: Identity) throws -> String? {
        if snapshot == nil {
            enumerations += 1
            snapshot = Result {
                var index: [Identity: [String]] = [:]
                for (relative, info) in try enumerate(root) { index[info.identity, default: []].append(relative) }
                return index
            }
        }
        for relative in (try snapshot?.get()[identity] ?? []).sorted() {
            let candidate = try checkedFile(root, relative: relative)
            if try readFileInfo(candidate.path)?.identity == identity { return relative }
        }
        return nil
    }

    func register(_ identity: Identity, relative: String) {
        guard case .success(var index) = snapshot else { return }
        index[identity, default: []].append(relative)
        snapshot = .success(index)
    }
}
