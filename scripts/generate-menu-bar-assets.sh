#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_svg="$repo_root/public/brand/logo.svg"
resources_dir="$repo_root/apps/MetagentMenuBar/Sources/Resources"

app_icon="$resources_dir/AppIcon.icns"
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

render_icon_png() {
  local size="$1"
  local output_name="$2"

  rsvg-convert -f png -a -w "$size" -h "$size" "$source_svg" \
    -o "$iconset/$output_name"
}

if [[ ! -f "$source_svg" ]]; then
  echo "Missing source logo: $source_svg" >&2
  exit 1
fi

require_command rsvg-convert
require_command python3

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/metagent-assets.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

iconset="$tmpdir/AppIcon.iconset"
mkdir -p "$iconset"

render_icon_png 16 icon_16x16.png
render_icon_png 32 icon_32x32.png
render_icon_png 64 icon_64x64.png
render_icon_png 128 icon_128x128.png
render_icon_png 256 icon_256x256.png
render_icon_png 512 icon_512x512.png
render_icon_png 1024 icon_1024x1024.png

generated_icon="$tmpdir/AppIcon.icns"
python3 - "$generated_icon" \
  "icp4=$iconset/icon_16x16.png" \
  "icp5=$iconset/icon_32x32.png" \
  "icp6=$iconset/icon_64x64.png" \
  "ic07=$iconset/icon_128x128.png" \
  "ic08=$iconset/icon_256x256.png" \
  "ic09=$iconset/icon_512x512.png" \
  "ic10=$iconset/icon_1024x1024.png" <<'PY'
from pathlib import Path
import struct
import sys

output = Path(sys.argv[1])
chunks = []

for spec in sys.argv[2:]:
    chunk_type, image_path = spec.split("=", 1)
    if len(chunk_type) != 4:
        raise ValueError(f"Invalid ICNS chunk type: {chunk_type}")

    payload = Path(image_path).read_bytes()
    chunk = chunk_type.encode("ascii") + struct.pack(">I", len(payload) + 8) + payload
    chunks.append(chunk)

payload = b"".join(chunks)
output.write_bytes(b"icns" + struct.pack(">I", len(payload) + 8) + payload)
PY
write_if_changed "$generated_icon" "$app_icon"

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
