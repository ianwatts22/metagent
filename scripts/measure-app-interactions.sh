#!/usr/bin/env bash
set -euo pipefail

channel="dev"
scenario="tabs"
iterations=5
timeout_seconds=30
output_root=""

usage() {
  cat <<'USAGE'
Usage: scripts/measure-app-interactions.sh [--channel dev|prod]
       [--scenario tabs|refresh|launch-warm|launch-cold] [--iterations COUNT]
       [--timeout SECONDS] [--output EMPTY_DIR]

Measures Metagent through macOS Accessibility. Tab measurements
end at AXSelected and are deliberately labeled selected-state latency, not full
visual presentation. Refresh measurements require the Reload control to leave
and return to its enabled ready state. Launch scenarios stop/start the selected
channel and leave it running; launch-cold requires it to be stopped beforehand.
Existing output is never replaced.
USAGE
}

while (($# > 0)); do
  case "$1" in
    --channel) channel="$2"; shift 2 ;;
    --scenario) scenario="$2"; shift 2 ;;
    --iterations) iterations="$2"; shift 2 ;;
    --timeout) timeout_seconds="$2"; shift 2 ;;
    --output) output_root="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ "$channel" != "dev" && "$channel" != "prod" ]]; then
  echo "Channel must be dev or prod." >&2
  exit 2
fi
if [[ "$scenario" != "tabs" && "$scenario" != "refresh" \
      && "$scenario" != "launch-warm" && "$scenario" != "launch-cold" ]]; then
  echo "Scenario must be tabs, refresh, launch-warm, or launch-cold." >&2
  exit 2
fi
if ! [[ "$iterations" =~ ^[1-9][0-9]*$ ]] || ((iterations > 20)); then
  echo "Iterations must be a whole number from 1 through 20." >&2
  exit 2
fi
if [[ "$scenario" == "launch-cold" && "$iterations" != "1" ]]; then
  echo "launch-cold requires --iterations 1; every later launch would be warm." >&2
  exit 2
fi
if ! [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || ((timeout_seconds > 300)); then
  echo "Timeout must be a whole number from 1 through 300 seconds." >&2
  exit 2
fi
if [[ "$(uname -s)" != "Darwin" ]] || ! command -v osascript >/dev/null 2>&1; then
  echo "App interaction measurement requires macOS and osascript." >&2
  exit 1
fi
if [[ -n "$output_root" && -e "$output_root" ]]; then
  if [[ ! -d "$output_root" ]]; then
    echo "Output must be a directory: ${output_root}" >&2
    exit 2
  fi
  if [[ -n "$(find "$output_root" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    echo "Output directory must be empty; refusing to replace existing artifacts: ${output_root}" >&2
    exit 2
  fi
fi

app_name="Metagent.app"
process_name="Metagent"
if [[ "$channel" == "dev" ]]; then
  app_name="Metagent Dev.app"
  process_name="Metagent Dev"
fi
app_path="${HOME}/Applications/${app_name}"
executable_path="${app_path}/Contents/MacOS/MetagentMenuBar"
plist_path="${app_path}/Contents/Info.plist"
if [[ ! -x "$executable_path" ]]; then
  echo "No installed ${app_name} executable found at ${executable_path}." >&2
  exit 1
fi
if [[ "$scenario" != "launch-warm" && "$scenario" != "launch-cold" ]] \
    && ! pgrep -f "^${executable_path}$" >/dev/null 2>&1; then
  echo "No running ${app_name} process found. Start it and open the Metagent window first." >&2
  exit 1
fi

if [[ -z "$output_root" ]]; then
  output_root="$(mktemp -d "/private/tmp/metagent-interactions-${channel}-${scenario}.XXXXXX")"
else
  mkdir -p "$output_root"
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
raw_path="${output_root}/raw.json"
summary_path="${output_root}/summary.txt"
summary_json_path="${output_root}/summary.json"

plist_value() {
  local key="$1"
  local value
  value="$(plutil -extract "$key" raw -o - "$plist_path" 2>/dev/null || true)"
  printf '%s\n' "${value:-unknown}"
}

if ! osascript -l JavaScript \
  "$repo_root/scripts/measure-metagent-interactions.js" \
  "$app_path" "$process_name" "$scenario" "$iterations" "$((timeout_seconds * 1000))" \
  >"$raw_path"; then
  echo "Accessibility automation failed. Grant Accessibility access to the terminal/Codex host, keep the Metagent window open, and retry." >&2
  exit 1
fi

repo_commit="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)"
build_commit="$(plist_value MetagentSourceCommit)"
if [[ "$build_commit" == "unknown" ]]; then
  build_commit="$(plist_value MetagentBuildCommit)"
fi
power_source="$(pmset -g batt 2>/dev/null | awk -F"'" 'NR == 1 { print $2; exit }' || true)"
low_power_mode="$(pmset -g 2>/dev/null | awk '$1 == "lowpowermode" { print $2; exit }' || true)"
python3 "$repo_root/scripts/summarize-interactions.py" \
  "$raw_path" "$summary_path" "$summary_json_path" \
  --repo-commit "${repo_commit:-unknown}" \
  --build-commit "$build_commit" \
  --app-version "$(plist_value CFBundleShortVersionString)" \
  --app-build "$(plist_value CFBundleVersion)" \
  --executable-path "$executable_path" \
  --executable-sha256 "$(shasum -a 256 "$executable_path" | awk '{print $1}')" \
  --os-version "$(sw_vers -productVersion)" \
  --os-build "$(sw_vers -buildVersion)" \
  --hardware-model "$(sysctl -n hw.model 2>/dev/null || printf unknown)" \
  --cpu-model "$(sysctl -n machdep.cpu.brand_string 2>/dev/null || printf unknown)" \
  --power-source "${power_source:-unknown}" \
  --low-power-mode "${low_power_mode:-unknown}"

printf 'raw: %s\n' "$raw_path"
printf 'summary: %s\n' "$summary_path"
printf 'json: %s\n' "$summary_json_path"
