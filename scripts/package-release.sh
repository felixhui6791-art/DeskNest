#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CHANNEL="${1:-beta}"
META="$PROJECT_DIR/scripts/distribution.py"
APP_NAME="$(python3 "$META" get "$CHANNEL" appName)"
ARCHIVE="$(python3 "$META" get "$CHANNEL" archive)"
TAG="$(python3 "$META" get "$CHANNEL" tag)"
PUBLIC_KEY="$(python3 "$META" get "$CHANNEL" publicKey)"
SOURCE_COMMIT=""
if git -C "$PROJECT_DIR" rev-parse HEAD >/dev/null 2>&1 && [[ -z "$(git -C "$PROJECT_DIR" status --porcelain)" ]]; then
    SOURCE_COMMIT="$(git -C "$PROJECT_DIR" rev-parse HEAD)"
fi
OUTPUT="$PROJECT_DIR/build/distribution/$CHANNEL/$TAG"
NOTES="$PROJECT_DIR/docs/notes/$TAG.md"
if [[ ! -f "$NOTES" ]]; then
    printf '请先创建版本说明：%s\n' "$NOTES" >&2
    exit 1
fi
if [[ -e "$OUTPUT" ]]; then
    printf '发布包目录已存在，请递增版本或先移走旧目录：%s\n' "$OUTPUT" >&2
    exit 1
fi
python3 - "$PROJECT_DIR" "$CHANNEL" <<'PY'
import json, sys, xml.etree.ElementTree as ET
from pathlib import Path
root, channel = Path(sys.argv[1]), sys.argv[2]
feed = root / 'updates' / (channel + '.xml')
if feed.exists():
    build = json.loads((root / 'config' / (channel + '.json')).read_text())['build']
    versions = [int(e.text) for e in ET.parse(feed).findall('.//{http://www.andymatuschak.org/xml-namespaces/sparkle}version')]
    if versions and build <= max(versions):
        raise SystemExit('build 必须高于此渠道已发布的版本。')
PY
DESKNEST_UNIVERSAL=1 "$PROJECT_DIR/scripts/build-app.sh" "$CHANNEL"
SPARKLE="$(python3 "$META" sparkle-root)"
ACTUAL_KEY="$("$SPARKLE/bin/generate_keys" --account desknest-felixhui6791-art -p)"
if [[ "$ACTUAL_KEY" != "$PUBLIC_KEY" ]]; then
    printf '钥匙串中的更新签名公钥与配置不一致，已停止。\n' >&2
    exit 1
fi
APP="$PROJECT_DIR/build/$APP_NAME.app"
if [[ -n "${DESKNEST_NOTARY_PROFILE:-}" ]]; then
    NOTARY_ZIP="$PROJECT_DIR/build/notary-$CHANNEL.zip"
    ditto -c -k --keepParent --norsrc "$APP" "$NOTARY_ZIP"
    xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$DESKNEST_NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
fi
mkdir -p "$OUTPUT"
ditto -c -k --keepParent --norsrc "$APP" "$OUTPUT/$ARCHIVE"
cp "$NOTES" "$OUTPUT/${ARCHIVE%.zip}.md"
if [[ -f "$PROJECT_DIR/updates/$CHANNEL.xml" ]]; then
    cp "$PROJECT_DIR/updates/$CHANNEL.xml" "$OUTPUT/appcast.xml"
fi
"$SPARKLE/bin/generate_appcast" --account desknest-felixhui6791-art \
    --download-url-prefix "https://github.com/felixhui6791-art/DeskNest/releases/download/$TAG/" \
    --link "https://github.com/felixhui6791-art/DeskNest/releases/tag/$TAG" \
    --embed-release-notes --maximum-deltas 0 -o "$OUTPUT/appcast.xml" "$OUTPUT"
"$SPARKLE/bin/sign_update" --verify --account desknest-felixhui6791-art "$OUTPUT/appcast.xml"
python3 "$PROJECT_DIR/scripts/verify-distribution.py" "$CHANNEL" "$OUTPUT"
(cd "$OUTPUT" && shasum -a 256 "$ARCHIVE" > SHA256SUMS.txt)
if [[ -n "$SOURCE_COMMIT" && "$(git -C "$PROJECT_DIR" rev-parse HEAD)" == "$SOURCE_COMMIT" && -z "$(git -C "$PROJECT_DIR" status --porcelain)" ]]; then
    printf '%s\n' "$SOURCE_COMMIT" > "$OUTPUT/source-commit.txt"
fi
printf '已生成并验证：%s\n' "$OUTPUT"
