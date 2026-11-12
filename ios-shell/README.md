# 几何面板 iOS 壳

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

顶部“软件更新”读取官方仓库 Release 的机器可读清单（`releaseFromGitHubAPI`），不请求 Android 版本或 APK。IPA 使用 ghfast、gh-proxy、GitHub raw、jsDelivr、Pages 镜像下载。镜像失败、旧缓存或校验不符会换源，第三方镜像不提供可信版本清单。

启动自动检查，也可手动检查；比较 iOS 版本与 build，拒绝降级及不支持当前系统的包。下载后核对大小和 SHA-256，再交系统分享菜单，由用户选择 TrollStore 并确认覆盖安装，不是静默安装。初始信任依赖固定官方 HTTPS，SHA-256 是完整性校验，不是独立发布者签名。

顶部“刷新面板”重新加载在线网页，不能把本工作树未发布的页面变成线上功能。保持原 Bundle ID 的覆盖安装可延用原 App 网页空间，不迁移 Safari 数据。

## 构建与发布（唯一路线：公开镜像仓库 CI）

**构建只通过公开镜像仓库 [`lswlc33/zh-dashboard-ios-shell`](https://github.com/lswlc33/zh-dashboard-ios-shell) 的 GitHub Actions（macOS runner + 真实 Xcode）进行，只产出未签名（ad-hoc）IPA**，发布到该仓库的 Release。私有仓库（本仓库）是唯一源码来源，按白名单用 `tools/sync-public-ios.sh` 同步过去；公开仓库永远是投影，不在公开侧改代码。本仓库不再包含本地 Apple 构建入口，`build.sh` 只服务于 CI。

CI 流程（`.github/workflows/build-ios.yml`）：源码契约检查（`python3 -I ios-shell/test.py`）→ Gradle 出 KMP framework → swiftc 编译 host / Shared / Widget appex → ad-hoc 由内到外签名 → 结构校验 → 发 Release（版本 / build / SHA-256 / sourceTreeSha256 记进 Release notes，`Update.swift` 解析）。

不恢复本地 CI，不出正式签名的 IPA；TrollStore 侧载是唯一安装途径，兼容范围见 <https://github.com/opa334/TrollStore>。公开 App Group entitlement 模板不代表 Apple 授权已批准。

## 验证边界

2026-11-10 第一阶段记录：Windows `Test` exit 0、KMP JVM **9 tests / 0 failures / 0 errors / 0 skipped**、iOS 网页桥 / 存储 / 设备 UI **21 组**、旧入口 **31 组**，以及 Android debug 与离线原生回归。旧 31 组对应当时的下载导流契约，已被新入口规则替代，不能当新预览通过证据。

2026-11-11 第二阶段有限 8 脚本：七个计数组共 **149 case groups**（4 + 4 + 6 + 15 + 16 + 90 + 14），model-smoke 原断言另通过；均为真实 JS 的离线 Node VM / linkedom / 合成 WK 检查，不是 iPhone。完整计数、入口与未测项见 [验证记录](../docs/iOS能力与Windows构建.md#验证记录)。

CI 出的 ad-hoc IPA 通过了 ZIP / Mach-O / appex / 签名结构校验，但 Apple 加密验签、iPhone / iPad 安装、实际 WebKit / Keychain / 权限 / BLE / GPS / Widget / ActivityKit 或实车验收仍以真机记录为准；离线与 CI 检查不能代替。
