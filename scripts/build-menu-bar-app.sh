#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_source="$repo_root/apps/MetagentMenuBar"
app_bundle="$repo_root/dist/MetagentMenuBar.app"
contents="$app_bundle/Contents"
macos="$contents/MacOS"
helpers="$contents/Helpers"
resources="$contents/Resources"

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/metagent-clang-cache}"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

"$repo_root/scripts/generate-menu-bar-assets.sh"

(
  cd "$app_source"
  swift build --disable-sandbox -c release --product MetagentMenuBar
  swift build --disable-sandbox -c release --product metagent
)

previous_bundle=""
if [[ -e "$app_bundle" ]]; then
  previous_bundle="$repo_root/dist/.MetagentMenuBar.app.previous-$(date +%Y%m%d%H%M%S)"
  mv "$app_bundle" "$previous_bundle"
fi

mkdir -p "$macos" "$helpers" "$resources"
cp "$app_source/.build/release/MetagentMenuBar" "$macos/MetagentMenuBar"
cp "$app_source/.build/release/metagent" "$helpers/metagent"
cp "$app_source/Info.plist" "$contents/Info.plist"
cp "$app_source/Sources/Resources/AppIcon.icns" "$resources/AppIcon.icns"
cp "$app_source/Sources/Resources/MenuBarIconTemplate.pdf" "$resources/MenuBarIconTemplate.pdf"

chmod +x "$macos/MetagentMenuBar"
chmod +x "$helpers/metagent"

if [[ -n "$previous_bundle" ]]; then
  if command -v trash >/dev/null 2>&1; then
    trash "$previous_bundle" || true
  fi
  if [[ -e "$previous_bundle" ]]; then
    echo "Previous app moved to $previous_bundle"
    echo "Build succeeded; remove that backup later if you do not need it."
  fi
fi

echo "$app_bundle"
