#!/usr/bin/env bash
set -euo pipefail

# Submits one artifact to Apple's notary service, waits for the verdict, and
# staples the ticket so the result works offline and survives being copied.
#
# Usage:
#   scripts/notarize.sh dist/MetagentMenuBar.app
#   scripts/notarize.sh artifacts/Metagent.dmg
#
# Credentials come from either a stored keychain profile:
#   METAGENT_NOTARY_PROFILE
# or an App Store Connect app-specific password:
#   METAGENT_NOTARY_APPLE_ID
#   METAGENT_NOTARY_PASSWORD
#   METAGENT_NOTARY_TEAM_ID

target="${1:-}"

if [[ -z "$target" ]]; then
  echo "Usage: scripts/notarize.sh <path to .app, .dmg, or .pkg>" >&2
  exit 1
fi

if [[ ! -e "$target" ]]; then
  echo "Notarization target does not exist: $target" >&2
  exit 1
fi

notary_args=()
if [[ -n "${METAGENT_NOTARY_PROFILE:-}" ]]; then
  notary_args=(--keychain-profile "$METAGENT_NOTARY_PROFILE")
elif [[ -n "${METAGENT_NOTARY_APPLE_ID:-}" \
  && -n "${METAGENT_NOTARY_PASSWORD:-}" \
  && -n "${METAGENT_NOTARY_TEAM_ID:-}" ]]; then
  notary_args=(
    --apple-id "$METAGENT_NOTARY_APPLE_ID"
    --password "$METAGENT_NOTARY_PASSWORD"
    --team-id "$METAGENT_NOTARY_TEAM_ID"
  )
else
  echo "No notarization credentials found." >&2
  echo "Set METAGENT_NOTARY_PROFILE, or all of METAGENT_NOTARY_APPLE_ID," >&2
  echo "METAGENT_NOTARY_PASSWORD, and METAGENT_NOTARY_TEAM_ID." >&2
  exit 1
fi

cleanup_zip=""
cleanup() {
  [[ -n "$cleanup_zip" ]] && rm -f "$cleanup_zip"
}
trap cleanup EXIT

# The notary service does not accept a bare .app, so an app bundle is submitted
# as a zip. The ticket is still stapled to the bundle itself afterwards.
case "$target" in
  *.app)
    cleanup_zip="$(mktemp -d)/notarize.zip"
    /usr/bin/ditto -c -k --keepParent "$target" "$cleanup_zip"
    submission="$cleanup_zip"
    ;;
  *.dmg | *.pkg)
    submission="$target"
    ;;
  *)
    echo "Unsupported notarization target: $target" >&2
    echo "Expected a .app, .dmg, or .pkg." >&2
    exit 1
    ;;
esac

echo "Submitting $target to the notary service..."
set +e
submit_output="$(xcrun notarytool submit "$submission" "${notary_args[@]}" --wait 2>&1)"
submit_status=$?
set -e
printf '%s\n' "$submit_output"

if ((submit_status != 0)) || ! grep -q "status: Accepted" <<<"$submit_output"; then
  submission_id="$(awk '/^  id: / { print $2; exit }' <<<"$submit_output")"
  if [[ -n "$submission_id" ]]; then
    echo "Notarization did not succeed. Full log:" >&2
    xcrun notarytool log "$submission_id" "${notary_args[@]}" >&2 || true
  fi
  exit 1
fi

echo "Stapling the notarization ticket to $target..."
xcrun stapler staple "$target"
xcrun stapler validate "$target"

echo "$target"
