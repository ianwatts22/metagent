#!/usr/bin/env bash
set -euo pipefail

channel="dev"
scenario="tabs"
iterations=5
iterations_explicit=false
timeout_seconds=30
output_root=""

usage() {
  cat <<'USAGE'
Usage: scripts/measure-app-interactions.sh [--channel dev|prod]
       [--scenario tabs|common-interactions|skills-cycle|refresh|launch-warm|launch-cold] [--iterations COUNT]
       [--timeout SECONDS] [--output EMPTY_DIR]

Measures Metagent through macOS Accessibility. Tab and common-interaction
measurements report both AXSelected diagnostics and view-specific AX content-ready
latency; they do not claim first-pixel or compositor presentation. The bounded
common-interactions scenario exercises tabs, top-level filters, and primary-column
sorts through exact Accessibility identifiers with no coordinate fallback.
Refresh measurements require the Reload control to leave
and return to its enabled ready state. Launch scenarios stop/start the selected
channel and leave it running; launch-cold requires it to be stopped beforehand.
skills-cycle performs only Overview → Skills → Overview, with a one-second Skills
dwell, so before/after memory captures have a reproducible view-cycle protocol.
Existing output is never replaced.
USAGE
}

while (($# > 0)); do
  case "$1" in
    --channel) channel="$2"; shift 2 ;;
    --scenario) scenario="$2"; shift 2 ;;
    --iterations) iterations="$2"; iterations_explicit=true; shift 2 ;;
    --timeout) timeout_seconds="$2"; shift 2 ;;
    --output) output_root="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ "$scenario" == "skills-cycle" && "$iterations_explicit" == "false" ]]; then
  iterations=1
fi

if [[ "$channel" != "dev" && "$channel" != "prod" ]]; then
  echo "Channel must be dev or prod." >&2
  exit 2
fi
if [[ "$scenario" != "tabs" && "$scenario" != "common-interactions" \
      && "$scenario" != "skills-cycle" && "$scenario" != "refresh" \
      && "$scenario" != "launch-warm" && "$scenario" != "launch-cold" ]]; then
  echo "Scenario must be tabs, common-interactions, skills-cycle, refresh, launch-warm, or launch-cold." >&2
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
if [[ "$(uname -s)" != "Darwin" ]] || ! command -v xcrun >/dev/null 2>&1; then
  echo "App interaction measurement requires macOS and the Xcode command-line tools." >&2
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
automation_inactivity_timeout_seconds=$((timeout_seconds + 5))
probe_source="$repo_root/scripts/metagent-ax-probe.swift"
probe_cache_base="${TMPDIR:-/private/tmp}"
probe_cache_root="${probe_cache_base%/}/metagent-ax-probe-cache-$(id -u)"
probe_source_sha="$(shasum -a 256 "$probe_source" | awk '{print $1}')"
probe_compiler_version="$(xcrun swiftc -version 2>&1 | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
probe_compile_contract="swiftc:-O:AppKit:ApplicationServices:v1"
probe_cache_key="$(printf '%s\n%s\n%s\n' "$probe_source_sha" "$probe_compiler_version" "$probe_compile_contract" | shasum -a 256 | awk '{print $1}')"
probe_binary="$probe_cache_root/metagent-ax-probe-$probe_cache_key"
probe_temporary=""

cleanup_probe_temporary() {
  [[ -n "$probe_temporary" && -e "$probe_temporary" ]] || return 0
  if command -v trash >/dev/null 2>&1; then
    trash "$probe_temporary"
  else
    unlink "$probe_temporary"
  fi
}
trap cleanup_probe_temporary EXIT

if [[ -L "$probe_cache_root" ]]; then
  echo "Refusing symbolic-link Accessibility probe cache: $probe_cache_root" >&2
  exit 1
fi
mkdir -p -m 700 "$probe_cache_root"
if [[ "$(/usr/bin/stat -f %u "$probe_cache_root")" != "$(id -u)" ]]; then
  echo "Accessibility probe cache is not owned by the current user: $probe_cache_root" >&2
  exit 1
fi
chmod 700 "$probe_cache_root"

if [[ -e "$probe_binary" ]] && { [[ -L "$probe_binary" ]] \
    || [[ "$(/usr/bin/stat -f %u "$probe_binary")" != "$(id -u)" ]] \
    || [[ ! -x "$probe_binary" ]]; }; then
  echo "Refusing unsafe cached Accessibility probe: $probe_binary" >&2
  exit 1
fi

if [[ ! -x "$probe_binary" ]]; then
  probe_temporary="$(mktemp "$probe_cache_root/metagent-ax-probe.XXXXXX")"
  if ! xcrun swiftc -O \
    -module-cache-path "$probe_cache_root/swift-module-cache" \
    -framework AppKit \
    -framework ApplicationServices \
    "$probe_source" \
    -o "$probe_temporary"; then
    echo "Could not compile the native Accessibility probe." >&2
    exit 1
  fi
  chmod 700 "$probe_temporary"
  mv "$probe_temporary" "$probe_binary"
  probe_temporary=""
fi

plist_value() {
  local key="$1"
  local value
  value="$(plutil -extract "$key" raw -o - "$plist_path" 2>/dev/null || true)"
  printf '%s\n' "${value:-unknown}"
}

automation_status=0
python3 "$repo_root/scripts/run-with-inactivity-timeout.py" \
  --inactivity-timeout "$automation_inactivity_timeout_seconds" \
  --stdout "$raw_path" \
  -- "$probe_binary" \
    "$app_path" "$process_name" "$scenario" "$iterations" "$((timeout_seconds * 1000))" \
  || automation_status=$?
if [[ "$automation_status" == "124" ]]; then
  echo "Accessibility automation timed out after producing no progress; partial raw output remains at $raw_path." >&2
  exit 124
elif [[ "$automation_status" != "0" ]]; then
  echo "Accessibility automation failed. Grant Accessibility access to the terminal/Codex host, keep the Metagent window open, and retry." >&2
  exit "$automation_status"
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
  --low-power-mode "${low_power_mode:-unknown}" \
  --probe-source-sha256 "$probe_source_sha" \
  --probe-binary-sha256 "$(shasum -a 256 "$probe_binary" | awk '{print $1}')" \
  --probe-compiler-version "$probe_compiler_version" \
  --probe-compile-contract "$probe_compile_contract"

printf 'raw: %s\n' "$raw_path"
printf 'summary: %s\n' "$summary_path"
printf 'json: %s\n' "$summary_json_path"
