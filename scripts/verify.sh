#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$repo_root"
cargo fmt --check
cargo test

(
  cd "$repo_root/apps/AgentToolsMenuBar"
  swift build
)

"$repo_root/target/debug/agent-tools" skills scan --max-depth 3 >/dev/null

echo "agent-tools verification passed"

