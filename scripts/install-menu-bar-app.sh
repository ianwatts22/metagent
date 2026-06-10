#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
install_dir="${AGENT_TOOLS_APPLICATIONS_DIR:-$HOME/Applications}"
installed_app="$install_dir/Agent Tools.app"
launch_mode="none"

usage() {
  cat <<'USAGE'
Usage:
  scripts/install-menu-bar-app.sh [--launch|--restart]

Builds the menu bar app and installs it to:
  ~/Applications/Agent Tools.app

Options:
  --launch    Open the installed app after installing.
  --restart   Ask the existing app to quit, then open the installed app.

Set AGENT_TOOLS_APPLICATIONS_DIR to install somewhere else.
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

built_output="$("$repo_root/scripts/build-menu-bar-app.sh")"
printf '%s\n' "$built_output"
built_app="$(printf '%s\n' "$built_output" | awk 'NF { line=$0 } END { print line }')"

if [[ ! -d "$built_app" ]]; then
  echo "Build did not produce an app bundle path: $built_app" >&2
  exit 1
fi

mkdir -p "$install_dir"

backup_app=""
if [[ -e "$installed_app" ]]; then
  backup_app="$install_dir/.Agent Tools.app.previous-$(date +%Y%m%d%H%M%S)"
  mv "$installed_app" "$backup_app"
fi

/usr/bin/ditto "$built_app" "$installed_app"

if [[ -n "$backup_app" ]]; then
  if command -v trash >/dev/null 2>&1; then
    trash "$backup_app"
  else
    echo "Previous app moved to $backup_app"
    echo "Install succeeded; remove that backup later if you do not need it."
  fi
fi

case "$launch_mode" in
  launch)
    open "$installed_app"
    ;;
  restart)
    osascript -e 'tell application id "com.ianwatts.agent-tools.menu-bar" to quit' >/dev/null 2>&1 || true
    sleep 0.5
    open "$installed_app"
    ;;
esac

echo "$installed_app"
