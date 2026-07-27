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

if [[ ! -d "$app_bundle" ]]; then
  echo "No app bundle at $app_bundle." >&2
  echo "Run scripts/build-app.sh first." >&2
  exit 1
fi

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

staging="$(mktemp -d)"
cleanup() {
  rm -rf "$staging"
}
trap cleanup EXIT

# The bundle is named for its executable on disk, but users should see the
# product name, which is also where install-app.sh puts it.
/usr/bin/ditto "$app_bundle" "$staging/Metagent.app"
ln -s /Applications "$staging/Applications"

mkdir -p "$(dirname "$output")"
rm -f "$output"

hdiutil create \
  -volname "$volume_name" \
  -srcfolder "$staging" \
  -fs HFS+ \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  "$output"

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
