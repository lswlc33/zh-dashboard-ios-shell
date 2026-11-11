#!/bin/bash
# 只在真实 macOS/Xcode 上出包；Windows/缺失 KMP 框架时绝不生成占位 IPA。
set -euo pipefail
script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
repo_dir="$(CDPATH= cd -- "$script_dir/.." && pwd -P)"
shared_dir="$repo_dir/native-shared"
support="$script_dir/build-support.py"
output_dir="$script_dir/dist"
source_manifest=''
build_number=''
preflight_only=false
offline=false

usage() {
    printf '%s\n' 'Usage: build.sh [--preflight-only] [--build-number POSITIVE_INTEGER] [--output-dir DIR] [--source-manifest FILE] [--offline]'
    printf '%s\n' 'Output is ad-hoc signed with public App Group entitlement templates; their Apple provisioning approval and TrollStore compatibility are not verified. Ordinary Apple installation needs matching identity/profiles and inside-out signing.'
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
[[ "$output_dir" = /* ]] || output_dir="$PWD/$output_dir"
if command -v python3 >/dev/null 2>&1; then
    python3 -I "$support" output-check --root "$repo_dir" --output "$output_dir" >/dev/null
fi
if [[ -n "$source_manifest" && "$source_manifest" != /* ]]; then source_manifest="$PWD/$source_manifest"; fi
if [[ -n "$build_number" && ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s\n' 'BLOCKED: build number must be a positive integer.' >&2
    exit 2
fi

missing=()
[[ "$(uname -s)" == Darwin ]] || missing+=('macOS (Darwin) for this Xcode backend; use build-xtool.sh for explicit Linux/WSL xtool')
for tool in bash python3 java git xcrun xcodebuild codesign plutil zip sips file; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
[[ -x /usr/libexec/PlistBuddy ]] || missing+=('/usr/libexec/PlistBuddy')
[[ -f "$shared_dir/gradlew" ]] || missing+=('native-shared/gradlew (a real Gradle wrapper is required; no substitute is generated)')
[[ -f "$shared_dir/gradle/wrapper/gradle-wrapper.jar" ]] || missing+=('native-shared/gradle/wrapper/gradle-wrapper.jar')
[[ -f "$script_dir/bridge-bootstrap.js" ]] || missing+=('ios-shell/bridge-bootstrap.js')
if [[ "$(uname -s)" == Darwin ]] && command -v xcrun >/dev/null 2>&1; then
    xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1 || missing+=('iPhoneOS SDK (full Xcode, not only Command Line Tools)')
    for tool in swiftc swift-stdlib-tool lipo otool; do
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
mkdir -p "$app_dir/Frameworks" "$widget_dir" "$staged_dist"
inputs="$build_dir/build-inputs.json"
python3 -I "$support" inputs "${input_args[@]}" --manifest "$inputs" \
    --swift-list "$build_dir/swift-sources.txt" --shared-list "$build_dir/shared-sources.txt" --widget-list "$build_dir/widget-sources.txt" \
    --framework-list "$build_dir/frameworks.txt" --library-list "$build_dir/libraries.txt" \
    --shared-framework-list "$build_dir/shared-frameworks.txt" --widget-framework-list "$build_dir/widget-frameworks.txt"

# 源码上传白名单不带 *-test.swift；本地原有短例子存在时才执行，不把源码检查冒充编译。
if [[ -f "$script_dir/navigation-test.swift" && -f "$script_dir/update-test.swift" ]]; then
    xcrun swiftc "$script_dir/Navigation.swift" "$script_dir/navigation-test.swift" -o "$build_dir/navigation-test"
    "$build_dir/navigation-test"
    xcrun swiftc "$script_dir/Update.swift" "$script_dir/update-test.swift" -o "$build_dir/update-test"
    "$build_dir/update-test"
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
while IFS= read -r path; do swift_sources+=("$repo_dir/$path"); done < "$build_dir/swift-sources.txt"
while IFS= read -r path; do shared_sources+=("$repo_dir/$path"); done < "$build_dir/shared-sources.txt"
while IFS= read -r path; do widget_sources+=("$repo_dir/$path"); done < "$build_dir/widget-sources.txt"
# PanelLoadingView.swift 及根业务源只入 host；Shared 独立 module/static object，两端链接、不嵌入假 framework。
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
    -target arm64-apple-ios15.4 -sdk "$sdk_path" \
    "${link_args[@]}" "${swift_sources[@]}" -o "$app_dir/Dashboard"
widget_args=(-I "$build_dir" "$build_dir/ZeehoSystemShared.o" "${activity_args[@]}" -framework Foundation \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -Xlinker -rpath -Xlinker '@executable_path/../../Frameworks' \
    -Xlinker -rpath -Xlinker '@executable_path/Frameworks' -Xlinker -rpath -Xlinker /usr/lib/swift)
while IFS= read -r module; do
    [[ -d "$sdk_path/System/Library/Frameworks/$module.framework" ]] || { printf 'BLOCKED: imported Widget SDK framework missing: %s\n' "$module" >&2; exit 2; }
    [[ "$module" == ActivityKit ]] || widget_args+=(-framework "$module")
done < "$build_dir/widget-frameworks.txt"
xcrun --sdk iphoneos swiftc -O -swift-version 5 -parse-as-library -application-extension \
    -target arm64-apple-ios15.4 -sdk "$sdk_path" "${widget_args[@]}" "${widget_sources[@]}" -o "$widget_dir/DashboardWidgets"

plist_args=(--source "$script_dir/Info.plist" --destination "$app_dir/Info.plist")
if [[ -n "$build_number" ]]; then plist_args+=(--build-number "$build_number"); fi
python3 -I "$support" prepare-plist "${plist_args[@]}"
python3 -I "$script_dir/XtoolSupport/xtool-support.py" prepare-widget --source "$script_dir/Widgets/Info.plist" \
    --host-info "$app_dir/Info.plist" --output "$widget_dir/Info.plist"
cp "$script_dir/bridge-bootstrap.js" "$app_dir/bridge-bootstrap.js"
for size in 120 152 167 180; do
    sips -z "$size" "$size" "$repo_dir/public/icons/icon-512.png" --out "$app_dir/Icon${size}.png" >/dev/null
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
stdlib_args=(--copy --platform iphoneos
    --scan-executable "$app_dir/Dashboard" --scan-executable "$widget_dir/DashboardWidgets"
    --scan-folder "$app_dir/Frameworks" --destination "$app_dir/Frameworks")
if xcrun --sdk iphoneos swift-stdlib-tool --help 2>&1 | grep -q -- '--filter-for-swift-os'; then
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
done < <(find "$app_dir/Frameworks" -type f -name '*.dylib' -print0)
if [[ "$shared_kind" == dynamic ]]; then
    codesign --force --sign - --timestamp=none "$app_dir/Frameworks/ZeehoShared.framework"
    codesign --verify --strict "$app_dir/Frameworks/ZeehoShared.framework"
fi
# 两个真实 bundle 内到外签名。公开 App Group entitlement 不代表 Apple profile 已批准；不保证普通安装/TrollStore能力。
codesign --force --sign - --timestamp=none --entitlements "$script_dir/XtoolSupport/Widgets.entitlements" --identifier io.github.lswlc33.dashboard.ios.widgets "$widget_dir"
codesign --verify --strict "$widget_dir"
codesign --force --sign - --timestamp=none --entitlements "$script_dir/XtoolSupport/App.entitlements" --identifier io.github.lswlc33.dashboard.ios "$app_dir"
codesign --verify --deep --strict "$app_dir"
file "$app_dir/Dashboard" | grep -q 'Mach-O 64-bit executable arm64'
xcrun lipo "$app_dir/Dashboard" -verify_arch arm64
xcrun otool -L "$app_dir/Dashboard"
plutil -lint "$app_dir/Info.plist"

# 构建过程中源码变化也要阻塞；清单记录工作树哈希，不能只拿旧 commit 冒充全部来源。
python3 -I "$support" inputs --root "$repo_dir" --source-manifest "$inputs" >/dev/null
(cd "$build_dir" && zip -qry "$staged_dist/dashboard-trollstore.ipa" Payload)
python3 -I "$support" write-release --ipa "$staged_dist/dashboard-trollstore.ipa" --inputs "$inputs" --framework "$shared_framework" --app "$app_dir"
python3 -I "$script_dir/test.py" "$staged_dist/dashboard-trollstore.ipa"
# 只有完整校验成功后才更新输出；失败不能残留一个假成功的新包。
python3 -I "$support" publish --root "$repo_dir" --staged "$staged_dist" --output "$output_dir"
python3 -I "$support" verify --ipa "$output_dir/dashboard-trollstore.ipa"
printf 'Built and verified %s\n' "$output_dir/dashboard-trollstore.ipa"
