import Foundation
import Darwin

final class ProcessLock {
    private let descriptor: Int32

    init(url: URL) throws {
        descriptor = open(url.path, O_CREAT | O_RDWR, mode_t(0o600))
        guard descriptor >= 0 else { throw SyncError.system("打开同步锁", errno) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw SyncError.message("同步程序或配置流程已在运行；修改配置前请先停止后台（LaunchAgent 使用 launchctl bootout），完成后重新启动")
        }
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
