#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_source="$repo_root/apps/AgentToolsMenuBar"
app_bundle="$repo_root/dist/AgentToolsMenuBar.app"
contents="$app_bundle/Contents"
macos="$contents/MacOS"

(
  cd "$app_source"
  swift build -c release
)

mkdir -p "$macos"
cp "$app_source/.build/release/AgentToolsMenuBar" "$macos/AgentToolsMenuBar"
cp "$app_source/Info.plist" "$contents/Info.plist"

chmod +x "$macos/AgentToolsMenuBar"

echo "$app_bundle"

