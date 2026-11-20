import Foundation

// 凭据不可用时的统一说明。授权材料由前台会话同步，不单独暴露快捷指令入口。
enum ZeehoCredentialIssueText {
    static func isCredentialIssue(_ code: String) -> Bool {
        switch code {
        case "no_credential", "credential_decode_failed", "credential_incomplete",
             "credential_partial", "keychain_locked", "keychain_unavailable":
            return true
        default:
            return false
        }
    }

    static func text(_ code: String) -> String {
        switch code {
        case "no_credential":
            return "还没同步后台凭据。打开面板并登录、选择车辆后会自动同步"
        case "credential_decode_failed":
            return "后台凭据格式无法识别，请打开面板登录并选择车辆后重试"
        case "credential_incomplete", "credential_partial":
            return "后台凭据不完整，请打开面板登录并选择车辆后重试"
        case "keychain_locked":
            return "设备锁屏中暂时读不到后台凭据，解锁后再试即可"
        case "keychain_unavailable":
            return "系统暂时无法读取后台凭据，请解锁并打开面板重试"
        default:
            return code
        }
    }
}
