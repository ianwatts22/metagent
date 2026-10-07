#!/usr/bin/env bash
# Builds the headless `metagent` helper (CLI + MCP server) for Linux as one
# executable with the Swift runtime and Foundation linked in. The remaining
# shared libraries are glibc, libstdc++, and libcurl (for FoundationNetworking,
# which the MCP SDK requires). Build on the oldest glibc you want to support;
# release builds use Ubuntu 22.04 (glibc 2.35).
#
# Usage: scripts/build-linux-cli.sh --output PATH
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$output" ]] || { echo "usage: $0 --output PATH" >&2; exit 2; }
[[ "$(uname -s)" == "Linux" ]] || { echo "build-linux-cli.sh must run on Linux" >&2; exit 1; }

cd "$repo_root/apps/MetagentMenuBar"
swift build -c release --product metagent --static-swift-stdlib -Xswiftc -gnone
binary="$(swift build -c release --product metagent --show-bin-path)/metagent"
mkdir -p "$(dirname "$output")"
cp "$binary" "$output"
strip "$output" 2>/dev/null || true
"$output" --help > /dev/null
echo "Built $output ($(du -h "$output" | cut -f1))"
