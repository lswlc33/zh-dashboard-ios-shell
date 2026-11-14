#!/bin/bash
# 只在真实 macOS/Xcode 上出包；Windows/缺失 KMP 框架时绝不生成占位 IPA。
#
# host Info.plist 是 version/build 的唯一来源；CI run_number 只能写日志。
# --build-number 只作为显式一致性断言，不能覆盖正式产物的 CFBundleVersion。
set -euo pipefail
script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
repo_dir="$(CDPATH= cd -- "$script_dir/.." && pwd -P)"
shared_dir="$repo_dir/native-shared"
support="$script_dir/build-support.py"
# 默认输出目录带 UTC 时间戳：默认固定 `dist/` 时第二次构建必被
# validate_output_directory 的 OUTPUT_ARTIFACT_EXISTS 拦下，README 里的
# `bash ios-shell/build.sh` 就只能成功一次。也可以用 --output-dir 自己指定。
output_dir=''
source_manifest=''
build_number=''
preflight_only=false
offline=false

usage() {
    printf '%s\n' 'Usage: build.sh [--preflight-only] [--build-number POSITIVE_INTEGER] [--output-dir DIR] [--source-manifest FILE] [--offline]'
    printf '%s\n' 'Default version/build come from ios-shell/Info.plist; --build-number must equal that plist. Default output is ios-shell/dist/<UTC timestamp>.'
    printf '%s\n' 'Output is ad-hoc signed with scoped App Group/HotspotConfiguration/wifi-info templates; Apple provisioning approval and TrollStore compatibility are not verified. Ordinary Apple installation needs matching identities/profiles for Host, Widget and Broadcast plus inside-out signing.'
}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --preflight-only) preflight_only=true; shift ;;
        --offline) offline=true; shift ;;
        --build-number|--output-dir|--source-manifest)
            [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 2; }
            case "$1" in
                --build-number) build_number="$2" ;;
                --output-dir) output_dir="$2" ;;
                --source-manifest) source_manifest="$2" ;;
            esac
            shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done
# 默认输出目录带 UTC 时间戳：如果固定用 `ios-shell/dist`，第二次构建就会被
# validate_output_directory 的 OUTPUT_ARTIFACT_EXISTS 拦下（它会拒绝覆盖已存在产物），
# README 里给的 `bash ios-shell/build.sh` 于是只能成功一次。
# 想固定路径就用 --output-dir 显式指定一个空目录。
if [[ -z "$output_dir" ]]; then output_dir="$script_dir/dist/$(date -u +%Y%m%d-%H%M%S)"; fi
[[ "$output_dir" = /* ]] || output_dir="$PWD/$output_dir"
# 先读唯一版本源；即使显式传参，也只能与 host 一致，浅克隆不再影响版本。
if command -v python3 >/dev/null 2>&1; then
    version_args=(build-number --source "$script_dir/Info.plist")
    if [[ -n "$build_number" ]]; then version_args+=(--build-number "$build_number"); fi
    build_number="$(python3 -I "$support" "${version_args[@]}")"
    python3 -I "$support" output-check --root "$repo_dir" --output "$output_dir" >/dev/null
fi
if [[ -n "$source_manifest" && "$source_manifest" != /* ]]; then source_manifest="$PWD/$source_manifest"; fi
if [[ ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s\n' 'BLOCKED: build number must be a positive integer.' >&2
    exit 2
fi

missing=()
[[ "$(uname -s)" == Darwin ]] || missing+=('macOS (Darwin) for this Xcode backend')
for tool in bash python3 java git xcrun xcodebuild codesign plutil zip sips file; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
[[ -x /usr/libexec/PlistBuddy ]] || missing+=('/usr/libexec/PlistBuddy')
[[ -f "$shared_dir/gradlew" ]] || missing+=('native-shared/gradlew (a real Gradle wrapper is required; no substitute is generated)')
[[ -f "$shared_dir/gradle/wrapper/gradle-wrapper.jar" ]] || missing+=('native-shared/gradle/wrapper/gradle-wrapper.jar')
[[ -f "$script_dir/bridge-bootstrap.js" ]] || missing+=('ios-shell/bridge-bootstrap.js')
if [[ "$(uname -s)" == Darwin ]] && command -v xcrun >/dev/null 2>&1; then
    xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1 || missing+=('iPhoneOS SDK (full Xcode, not only Command Line Tools)')
    for tool in swiftc swift-stdlib-tool lipo otool nm; do
        xcrun --sdk iphoneos --find "$tool" >/dev/null 2>&1 || missing+=("Xcode $tool")
    done
    xcodebuild -version >/dev/null 2>&1 || missing+=('usable Xcode license/first-launch setup; prepare it manually')
fi
if [[ ${#missing[@]} -gt 0 ]]; then
    printf '%s\n' 'BLOCKED: no local Apple build is possible. Missing requirements:' >&2
    printf '  - %s\n' "${missing[@]}" >&2
    printf '%s\n' 'No IPA was generated; no tools were installed and no remote build was started.' >&2
    exit 2
fi
python3 -I -c 'import sys; assert sys.version_info >= (3, 9), "Python 3.9+ required"'
java_version="$(java -version 2>&1)"
if [[ ! "$java_version" =~ version\ \"21[.\"] ]]; then
    printf '%s\n' 'BLOCKED: JDK 21 is required. Set JAVA_HOME to your existing JDK; this script does not install it.' >&2
    exit 2
fi
input_args=(--root "$repo_dir")
if [[ -n "$source_manifest" ]]; then input_args+=(--source-manifest "$source_manifest"); fi
# 只读检查源码、框架契约与传入的上传快照，不创建 build/dist，也不调用 Gradle。
if [[ "$preflight_only" == true ]]; then
    python3 -I "$support" inputs "${input_args[@]}"
    printf '%s\n' 'Preflight passed. No compilation, signing, dependency download or upload was performed.'
    exit 0
fi

build_dir="$(mktemp -d "${TMPDIR:-/tmp}/zeeho-ios-build.XXXXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
app_dir="$build_dir/Payload/Dashboard.app"
staged_dist="$build_dir/artifacts"
widget_dir="$app_dir/PlugIns/DashboardWidgets.appex"
broadcast_dir="$app_dir/PlugIns/ZeehoCastBroadcast.appex"
mkdir -p "$app_dir/Frameworks" "$widget_dir/Frameworks" "$broadcast_dir/Frameworks" "$staged_dist"
inputs="$build_dir/build-inputs.json"
# Host frameworks 合并 Host + Shared imports；Broadcast 单独清单，不链接 Bridge/KMP/Widget shared object。
python3 -I "$support" inputs "${input_args[@]}" --manifest "$inputs" \
    --swift-list "$build_dir/swift-sources.txt" --shared-list "$build_dir/shared-sources.txt" --widget-list "$build_dir/widget-sources.txt" \
    --broadcast-list "$build_dir/broadcast-sources.txt" --host-module-imports-list "$build_dir/host-module-imports.txt" \
    --framework-list "$build_dir/frameworks.txt" --library-list "$build_dir/libraries.txt" \
    --widget-framework-list "$build_dir/widget-frameworks.txt" \
    --broadcast-framework-list "$build_dir/broadcast-frameworks.txt" --broadcast-library-list "$build_dir/broadcast-libraries.txt"

# 两个短例子各自独立判断：上传白名单本来就不带 *-test.swift，远程 Mac 上一定缺失，
# 拆开打印「已跳过（缺 X）」比原来静默跳过更容易看出测试根本没跑。
if [[ -f "$script_dir/navigation-test.swift" ]]; then
    xcrun swiftc "$script_dir/Navigation.swift" "$script_dir/navigation-test.swift" -o "$build_dir/navigation-test"
    "$build_dir/navigation-test"
else
    printf '%s\n' 'note: navigation-test 已跳过（缺 ios-shell/navigation-test.swift，上传快照不含 *-test.swift）'
fi
if [[ -f "$script_dir/update-test.swift" ]]; then
    xcrun swiftc "$script_dir/Update.swift" "$script_dir/IOSStrings.swift" "$script_dir/PanelLine.swift" "$script_dir/Navigation.swift" "$script_dir/update-test.swift" -o "$build_dir/update-test"
    "$build_dir/update-test"
else
    printf '%s\n' 'note: update-test 已跳过（缺 ios-shell/update-test.swift，上传快照不含 *-test.swift）'
fi

if [[ -f "$script_dir/panel-cache-policy-test.swift" ]]; then
    xcrun swiftc "$script_dir/PanelCachePolicy.swift" "$script_dir/panel-cache-policy-test.swift" -o "$build_dir/panel-cache-policy-test"
    "$build_dir/panel-cache-policy-test"
else
    printf '%s\n' 'note: panel-cache-policy-test 已跳过（缺 ios-shell/panel-cache-policy-test.swift）'
fi

if [[ -f "$script_dir/bridge-budget-test.swift" ]]; then
    xcrun swiftc "$script_dir/BridgeBudget.swift" "$script_dir/bridge-budget-test.swift" -o "$build_dir/bridge-budget-test"
    "$build_dir/bridge-budget-test"
else
    printf '%s\n' 'note: bridge-budget-test 已跳过（缺 ios-shell/bridge-budget-test.swift）'
fi

gradle_args=(--project-dir "$shared_dir" --no-daemon --console=plain)
if [[ "$offline" == true ]]; then gradle_args+=(--offline); fi
# 原样传播 KMP 编译/链接失败；不捕获成成功，也不使用 canImport 假回退。
bash "$shared_dir/gradlew" "${gradle_args[@]}" :linkReleaseFrameworkIosArm64
shared_framework="$shared_dir/build/bin/iosArm64/releaseFramework/ZeehoShared.framework"
shared_kind="$(python3 -I "$support" framework-kind --path "$shared_framework")"

sdk_path="$(xcrun --sdk iphoneos --show-sdk-path)"
swift_sources=()
shared_sources=()
widget_sources=()
broadcast_sources=()
while IFS= read -r path; do swift_sources+=("$repo_dir/$path"); done < "$build_dir/swift-sources.txt"
while IFS= read -r path; do shared_sources+=("$repo_dir/$path"); done < "$build_dir/shared-sources.txt"
while IFS= read -r path; do widget_sources+=("$repo_dir/$path"); done < "$build_dir/widget-sources.txt"
while IFS= read -r path; do broadcast_sources+=("$repo_dir/$path"); done < "$build_dir/broadcast-sources.txt"
# 根业务源只入 host；Shared 独立 module/static object，两端链接、不嵌入假 framework。
activity_args=(-Xlinker -weak_framework -Xlinker ActivityKit)
xcrun --sdk iphoneos swiftc -O -swift-version 5 -parse-as-library -whole-module-optimization -application-extension \
    -target arm64-apple-ios15.4 -sdk "$sdk_path" -module-name ZeehoSystemShared \
    -emit-module -emit-module-path "$build_dir/ZeehoSystemShared.swiftmodule" -emit-object \
    "${shared_sources[@]}" -o "$build_dir/ZeehoSystemShared.o"
link_args=(-I "$build_dir" "$build_dir/ZeehoSystemShared.o" "${activity_args[@]}" -F "$(dirname -- "$shared_framework")" -framework ZeehoShared -lc++ -Xlinker -ObjC -Xlinker -rpath -Xlinker '@executable_path/Frameworks' -Xlinker -rpath -Xlinker /usr/lib/swift)
while IFS= read -r module; do
    [[ -d "$sdk_path/System/Library/Frameworks/$module.framework" ]] || { printf 'BLOCKED: imported SDK framework missing: %s\n' "$module" >&2; exit 2; }
    [[ "$module" == ActivityKit ]] || link_args+=(-framework "$module")
done < "$build_dir/frameworks.txt"
while IFS= read -r library; do link_args+=("-l$library"); done < "$build_dir/libraries.txt"
xcrun --sdk iphoneos swiftc -O -swift-version 5 -parse-as-library \
    -target arm64-apple-ios15.4 -sdk "$sdk_path" -module-name Dashboard \
    "${link_args[@]}" "${swift_sources[@]}" -o "$app_dir/Dashboard"
widget_args=(-I "$build_dir" "$build_dir/ZeehoSystemShared.o" "${activity_args[@]}" -framework Foundation \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -Xlinker -rpath -Xlinker '@executable_path/../../Frameworks' \
    -Xlinker -rpath -Xlinker '@executable_path/Frameworks' -Xlinker -rpath -Xlinker /usr/lib/swift)
while IFS= read -r module; do
    [[ -d "$sdk_path/System/Library/Frameworks/$module.framework" ]] || { printf 'BLOCKED: imported Widget SDK framework missing: %s\n' "$module" >&2; exit 2; }
    # WidgetKit 提供 Widget / WidgetConfiguration 协议，必须真实链接。
    [[ "$module" == ActivityKit || "$module" == AppIntents ]] || widget_args+=(-framework "$module")
done < "$build_dir/widget-frameworks.txt"
# 小组件用 AppIntents 做车控/刷新按钮：iOS 只从各 bundle 的 Metadata.appintents
# 索引里找 intent，缺了索引点按钮会静默无效（真机日志 linkd Missing: <bundle>:<Type>）。
# 手写 swiftc 流程必须自己产 metadata：
#   1) 编译时用 -emit-const-values-path 导出 .swiftconstvalues
#   2) 链接后用 appintentsmetadataprocessor 对 appex 与 app 各生成一份（见下方 metadata 段）
#   3) 生成后再签名（保证索引进签名封条）
# AppIntents 是按钮点击的执行入口，必须真实链接、不能当可选弱依赖。
# 弱链接：deployment target 仍是 15.4，强链接 iOS 16+ 框架会让老系统 dyld 崩。
# 与 ActivityKit 同样处理；真正用到 AppIntents 的地方都做了 #available 分支。
widget_args+=(-Xlinker -weak_framework -Xlinker AppIntents)
# AppIntents const-values：processor 的输入。
#
# swiftc 只在同时给了协议清单时才真的提取（源码里 emitConstValues 的
# 「ConstGatherProtocolListFilePath 为空就直接 return」），否则文件是空的，
# processor 报 "No swift const values found" 并跳过写索引，按钮就点不动。
# 协议清单必须是**裸 JSON 数组**、元素是**不带模块前缀**的协议名
# （Xcode 自己那份是 wrapper dict，前端会拒绝）。
widget_const_values="$build_dir/DashboardWidgets.swiftconstvalues"
const_protocols="$build_dir/const_extract_protocols.json"
cat > "$const_protocols" <<'ZEEHO_PROTOCOLS'
["AppIntent","EntityQuery","AppEntity","EntityStringQuery","TransientEntity","AppEnum","AppShortcutProviding","AppShortcutsProvider","AnyResolverProviding","AppIntentsPackage","DynamicOptionsProvider","OpenIntent","_IntentValueRepresentable","_AssistantIntentsProvider","_GenerativeFunctionExtractable","IntentValueQuery","Resolver"]
ZEEHO_PROTOCOLS
# -wmo 保证整模块只产出一个 const-values 文件（非 wmo 下每个 primary 各要一个路径）。
xcrun --sdk iphoneos swiftc -O -wmo -swift-version 5 -parse-as-library -application-extension \
    -target arm64-apple-ios15.4 -sdk "$sdk_path" -module-name DashboardWidgets \
    -emit-const-values -emit-const-values-path "$widget_const_values" \
    -Xfrontend -const-gather-protocols-file -Xfrontend "$const_protocols" \
    "${widget_args[@]}" "${widget_sources[@]}" -o "$widget_dir/DashboardWidgets"
# 空 const-values 必须当场报错：否则一路走到 processor 才失败，日志里只有一句
# "No swift const values found"，看不出是协议清单没生效。
python3 -I - "$widget_const_values" <<'ZEEHO_CHECKCV'
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception as error:
    sys.exit("BLOCKED: 读不出 const-values: %s" % error)
if not isinstance(data, list) or not data:
    sys.exit("BLOCKED: const-values 为空，AppIntents 索引会缺失（检查协议清单是否为裸 JSON 数组）")
ZEEHO_CHECKCV

# ReplayKit 的标准 upload extension 仍由 _NSExtensionMain 进入 NSObject 子类 SampleHandler。
# -framework ReplayKit 提供真实 API/入口依赖；不发明 _appexentry，也不复用 host main。
# module-name 必须与展开后的 NSExtensionPrincipalClass 完全一致。
broadcast_args=(-framework Foundation -framework ReplayKit -Xlinker -ObjC \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -Xlinker -rpath -Xlinker '@executable_path/../../Frameworks' \
    -Xlinker -rpath -Xlinker '@executable_path/Frameworks' -Xlinker -rpath -Xlinker /usr/lib/swift)
while IFS= read -r module; do
    [[ -d "$sdk_path/System/Library/Frameworks/$module.framework" ]] || { printf 'BLOCKED: imported Broadcast SDK framework missing: %s\n' "$module" >&2; exit 2; }
    [[ "$module" == Foundation || "$module" == ReplayKit ]] || broadcast_args+=(-framework "$module")
done < "$build_dir/broadcast-frameworks.txt"
while IFS= read -r library; do broadcast_args+=("-l$library"); done < "$build_dir/broadcast-libraries.txt"
xcrun --sdk iphoneos swiftc -O -swift-version 5 -parse-as-library -application-extension \
    -target arm64-apple-ios15.4 -sdk "$sdk_path" -module-name ZeehoCastBroadcast \
    "${broadcast_args[@]}" "${broadcast_sources[@]}" -o "$broadcast_dir/ZeehoCastBroadcast"

plist_args=(--source "$script_dir/Info.plist" --destination "$app_dir/Info.plist")
if [[ -n "$build_number" ]]; then plist_args+=(--build-number "$build_number"); fi
python3 -I "$support" prepare-plist "${plist_args[@]}"
python3 -I "$support" prepare-widget --source "$script_dir/Widgets/Info.plist" \
    --host-info "$app_dir/Info.plist" --destination "$widget_dir/Info.plist"
python3 -I "$support" prepare-extension --target broadcast --source "$script_dir/Broadcast/Info.plist" \
    --host-info "$app_dir/Info.plist" --destination "$broadcast_dir/Info.plist"
# Widget 只用 StaticConfiguration，不再有 AppIntents 配置需要提取 metadata。
xcrun nm -g "$broadcast_dir/ZeehoCastBroadcast" | grep 'SampleHandler'
cp "$script_dir/bridge-bootstrap.js" "$app_dir/bridge-bootstrap.js"
# 桌面显示名本地化：Info.plist 的 CFBundleDisplayName 基础值必须是纯 ASCII
# （AltStore/SideStore 用它向 Apple 门户注册 App-ID，中文会被拒成 3009），
# 中文名由 zh-Hans.lproj/InfoPlist.strings 提供，SpringBoard 按键本地化取到。
[[ -f "$script_dir/zh-Hans.lproj/InfoPlist.strings" ]] || {
    printf 'BLOCKED: missing zh-Hans.lproj/InfoPlist.strings（桌面中文名来源）\n' >&2; exit 2; }
mkdir -p "$app_dir/zh-Hans.lproj"
cp "$script_dir/zh-Hans.lproj/InfoPlist.strings" "$app_dir/zh-Hans.lproj/InfoPlist.strings"
# iOS 自己会给 App 图标切圆角，源图必须是「满出血」的正方形：
# 用普通 icon-512.png 会在四角留透明区（iOS 底下衬白/黑底 → 四角白边），
# 而且图中自带的圆角会和系统圆角叠成双层。
# icon-ios-1024.png 由 tools/make-icons.mjs 的 ios 模式产出：radius=0、内容满幅，
# 取景与安卓 App 图标一致（普通图标是 radius=0.28，maskable 是内容缩 80%，都不合适）。
icon_source="$repo_dir/public/icons/icon-ios-1024.png"
[[ -f "$icon_source" ]] || { printf 'BLOCKED: missing iOS icon source: %s\n' "$icon_source" >&2; exit 2; }
for size in 120 152 167 180; do
    sips -z "$size" "$size" "$icon_source" --out "$app_dir/Icon${size}.png" >/dev/null
done
if [[ "$shared_kind" == dynamic ]]; then
    cp -R "$shared_framework" "$app_dir/Frameworks/ZeehoShared.framework"
fi

# 由 Xcode 扫描真实 executable/framework imports；需要的 Swift compatibility dylib 必须带齐。
# 不按估计大小省略运行时。失败即阻塞，额外库按实际目标切薄 arm64 再签名。
#
# --filter-for-swift-os 在部分 Xcode（实测 16.4）的 swift-stdlib-tool 里不存在，传了会直接
# "Unknown argument" 退出。deployment target 15.4 高于 Swift ABI 稳定线（iOS 12.2），
# 设备自带 Swift 运行时，通常没有库要拷；所以这里做参数探测：支持就带上，不支持就跳过，
# 剩下的兼容性 dylib 仍由下面的扫描 + 签名循环兜住。
#
# 探测写法有两个坑：
#   1. `--help | grep -q` 在 `set -o pipefail` 下，grep 命中后提前退出会让左边拿到
#      SIGPIPE（141），整条管道被判失败 → 明明支持却走 else；
#   2. `2>&1` 必须写在管道左侧，否则 swift-stdlib-tool 的 stderr 不进管道。
# 所以把输出先收进变量，再用 `|| true` 兜住 grep 的退出码。
stdlib_help="$(xcrun --sdk iphoneos swift-stdlib-tool --help 2>&1 || true)"
stdlib_args=(--copy --platform iphoneos
    --scan-executable "$app_dir/Dashboard" --scan-executable "$widget_dir/DashboardWidgets"
    --scan-executable "$broadcast_dir/ZeehoCastBroadcast"
    --scan-folder "$app_dir/Frameworks" --scan-folder "$widget_dir/Frameworks" --scan-folder "$broadcast_dir/Frameworks"
    --destination "$app_dir/Frameworks")
if printf '%s\n' "$stdlib_help" | grep -q -- '--filter-for-swift-os'; then
    stdlib_args+=(--filter-for-swift-os)
else
    printf 'note: swift-stdlib-tool 不支持 --filter-for-swift-os，跳过该过滤（deployment target 15.4 自带运行时）\n'
fi
xcrun --sdk iphoneos swift-stdlib-tool "${stdlib_args[@]}"
while IFS= read -r -d '' dylib; do
    architectures="$(xcrun lipo -archs "$dylib")"
    if [[ "$architectures" != arm64 ]]; then
        xcrun lipo "$dylib" -thin arm64 -output "$dylib.arm64"
        mv "$dylib.arm64" "$dylib"
    fi
    codesign --force --sign - --timestamp=none "$dylib"
    codesign --verify --strict "$dylib"
done < <(find "$app_dir/Frameworks" "$widget_dir/Frameworks" "$broadcast_dir/Frameworks" -type f -name '*.dylib' -print0)
# 所有 framework 同样由内到外签名，不限于 KMP；允许的实际嵌入范围仍由 validate_ipa 严格核对。
while IFS= read -r -d '' framework; do
    codesign --force --sign - --timestamp=none "$framework"
    codesign --verify --strict "$framework"
done < <(find "$app_dir/Frameworks" "$widget_dir/Frameworks" "$broadcast_dir/Frameworks" -depth -type d -name '*.framework' -print0)
# AppIntents metadata：小组件上的车控/刷新按钮靠它才生效。
#
# 手写 swiftc 流程不会自动生成，必须自己跑 Xcode 内的 appintentsmetadataprocessor。
# 缺了索引的真机表现是「按钮点了毫无反应」，日志里是 linkd Missing: <bundle>:<Type>，
# 不崩溃也不报错，所以这里是硬闸门：工具缺失或索引没落地都直接 BLOCKED。
#
# 不给 --swift-const-vals-list：那需要 Xcode 自己的协议清单，手写流程拿不到，
# 传空文件反而可能产出结构合法但 actions 为空的索引。改让 processor 扫源码。
metadata_tool="$(xcrun --find appintentsmetadataprocessor 2>/dev/null || true)"
if [ -z "$metadata_tool" ] || [ ! -x "$metadata_tool" ]; then
    echo 'BLOCKED: appintentsmetadataprocessor 不可用（需要完整 Xcode，不是只有 CLT）' >&2
    exit 2
fi
toolchain_dir="$(xcode-select -p 2>/dev/null)/Toolchains/XcodeDefault.xctoolchain"
if [ ! -d "$toolchain_dir" ]; then toolchain_dir="$(xcode-select -p 2>/dev/null)"; fi
# processor 强制要求显式 xcode-version，缺了会直接 error 退出、不产出任何索引。
xcode_version="$(xcodebuild -version 2>/dev/null | head -1 | awk '{print $2}')"
if [ -z "$xcode_version" ]; then xcode_version=16.0; fi
# 按钮 intent 归属扩展，但系统也会查主 App 的索引，所以两份都要生成。
for bundle in "$widget_dir" "$app_dir"; do
    if [ "$bundle" = "$app_dir" ]; then
        module_name=Dashboard
        source_list="$build_dir/swift-sources.txt"
    else
        module_name=DashboardWidgets
        source_list="$build_dir/widget-sources.txt"
    fi
    metadata_log="$build_dir/appintents-$module_name.log"
    "$metadata_tool" --toolchain-dir "$toolchain_dir" \
        --module-name "$module_name" --sdk-root "$sdk_path" \
        --platform-family iOS --deployment-target 15.4 \
        --xcode-version "$xcode_version" \
        --target-triple arm64-apple-ios15.4 --output "$bundle" \
        --source-file-list "$source_list" \
        --swift-const-vals-list "$widget_const_values" \
        --compile-time-extraction --force >"$metadata_log" 2>&1 || true
    echo "[appintents] $module_name: xcode=$xcode_version"
    tail -5 "$metadata_log" | sed 's/^/[appintents]   /'
    if [ ! -f "$bundle/Metadata.appintents/extract.actionsdata" ]; then
        echo "BLOCKED: $bundle 缺少 AppIntents 索引（按钮会静默无效）；processor 输出：" >&2
        cat "$metadata_log" >&2
        exit 2
    fi
done
# 三个真实 bundle 内到外签名。模板不是 Apple 授权，不保证普通安装/TrollStore能力。
# 注意：签名必须在 metadata 生成之后，否则索引不会进签名封条。
codesign --force --sign - --timestamp=none --entitlements "$script_dir/Entitlements/Broadcast.entitlements" --identifier io.github.lswlc33.dashboard.ios.broadcast "$broadcast_dir"
codesign --verify --strict "$broadcast_dir"
codesign --force --sign - --timestamp=none --entitlements "$script_dir/Entitlements/Widgets.entitlements" --identifier io.github.lswlc33.dashboard.ios.widgets "$widget_dir"
codesign --verify --strict "$widget_dir"
codesign --force --sign - --timestamp=none --entitlements "$script_dir/Entitlements/App.entitlements" --identifier io.github.lswlc33.dashboard.ios "$app_dir"
codesign --verify --deep --strict "$app_dir"
for executable in "$app_dir/Dashboard" "$widget_dir/DashboardWidgets" "$broadcast_dir/ZeehoCastBroadcast"; do
    file "$executable" | grep -q 'Mach-O 64-bit executable arm64'
    xcrun lipo "$executable" -verify_arch arm64
    xcrun otool -L "$executable"
done
plutil -lint "$app_dir/Info.plist" "$widget_dir/Info.plist" "$broadcast_dir/Info.plist"

# 构建过程中源码变化也要阻塞；清单记录工作树哈希，不能只拿旧 commit 冒充全部来源。
python3 -I "$support" inputs --root "$repo_dir" --source-manifest "$inputs" >/dev/null
(cd "$build_dir" && zip -qry "$staged_dist/zeehowebnext.ipa" Payload)
python3 -I "$support" write-release --ipa "$staged_dist/zeehowebnext.ipa" --inputs "$inputs" --framework "$shared_framework" --app "$app_dir"
python3 -I "$script_dir/test.py" "$staged_dist/zeehowebnext.ipa"
# 只有完整校验成功后才更新输出；失败不能残留一个假成功的新包。
python3 -I "$support" publish --root "$repo_dir" --staged "$staged_dist" --output "$output_dir"
python3 -I "$support" verify --ipa "$output_dir/zeehowebnext.ipa"
printf 'Built and verified %s\n' "$output_dir/zeehowebnext.ipa"
