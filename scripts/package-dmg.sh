#!/usr/bin/env bash
set -euo pipefail

# Packages the built bundle as a disk image containing Metagent.app beside an
# Applications shortcut, which is the install gesture people expect on macOS.
#
# Usage:
#   scripts/package-dmg.sh [output.dmg]
#
# The app must already be built and signed; run scripts/build-app.sh
# first. Notarization is a separate step: scripts/notarize.sh on the result.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_bundle="$repo_root/dist/MetagentMenuBar.app"
output="${1:-$repo_root/artifacts/Metagent.dmg}"
volume_name="Metagent"
signing_identity="${METAGENT_CODE_SIGN_IDENTITY:-}"
background_png="$repo_root/public/brand/dmg-background.png"
background_2x_png="$repo_root/public/brand/dmg-background@2x.png"

if [[ ! -d "$app_bundle" ]]; then
  echo "No app bundle at $app_bundle." >&2
  echo "Run scripts/build-app.sh first." >&2
  exit 1
fi

for required_command in create-dmg tiffutil; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "Missing required packaging tool: $required_command" >&2
    echo "Install the release tools with: brew install create-dmg" >&2
    exit 1
  fi
done

for background_asset in "$background_png" "$background_2x_png"; do
  if [[ ! -f "$background_asset" ]]; then
    echo "No disk image background at $background_asset." >&2
    exit 1
  fi
done

if [[ -z "$signing_identity" ]]; then
  detected_identities="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | awk 'index($0, "\"Developer ID Application: ") { print $2 }'
  )"
  identity_count="$(awk 'NF { count += 1 } END { print count + 0 }' <<<"$detected_identities")"
  if [[ "$identity_count" == "1" ]]; then
    signing_identity="$detected_identities"
  elif [[ "$identity_count" -gt 1 ]]; then
    echo "Multiple Developer ID Application identities found." >&2
    echo "Set METAGENT_CODE_SIGN_IDENTITY to the intended certificate hash." >&2
    exit 1
  fi
fi

temp_root="$(mktemp -d)"
staging="$temp_root/source"
background_tiff="$temp_root/dmg-background.tiff"
cleanup() {
  rm -rf "$temp_root"
}
trap cleanup EXIT

# The bundle is named for its executable on disk, but users should see the
# product name, which is also where install-app.sh puts it.
mkdir -p "$staging"
/usr/bin/ditto "$app_bundle" "$staging/Metagent.app"
tiffutil \
  -cathidpicheck "$background_png" "$background_2x_png" \
  -out "$background_tiff"

mkdir -p "$(dirname "$output")"
rm -f "$output"

# Finder can reserve vertical room for its tab/path bars even when the DMG asks
# it to hide the toolbar and status bar. Give the outer window enough height to
# show the entire 424×260 background without a scrollbar.
create-dmg \
  --volname "$volume_name" \
  --volicon "$app_bundle/Contents/Resources/AppIcon.icns" \
  --background "$background_tiff" \
  --window-pos 180 120 \
  --window-size 424 320 \
  --text-size 11 \
  --icon-size 76 \
  --icon "Metagent.app" 106 145 \
  --app-drop-link 318 145 \
  --no-internet-enable \
  --hdiutil-retries 10 \
  --overwrite \
  "$output" \
  "$staging"

if [[ -n "$signing_identity" ]]; then
  # Signing the image itself is what lets Gatekeeper vouch for the download
  # before the user has opened anything inside it.
  codesign --force --sign "$signing_identity" --timestamp "$output"
  codesign --verify --strict --verbose=2 "$output"
  echo "Signed $output with $signing_identity"
else
  echo "No Developer ID Application identity found; the disk image is unsigned." >&2
  echo "Set METAGENT_CODE_SIGN_IDENTITY before packaging a public download." >&2
fi

echo "$output"
