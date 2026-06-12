#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cargo install \
  --path "$repo_root/crates/metagent-cli" \
  --locked

echo "Installed metagent to $(command -v metagent || echo "$HOME/.cargo/bin/metagent")"

