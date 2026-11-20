import Foundation
import AppKit
import ServiceManagement

let applicationIdentifier = "0xRock3.WechatFileSync"

/// Installer helpers do not open/migrate the state database or acquire directory bookmarks.
func checkApplicationStopped() throws {
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: applicationIdentifier)
        .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }
    guard others.isEmpty else { throw SyncError.message("请先从菜单栏退出微信文件同步，再安装、升级或卸载；关闭窗口不会停止同步") }
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("WeChatFileSync", isDirectory: true)
    let lockURL = support.appendingPathComponent("sync.lock")
    if FileManager.default.fileExists(atPath: lockURL.path) {
        let lock = try ProcessLock(url: lockURL)
        withExtendedLifetime(lock) {}
    }
}

func disableApplicationLogin() throws {
    try checkApplicationStopped()
    switch SMAppService.mainApp.status {
    case .enabled, .requiresApproval: try SMAppService.mainApp.unregister()
    case .notRegistered: break
    default: throw SyncError.message("无法确认登录项状态，请在系统设置中移除本应用的登录启动后再卸载")
    }
}
