import Foundation
import AppKit

let app = NSApplication.shared
app.finishLaunching()
do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 1 || (arguments.count == 2 && ["--manual", "--manual-smoke"].contains(arguments[1])) else {
        throw SyncError.message("需要输出图片路径，可选 --manual")
    }
    try desktopPreviewTest(output: URL(fileURLWithPath: arguments[0]), manual: arguments.count == 2,
                           autoClose: arguments.last == "--manual-smoke")
} catch {
    fputs("界面隔离测试失败：\(error)\n", stderr)
    exit(1)
}
