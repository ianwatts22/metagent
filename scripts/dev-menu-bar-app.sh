#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_source="$repo_root/apps/MetagentMenuBar"
configuration="debug"

usage() {
  cat <<'USAGE'
Usage:
  scripts/dev-menu-bar-app.sh [--release|--debug]

Watches app sources and rebuilds, installs, and restarts Metagent on every
change. Builds the debug configuration by default (--debug) so reloads stay
fast; pass --release to iterate against the optimized build instead.
USAGE
}

while (($# > 0)); do
  case "$1" in
    --release)
      configuration="release"
      shift
      ;;
    --debug)
      configuration="debug"
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

export METAGENT_BUILD_CONFIGURATION="$configuration"

snapshot() {
  find \
    "$app_source/Sources" \
    "$app_source/Package.swift" \
    "$app_source/Info.plist" \
    -type f \
    \( -name '*.swift' -o -name '*.plist' -o -name '*.svg' -o -name '*.json' -o -name '*.pdf' -o -name '*.icns' -o -name 'VERSION' \) \
    -exec stat -f '%m:%z:%N' {} \; \
    | LC_ALL=C sort \
    | shasum
}

reload() {
  printf '\n[%s] Rebuilding (%s) and restarting Metagent...\n' "$(date '+%H:%M:%S')" "$configuration"
  "$repo_root/scripts/install-menu-bar-app.sh" --restart
  printf '[%s] Metagent restarted. Watching for changes...\n' "$(date '+%H:%M:%S')"
}

reload
previous="$(snapshot)"

while sleep 0.75; do
  current="$(snapshot)"
  if [[ "$current" == "$previous" ]]; then
    continue
  fi
  previous="$current"
  reload
done
