#!/bin/bash
# Run after reviewing and committing changes. Publishing makes files public.
set -euo pipefail
PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"
CHANNEL="${1:-beta}"
GH="${DESKNEST_GH:-gh}"
REPO="felixhui6791-art/DeskNest"
META="$PROJECT_DIR/scripts/distribution.py"
TAG="$(python3 "$META" get "$CHANNEL" tag)"
VERSION="$(python3 "$META" get "$CHANNEL" version)"
ARCHIVE="$(python3 "$META" get "$CHANNEL" archive)"
OUTPUT="$PROJECT_DIR/build/distribution/$CHANNEL/$TAG"
[[ "$(git branch --show-current)" == "main" ]] || { printf '请先将待发布改动合并到 main。\n' >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { printf '请先提交所有待发布改动。\n' >&2; exit 1; }
case "$(git remote get-url origin)" in
    "https://github.com/$REPO"|"https://github.com/$REPO.git"|"git@github.com:$REPO.git") ;;
    *) printf 'origin 与发布仓库不一致，已停止。\n' >&2; exit 1 ;;
esac
"$GH" auth status --hostname github.com
ACTOR="$("$GH" api user --jq .login)"
[[ "$ACTOR" == "felixhui6791-art" ]] || { printf '当前 GitHub 账号不是仓库所有者。\n' >&2; exit 1; }
git fetch origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { printf '请先同步本地与远程 main。\n' >&2; exit 1; }
if "$GH" release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    printf '此版本已存在，请递增版本。若上次发布中断，请按 docs/PUBLISHING.md 恢复。\n' >&2
    exit 1
fi
swift test
if [[ ! -d "$OUTPUT" ]]; then
    "$PROJECT_DIR/scripts/package-release.sh" "$CHANNEL"
fi
python3 "$PROJECT_DIR/scripts/verify-distribution.py" "$CHANNEL" "$OUTPUT"
[[ -f "$OUTPUT/source-commit.txt" && "$(cat "$OUTPUT/source-commit.txt")" == "$(git rev-parse HEAD)" ]] || {
    printf '安装包不是当前提交构建，请移走旧发布包目录并重新打包。\n' >&2; exit 1;
}
SPARKLE="$(python3 "$META" sparkle-root)"
"$SPARKLE/bin/sign_update" --verify --account desknest-felixhui6791-art "$OUTPUT/appcast.xml"
ARGS=(--repo "$REPO" --target "$(git rev-parse HEAD)" --draft --title "栖桌 $VERSION" --notes-file "docs/notes/$TAG.md")
if [[ "$CHANNEL" == "beta" ]]; then ARGS+=(--prerelease); fi
"$GH" release create "$TAG" "$OUTPUT/$ARCHIVE" "$OUTPUT/SHA256SUMS.txt" "${ARGS[@]}"
EDIT_ARGS=(--repo "$REPO" --draft=false)
if [[ "$CHANNEL" == "beta" ]]; then EDIT_ARGS+=(--latest=false); else EDIT_ARGS+=(--latest); fi
"$GH" release edit "$TAG" "${EDIT_ARGS[@]}"
# Only expose a feed after the corresponding public download is available.
DOWNLOADED="$(mktemp "$PROJECT_DIR/build/.published-download.XXXXXX")"
trap 'rm -f "$DOWNLOADED"' EXIT
curl --fail --location --retry 3 --output "$DOWNLOADED" "https://github.com/$REPO/releases/download/$TAG/$ARCHIVE"
cmp "$DOWNLOADED" "$OUTPUT/$ARCHIVE"
cp "$OUTPUT/appcast.xml" "updates/$CHANNEL.xml"
git add "updates/$CHANNEL.xml"
git commit -m "Publish $CHANNEL update feed for $TAG"
git push origin main
printf '发布完成：https://github.com/%s/releases/tag/%s\n' "$REPO" "$TAG"
