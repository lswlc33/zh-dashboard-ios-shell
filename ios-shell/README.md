# 几何面板 iOS 壳

Swift UIKit + WKWebView 面板壳，默认从 `https://lswlc33.github.io/zeeho-3d-models/` 加载，也可选择固定 Cloudflare 线路。网页是 App 内唯一业务 UI 与官方 API 请求签名实现；Swift 提供系统服务，[KMP 核心](../native-shared/README.md) 提供协议、数值与历史算法，不使用 Compose Multiplatform UI 或 Skia。IPA 不内置本轮网页快照，首次初始化需联网；构建脚本不发布网页。

账号与 `Store` 数据经 AES-GCM 私有文件及本机 Keychain 保存；轻量网页偏好使用持久 WKWebsiteDataStore，不与 Safari 或 Android 互通。WebView 铺满页面，网页按原生 safeArea 留白；需要初始化资源时先显示原生欢迎页。资产沿用网页自身发布机制，没有 Android 原生签名快照更新器。

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

在面板或原生「版本与更新」检查软件更新，读取 `zeeho-3d-models/app/version2.json`；IPA 固定为 `app/zeehowebnext.ipa`，不请求 Android 的 `app/version.json` / APK。清单使用 [AltStore source 格式](https://faq.altstore.io/developers/make-a-source)，仅含本 App 最新版本；简介注明官方产物 / 公开 iOS 源码仓库与 TrollStore ad-hoc 现状，不表示 AltStore 重签安装已验收。GitHub 线路的下载来源有 GitHub Pages、ghfast、ghproxy、raw、jsDelivr、Cloudflare 六项；CF 专线仅有 Cloudflare。来源页显示 HEAD 响应头延迟，不是下载速率；用户点击才选定 source，下载失败明确报错，不暗中换源。清单查询的 GitHub 线路可依次尝试 Pages、raw、CF，CF 专线不串外源。

进入面板时仅在前台自动检查，手动检查与自动检查共用按线路缓存的 `IOSUpdateCenter`；自动检查结果在 30 分钟内复用，网页状态刷新只读中心缓存，不是后台联网轮询。比较 iOS 版本与 build，只提供较新的、支持当前系统的包；IPA 最多 30 MiB，下载后核对大小与 SHA-256。通过后打开系统 `UIActivityViewController`，由用户选择 TrollStore 并确认覆盖安装；分享回执不是安装成功，也不是静默安装。HTTPS 与清单哈希不构成独立发布者签名。

「登录与账号 → 欢迎与恢复」通过 `app.recovery` 回到正常原生欢迎页，不记成启动失败、不删除账号。账号管理与面板资源分别处理：资源初始化、换线或软件检查不读写 token，快照与账号存储独立。首次、升级或启动失败可进入欢迎 / 恢复页；升级、换线、缺元数据或快照超过 24 小时会触发资源刷新，失败 / 取消保留旧快照。普通冷启动先用可用快照，过期刷新异步执行，新资源供下次进入使用；手动面板更新成功后重载当前页面，「版本与更新」也可重新初始化资源。未发布的工作树网页不会因此变成线上功能。

诊断日志记录 App build、实际加载的网页 build、桥握手与受限错误码，不记录账号参数或 token。消息按本条 JSON 的保守字节上界计入 32MiB 在途预算，不按每个方法的最大包大小预占；普通读取与偏好写入可以同时受理，真正超出预算时仍拒绝并记录大小与数量。文档加载完成后仍继续观察业务就绪，避免卡住的骨架被误判成功；原生服务未就绪时会打开可复制/分享的诊断页，也可在「版本与更新 → 查看诊断日志」主动导出。

## 构建与发布（唯一路线：公开镜像仓库 CI）

**构建只通过公开镜像仓库 [`lswlc33/zh-dashboard-ios-shell`](https://github.com/lswlc33/zh-dashboard-ios-shell) 的 GitHub Actions（macOS runner + 真实 Xcode）进行，产出 ad-hoc 签名 IPA，不是 Apple 分发签名包**。私有仓库是唯一源码来源，按白名单用 `tools/sync-public-ios.sh` 同步；公开仓库是投影，不在公开侧维护业务源码。`build.sh` 服务于这条 CI 路线，Windows 不编译 Swift 或生成 IPA。

CI 经源码契约检查、KMP framework 构建、Swift host / Shared / Widget 编译、由内到外 ad-hoc 签名与结构校验后，仅上传五个文件：`zeehowebnext.ipa`、`version2.json`、`build-manifest.json`、`source-commit.txt`、`SHA256SUMS`。不自动创建日期 pre-release，不持有产物仓库写密钥；CI 绿色或 artifact 存在不等于正式发布。

版本与 build 唯一取自 host `Info.plist` 的 `CFBundleShortVersionString` / `CFBundleVersion`，打包时派生 Widget 同值；`--build-number` 只能断言一致，不覆盖版本，不从 CI run number 定号。每次获授权的正式迭代前，主会话核对真实已发包及烧号记录后递增两项；`1.1.0 (47)` 只是格式示例，实际版本由主发布会话定号，不继续沿用 1.0 发布新字节。

主会话用当前可信 `tools/ios-release.mjs` / helper 复验下载的五文件、私有源码与公开 CI 双 SHA、白名单输入、包版本和高水位，再只将 `app/zeehowebnext.ipa`、`app/version2.json`、`app/icon-ios-1024.png` 移交到 `zeeho-3d-models`；图标直接取获批准源码的 `public/icons/icon-ios-1024.png`，不重新绘制。不动 Android 清单 / APK，不另建私有 IPA Release 备份；命令与失败恢复见 [iOS 发布规范](../docs/发布规范.md#ios-发布规范)。

不恢复 Android CI，不出 Apple 分发签名 IPA；TrollStore 侧载是安装路线，兼容范围见 <https://github.com/opa334/TrollStore>。公开 App Group entitlement 模板不代表 Apple 授权已批准。

## 验证边界

2026-11-10 第一阶段记录：Windows `Test` exit 0、KMP JVM **9 tests / 0 failures / 0 errors / 0 skipped**、iOS 网页桥 / 存储 / 设备 UI **21 组**、旧入口 **31 组**，以及 Android debug 与离线原生回归。旧 31 组对应当时的下载导流契约，已被新入口规则替代，不能当新预览通过证据。

2026-11-11 第二阶段有限 8 脚本：七个计数组共 **149 case groups**（4 + 4 + 6 + 15 + 16 + 90 + 14），model-smoke 原断言另通过；均为真实 JS 的离线 Node VM / linkedom / 合成 WK 检查，不是 iPhone。完整计数、入口与未测项见 [验证记录](../docs/iOS能力与Windows构建.md#验证记录)。

CI 出的 ad-hoc IPA 通过了 ZIP / Mach-O / appex / 签名结构校验，但 Apple 加密验签、iPhone / iPad 安装、实际 WebKit / Keychain / 权限 / BLE / GPS / Widget / ActivityKit 或实车验收仍以真机记录为准；离线与 CI 检查不能代替。
