#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cargo install \
  --path "$repo_root/crates/agent-tools-cli" \
  --locked

echo "Installed agent-tools to $(command -v agent-tools || echo "$HOME/.cargo/bin/agent-tools")"

