# 几何面板 iOS 壳

Swift UIKit + WKWebView 面板壳，默认从 `https://lswlc33.github.io/zeeho-3d-models/` 初始化，也可选择固定 Cloudflare 线路。网页是唯一业务 UI 与官方 API 请求签名实现；Swift 提供系统服务，[KMP 核心](../native-shared/README.md) 提供既有协议、数值与历史算法，不使用 Compose Multiplatform UI 或 Skia。IPA 不内置本轮网页快照，首次初始化需联网；后续优先加载已初始化的本地快照，构建脚本不发布网页。

账号与 `Store` 数据经 AES-GCM 私有文件及本机 Keychain 保存；轻量网页偏好使用持久 WKWebsiteDataStore，不与 Safari 或 Android 互通。WebView 铺满页面，原生安全区交给网页留白；无可用快照时先显示欢迎 / 恢复页。资产沿用网页自身发布机制，没有 Android 原生签名快照更新器。

构建目标仍是 arm64 iPhone / iPad、**iOS 15.4**。网页检查真实 `HTMLElement.inert`，参考基线为 **iOS / Safari 15.5**；只补确定性的 `findLast`，不伪造 `inert`，不能保证 15.4 可用。Live Activities 另需 **iOS 16.1+**；Widget 每实例车辆选择使用 **iOS 17+** 的 AppIntentConfiguration，旧系统沿用默认 StaticConfiguration。更高系统版本、方法存在或合成回执均不是设备验收证明。

新网页等待真实 `WKScriptMessageHandlerWithReply` 的 `hello`，按逐方法 capability 与 `NativeShell.has(method)` 启用业务，不注入同步 `ZeehoShell`。普通浏览器 / PWA 转下载页；本地回环预览、旧壳或桥自检失败进入隔离合成 UI，不保存真实账号、不请求官方 API / H5 或发送车控，原生动作显示 `unavailable`。产品平台只有 Android / iOS，平台归属只作内部渲染/执行判据、界面不展示平台标签；[功能环境标记](../docs/功能环境标记.md) 中旧归属需结合本轮[迁移验收](../docs/iOS原生兼容迁移验收.md) 阅读。

## 已接入源码与系统展示

已接入原生请求、加密事务存储、用户主动 GPS、BLE、骑行文件、前台电池 / 充电历史、文件分享、照片添加和本地通知。2026-11-13 迁移新增 `NativeShell` 中性门面：保留原网页仪表 / 编辑器 / 设置 / 记录 UI，Android 透传原同步桥，iOS 等真实 RPC。`Dashboard.swift` 安装 scope / metadata / presenter / consent provider；新增 Swift 通用 pipe 不包含车辆认证、配准、云登记或接收端配方，这些由私有 `public/js/{vehicle-wire,ios-vehicle-driver,ios-vehicle-tools}.js` 实现。原 SDK schema / KMP 的公开历史不追回，网页交付与混淆也不保证密钥绝对保密。

| 能力 / API | 已接源码与实际边界 |
|---|---|
| `wifi.status / isJoined / join / leave`、`network.open / read / write / poll / close` | 普通 Wi-Fi AP + 有界 TCP，按当前 SSID / Wi-Fi 路径及原生端口确认放行；`p2pSupported=false / legacyAPAvailability=unknown`，不保证 Wi-Fi Direct GO 兼容 |
| `asset.download.begin / zip.build.begin / poll / read / cancel`；`beginWallpaperTransfer* / wallpaperTransferAction` | 云包 / 本地实验包、准备确认与壁纸下发；16 MiB 包 / 8 MiB 单图，MD5 / ACK 不等于签名、审核或屏幕已更新 |
| `ble.open / exchange / poll / close / identity / systemPairing`；`beginInductiveSession / inductiveSessionAction` | 私有 driver 负责 BLE1 认证、遥测、2.0 配准与单次云登记；系统 bond 始终 `unknown_os_managed`，5 分钟授权窗口，`backgroundAuthRenewalSupported=false` |
| `begin / restore / pollRideRecording`、`rideRecordingAction / detachRideRecording`、`*RideRecord*`、`*GpsSpeed` | 原虚拟 / 孪生仪表、GPS / BLE 录制、保存 / 读删 / 导出；detach 不停止获准录制，锁屏 / 强退恢复与完整连续性待设备验收 |
| `cast.version / capabilities / pair / start / stop / status / setTier / diagnostics / requestProjection / forgetProfile` | ReplayKit 整屏 Broadcast extension + H264 + 私有 recipe；须系统真实确认，视频 only，不是 AirPlay / 反控；`accepted` 不等于 streaming 或车机已显示 |
| `blob.pick / poll / read / release`；`openMeterOta / meterOta.*`；`openBtDebug / btDebug.*` | 系统文件流最多 512 MiB / 单块 65536 字节；AE5I 5 寸 Gemini OTA 需两次确认，VERIFY 只展示原响应；调试逐条确认并检查当前认证 / 速度，未知音效分包不宣称完整上传 |
| `ble.scan / diagnostic.open / diagnostic.poll / diagnostic.close` | 只读 BLE2 pipe、B555 扫描及显式 UUID 选择已接入；服务 / RSSI 读取不代表 BLE2 / B360 认证、导航或音效闭环 |
| `system.surfaces.status / system.snapshot / liveActivity.* / widgets.reload`，兼容 `liveUpdate* / widgetSettings* / setWidgetSetting* / refreshWidget* / requestAddWidget / pinWidget / widgetAddStatus / notifyGroups / setNotifyGroup / syncStatus` | Live Activities / Widget 配置、读回与刷新；添加只给说明，reload 不证明显示；仅 `charge_progress` 映射充电活动，其它通知组不可用 |

其余基础 RPC 的唯一方法表在 `Bridge.swift` 与各 service 的 `methods`：`hello / store.commit / txn.request / txn.cancel / sync.session`、`gps.* / ride.* / history.*`、传统 `ble.status / scan / stopScan / connect / disconnect / services / read / subscribe / write`、文件 / 剪贴板 / 照片 / 通知 / App 信息、`panelLine*`，以及 `compat.call / compat.<method>`。通用 `ui.confirm / crypto.aes.decrypt / app.keepScreenOn` 只处理已确认会话；方法存在不替代权限、用户确认或最终回执。逐项 API、文件与四层证据见[迁移验收](../docs/iOS原生兼容迁移验收.md)。

- `Shared/` 是主 App 与 Widget extension 共用的 Swift 模块 `ZeehoSystemShared`，不是 KMP `ZeehoShared`。只共享匿名 owner、多车选择、车辆摘要、骑行 / gauge 状态与真实事件时间；token、完整账号 / VIN 和 GPS 坐标不入系统快照。Cast mailbox 与快照隔离，不共享云凭据或 Wi-Fi 密码。
- `SystemSurfaces.swift` 发布已接受的前台真实云 API 样本；`Ride.swift` 经原生确认的 GPS / BLE 录制与 gauge 事件更新已存在活动，不自动启动活动、不新增后台云轮询器。
- `Widgets/` 只有一个传统 `com.apple.widgetkit-extension` appex。普通 Widget 支持 small / medium / large；同一 `WidgetBundle` 内的 `ActivityConfiguration` 提供锁屏 / 横幅、Dynamic Island compact / minimal / expanded 布局，不使用 ExtensionKit 的 `EXAppExtensionAttributes`。
- 「我的 → iOS 系统展示」使用标准页面卡片，提供启用 / 关闭、活动开始 / 更新 / 结束及小组件刷新。执行检查真实回执、有效车辆范围、extension、App Group 与系统权限；缺能力显示 `unavailable`。公开 entitlement 模板不证明群组权限已获批准，灵动岛展示还取决于设备硬件与系统。
- 车辆数值超过 **180 秒**、骑行速度超过 **10 秒**显示过期 / 未知；重新读取或刷新不改样本时间。iOS 16.2+ 使用 `staleDate`，16.1 没有同等系统自动过期保证。Widget 实际刷新受系统预算控制，`reload_requested` 不是已显示新数据。

后台连续电量 / 完整充电采样、每日自动云任务、Android 桌面小组件、VPN 抓取、Android Wi-Fi Direct 建组与 root 增强仍只有 Android 原生实现；iOS 普通 AP 投屏与壁纸传输是另一条已接源码、未验设备的路线。iOS 可保存真实前台历史与已收到的骑行点，缺测留空；不能宣称完整连续轨迹、后台电池健康或用 GPS 推算容量。

## iOS 软件更新与面板更新

在面板或原生「版本与更新」检查软件更新，读取 `zeeho-3d-models/app/version2.json`；IPA 固定为 `app/zeehowebnext.ipa`，不请求 Android 的 `app/version.json` / APK。清单使用 [AltStore source 格式](https://faq.altstore.io/developers/make-a-source)，仅含本 App 最新版本。**App 内只提示是否有新版，不提供下载或安装入口**：发现新版时弹全屏提示（版本对比 + 更新说明 + 「我知道了」），用户自行从外部获取安装包并自签覆盖安装。线路只在首次使用时选一次，之后每次检查直接用已保存的线路；「我的 → 面板线路」仍可手动改。清单查询的 GitHub 线路可依次尝试 Pages、raw、CF，CF 专线不串外源。

进入面板时仅在前台自动检查，手动检查与自动检查共用按线路缓存的 `IOSUpdateCenter`；自动检查结果在 30 分钟内复用，网页状态刷新只读中心缓存，不是后台联网轮询。比较 iOS 版本与 build，只采纳较新的、支持当前系统的版本；App 内不下载更新包，也不做任何安装动作，`update.download` 与来源选择页已移除。HTTPS 与清单哈希不构成独立发布者签名。

「登录与账号 → 欢迎与恢复」通过 `app.recovery` 回到正常原生欢迎页，不记成启动失败、不删除账号。账号管理与面板资源分别处理：资源初始化、换线或软件检查不读写 token，快照与账号存储独立。首次、升级或启动失败可进入欢迎 / 恢复页；升级、换线、缺元数据或快照超过 24 小时会触发资源刷新，失败 / 取消保留旧快照。普通冷启动先用可用快照，过期刷新异步执行，新资源供下次进入使用；手动面板更新成功后重载当前页面，「版本与更新」也可重新初始化资源。未发布的工作树网页不会因此变成线上功能。

诊断日志记录 App build、实际加载的网页 build、桥握手与受限错误码，不记录账号参数或 token。消息按本条 JSON 的保守字节上界计入 32MiB 在途预算，不按每个方法的最大包大小预占；普通读取与偏好写入可以同时受理，真正超出预算时仍拒绝并记录大小与数量。文档加载完成后仍继续观察业务就绪，避免卡住的骨架被误判成功；原生服务未就绪时会打开可复制/分享的诊断页，也可在「版本与更新 → 查看诊断日志」主动导出。

## 构建与发布（唯一路线：公开镜像仓库 CI）

**构建只通过公开镜像仓库 [`lswlc33/zh-dashboard-ios-shell`](https://github.com/lswlc33/zh-dashboard-ios-shell) 的 GitHub Actions（macOS runner + 真实 Xcode）进行，产出 ad-hoc 签名 IPA，不是 Apple 分发签名包**。私有仓库是唯一源码来源，按白名单用 `tools/sync-public-ios.sh` 同步；公开仓库是投影，不在公开侧维护业务源码。`build.sh` 服务于这条 CI 路线，Windows 不编译 Swift 或生成 IPA。

CI 经源码契约检查、KMP framework 构建、Swift host / Shared / Widget / Broadcast 编译、真实 Widget AppIntents metadata 提取、由内到外 ad-hoc 签名与结构校验后，仅上传五个文件：`zeehowebnext.ipa`、`version2.json`、`build-manifest.json`、`source-commit.txt`、`SHA256SUMS`。不自动创建日期 pre-release，不持有产物仓库写密钥；CI 绿色或 artifact 存在不等于正式发布。本轮新增通信目标尚未同步或在 Xcode 执行；外向同步 / CI 确认未得到答复，不能当允许或拒绝。

版本与 build 唯一取自 host `Info.plist` 的 `CFBundleShortVersionString` / `CFBundleVersion`，打包时派生 Widget 同值；`--build-number` 只能断言一致，不覆盖版本，不从 CI run number 定号。每次获授权的正式迭代前，主会话核对真实已发包及烧号记录后递增两项；`1.1.0 (47)` 只是格式示例，实际版本由主发布会话定号，不继续沿用 1.0 发布新字节。

主会话用当前可信 `tools/ios-release.mjs` / helper 复验下载的五文件、私有源码与公开 CI 双 SHA、白名单输入、包版本和高水位，再只将 `app/zeehowebnext.ipa`、`app/version2.json`、`app/icon-ios-1024.png` 移交到 `zeeho-3d-models`；图标直接取获批准源码的 `public/icons/icon-ios-1024.png`，不重新绘制。不动 Android 清单 / APK，不另建私有 IPA Release 备份；命令与失败恢复见 [iOS 发布规范](../docs/发布规范.md#ios-发布规范)。

不恢复 Android CI，不出 Apple 分发签名 IPA。分发的 IPA 是 ad-hoc 自签包，需要用户自行用自签工具安装；公开 App Group entitlement 模板不代表 Apple 授权已批准。

## 验证边界

2026-11-10 第一阶段记录：Windows `Test` exit 0、KMP JVM **9 tests / 0 failures / 0 errors / 0 skipped**、iOS 网页桥 / 存储 / 设备 UI **21 组**、旧入口 **31 组**，以及 Android debug 与离线原生回归。旧 31 组对应当时的下载导流契约，已被新入口规则替代，不能当新预览通过证据。

2026-11-11 第二阶段有限 8 脚本：七个计数组共 **149 case groups**（4 + 4 + 6 + 15 + 16 + 90 + 14），model-smoke 原断言另通过；均为真实 JS 的离线 Node VM / linkedom / 合成 WK 检查，不是 iPhone。完整计数、入口与未测项见 [验证记录](../docs/iOS能力与Windows构建.md#验证记录)。

历史 CI 的 ad-hoc IPA 通过 ZIP / Mach-O / appex / 签名结构校验，不验证本轮新增目标。2026-11-13 本轮 source inventory、归档回环、桥、driver、network、BLE、ride、tools、Widget / 文件定向检查通过；审查发现另有修复回归，最后逐执行记录见[迁移验收](../docs/iOS原生兼容迁移验收.md#本轮本地执行结果)。原有 Android / 网页测试仍需单独核对，不以新增 fixture 代替。

本轮源码未为此抬版本或发布。Windows 没有 Swift / Xcode 实编，没有 iPhone 接车、锁屏 / 强退恢复、Cast / Widget / Live Activity 实际显示或热点 entitlement 验证；Apple 编译、metadata、安装、真实 WebKit / Keychain / 权限 / BLE / GPS / App Group 与实车效果均待验。源码与离线通过不能代替这些验证。
