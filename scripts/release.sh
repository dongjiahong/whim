#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/release.sh <version> [--dry-run] [--no-push]

Examples:
  ./scripts/release.sh 0.1.4            # 同步双端版本号 -> 跑测试与编译 -> 提交、打 tag 并推送触发 GitHub Release
  ./scripts/release.sh 0.1.4 --dry-run  # 仅预览将执行的步骤，不修改文件
  ./scripts/release.sh 0.1.4 --no-push  # 仅在本地提交并打 tag，不推送到远端
EOF
}

if [ $# -lt 1 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  usage
  exit 0
fi

RAW_VER="$1"
shift
VER="${RAW_VER#v}"
VER="${VER#V}"

if ! [[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: version must be semver X.Y.Z (got '$RAW_VER')" >&2
  exit 1
fi

DRY_RUN=0
NO_PUSH=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --no-push) NO_PUSH=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

TAG="v$VER"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
CUR_VER="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION" 2>/dev/null || echo "0.1.0")"
CUR_CODE="$(grep -E 'versionCode = [0-9]+' android/app/build.gradle.kts | head -n 1 | sed -E 's/[^0-9]*([0-9]+).*/\1/')"
NEXT_CODE=$(( ${CUR_CODE:-0} + 1 ))

echo "==> Release plan: $CUR_VER -> $VER (tag: $TAG, branch: $BRANCH, buildCode: $NEXT_CODE)"

if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "Error: git tag $TAG already exists." >&2
  exit 1
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "[dry-run] Would update VERSION, macos/Resources/Info.plist, android/app/build.gradle.kts, GitHubUpdater.kt"
  echo "[dry-run] Would run ./scripts/test.sh, ./scripts/build-macos.sh, ./scripts/build-mcp.sh"
  echo "[dry-run] Would commit 'chore(release): $TAG' and create tag '$TAG'"
  if [ "$NO_PUSH" -eq 0 ]; then
    echo "[dry-run] Would push: git push origin $BRANCH && git push origin $TAG"
  fi
  exit 0
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "Error: working tree is not clean. Please commit or stash changes before releasing." >&2
  git status -s
  exit 1
fi

# 1. Bump version across VERSION, macOS Info.plist, Android build.gradle.kts & GitHubUpdater.kt
printf "%s\n" "$VER" > "$ROOT_DIR/VERSION"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VER" "$ROOT_DIR/macos/Resources/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEXT_CODE" "$ROOT_DIR/macos/Resources/Info.plist"

sed -i '' -E "s/versionCode = [0-9]+/versionCode = $NEXT_CODE/" "$ROOT_DIR/android/app/build.gradle.kts"
sed -i '' -E "s/versionName = \"[^\"]+\"/versionName = \"$VER\"/" "$ROOT_DIR/android/app/build.gradle.kts"
sed -i '' -E "s/const val CURRENT_VERSION = \"[^\"]+\"/const val CURRENT_VERSION = \"$VER\"/" "$ROOT_DIR/android/app/src/main/kotlin/com/whim/app/update/GitHubUpdater.kt"

# 2. Run tests and verify macOS/MCP builds before tagging
"$ROOT_DIR/scripts/test.sh"
"$ROOT_DIR/scripts/build-macos.sh"
"$ROOT_DIR/scripts/build-mcp.sh"

# 3. Commit and tag locally
git add VERSION macos/Resources/Info.plist android/app/build.gradle.kts android/app/src/main/kotlin/com/whim/app/update/GitHubUpdater.kt
git commit -m "chore(release): $TAG"
git tag -a "$TAG" -m "Release $TAG"

# 4. Push branch and tag to trigger GitHub Actions Release workflow
if [ "$NO_PUSH" -eq 1 ]; then
  echo ""
  echo "==> Local release $TAG is ready (--no-push)."
  echo "Push manually when ready:"
  echo "  git push origin $BRANCH && git push origin $TAG"
else
  echo "==> Pushing $BRANCH and $TAG to origin..."
  git push origin "$BRANCH"
  git push origin "$TAG"
  echo ""
  echo "==> Release $TAG pushed! GitHub Actions is building macOS & Android assets."
fi
