#!/bin/bash
# WSL/Linux xtool 入口；不 auth/setup/install，也不下载 SDK/工具。
set -euo pipefail
script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
mode=build
product=DashboardIOS
output_dir=''
args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --preflight-only) mode=preflight; shift ;;
        --product|--xcframework|--kmp-manifest|--sdk-root|--output-dir|--build-number)
            [[ $# -ge 2 && -n "$2" ]] || { printf '%s\n' 'BLOCKED: missing argument value' >&2; exit 2; }
            case "$1" in
                --product) product="$2" ;;
                --output-dir) output_dir="$2" ;;
                *) args+=("$1" "$2") ;;
            esac
            shift 2 ;;
        --help|-h)
            printf '%s\n' 'Usage: build-xtool.sh [--preflight-only] [--product DashboardIOS|SwiftProbe] [--xcframework PATH --kmp-manifest PATH] [--sdk-root LEGALLY_INSTALLED_IPHONEOS_SDK] [--output-dir DIR] [--build-number N]'
            printf '%s\n' 'Requires Linux Swift 6.4+, xtool 1.24.0 and a real darwin SDK; full app additionally needs a real KMP XCFramework. No login, install or SDK download.'
            exit 0 ;;
        *) printf 'BLOCKED: unknown argument %s\n' "$1" >&2; exit 2 ;;
    esac
done
if ! command -v python3 >/dev/null 2>&1; then
    printf '%s\n' 'BLOCKED: PYTHON_MISSING (Python 3.9+ must already be installed)' >&2
    exit 2
fi
[[ "$product" == DashboardIOS || "$product" == SwiftProbe ]] || { printf '%s\n' 'BLOCKED: unknown product' >&2; exit 2; }
if [[ -z "$output_dir" ]]; then output_dir="$script_dir/dist/xtool/$product"; fi
if [[ "$mode" == build ]]; then args+=(--output "$output_dir"); fi
exec python3 -I "$script_dir/XtoolSupport/xtool-support.py" "$mode" --root "$script_dir/.." --product "$product" "${args[@]}"
