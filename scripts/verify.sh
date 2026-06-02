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

"$repo_root/scripts/build-menu-bar-app.sh" >/dev/null
plutil -lint "$repo_root/dist/AgentToolsMenuBar.app/Contents/Info.plist" >/dev/null
test -x "$repo_root/dist/AgentToolsMenuBar.app/Contents/MacOS/AgentToolsMenuBar"
"$repo_root/target/debug/agent-tools" skills scan --max-depth 3 >/dev/null

echo "agent-tools verification passed"
