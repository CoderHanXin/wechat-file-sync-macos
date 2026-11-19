import Foundation
import AppKit

let app = NSApplication.shared
app.finishLaunching()
do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 1 || (arguments.count == 2 && ["--manual", "--manual-smoke", "--capture"].contains(arguments[1])) else {
        throw SyncError.message("需要输出图片路径，可选 --manual、--manual-smoke 或 --capture")
    }
    try desktopPreviewTest(output: URL(fileURLWithPath: arguments[0]), manual: arguments.count == 2 && arguments[1] != "--capture",
                           autoClose: arguments.last == "--manual-smoke", captureRequested: arguments.last == "--capture")
} catch {
    fputs("界面隔离测试失败：\(error)\n", stderr)
    exit(1)
}
