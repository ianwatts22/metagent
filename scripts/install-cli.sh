#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_source="$repo_root/apps/MetagentMenuBar"

if [[ -n "${METAGENT_INSTALL_DIR:-}" ]]; then
  install_dir="$METAGENT_INSTALL_DIR"
else
  resolved_metagent="$(command -v metagent 2>/dev/null || true)"
  if [[ -n "$resolved_metagent" && "$resolved_metagent" == "$HOME/"* ]]; then
    install_dir="$(dirname "$resolved_metagent")"
  else
    install_dir="$HOME/.local/bin"
  fi
fi

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/metagent-clang-cache}"

(
  cd "$app_source"
  swift build -c release --product metagent
)

mkdir -p "$install_dir"
installed_metagent="$install_dir/metagent"
install -m 0755 "$app_source/.build/release/metagent" "$installed_metagent"

resolved_after="$(command -v metagent 2>/dev/null || true)"
if [[ -n "$resolved_after" && "$resolved_after" != "$installed_metagent" ]]; then
  echo "Warning: PATH resolves metagent to $resolved_after before $installed_metagent" >&2
fi

echo "Installed metagent to $installed_metagent"
