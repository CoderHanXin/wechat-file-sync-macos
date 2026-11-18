import Foundation

enum Command: Equatable {
    case background, help, selfTest, check, diagnose, listAccounts, configure
    case addAccount(String?), pauseAccount(String), resumeAccount(String), renameAccount(String, String)
    case removeAccount(String), restoreAccount(String), reauthorizeAccount(String), reauthorizeRoot, recoverAccounts
    case setReadOnly(String, Bool), applyReadOnly(String, Bool), listFileIssues(String?), recoverOperations(String?)

    var readOnly: Bool {
        switch self { case .help, .selfTest, .check, .listAccounts, .listFileIssues: return true; default: return false }
    }

    static func parse(_ arguments: [String]) throws -> Command {
        switch arguments {
        case []: return .background
        case ["--help"], ["-h"]: return .help
        case ["--self-test"]: return .selfTest
        case ["--check"]: return .check
        case ["--diagnose"]: return .diagnose
        case ["--list-accounts"]: return .listAccounts
        case ["--configure"]: return .configure
        case ["--add-account"]: return .addAccount(nil)
        case ["--reauthorize-root"]: return .reauthorizeRoot
        case ["--recover-accounts"]: return .recoverAccounts
        case ["--list-file-issues"]: return .listFileIssues(nil)
        case ["--recover-operations"]: return .recoverOperations(nil)
        default: break
        }
        if arguments.count == 2, !arguments[1].isEmpty, !arguments[1].hasPrefix("--") {
            let id = arguments[1]
            switch arguments[0] {
            case "--pause-account": return .pauseAccount(id)
            case "--resume-account": return .resumeAccount(id)
            case "--remove-account": return .removeAccount(id)
            case "--restore-account": return .restoreAccount(id)
            case "--reauthorize-account": return .reauthorizeAccount(id)
            case "--list-file-issues": return .listFileIssues(id)
            case "--recover-operations": return .recoverOperations(id)
            default: break
            }
        }
        if arguments.count == 3, !arguments[1].isEmpty, !arguments[1].hasPrefix("--"), ["on", "off"].contains(arguments[2]) {
            if arguments[0] == "--set-read-only" { return .setReadOnly(arguments[1], arguments[2] == "on") }
            if arguments[0] == "--apply-read-only" { return .applyReadOnly(arguments[1], arguments[2] == "on") }
        }
        if arguments.count == 3, arguments[0] == "--add-account", arguments[1] == "--name", !arguments[2].isEmpty {
            return .addAccount(arguments[2])
        }
        if arguments.count == 4, arguments[0] == "--rename-account", arguments[2] == "--name", !arguments[1].isEmpty, !arguments[3].isEmpty {
            return .renameAccount(arguments[1], arguments[3])
        }
        throw SyncError.message("命令或参数无效；使用 --help 查看用法")
    }
}

let commandHelp = """
微信文件同步（M3）
  无参数                             后台同步所有已启用账号
  --configure                        首次配置管理根目录并添加账号
  --add-account [--name 备注]          添加微信账号（弹窗授权）
  --list-accounts                    只读列出账号和未完成配置
  --pause-account ID                 仅暂停该账号的新文件同步
  --resume-account ID                恢复新文件同步，补同步暂停期间的新文件
  --rename-account ID --name 备注     修改备注，归档文件夹不改名
  --remove-account ID                移除管理及当前授权，保留文件、链接和记录
  --restore-account ID               显式恢复原账号并重新授权
  --reauthorize-account ID           重新授权原账号目录
  --reauthorize-root                 重新授权原管理根目录
  --recover-accounts                 恢复未完成的账号配置
  --set-read-only ID on|off           设置以后新建实体的只读默认值
  --apply-read-only ID on|off         显式调整已有实体的保护，未知原权限不解锁
  --list-file-issues [ID]             只读列出内容、来源及未完成操作状态
  --recover-operations [ID]           仅恢复记录中的操作，不接纳新文件
  --check                            只读检查授权及账号目录
  --diagnose                         在授权目录创建临时文件诊断（须停止后台）
  --self-test                        仅使用临时样本自检

修改配置前须先停止后台服务（launchctl bootout）；完成后可重新启动。
"""
