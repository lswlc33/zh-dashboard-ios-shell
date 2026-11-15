// 后台凭据的纯逻辑回归：不进 App target，只在本机/CI 用 swiftc 单独编译跑。
//
// 覆盖的正是用户报的那个 bug：快捷指令一直说「未导入后台凭据」，
// 但用户其实授权过。三个成因各有一个用例。
//
// 跑法（macOS）：
//   xcrun swiftc -swift-version 5 ios-shell/BackgroundSigning.swift \
//       ios-shell/background-credential-test.swift -o /tmp/credential-test && /tmp/credential-test
//
// **为什么必须用 @main 而不是顶层语句**：swiftc 只在**单文件**编译时接受顶层可执行语句；
// 这里要连同 BackgroundSigning.swift 一起编（多文件），顶层语句会报
// "expressions are not allowed at the top level"（CI 实测）。
//
// **为什么不在本文件断言 `ZeehoCredentialIssueText`**：那个类型在
// `BackgroundIntentSupport.swift`，依赖 AppIntents + UIKit；把整条 UI 依赖拖进
// 纯逻辑回归既慢又容易在无 UI 环境失败。文案层由 test.py 的源码断言覆盖，
// 这里只钉错误码映射（`IOSBackgroundCredentialIssue`，在 BackgroundSigning.swift 里）。

import Foundation

@main
enum BackgroundCredentialTest {
    static func main() {
        var failures = 0
        func check(_ ok: Bool, _ name: String) {
            if ok { print("  ok   \(name)") }
            else { print("  FAIL \(name)"); failures += 1 }
        }

        // MARK: - 1. 旧 schema（缺字段）必须仍能解码

        // 这是 v1 时代真实存进 Keychain 的形状：没有 signinToken / h5Secret / h5AppID。
        // 旧实现用合成 Codable，缺键直接 throw -> load() 返回 nil -> 报 no_credential。
        let legacyJSON = """
        {"accountID":"acc-1","vin":"358122500025900","token":"tok-app",
         "appSecret":"sec-app","appID":"id-app","updatedAt":1700000000000}
        """
        let legacy = try? JSONDecoder().decode(IOSBackgroundCredential.self, from: Data(legacyJSON.utf8))
        check(legacy != nil, "旧 schema 能解码（不再整体失败）")
        check(legacy?.canSampleVehicle == true, "旧 schema 仍可采样车况（app 域齐全）")
        check(legacy?.canSignIn == false, "旧 schema 不能签到（h5 域确实缺）")
        check(legacy?.isValid == true, "旧 schema 至少一个域可用 -> 有效")

        // MARK: - 2. 只有 app 域 / 只有 h5 域

        func makeCredential(token: String = "t", appID: String = "a", appSecret: String = "s",
                            h5AppID: String = "ha", h5Secret: String = "hs") -> IOSBackgroundCredential {
            IOSBackgroundCredential(accountID: "acc", vin: "vin", token: token, signinToken: token,
                                    appSecret: appSecret, h5Secret: h5Secret,
                                    appID: appID, h5AppID: h5AppID, updatedAt: 1)
        }
        let appOnly = makeCredential(h5AppID: "", h5Secret: "")
        check(appOnly.canSampleVehicle, "只有 app 域时仍可采样")
        check(!appOnly.canSignIn, "只有 app 域时不能签到")
        check(appOnly.grantedScopes == ["app"], "只有一个域时 grantedScopes 精确")

        let h5Only = makeCredential(token: "", appID: "", appSecret: "")
        check(!h5Only.canSampleVehicle, "只有 h5 域时不能采样")
        // signinToken 非空即可签（构造器里 signinToken=token=""，所以这里应为 false）
        check(!h5Only.canSignIn, "h5 域齐全但无任何 token 时不能签到")

        let both = makeCredential()
        check(both.canSampleVehicle && both.canSignIn, "两域齐全时都能用")
        check(both.grantedScopes == ["app", "h5"], "两域齐全时 scopes 是 app+h5")

        // MARK: - 3. 全空凭据必须判为无效

        let empty = IOSBackgroundCredential(accountID: "", vin: "", token: "", signinToken: "",
                                            appSecret: "", h5Secret: "", appID: "", h5AppID: "", updatedAt: 0)
        check(!empty.isValid, "全空凭据无效（不会被当成已授权）")
        check(empty.grantedScopes.isEmpty, "全空凭据没有可用域")

        // MARK: - 4. 控制字符必须被拒绝（防止 JSON 里塞换行破坏回执）

        let dirty = makeCredential(token: "tok\nen")
        check(!dirty.canSampleVehicle, "token 含控制字符时该域不可用")

        // MARK: - 5. 错误码映射：不得把「有数据但坏了」说成「没授权」

        check(IOSBackgroundCredentialIssue.from(.missing) == .neverGranted,
              "missing -> no_credential（这才是真正的没授权）")
        check(IOSBackgroundCredentialIssue.from(.unusable(reason: "credential_decode_failed")) == .decodeFailed,
              "解码失败 -> credential_decode_failed")
        check(IOSBackgroundCredentialIssue.from(.unusable(reason: "credential_partial")) == .partial,
              "部分域 -> credential_partial")
        check(IOSBackgroundCredentialIssue.from(.unusable(reason: "keychain_-25308")) == .keychainLocked,
              "锁屏不可读 -> keychain_locked（可重试，不误导用户重新授权）")
        check(IOSBackgroundCredentialIssue.from(.unusable(reason: "keychain_-25293")) == .keychainUnavailable,
              "钥匙串拒绝 -> keychain_unavailable")
        check(IOSBackgroundCredentialIssue.from(.ready(both)) == nil,
              "可用凭据 -> 没有问题码")

        // MARK: - 6. 错误码必须能区分「没授权」与「有数据但读不到」

        // 用户可读文案在 BackgroundIntentSupport.swift（依赖 UIKit），由 test.py 的
        // 源码断言覆盖；这里只保证机器码本身可区分，不会三件事压成同一个。
        let codes: Set<String> = [
            IOSBackgroundCredentialIssue.neverGranted.rawValue,
            IOSBackgroundCredentialIssue.decodeFailed.rawValue,
            IOSBackgroundCredentialIssue.incomplete.rawValue,
            IOSBackgroundCredentialIssue.partial.rawValue,
            IOSBackgroundCredentialIssue.keychainLocked.rawValue,
            IOSBackgroundCredentialIssue.keychainUnavailable.rawValue,
        ]
        check(codes.count == 6, "六类凭据问题各有独立错误码（不压成一句「未授权」）")
        check(!codes.contains("ok") && codes.allSatisfy { !$0.isEmpty }, "错误码都非空")

        // MARK: - 结果

        if failures == 0 {
            print("\nall credential regression checks passed")
        } else {
            print("\n\(failures) check(s) failed")
            exit(1)
        }
    }
}
