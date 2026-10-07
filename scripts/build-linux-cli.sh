#!/usr/bin/env bash
# Builds the headless `metagent` helper (CLI + MCP server) for Linux.
#
# --static (release builds) links against musl with Swift's Static Linux SDK
# (scripts/install-static-linux-sdk.sh), producing one executable with no
# shared-library dependencies that runs on any Linux, Alpine included.
#
# Without --static the binary links the Swift runtime statically but still
# needs glibc, libstdc++, and libcurl (FoundationNetworking, which the MCP SDK
# requires). That build is quicker and needs no extra SDK, which suits CI.
#
# Usage: scripts/build-linux-cli.sh --output PATH [--static]
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output=""
static=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --static) static=true; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$output" ]] || { echo "usage: $0 --output PATH [--static]" >&2; exit 2; }
[[ "$(uname -s)" == "Linux" ]] || { echo "build-linux-cli.sh must run on Linux" >&2; exit 1; }

cd "$repo_root/apps/MetagentMenuBar"
if $static; then
  flags=(--swift-sdk "$(uname -m)-swift-linux-musl")
else
  flags=(--static-swift-stdlib)
fi
swift build -c release --product metagent "${flags[@]}" -Xswiftc -gnone
binary="$(swift build -c release --product metagent "${flags[@]}" --show-bin-path)/metagent"
mkdir -p "$(dirname "$output")"
cp "$binary" "$output"
strip "$output" 2>/dev/null || true
"$output" --help > /dev/null
echo "Built $output ($(du -h "$output" | cut -f1))"
