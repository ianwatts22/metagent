#!/usr/bin/env bash
set -euo pipefail

# Packages the signed app bundle for Sparkle. The archive must contain
# Metagent.app: Sparkle matches the update bundle by the installed filename or
# CFBundleName and will reject the internal build name MetagentMenuBar.app.
#
# Usage:
#   scripts/package-update.sh [output.zip]

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_bundle="$repo_root/dist/MetagentMenuBar.app"
output="${1:-$repo_root/artifacts/updates/Metagent.zip}"

if [[ ! -d "$app_bundle" ]]; then
  echo "No app bundle at $app_bundle." >&2
  echo "Run scripts/build-app.sh first." >&2
  exit 1
fi

temp_root="$(mktemp -d)"
cleanup() {
  rm -rf "$temp_root"
}
trap cleanup EXIT

staged_app="$temp_root/Metagent.app"
/usr/bin/ditto "$app_bundle" "$staged_app"

mkdir -p "$(dirname "$output")"
rm -f "$output"
/usr/bin/ditto -c -k --keepParent "$staged_app" "$output"

verification_root="$temp_root/verification"
mkdir -p "$verification_root"
/usr/bin/ditto -x -k "$output" "$verification_root"

if [[ ! -d "$verification_root/Metagent.app" ]]; then
  echo "Sparkle archive must contain Metagent.app at its top level." >&2
  exit 1
fi
if find "$verification_root" -mindepth 1 -maxdepth 1 ! -name "Metagent.app" | grep -q .; then
  echo "Sparkle archive contains unexpected top-level items." >&2
  exit 1
fi

if /usr/bin/codesign --display "$app_bundle" >/dev/null 2>&1; then
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$verification_root/Metagent.app"
elif [[ "${METAGENT_REQUIRE_SIGNED_UPDATE:-0}" == "1" ]]; then
  echo "Public Sparkle archives require a signed app bundle." >&2
  exit 1
else
  echo "App bundle is unsigned; verified archive layout and version only." >&2
fi

source_info="$app_bundle/Contents/Info.plist"
archive_info="$verification_root/Metagent.app/Contents/Info.plist"
for version_key in CFBundleShortVersionString CFBundleVersion; do
  source_value="$(/usr/libexec/PlistBuddy -c "Print :$version_key" "$source_info")"
  archive_value="$(/usr/libexec/PlistBuddy -c "Print :$version_key" "$archive_info")"
  if [[ "$archive_value" != "$source_value" ]]; then
    echo "Sparkle archive changed $version_key ($source_value → $archive_value)." >&2
    exit 1
  fi
done

echo "$output"
