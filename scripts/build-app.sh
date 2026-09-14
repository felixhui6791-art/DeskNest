#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
CHANNEL="${1:-beta}"
case "$CHANNEL" in
    release) APP_NAME="栖桌"; BUNDLE_ID="com.hui.desknest" ;;
    beta) APP_NAME="栖桌 测试版"; BUNDLE_ID="com.hui.desknest.beta" ;;
    *) printf '用法：%s [release|beta]\n' "$0" >&2; exit 1 ;;
esac
APP_PATH="$BUILD_DIR/$APP_NAME.app"
SIGN_IDENTITY="${DESKNEST_SIGN_IDENTITY:--}"
ARTIFACT_MARKER="DeskNest generated application bundle v1"
STAGING_DIR=""
BACKUP_APP=""

cleanup() {
    local exit_status="$1"
    trap - EXIT
    if [[ -n "$BACKUP_APP" && -d "$BACKUP_APP" && ! -e "$APP_PATH" ]]; then
        if ! mv -- "$BACKUP_APP" "$APP_PATH"; then
            printf '恢复旧应用失败；旧应用保留在：%s\n' "$BACKUP_APP" >&2
            exit 1
        fi
    fi
    if [[ -n "$STAGING_DIR" && -d "$STAGING_DIR" ]]; then
        rm -rf -- "$STAGING_DIR"
    fi
    exit "$exit_status"
}
trap 'cleanup "$?"' EXIT

if [[ "$(uname -s)" != "Darwin" ]]; then
    printf '请在 macOS 14 或更新版本上构建栖桌。\n' >&2
    exit 1
fi

if [[ -e "$APP_PATH" || -L "$APP_PATH" ]]; then
    EXISTING_MARKER="$APP_PATH/Contents/Resources/desknest-generated.txt"
    if [[ ! -f "$EXISTING_MARKER" ]]; then
        EXISTING_MARKER="$APP_PATH/Contents/.desknest-generated"
    fi
    if [[ -L "$APP_PATH" || ! -f "$EXISTING_MARKER" ]]; then
        printf '目标位置已有非本脚本生成的文件，请先移走：%s\n' "$APP_PATH" >&2
        exit 1
    fi
    if [[ "$(cat "$EXISTING_MARKER")" != "$ARTIFACT_MARKER" ]]; then
        printf '目标应用的生成标记不匹配，已停止以保留现有文件：%s\n' "$APP_PATH" >&2
        exit 1
    fi
    EXISTING_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")"
    if [[ "$EXISTING_BUNDLE_ID" != "$BUNDLE_ID" ]]; then
        printf '目标应用的 Bundle ID 不匹配，已停止以保留现有文件：%s\n' "$APP_PATH" >&2
        exit 1
    fi
fi

cd -- "$PROJECT_DIR"
printf '正在编译栖桌……\n'
BUILD_ARGS=(--configuration release)
if [[ "${DESKNEST_UNIVERSAL:-0}" == "1" ]]; then
    BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
SPARKLE_DIR="$(python3 "$PROJECT_DIR/scripts/distribution.py" sparkle-root)"

mkdir -p -- "$BUILD_DIR"
STAGING_DIR="$(mktemp -d "$BUILD_DIR/.desknest-app.XXXXXX")"
STAGED_APP="$STAGING_DIR/$APP_NAME.app"
mkdir -p -- "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp -- "$BIN_DIR/DeskNest" "$STAGED_APP/Contents/MacOS/DeskNest"
chmod 755 "$STAGED_APP/Contents/MacOS/DeskNest"
printf '%s\n' "$ARTIFACT_MARKER" > "$STAGED_APP/Contents/Resources/desknest-generated.txt"

python3 "$PROJECT_DIR/scripts/distribution.py" plist "$CHANNEL" "$STAGED_APP/Contents/Info.plist"
mkdir -p "$STAGED_APP/Contents/Frameworks"
ditto "$SPARKLE_DIR/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$STAGED_APP/Contents/Frameworks/Sparkle.framework"
cp "$PROJECT_DIR/THIRD_PARTY_NOTICES.md" "$STAGED_APP/Contents/Resources/THIRD_PARTY_NOTICES.md"

if [[ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]]; then
    cp -- "$PROJECT_DIR/Resources/AppIcon.icns" "$STAGED_APP/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon' "$STAGED_APP/Contents/Info.plist"
fi

plutil -lint "$STAGED_APP/Contents/Info.plist"
SIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    SIGN_ARGS+=(--options runtime --timestamp)
fi
FRAMEWORK="$STAGED_APP/Contents/Frameworks/Sparkle.framework"
codesign "${SIGN_ARGS[@]}" "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc"
codesign "${SIGN_ARGS[@]}" --preserve-metadata=entitlements "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc"
codesign "${SIGN_ARGS[@]}" "$FRAMEWORK/Versions/B/Autoupdate"
codesign "${SIGN_ARGS[@]}" "$FRAMEWORK/Versions/B/Updater.app"
codesign "${SIGN_ARGS[@]}" "$FRAMEWORK"
codesign "${SIGN_ARGS[@]}" "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"

if [[ -e "$APP_PATH" ]]; then
    BACKUP_APP="$STAGING_DIR/previous.app"
    mv -- "$APP_PATH" "$BACKUP_APP"
fi
mv -- "$STAGED_APP" "$APP_PATH"
printf '构建完成：%s\n' "$APP_PATH"
