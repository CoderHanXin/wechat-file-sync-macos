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
        let repository: AccountRepository
        if command.readOnly {
            lock = nil
            repository = try AccountRepository(url: support.appendingPathComponent("state.sqlite"), readOnly: true)
        } else {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            lock = try ProcessLock(url: support.appendingPathComponent("sync.lock"))
            repository = try openAccountRepository(appSupport: support)
        }
        defer { withExtendedLifetime(lock) {} }
        switch command {
        case .background: try runBackground(repository: repository)
        case .listAccounts: try listAccounts(repository)
        case .check: try checkAccounts(repository, diagnose: false)
        case .diagnose: try checkAccounts(repository, diagnose: true)
        default: try runConfiguration(command, repository: repository)
        }
    }
} catch {
    fputs("微信下载同步失败：\(error)\n", stderr)
    exit(1)
}
