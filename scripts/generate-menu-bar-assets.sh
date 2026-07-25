#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The app icon is authored in Icon Composer and compiled by actool, which emits
# both a legacy .icns and an Assets.car carrying the macOS 26 appearance
# variants (default, dark, clear, tinted). The menu bar glyph is a separate
# template image: macOS tints it, so it must stay flat with no background.
icon_document="$repo_root/metagent-icon.icon"
# AppBrand.markAspectRatio is derived from this file's 506x400 proportions, so
# swapping in the square icon artwork here would squash the menu bar glyph.
source_svg="$repo_root/public/brand/logo.svg"
resources_dir="$repo_root/apps/MetagentMenuBar/Sources/Resources"

app_icon="$resources_dir/AppIcon.icns"
app_assets="$resources_dir/Assets.car"
menu_bar_svg="$resources_dir/MenuBarIconTemplate.svg"
menu_bar_pdf="$resources_dir/MenuBarIconTemplate.pdf"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

write_if_changed() {
  local source="$1"
  local destination="$2"

  if [[ -f "$destination" ]] && cmp -s "$source" "$destination"; then
    return
  fi

  cp "$source" "$destination"
}

if [[ ! -f "$source_svg" ]]; then
  echo "Missing source glyph: $source_svg" >&2
  exit 1
fi

if [[ ! -d "$icon_document" ]]; then
  echo "Missing Icon Composer document: $icon_document" >&2
  exit 1
fi

require_command rsvg-convert
require_command xcrun

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/metagent-assets.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

# actool needs the document named after the icon it produces.
icon_build="$tmpdir/icon-build"
mkdir -p "$icon_build/out"
cp -R "$icon_document" "$icon_build/AppIcon.icon"

xcrun actool "$icon_build/AppIcon.icon" \
  --compile "$icon_build/out" \
  --platform macosx \
  --minimum-deployment-target 26.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$icon_build/partial.plist" \
  >/dev/null

write_if_changed "$icon_build/out/AppIcon.icns" "$app_icon"
write_if_changed "$icon_build/out/Assets.car" "$app_assets"

generated_menu_bar_svg="$tmpdir/MenuBarIconTemplate.svg"
awk '
  BEGIN { removed_background = 0 }
  removed_background == 0 && $0 ~ /^[[:space:]]*<rect[^>]*fill="white"[^>]*\/>[[:space:]]*$/ {
    removed_background = 1
    next
  }
  { print }
' "$source_svg" > "$generated_menu_bar_svg"
write_if_changed "$generated_menu_bar_svg" "$menu_bar_svg"

generated_menu_bar_pdf="$tmpdir/MenuBarIconTemplate.pdf"
SOURCE_DATE_EPOCH=0 rsvg-convert -f pdf "$generated_menu_bar_svg" -o "$generated_menu_bar_pdf"
write_if_changed "$generated_menu_bar_pdf" "$menu_bar_pdf"
