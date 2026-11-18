import Foundation
import Darwin

do {
    let command = try Command.parse(Array(CommandLine.arguments.dropFirst()))
    switch command {
    case .help: print(commandHelp)
    case .selfTest: try selfTest()
    default:
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WeChatDownloadSync", isDirectory: true)
        let lock: ProcessLock?
        let content: ContentRepository
        if command.readOnly {
            lock = nil
            content = try ContentRepository(url: support.appendingPathComponent("state.sqlite"), readOnly: true)
        } else {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            lock = try ProcessLock(url: support.appendingPathComponent("sync.lock"))
            content = try ContentRepository(url: support.appendingPathComponent("state.sqlite"))
        }
        defer { withExtendedLifetime(lock) {} }
        switch command {
        case .background: try runBackground(content: content)
        case .listAccounts: try listAccounts(content.accounts)
        case .check: try checkAccounts(content.accounts, diagnose: false)
        case .diagnose: try checkAccounts(content.accounts, diagnose: true)
        case .setReadOnly, .applyReadOnly, .listFileIssues, .recoverOperations: try runContentCommand(command, store: content)
        default: try runConfiguration(command, repository: content.accounts)
        }
    }
} catch {
    fputs("微信下载同步失败：\(error)\n", stderr)
    exit(1)
}
