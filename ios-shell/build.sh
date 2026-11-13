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
    for tool in swiftc swift-stdlib-tool lipo otool nm appintentsmetadataprocessor; do
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
# AppIntents 不能只链接 framework 就声称配置可发现；先核本机工具实际支持的参数。
# Xcode 16.4 的真实契约是「列表文件」而不是裸 --source-files/--binary-file；
# 缺任一项 processor 会 Unable to parse options 直接失败，所以按可用参数逐项校验。
intents_help="$(xcrun --sdk iphoneos appintentsmetadataprocessor --help 2>&1 || true)"
intents_required=(--output --target-triple --module-name --toolchain-dir --sdk-root
                  --source-file-list --swift-const-vals-list --platform-family --deployment-target --xcode-version)
for flag in "${intents_required[@]}"; do
    if ! printf '%s\n' "$intents_help" | grep -q -- "$flag"; then
        printf 'BLOCKED: appintentsmetadataprocessor lacks required flag: %s\n' "$flag" >&2
        exit 2
    fi
done
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
    # WidgetKit 提供 Widget / WidgetConfiguration 协议，必须真实链接；
    # AppIntents 从 iOS 16 才有，按 deployment target 弱链接（下面单独加）。
    [[ "$module" == ActivityKit || "$module" == AppIntents ]] || widget_args+=(-framework "$module")
done < "$build_dir/widget-frameworks.txt"
# AppIntents API 从 iOS 16 开始；具体配置类型另有 iOS 17 availability，15.4 不能强加载它。
widget_args+=(-Xlinker -weak_framework -Xlinker AppIntents)
# AppIntents metadata 提取依赖 Swift 编译器产出的 const-values 文件。
# 关键点：const-values 只在**编译**（-c）阶段产出；我们最终产物是「编译 + 链接」
# 一次调用，driver 不会为这种整体任务写 const-values（前面两轮 CI 都印证了文件缺失）。
# 因此单独跑一次「只编译」的 pass 专门拿 const-values，再照常编译链接最终可执行文件。
widget_const_values="$build_dir/widget-const-vals.json"
emit_widget_const_values() {
    xcrun --sdk iphoneos swiftc -O -swift-version 5 -parse-as-library -application-extension \
        -target arm64-apple-ios15.4 -sdk "$sdk_path" -module-name DashboardWidgets \
        -I "$build_dir" -c -whole-module-optimization \
        "$@" "${widget_sources[@]}" -o "$build_dir/widget-const-values.o" >/dev/null 2>&1
}
const_values_ready=false
for variant in \
    "-emit-const-values-path $widget_const_values" \
    "-Xfrontend -emit-const-values-path -Xfrontend $widget_const_values" \
    "-Xfrontend -emit-const-values-path=$widget_const_values"; do
    rm -f "$widget_const_values"
    # shellcheck disable=SC2086 # 三种写法需要按空格拆成独立参数
    if emit_widget_const_values $variant && [[ -s "$widget_const_values" ]]; then
        const_values_ready=true
        printf 'Widget const-values emitted via: %s\n' "$variant"
        break
    fi
done
[[ "$const_values_ready" == true ]] || {
    printf '%s\n' 'BLOCKED: swiftc produced no const-values under any known flag form; AppIntents metadata cannot be extracted.' >&2
    exit 2
}
xcrun --sdk iphoneos swiftc -O -swift-version 5 -parse-as-library -application-extension \
    -target arm64-apple-ios15.4 -sdk "$sdk_path" -module-name DashboardWidgets \
    "${widget_args[@]}" "${widget_sources[@]}" -o "$widget_dir/DashboardWidgets"

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
# 在签名之前从真实 Widget executable/源码提取系统配置 metadata，不造目录/伪造 actionsdata。
# Xcode 16.4 只接受列表文件：--source-file-list / --swift-const-vals-list。
swiftc_path="$(xcrun --sdk iphoneos --find swiftc)"
toolchain_dir="$(CDPATH= cd -- "$(dirname -- "$swiftc_path")/../.." && pwd -P)"
xcode_version="$(xcodebuild -version | awk 'NR==1{print $2}')"
printf '%s\n' "${widget_sources[@]}" > "$build_dir/widget-sources-list.txt"
# --swift-const-vals-list 要的是「每行一个 const-values 文件路径」的列表，
# 不是编译器产出的 JSON 本身；文件已由上面的独立编译 pass 保证存在且非空。
printf '%s\n' "$widget_const_values" > "$build_dir/widget-const-vals-list.txt"
xcrun --sdk iphoneos appintentsmetadataprocessor \
    --output "$widget_dir" --target-triple arm64-apple-ios15.4 --module-name DashboardWidgets \
    --toolchain-dir "$toolchain_dir" --sdk-root "$sdk_path" \
    --platform-family iphoneos --deployment-target 15.4 --xcode-version "$xcode_version" \
    --source-file-list "$build_dir/widget-sources-list.txt" \
    --swift-const-vals-list "$build_dir/widget-const-vals-list.txt"
[[ -s "$widget_dir/Metadata.appintents/extract.actionsdata" ]] || { printf '%s\n' 'BLOCKED: real Widget AppIntents metadata extraction produced no actionsdata; no IPA generated.' >&2; exit 2; }
xcrun nm -g "$broadcast_dir/ZeehoCastBroadcast" | grep 'SampleHandler'
cp "$script_dir/bridge-bootstrap.js" "$app_dir/bridge-bootstrap.js"
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
# 三个真实 bundle 内到外签名。模板不是 Apple 授权，不保证普通安装/TrollStore能力。
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
