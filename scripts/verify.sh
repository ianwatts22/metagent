#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$repo_root"
cargo fmt --check
cargo test
cargo build -p metagent-cli
sg scan --config "$repo_root/sgconfig.yml" --filter no-direct-hard-delete --report-style short
bash -n "$repo_root/scripts/install-menu-bar-app.sh"

(
  cd "$repo_root/apps/MetagentMenuBar"
  swift build
)

"$repo_root/scripts/build-menu-bar-app.sh" >/dev/null
plutil -lint "$repo_root/dist/MetagentMenuBar.app/Contents/Info.plist" >/dev/null
test -x "$repo_root/dist/MetagentMenuBar.app/Contents/MacOS/MetagentMenuBar"
"$repo_root/target/debug/metagent" skills scan --root "$repo_root" --max-depth 3 >/dev/null
"$repo_root/target/debug/metagent" skills format --root "$repo_root" --max-depth 3 >/dev/null
"$repo_root/target/debug/metagent" config show --json >/dev/null
"$repo_root/target/debug/metagent" code-summary --repo "$repo_root" --graph none >/dev/null

echo "metagent verification passed"
