# 几何面板 iOS（TrollStore）

Windows 可以经 **WSL / Linux、Swift 6.4+、xtool 1.24.0 和合法 iPhoneOS SDK** 构建 Swift iOS App 与传统 WidgetKit extension；完整面板还需可信 Mac 实际构建的 KMP Apple XCFramework。**2026-11-11 本轮新源码尚未发布**，WSL 功能已启用但待用户重启，专用 distro / 工具链未装，用户没有 SDK 或 KMP Apple 产物。构建入口仅完成阻塞预检（exit 2），未执行真实 xtool 命令、Swift 编译、IPA 或 iPhone / iPad 验收。步骤见 [iOS 能力与 Windows 构建](../docs/iOS能力与Windows构建.md)。

Swift UIKit + WKWebView 在线面板壳，固定打开 `https://lswlc33.github.io/zeeho-3d-models/`。网页是 App 内唯一业务 UI 与官方 API 请求签名实现；Swift 提供系统服务，[KMP 核心](../native-shared/README.md) 提供协议、数值与历史算法，不使用 Compose Multiplatform UI 或 Skia。IPA 不内置本轮网页快照，首次启动需联网；构建脚本不发布网页。

账号与 `Store` 数据经 AES-GCM 私有文件及本机 Keychain 保存；轻量网页偏好使用持久 WKWebsiteDataStore，不与 Safari 或 Android 互通。WebView 由原生安全区约束；远程页面到达前显示骨架屏。资产沿用网页自身发布机制，没有 Android 原生签名快照更新器。

构建目标仍是 arm64 iPhone / iPad、**iOS 15.4**。网页检查真实 `HTMLElement.inert`，参考基线为 **iOS / Safari 15.5**；只补确定性的 `findLast`，不伪造 `inert`，不能保证 15.4 可用。Live Activities 另需 **iOS 16.1+**；更高系统版本、方法存在或合成回执均不是设备验收证明。

新网页等待真实 `WKScriptMessageHandlerWithReply` 的 `hello`，按 `IOSBR.has(method)` 启用业务，不注入同步 `ZeehoShell`。无桥浏览器 / PWA / 旧壳默认进入隔离合成 UI 预览，全部控件可见，但不保存真实账号、不请求官方 API / H5 或发送车控；原生动作显示 `unavailable`。产品平台只有 Android / iOS，标签只用精确 `Android only` / `iOS only`，跨平台功能无标签，见 [功能环境标记](../docs/功能环境标记.md)。

## 已接入源码与系统展示

已接入原生请求、加密事务存储、用户主动 GPS、BLE 只读仪表、骑行文件、前台电池 / 充电历史、文件分享、照片添加和本地通知。BLE 连接不等于钥匙认证、云端登记或自动解锁；接口与源码存在不代表 Apple 编译或实车通过。

- `Shared/` 是主 App 与 extension 共用的 Swift 模块 `ZeehoSystemShared`，不是 KMP `ZeehoShared`。只共享匿名 owner、车辆摘要、骑行状态与真实事件时间；token、完整账号 / VIN 和 GPS 坐标不入 App Group。
- `SystemSurfaces.swift` 发布已接受的前台真实云 API 样本；`Ride.swift` 经原生确认的 GPS / BLE 录制事件更新已存在活动，不自动启动活动、不新增后台云轮询器。
- `Widgets/` 只有一个传统 `com.apple.widgetkit-extension` appex。普通 Widget 支持 small / medium / large；同一 `WidgetBundle` 内的 `ActivityConfiguration` 提供锁屏 / 横幅、Dynamic Island compact / minimal / expanded 布局，不使用 ExtensionKit 的 `EXAppExtensionAttributes`。
- 「我的 → iOS 系统展示」使用标准页面卡片，提供启用 / 关闭、活动开始 / 更新 / 结束及小组件刷新。执行检查真实回执、有效车辆范围、extension、App Group 与系统权限；缺能力显示 `unavailable`。公开 entitlement 模板不证明群组权限已获批准，灵动岛展示还取决于设备硬件与系统。
- 车辆数值超过 **180 秒**、骑行速度超过 **10 秒**显示过期 / 未知；重新读取或刷新不改样本时间。iOS 16.2+ 使用 `staleDate`，16.1 没有同等系统自动过期保证。Widget 实际刷新受系统预算控制，`reload_requested` 不是已显示新数据。

后台连续电量 / 完整充电采样、每日自动云任务、Android 桌面小组件、VPN 抓取、Wi-Fi Direct 投屏与 root 增强是 `Android only`。iOS 可保存真实前台历史与已收到的骑行点，缺测留空；不能宣称完整连续轨迹、后台电池健康或用 GPS 推算容量。

## iOS 软件更新与面板更新

顶部“软件更新”读取官方仓库 `main/app/ios/version.json`，不请求 Android 版本或 APK。清单从 GitHub raw / Pages / API 依次读取；IPA 使用 ghfast、gh-proxy、GitHub raw、jsDelivr、Pages。镜像失败、旧缓存或校验不符会换源，第三方镜像不提供可信版本清单。

启动自动检查，也可手动检查；比较 iOS 版本与 build，拒绝降级及不支持当前系统的包。下载后核对大小和 SHA-256，再交系统分享菜单，由用户选择 TrollStore 并确认覆盖安装，不是静默安装。初始信任依赖固定官方 HTTPS，SHA-256 是完整性校验，不是独立发布者签名。

顶部“刷新面板”重新加载在线网页，不能把本工作树未发布的页面变成线上功能。保持原 Bundle ID 的覆盖安装可延用原 App 网页空间，不迁移 Safari 数据；旧 1.0.0 首次须手动安装带更新入口的 1.0.1。

## 构建与发布

GitHub Actions 已停用，本轮不恢复。Windows 本地源码 / JVM 测试使用已有 JDK 21、Python 3.9+ 和缓存 Gradle 9.6.1：

```powershell
powershell -NoProfile -File D:/zeeho-ios-20261110/source/ios-shell/build-windows.ps1 `
  -Mode Test -GradleUserHome C:/Users/lswlc/.gradle `
  -PythonPath C:/Users/lswlc/AppData/Local/Programs/Python/Python312/python.exe
```

`Test` 只执行源码检查与真实离线 `:jvmTest`，不编译 Swift。默认 `Preflight` 检查传统 Mac 后端；WSL 路线须显式选择：

```powershell
powershell -NoProfile -File D:/zeeho-ios-20261110/source/ios-shell/build-windows.ps1 `
  -Mode XtoolPreflight -WslDistribution Zeeho-iOS -Product DashboardIOS

# 独立 UIKit / WebKit 探针，不是完整 App；当前无 SDK，入口仍被阻塞。
powershell -NoProfile -File D:/zeeho-ios-20261110/source/ios-shell/build-windows.ps1 `
  -Mode XtoolBuild -WslDistribution Zeeho-iOS -Product SwiftProbe `
  -OutputDirectory D:/zeeho-ios-20261110/environment/artifacts/swift-probe
```

`DashboardIOS` 构建须另给真实 `-KmpXCFramework`、`-KmpManifest` 与已有 SDK 的 `-SwiftSDKRoot`。`Package.swift` 将 host `DashboardIOS`、共享模块 `ZeehoSystemShared`、Widget product `DashboardWidgets` 分开；独立 `SwiftProbe` 无 KMP、业务、appex 或真实账号共享。构建实际调用 `xtool dev build --configuration release`，不加 `--sign`，不登录或安装设备，不杜撰 `--no-install` / `--skip-signing`。

完整 Xcode / 已接受许可、JDK 21、Python 3.9+ 齐备的 Mac 可用现有后端；把路径换成该 Mac 的源码绝对路径：

```bash
bash /path/to/dashboard/ios-shell/build.sh
```

脚本先生成真实 KMP device framework，再编译 Swift host / shared / Widget appex，由内到外 ad-hoc 签名并校验；失败不写替代包。成功后才输出 `dashboard-trollstore.ipa` 与匹配 `version.json`、构建 / 源码摘要、`SHA256SUMS`。xtool 路线另用 `dashboard-xtool.ipa` / `swift-probe.ipa` 和 `xtool-build-manifest.json`，不冒充 TrollStore 更新清单。

普通开发 / 正式签名仍须有效身份、匹配 profile / entitlements 和群组权限；ad-hoc 包不是任意 iPhone 都能安装，TrollStore 兼容范围见 <https://github.com/opa334/TrollStore>。当前 App Group、Apple 验签与安装均未验证。远程 Mac 后端还需另行确认源码外传，并显式选择 `-Mode Build -MacHost -AllowSourceUpload`；默认入口不外传、登录、重启或自动安装工具 / SDK。

## 验证边界

2026-11-10 第一阶段记录：Windows `Test` exit 0、KMP JVM **9 tests / 0 failures / 0 errors / 0 skipped**、iOS 网页桥 / 存储 / 设备 UI **21 组**、旧入口 **31 组**，以及 Android debug 与离线原生回归。旧 31 组对应当时的下载导流契约，已被新入口规则替代，不能当新预览通过证据。

2026-11-11 第二阶段有限 8 脚本：七个计数组共 **149 case groups**（4 + 4 + 6 + 15 + 16 + 90 + 14），model-smoke 原断言另通过；均为真实 JS 的离线 Node VM / linkedom / 合成 WK 检查，不是 iPhone。官方 Browser Skill / IAB 本机预览看到两种 only 标签、不可执行的系统活动按钮与 Android Widget 预览，性能资源记录未见实际 `tapi` / H5 请求。最后 changed JS 语法及 `python -I test.py` source contracts 通过；完整网页回归、发布和最终本地网页构建产物验证不在该结果内。完整计数、入口与未测项见 [验证记录](../docs/iOS能力与Windows构建.md#验证记录)。

2026-11-11 两个 xtool `XtoolBuild` 入口均在预检返回 **exit 2**：这是阻塞报告，不是 Swift 编译或构建成功。尚无 framework / IPA、Apple 验签、iPhone / iPad 安装、实际 WebKit / Keychain / 权限 / BLE / GPS / Widget / ActivityKit 或实车验收。实际 IPA 字节与设备安装占用仍待测量，不作体积、性能或 App Store 上架承诺。
