#!/usr/bin/env bash
# Drives `metagent mcp --stdio` through initialize and tools/list, then closes
# stdin and requires the helper to exit on its own. Usage: smoke-mcp-stdio.sh BIN
set -euo pipefail

binary="${1:?usage: smoke-mcp-stdio.sh /path/to/metagent}"
output="$(mktemp)"
trap 'rm -f "$output"' EXIT

{
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}'
  printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
  sleep 2
} | timeout 30 "$binary" mcp --stdio > "$output"

grep -q '"id":1' "$output" || { echo "missing initialize response" >&2; cat "$output" >&2; exit 1; }
grep -q '"id":2' "$output" || { echo "missing tools/list response" >&2; cat "$output" >&2; exit 1; }
tools="$(grep -o '"name":"[a-z_]*"' "$output" | wc -l)"
[ "$tools" -gt 0 ] || { echo "tools/list returned no tools" >&2; exit 1; }
echo "metagent mcp --stdio: initialize ok, $tools tool names listed, exited on EOF"
