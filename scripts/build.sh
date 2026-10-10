#!/bin/bash
set -euo pipefail
invocation_dir="$PWD"
cd "$(dirname "$0")/.."
project_dir="$PWD"
configuration="release"
format="app"
output=""
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)"

usage() {
    cat <<'EOF'
用法：bash scripts/build.sh [debug|release] [选项]

  -f, --format app|dmg                 输出格式，默认 app
  -o, --output PATH                    完整产物路径，需以 .app 或 .dmg 结尾
  -c, --configuration debug|release    构建配置，默认 release
  -v, --version VERSION                版本号，格式为 X.Y.Z，默认读取 Resources/Info.plist
  -b, --build-number NUMBER            构建号，1 至 3 段数字，默认读取 Resources/Info.plist
  -h, --help                           显示帮助

未指定 output 时输出到项目 dist/Fileto.app 或 dist/Fileto.dmg。
相对 output 路径以调用脚本时的工作目录为准；已有同类产物会被替换。
诊断工具始终输出到项目 dist/fileto-probe。
签名身份通过 FILETO_SIGN_IDENTITY 传入；未设置时使用 ad-hoc 签名。
DMG 不自动签名或公证；其中的应用沿用上述签名方式。
版本号与构建号仅写入本次应用包，不修改源码中的 Info.plist。
EOF
}

fail() {
    printf '错误：%s\n使用 --help 查看用法。\n' "$1" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -f|--format|-o|--output|-c|--configuration|-v|--version|-b|--build-number)
            [ "$#" -ge 2 ] && [ -n "$2" ] && [[ "$2" != -* ]] || fail "$1 缺少参数"
            case "$1" in
                -f|--format) format="$2" ;;
                -o|--output) output="$2" ;;
                -c|--configuration) configuration="$2" ;;
                -v|--version) version="$2" ;;
                -b|--build-number) build_number="$2" ;;
            esac
            shift 2
            ;;
        --format=*) format="${1#*=}"; shift ;;
        --output=*) output="${1#*=}"; [ -n "$output" ] || fail "--output 缺少参数"; shift ;;
        --configuration=*) configuration="${1#*=}"; shift ;;
        --version=*) version="${1#*=}"; shift ;;
        --build-number=*) build_number="${1#*=}"; shift ;;
        debug|release) configuration="$1"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "未知参数：$1" ;;
    esac
done

case "$format" in app|dmg) ;; *) fail "format 仅支持 app 或 dmg" ;; esac
case "$configuration" in debug|release) ;; *) fail "configuration 仅支持 debug 或 release" ;; esac
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version 必须为三段数字，例如 0.2.0"
[[ "$build_number" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || fail "build-number 必须为 1 至 3 段数字，例如 2 或 2.1.0"
if [ -z "$output" ]; then
    output="$project_dir/dist/Fileto.$format"
elif [[ "$output" != /* ]]; then
    output="$invocation_dir/$output"
fi
[[ "$output" == *."$format" ]] || fail "output 必须以 .$format 结尾"
mkdir -p "$(dirname "$output")"
output_dir="$(cd "$(dirname "$output")" && pwd -P)"
output="$output_dir/$(basename "$output")"
[ ! -L "$output" ] || fail "output 不能是符号链接：$output"
if [ -e "$output" ]; then
    if [ "$format" = app ]; then
        [ -d "$output" ] && [ -f "$output/Contents/Info.plist" ] || fail "output 已存在且不是应用包：$output"
        package_type="$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$output/Contents/Info.plist" 2>/dev/null || true)"
        [ "$package_type" = APPL ] || fail "output 已存在且不是应用包：$output"
    else
        [ -f "$output" ] || fail "output 已存在且不是普通文件：$output"
    fi
fi

work_dir="$(mktemp -d "$output_dir/.fileto-build.XXXXXX")"
cleanup() {
    if [ -d "$work_dir/previous.app" ] && [ ! -e "$output" ]; then
        mv "$work_dir/previous.app" "$output"
    fi
    rm -rf "$work_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

bash scripts/build-icons.sh
bash scripts/swift.sh build -c "$configuration"
binary_dir="$(bash scripts/swift.sh build -c "$configuration" --show-bin-path)"
app_dir="$work_dir/Fileto.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/Fileto" "$app_dir/Contents/MacOS/Fileto"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string com.fileto.app "$app_dir/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$version" "$app_dir/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$build_number" "$app_dir/Contents/Info.plist"
xcrun actool Sources/FiletoApp/Resources/Assets.xcassets \
    --compile "$app_dir/Contents/Resources" --platform macosx \
    --minimum-deployment-target 13.0 --app-icon AppIcon \
    --output-partial-info-plist .build/AppIcon-info.plist \
    --output-format human-readable-text --warnings --notices
plutil -insert CFBundleIconName -string AppIcon "$app_dir/Contents/Info.plist"
mkdir -p dist
cp "$binary_dir/fileto-probe" dist/fileto-probe
if [ -n "${FILETO_SIGN_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp --sign "$FILETO_SIGN_IDENTITY" "$app_dir"
else
    codesign --force --options runtime --sign - "$app_dir"
fi
codesign --verify --strict --verbose=2 "$app_dir"
if [ "$format" = dmg ]; then
    volume_dir="$work_dir/volume"
    mkdir -p "$volume_dir"
    mv "$app_dir" "$volume_dir/Fileto.app"
    ln -s /Applications "$volume_dir/Applications"
    cat > "$volume_dir/安装说明.txt" <<'EOF'
请将 Fileto.app 拖入 Applications，然后从“应用程序”中打开。

本版本未经过 Apple 公证。如果 macOS 阻止打开，请在尝试打开后，
进入“系统设置 → 隐私与安全性”，在本次阻止记录旁选择“仍要打开”，
并按系统提示确认。
EOF
    hdiutil create -volname Fileto -srcfolder "$volume_dir" \
        -fs HFS+ -format UDZO "$work_dir/Fileto.dmg"
    hdiutil verify "$work_dir/Fileto.dmg"
    mv -f "$work_dir/Fileto.dmg" "$output"
else
    if [ -e "$output" ]; then
        mv "$output" "$work_dir/previous.app"
    fi
    mv "$app_dir" "$output"
fi
printf 'Built: %s\n' "$output"
printf 'Version: %s (%s)\n' "$version" "$build_number"
