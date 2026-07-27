#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
install_dir="${METAGENT_APPLICATIONS_DIR:-$HOME/Applications}"
installed_app="$install_dir/Metagent Dev.app"
launch_mode="none"

usage() {
  cat <<'USAGE'
Usage:
  scripts/install-app.sh [--launch|--restart]

Builds the DEV channel of the menu bar app and installs it to:
  ~/Applications/Metagent Dev.app

The production app at ~/Applications/Metagent.app is installed from
https://metagent.sh and updated by Sparkle. This script never touches it:
local builds carry the .dev bundle ID, a dev version stamp, and no update
feed, so the two apps coexist and neither can overwrite the other.

Options:
  --launch    Open the installed app after installing.
  --restart   Ask the existing app to quit, then open the installed app.

Set METAGENT_APPLICATIONS_DIR to install somewhere else.
USAGE
}

while (($# > 0)); do
  case "$1" in
    --launch)
      launch_mode="launch"
      shift
      ;;
    --restart)
      launch_mode="restart"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

built_output="$(METAGENT_REQUIRE_STABLE_SIGNING=1 METAGENT_CHANNEL=dev "$repo_root/scripts/build-app.sh")"
printf '%s\n' "$built_output"
built_app="$(printf '%s\n' "$built_output" | awk 'NF { line=$0 } END { print line }')"

if [[ ! -d "$built_app" ]]; then
  echo "Build did not produce an app bundle path: $built_app" >&2
  exit 1
fi

mkdir -p "$install_dir"

backup_app=""
if [[ -e "$installed_app" ]]; then
  backup_app="$install_dir/.Metagent Dev.app.previous-$(date +%Y%m%d%H%M%S)"
  mv "$installed_app" "$backup_app"
fi

/usr/bin/ditto "$built_app" "$installed_app"
codesign --verify --deep --strict --verbose=2 "$installed_app"
installed_requirement="$(codesign -dr - "$installed_app" 2>&1)"
if ! grep -q "anchor apple generic" <<<"$installed_requirement"; then
  echo "Installed app does not have an Apple-anchored designated requirement." >&2
  echo "$installed_requirement" >&2
  exit 1
fi

if [[ -n "$backup_app" ]]; then
  if command -v trash >/dev/null 2>&1; then
    trash "$backup_app" || true
  fi
  if [[ -e "$backup_app" ]]; then
    echo "Previous app moved to $backup_app"
    echo "Install succeeded; remove that backup later if you do not need it."
  fi
fi

case "$launch_mode" in
  launch)
    open "$installed_app"
    ;;
  restart)
    osascript -e 'tell application id "com.ianwatts.metagent.menu-bar.dev" to quit' >/dev/null 2>&1 || true
    sleep 0.5
    open "$installed_app"
    ;;
esac

echo "$installed_app"
