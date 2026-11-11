# 原生共享核心（KMP）

在 Windows 验证协议与算法；在 Mac 生成供 Swift 链接的 `ZeehoShared` framework。**本轮源码尚未发布，没有 Apple framework 或 IPA**；JVM 通过不等于 iOS 编译通过。

`native-shared/` 是独立 Kotlin Multiplatform 工程，不依赖 Android Gradle Plugin 或 Android SDK。网页仍是唯一业务 UI 与请求签名实现，Swift UIKit / WKWebView 和 Android WebView 提供各自的系统入口；这里不使用 Compose Multiplatform UI 或 Skia。

## 接入边界

| 接口 | 当前职责 | 不包含什么 |
|---|---|---|
| `SharedProtocol` | 小 BLE 控制帧、分片重组、校验、protobuf 字段与遥测解析、challenge 算法；Swift 使用 String / 数值接口 | 蓝牙连接、用户授权、云端登记或自动解锁 |
| `SharedBattery` | 电池数值归一化、真实采样受理、历史报告 / 快照恢复、24 字节 v4 记录编解码 | 平台磁盘、Keychain、后台采样；`accepted` 不表示已落盘 |
| `SharedChargeLog` | 充电段 reducer、清除水位、按真实样本还原曲线 | 自己保存第二份采样、GPS 推算电池容量或补缺测点 |
| `SharedTransport` | 原始请求字节、签名头透传、白名单、超时 / 取消 / 有界响应与回执；iOS 走 Ktor Darwin | 生成签名、自动重发、网页 `fetch` 回退 |
| `SharedByteProtocol` / `SharedBatteryReadingJvm` | Android Java 调用的 `byte[]` / 基础数值热路径 | 每次采样的 JSON 转换或迁移全部 Android 原生实现 |

Android 通过 `app-shell/settings.gradle.kts` 的 composite build 和固定坐标 `io.github.lswlc33:zeeho-native-shared:1.0.0` 接入本工作树 JVM jar，Java 目标仍为 17。
当前只委托已经接线的帧 / 校验 / hex / UTF-8 / challenge 与电池数值规则。Android 原 `WebRequestBridge` 仍用 `HttpURLConnection`，原磁盘账本、历史二进制读写和 BLE `Stream` 保留；**没有把 Android 官方请求迁成 Ktor，也没有统一所有账本 / streams**。共享库自身的 JVM Ktor 引擎供对应接口与离线测试使用，不代表 Android 正在用它发请求。

Swift 直接 `import ZeehoShared`，没有缺框架时绕过导入的替代实现。`ios-shell/History.swift` 调用共享采样 / 账本算法后再负责本机持久化；BLE 与定位生命周期仍在 Swift 系统服务中。

## Windows 离线验证

需要现有 **JDK 21、Python 3.9+、Git、缓存 Gradle 9.6.1 与本工程依赖**。JDK 21 是工具要求，JVM 输出目标是 Java 17；版本以 Gradle 源文件和 wrapper 为准。

本机可复现入口：

```powershell
powershell -NoProfile -File D:/zeeho-ios-20261110/source/ios-shell/build-windows.ps1 `
  -Mode Test -GradleUserHome C:/Users/lswlc/.gradle `
  -PythonPath C:/Users/lswlc/AppData/Local/Programs/Python/Python312/python.exe
```

`-JavaHome` 默认 `E:/Java/jdk-21.0.12.1+1`；其他机器须换成已有 JDK 21。`-PythonPath` 可省略让预检寻找现有解释器；Microsoft Store 别名不算已安装 Python。
入口先执行 iOS 源码检查，再用缓存中的真实 Gradle `--offline :jvmTest`，不是把 `NO-SOURCE` 当成功。不下载缺失 wrapper / 依赖、不安装工具、不联系 Mac。工程缓存写在 `ios-shell/.build-local/`，JVM 输出在 `native-shared/build/`；默认专用 Gradle 缓存不一定已有依赖，本机用上面显式缓存路径。

2026-11-10 最终 `:jvmTest` 为 **9 tests / 0 failures / 0 errors / 0 skipped**（4 common + 5 JVM）。真实 XML 在 `build/test-results/jvmTest/TEST-io.github.lswlc33.zeehoshared.SharedCoreTest.xml` 与 `TEST-io.github.lswlc33.zeehoshared.SharedJvmTest.xml`；它们是本地构建输出，不随源码分发。测试体在 [SharedCoreTest.kt](src/commonTest/kotlin/io/github/lswlc33/zeehoshared/SharedCoreTest.kt) 和 [SharedJvmTest.kt](src/jvmTest/kotlin/io/github/lswlc33/zeehoshared/SharedJvmTest.kt)。包含真实 AES 夹具、未知充电态、快照水位、缺口，以及 MockEngine 的原始字节 / 取消 / 超时 / 截断检查，不连接真实 API。
完整本轮计数与尚未执行项见 [验证记录](../docs/iOS能力与Windows构建.md#验证记录)，不要把旧 8 项结果或重复运行相加。

## 调用约定

下面可在已接入共享 JVM jar 的 Kotlin 调用端运行，只做本地纯算法，参数和输出与已有测试相同：

```kotlin
import io.github.lswlc33.zeehoshared.SharedProtocol

fun main() {
    val protocol = SharedProtocol()
    println(protocol.encodeFrameHex(command = 93, payloadHex = "0800"))
    println(protocol.crc32Hex(bytesHex = "313233343536373839"))
}
```

```text
abcd5d0200080067cf
cbf43926
```

- 小帧 payload 上限 **240 字节**；未知 protobuf 字段和未标定单位不能当车辆协议全部验证。
- `SharedProtocol` / v4 编码的无效输入返回 `error:<原因>`；JSON facade 的参数失败返回 `{"ok":false,"error":"<原因>"}`。例如非 ASCII hex 返回 `error:hex_format`。Java byte facade 保留异常契约，不把错误当空字节。
- 电流未知用 `NaN`，`-1 A` 仍是有效放电值；未知充电态为 `-1`，不能当未充电。历史只使用真实、归属一致的采样；超过 **5 分钟**的间隔不积分，不插值。
- 历史保留 **31 天 / 最多 100000 点**，充电账本最多 **12 场 / 每场曲线 600 点**。共享 facade 返回 `persisted:false`；必须由平台实际写盘成功后确认持久化。
- `SharedTransport.execute(json, completion)` 异步回执；请求体上限 **8 MiB**、响应上限 **4 MiB**，截断用 `truncated:true` 标记。默认超时 **12000 ms**、最多 **60000 ms**；传输失败用 `http:0` / `bodyB64:null` / `err`，真实 HTTP 401 不改成网络错误。签名仍来自网页，不能重编码 multipart 或补发请求。

## Apple 构建

Mac 上才配置 `iosArm64` 与 `iosSimulatorArm64`，输出静态 `ZeehoShared` framework。设备包使用 `:linkReleaseFrameworkIosArm64`；完整流程由 `ios-shell/build.sh` 执行，不用单独拼接未验证框架。
Windows 的对应 Apple 任务会明确失败，不能用空 framework 代替。Kotlin/Native 的最终 Apple framework 编译 / 链接仍需 macOS 与 Xcode，官方限制见 https://kotlinlang.org/docs/native-target-support.html 。这是 **KMP Apple 最终产物**的限制，不是「Windows / WSL 不能构建任何 iOS App」：Linux / WSL 上的 Swift 6.4+、xtool 1.24.0 与合法 SDK 可以构建 Swift App 和传统 WidgetKit extension。

本项目完整 xtool App 仍链接 `ZeehoShared`，须提供可信 Mac 实际生成的 `ZeehoShared.xcframework` 与当前 KMP 源码匹配的 manifest；入口检查模块 / 头文件、真实 arm64 iOS 对象与源码哈希。manifest 是构建输入记录，不代替产物来源可信度，也不生成 framework。当前用户没有 SDK 或该 Apple 产物，完整构建被阻塞；独立 `SwiftProbe` 不包含 KMP，也不能证明完整 App 可构建。步骤与签名边界见 [iOS 能力与 Windows 构建](../docs/iOS能力与Windows构建.md)。
