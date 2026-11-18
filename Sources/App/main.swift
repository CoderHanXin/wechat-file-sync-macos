import Foundation
import Darwin


do {
    if CommandLine.arguments.contains("--self-test") {
        try selfTest()
    } else {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WeChatDownloadSync", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        if CommandLine.arguments.contains("--configure") {
            do { try configure(appSupport: support) }
            catch { showMessage("无法完成授权：\(error)"); exit(1) }
        } else {
            try runBackground(appSupport: support)
        }
    }
} catch {
    NSLog("微信下载同步失败：%@", String(describing: error))
    exit(1)
}
