# zh-dashboard-ios-shell

几何面板（极核面板）的 iOS 壳源码，用于真实 Xcode 构建 **ad-hoc 签名 IPA**，供 TrollStore 侧载安装。

## 这是什么

Swift UIKit + WKWebView 壳，配合 Kotlin Multiplatform 共享协议层。网页负责业务界面与官方 API 签名，原生壳提供系统能力（Keychain 存储、网络代发、CoreBluetooth、CoreLocation、文件与通知）。

- `ios-shell/` — Swift 壳、WidgetKit 扩展、构建脚本
- `native-shared/` — KMP 协议与算法核心（BLE 帧编解码、电池采样、充电账本、原始字节 HTTP 代发）
- `public/icons/` — 仅应用图标

## 产物

GitHub Actions 在 macOS runner 上构建并上传五文件 artifact，由发布会话独立核对源码指纹和真实 IPA 后移交到[官方产物源仓库](https://github.com/lswlc33/zeeho-3d-models)。正式更新源是 [`app/version2.json`](https://lswlc33.github.io/zeeho-3d-models/app/version2.json)，采用 [AltStore 官方源格式](https://faq.altstore.io/developers/make-a-source)，只保留一个 App 和最新版；图标、名称与可换行介绍使用官方字段。

| 项 | 说明 |
|---|---|
| 文件名 | `app/zeehowebnext.ipa` |
| 签名 | **ad-hoc**（`codesign --sign -`），无证书、无 provisioning profile |
| 用途 | TrollStore 侧载，由用户确认覆盖安装，不静默安装 |
| 尚未验证 | AltStore 重签安装与设备上的 App Group 授权 |
| 不适用 | App Store、TestFlight |

软件版本与 build 由 `ios-shell/Info.plist` 唯一维护，每次正式迭代递增，CI 运行次数不作软件版本。构建报告记录 `sourceTreeSha256` 与公开仓库 commit，正式发布不上传这些诊断边车文件。

## 自行构建

需要完整 Xcode（非仅 Command Line Tools）、JDK 21、Python 3.9+：

```bash
bash ios-shell/build.sh --output-dir /tmp/zeeho-ios-out
# 产物：/tmp/zeeho-ios-out/zeehowebnext.ipa 与 version2.json、构建报告等
```

`build.sh` 会先用 Gradle 生成 `ZeehoShared` framework，再编译 Swift host 与 Widget 扩展，由内到外 ad-hoc 签名并做结构校验；失败不会写出替代包。

## 边界说明

- **不是完整客户端**：面板网页不在本仓库，运行时由壳加载线上页面。
- **没有凭据**：仓库不含任何客户端密钥、账号数据或签名证书。
- **平台能力差异**：iOS 不支持 Android 的后台常驻采样、Wi-Fi Direct 投屏、桌面小组件与 root 增强；这些入口在网页侧标为 `Android only`。
- **iOS 系统展示**：WidgetKit 与 Live Activities 需要 App Group 授权与真实签名配置，ad-hoc 包不保证这些能力可用。
- **最低系统**：壳 target 为 iOS 15.4；网页侧检查真实 `inert`，参考基线为 15.5。Live Activities 另需 16.1+。

## 源码来源

本仓库是私有仓库的白名单投影，单向同步，不接受直接修改。同步脚本在私有仓库 `tools/sync-public-ios.sh`，会做脱敏自检（拒绝任何客户端密钥标识符）与私有路径检查。

## 许可

源码仅供学习与个人设备使用。极核（CFMOTO ZEEHO）相关商标与接口归属其所有者。
