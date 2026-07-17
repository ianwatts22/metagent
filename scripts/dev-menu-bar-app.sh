#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_source="$repo_root/apps/MetagentMenuBar"

snapshot() {
  find \
    "$app_source/Sources" \
    "$app_source/Package.swift" \
    "$app_source/Info.plist" \
    -type f \
    \( -name '*.swift' -o -name '*.plist' -o -name '*.svg' -o -name '*.pdf' -o -name '*.icns' \) \
    -exec stat -f '%m:%z:%N' {} \; \
    | LC_ALL=C sort \
    | shasum
}

reload() {
  printf '\n[%s] Rebuilding and restarting Metagent...\n' "$(date '+%H:%M:%S')"
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
