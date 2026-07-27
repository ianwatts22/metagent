#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_source="$repo_root/apps/MetagentMenuBar"
app_bundle="$repo_root/dist/MetagentMenuBar.app"
contents="$app_bundle/Contents"
macos="$contents/MacOS"
helpers="$contents/Helpers"
frameworks="$contents/Frameworks"
resources="$contents/Resources"
signing_identity="${METAGENT_CODE_SIGN_IDENTITY:-}"
configuration="${METAGENT_BUILD_CONFIGURATION:-release}"
# Local builds sign with a development certificate, which is enough to run the
# app on this machine. Public downloads need Developer ID, because that is the
# only identity Gatekeeper accepts and the only one notarization will process.
distribution="${METAGENT_DISTRIBUTION_BUILD:-0}"
# The channel decides what the bundle claims to be. `release` is the shipping
# identity; `dev` builds a separate app ("Metagent Dev", bundle ID suffixed
# .dev, no Sparkle feed) so a locally installed build can never collide with
# the website-installed copy or be rolled back by its updater.
channel="${METAGENT_CHANNEL:-release}"

case "$channel" in
  release|dev) ;;
  *)
    echo "Invalid METAGENT_CHANNEL: $channel (expected release or dev)" >&2
    exit 1
    ;;
esac

if [[ "$distribution" == "1" && "$channel" == "dev" ]]; then
  echo "A distribution build cannot use the dev channel." >&2
  exit 1
fi

case "$configuration" in
  release|debug) ;;
  *)
    echo "Invalid METAGENT_BUILD_CONFIGURATION: $configuration (expected debug or release)" >&2
    exit 1
    ;;
esac

if [[ "$distribution" == "1" ]]; then
  identity_prefix="Developer ID Application: "
  identity_label="Developer ID Application"
  identity_hint="Create one at developer.apple.com > Certificates, or in Xcode Settings > Accounts > Manage Certificates."
else
  identity_prefix="Apple Development: "
  identity_label="Apple Development"
  identity_hint="Create one in Xcode Settings > Accounts > Manage Certificates, then retry."
fi

if [[ -z "$signing_identity" ]]; then
  detected_identities="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | awk -v prefix="\"$identity_prefix" 'index($0, prefix) { print $2 }'
  )"
  identity_count="$(awk 'NF { count += 1 } END { print count + 0 }' <<<"$detected_identities")"
  if [[ "$identity_count" == "1" ]]; then
    signing_identity="$detected_identities"
  elif [[ "$identity_count" -gt 1 ]]; then
    echo "Multiple $identity_label identities found." >&2
    echo "Set METAGENT_CODE_SIGN_IDENTITY to the intended certificate hash." >&2
    if [[ "${METAGENT_REQUIRE_STABLE_SIGNING:-0}" == "1" || "$distribution" == "1" ]]; then
      exit 1
    fi
  fi
fi

if [[ -z "$signing_identity" ]] \
  && [[ "${METAGENT_REQUIRE_STABLE_SIGNING:-0}" == "1" || "$distribution" == "1" ]]; then
  echo "A $identity_label code-signing identity is required for this build." >&2
  echo "$identity_hint" >&2
  exit 1
fi

source "$repo_root/scripts/lib.sh"
setup_swift_build_env

"$repo_root/scripts/generate-app-assets.sh"

(
  cd "$app_source"
  # Sparkle ships as a binary framework, and this bundle is assembled by hand
  # rather than by Xcode, so the executable needs an explicit rpath into the
  # Frameworks directory it will actually be loaded from.
  swift build --disable-sandbox -c "$configuration" --product MetagentMenuBar \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks
  swift build --disable-sandbox -c "$configuration" --product metagent
)

sparkle_framework="$(
  find "$app_source/.build/artifacts/sparkle" \
    -maxdepth 4 \
    -type d \
    -path '*/macos-*/Sparkle.framework' \
    2>/dev/null \
    | head -n 1
)"

if [[ -z "$sparkle_framework" ]]; then
  echo "Sparkle.framework was not found under .build/artifacts." >&2
  echo "Run 'swift package resolve' in $app_source and retry." >&2
  exit 1
fi

discard_bundle() {
  local target="$1"
  [[ -e "$target" ]] || return 0
  if command -v trash >/dev/null 2>&1; then
    trash "$target" >/dev/null 2>&1 || true
  fi
  rm -rf "$target"
}

# Sweep backups left behind by builds that failed before their cleanup ran.
while IFS= read -r stale_bundle; do
  discard_bundle "$stale_bundle"
done < <(find "$repo_root/dist" -maxdepth 1 -type d -name '.MetagentMenuBar.app.previous-*')

previous_bundle=""
if [[ -e "$app_bundle" ]]; then
  previous_bundle="$repo_root/dist/.MetagentMenuBar.app.previous-$(date +%Y%m%d%H%M%S)"
  mv "$app_bundle" "$previous_bundle"
fi

mkdir -p "$macos" "$helpers" "$frameworks" "$resources"
cp "$app_source/.build/$configuration/MetagentMenuBar" "$macos/MetagentMenuBar"
cp "$app_source/.build/$configuration/metagent" "$helpers/metagent"
cp "$app_source/Info.plist" "$contents/Info.plist"

if [[ "$channel" == "dev" ]]; then
  # A dev build is a different app, not an older version of the real one.
  # Distinct bundle ID: never shares defaults, login-item registration, or a
  # running-instance identity with prod, so both can run side by side.
  # No feed keys: AppUpdateStartupPolicy treats a missing SUFeedURL as
  # unconfigured and never starts Sparkle, so the public appcast (whose build
  # numbers always exceed a local build's) can never "update" a dev install
  # back to an older release.
  git_sha="$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  /usr/libexec/PlistBuddy \
    -c "Set :CFBundleIdentifier com.ianwatts.metagent.menu-bar.dev" \
    -c "Set :CFBundleName Metagent Dev" \
    -c "Set :CFBundleShortVersionString 0.0.0-dev" \
    -c "Set :CFBundleVersion 0" \
    "$contents/Info.plist"
  /usr/libexec/PlistBuddy \
    -c "Add :MetagentBuildCommit string $git_sha" \
    "$contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy \
      -c "Set :MetagentBuildCommit $git_sha" \
      "$contents/Info.plist"
  for feed_key in SUFeedURL SUPublicEDKey SUEnableAutomaticChecks; do
    /usr/libexec/PlistBuddy -c "Delete :$feed_key" "$contents/Info.plist" 2>/dev/null || true
  done
fi

# Sparkle decides an update exists by comparing CFBundleVersion against the
# appcast, so shipping the checked-in placeholder on every release would leave
# installed copies believing they are already current. The tag drives both.
if [[ -n "${METAGENT_VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy \
    -c "Set :CFBundleShortVersionString $METAGENT_VERSION" \
    "$contents/Info.plist"
fi
if [[ -n "${METAGENT_BUILD_NUMBER:-}" ]]; then
  /usr/libexec/PlistBuddy \
    -c "Set :CFBundleVersion $METAGENT_BUILD_NUMBER" \
    "$contents/Info.plist"
fi

if [[ "$distribution" == "1" ]]; then
  if [[ -z "${METAGENT_VERSION:-}" || -z "${METAGENT_BUILD_NUMBER:-}" ]]; then
    echo "Distribution builds require METAGENT_VERSION and METAGENT_BUILD_NUMBER." >&2
    echo "Without them every release advertises the same version to Sparkle." >&2
    exit 1
  fi
  for placeholder_key in SUFeedURL SUPublicEDKey; do
    placeholder_value="$(
      /usr/libexec/PlistBuddy -c "Print :$placeholder_key" "$contents/Info.plist" 2>/dev/null || true
    )"
    if [[ -z "$placeholder_value" || "$placeholder_value" == *REPLACE_ME* ]]; then
      echo "$placeholder_key is still a placeholder in Info.plist." >&2
      echo "Set the appcast URL and the Sparkle EdDSA public key before publishing." >&2
      exit 1
    fi
  done
fi
cp "$app_source/Sources/Resources/AppIcon.icns" "$resources/AppIcon.icns"
# Assets.car carries the macOS 26 icon appearance variants; CFBundleIconName
# in Info.plist is what makes the system read them.
cp "$app_source/Sources/Resources/Assets.car" "$resources/Assets.car"
cp "$app_source/Sources/Resources/MenuBarIconTemplate.pdf" "$resources/MenuBarIconTemplate.pdf"
cp "$app_source/Sources/Resources/Lucide/LICENSE" "$resources/Lucide-LICENSE.txt"
cp "$app_source/Sources/Resources/Lucide/sprite.svg" "$resources/Lucide-sprite.svg"
cp "$app_source/Sources/Resources/Lucide/tags.json" "$resources/Lucide-tags.json"
cp "$app_source/Sources/Resources/Lucide/VERSION" "$resources/Lucide-VERSION.txt"

# ditto rather than cp, because the framework's Versions/Current symlink has to
# survive the copy for the bundle to load at runtime.
rm -rf "$frameworks/Sparkle.framework"
/usr/bin/ditto "$sparkle_framework" "$frameworks/Sparkle.framework"
# Headers are build inputs, not runtime code. Dropping them keeps the shipped
# bundle smaller and matches what Xcode's framework embedding produces.
rm -rf \
  "$frameworks/Sparkle.framework/Versions/B/Headers" \
  "$frameworks/Sparkle.framework/Versions/B/PrivateHeaders" \
  "$frameworks/Sparkle.framework/Versions/B/Modules"

chmod +x "$macos/MetagentMenuBar"
chmod +x "$helpers/metagent"

if [[ -n "$signing_identity" ]]; then
  # A secure timestamp is mandatory for notarization and needs Apple's timestamp
  # server, so local development builds keep skipping it to stay offline-capable.
  if [[ "$distribution" == "1" ]]; then
    timestamp_flag=(--timestamp)
  else
    timestamp_flag=(--timestamp=none)
  fi

  # The hardened runtime is a notarization requirement. It is applied to local
  # builds too, so a runtime restriction shows up here rather than in a release.
  sign() {
    codesign \
      --force \
      --sign "$signing_identity" \
      --options runtime \
      "${timestamp_flag[@]}" \
      "$@"
  }

  # Nested code has to be signed before its container, innermost first, or the
  # outer signature seals a hash that no longer matches.
  sparkle_versioned="$frameworks/Sparkle.framework/Versions/B"
  # Sparkle's own signing guidance: re-sign the downloader without discarding
  # whatever entitlements it shipped with. 2.9.4 ships none, so this currently
  # preserves an empty set and exists so a future sandboxed build stays intact.
  sign --preserve-metadata=entitlements "$sparkle_versioned/XPCServices/Downloader.xpc"
  sign "$sparkle_versioned/XPCServices/Installer.xpc"
  sign "$sparkle_versioned/Autoupdate"
  sign "$sparkle_versioned/Updater.app"
  sign "$sparkle_versioned"
  sign "$helpers/metagent"
  sign "$app_bundle"

  codesign --verify --deep --strict --verbose=2 "$app_bundle"
  designated_requirement="$(codesign -dr - "$app_bundle" 2>&1)"
  if [[ "${METAGENT_REQUIRE_STABLE_SIGNING:-0}" == "1" || "$distribution" == "1" ]] \
    && ! grep -q "anchor apple generic" <<<"$designated_requirement"; then
    echo "Installation requires an Apple-anchored code-signing identity." >&2
    echo "$designated_requirement" >&2
    exit 1
  fi
  if [[ "$distribution" == "1" ]]; then
    # Catch a missing hardened runtime here instead of in a notarization log.
    signature_details="$(codesign --display --verbose=2 "$app_bundle" 2>&1)"
    if ! grep -q "flags=.*runtime" <<<"$signature_details"; then
      echo "Distribution builds must carry the hardened runtime." >&2
      exit 1
    fi
  fi
  echo "Signed with $signing_identity"
else
  echo "Built without an Apple code-signing identity; this build is not suitable for local installation." >&2
fi

if [[ -n "$previous_bundle" ]]; then
  discard_bundle "$previous_bundle"
fi

echo "$app_bundle"
