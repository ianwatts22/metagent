#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_source="$repo_root/apps/MetagentMenuBar"
app_bundle="$repo_root/dist/MetagentMenuBar.app"
contents="$app_bundle/Contents"
macos="$contents/MacOS"
helpers="$contents/Helpers"
resources="$contents/Resources"
signing_identity="${METAGENT_CODE_SIGN_IDENTITY:-}"

if [[ -z "$signing_identity" ]]; then
  detected_identities="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | awk '/"Apple Development: / { print $2 }'
  )"
  identity_count="$(awk 'NF { count += 1 } END { print count + 0 }' <<<"$detected_identities")"
  if [[ "$identity_count" == "1" ]]; then
    signing_identity="$detected_identities"
  elif [[ "$identity_count" -gt 1 ]]; then
    echo "Multiple Apple Development identities found." >&2
    echo "Set METAGENT_CODE_SIGN_IDENTITY to the intended certificate hash." >&2
    if [[ "${METAGENT_REQUIRE_STABLE_SIGNING:-0}" == "1" ]]; then
      exit 1
    fi
  fi
fi

if [[ -z "$signing_identity" && "${METAGENT_REQUIRE_STABLE_SIGNING:-0}" == "1" ]]; then
  echo "An Apple Development code-signing identity is required for installation." >&2
  echo "Create one in Xcode Settings > Accounts > Manage Certificates, then retry." >&2
  exit 1
fi

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

if [[ -n "$signing_identity" ]]; then
  codesign \
    --force \
    --sign "$signing_identity" \
    --timestamp=none \
    "$helpers/metagent"
  codesign \
    --force \
    --sign "$signing_identity" \
    --timestamp=none \
    "$app_bundle"
  codesign --verify --deep --strict --verbose=2 "$app_bundle"
  designated_requirement="$(codesign -dr - "$app_bundle" 2>&1)"
  if [[ "${METAGENT_REQUIRE_STABLE_SIGNING:-0}" == "1" ]] \
    && ! grep -q "anchor apple generic" <<<"$designated_requirement"; then
    echo "Installation requires an Apple-anchored code-signing identity." >&2
    echo "$designated_requirement" >&2
    exit 1
  fi
  echo "Signed with $signing_identity"
else
  echo "Built without an Apple code-signing identity; this build is not suitable for local installation." >&2
fi

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
