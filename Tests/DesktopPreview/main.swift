import Foundation
import AppKit

let app = NSApplication.shared
app.finishLaunching()
do {
    guard CommandLine.arguments.count == 2 else { throw SyncError.message("需要输出图片路径") }
    try desktopPreviewTest(output: URL(fileURLWithPath: CommandLine.arguments[1]))
} catch {
    fputs("界面隔离测试失败：\(error)\n", stderr)
    exit(1)
}
