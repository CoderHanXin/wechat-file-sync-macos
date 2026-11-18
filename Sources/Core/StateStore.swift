import Foundation

protocol StateStore: AnyObject {
    func load() throws -> SyncState
    func save(_ state: SyncState) throws
}

struct DirectoryBookmarks: Equatable {
    let source: Data
    let managedRoot: Data
}

func initialState(source: URL, managedRoot: URL) throws -> SyncState {
    let sourcePath = source.resolvingSymlinksInPath().path
    let rootPath = managedRoot.resolvingSymlinksInPath().path
    guard let sourceInfo = try readFileInfo(source.path), sourceInfo.directory,
          let rootInfo = try readFileInfo(managedRoot.path), rootInfo.directory,
          sourceInfo.identity.device == rootInfo.identity.device else {
        throw SyncError.message("微信目录和管理根目录必须存在于同一文件系统")
    }
    let sourceComponents = URL(fileURLWithPath: sourcePath).pathComponents
    let rootComponents = URL(fileURLWithPath: rootPath).pathComponents
    guard sourceInfo.identity != rootInfo.identity,
          !sourceComponents.starts(with: rootComponents), !rootComponents.starts(with: sourceComponents) else {
        throw SyncError.message("微信目录与管理根目录不能相同或互相包含")
    }
    let baseline = try allFiles(source).mapValues { $0.identity }
    return SyncState(version: 1, source: source.path, managedRoot: managedRoot.path,
                     sourceIdentity: sourceInfo.identity, managedRootIdentity: rootInfo.identity,
                     baseline: baseline, transfers: [:])
}

func validateConfiguration(_ state: SyncState, source: URL, managedRoot: URL) throws {
    guard state.version == 1,
          URL(fileURLWithPath: state.source).resolvingSymlinksInPath().path == source.resolvingSymlinksInPath().path,
          URL(fileURLWithPath: state.managedRoot).resolvingSymlinksInPath().path == managedRoot.resolvingSymlinksInPath().path,
          try readFileInfo(source.path)?.identity == state.sourceIdentity,
          try readFileInfo(managedRoot.path)?.identity == state.managedRootIdentity else {
        throw SyncError.message("同步配置与授权目录不一致，原配置未更新")
    }
}

func configureDirectories(store: SQLiteStateStore, source: URL, managedRoot: URL,
                          bookmarks: DirectoryBookmarks) throws {
    let state: SyncState
    if let existing = try store.loadIfPresent() {
        try validateConfiguration(existing, source: source, managedRoot: managedRoot)
        state = existing
    } else {
        state = try initialState(source: source, managedRoot: managedRoot)
    }
    try store.configure(state, bookmarks: bookmarks)
}

func openConfiguredStore(appSupport: URL) throws -> SQLiteStateStore {
    let store = try SQLiteStateStore(url: appSupport.appendingPathComponent("state.sqlite"))
    if try store.loadIfPresent() == nil {
        let legacy = appSupport.appendingPathComponent("state.json")
        if FileManager.default.fileExists(atPath: legacy.path) {
            let state = try JSONDecoder().decode(SyncState.self, from: Data(contentsOf: legacy))
            guard state.version == 1 else { throw SyncError.message("不支持的旧状态版本") }
            let sourceBookmark = appSupport.appendingPathComponent("source.bookmark")
            let rootBookmark = appSupport.appendingPathComponent("downloads.bookmark")
            let bookmarks: DirectoryBookmarks?
            if FileManager.default.fileExists(atPath: sourceBookmark.path)
                || FileManager.default.fileExists(atPath: rootBookmark.path) {
                bookmarks = try DirectoryBookmarks(source: Data(contentsOf: sourceBookmark),
                                                   managedRoot: Data(contentsOf: rootBookmark))
            } else {
                bookmarks = nil
            }
            try store.configure(state, bookmarks: bookmarks)
        }
    }
    return store
}
