#!/usr/bin/env bash
set -euo pipefail

channel="dev"
output_root=""

usage() {
  cat <<'USAGE'
Usage: scripts/profile-app-memory.sh [--channel dev|prod] [--output DIR]

Captures a read-only vmmap summary for one running Metagent process and reports
physical footprint separately from live malloc allocations and fragmentation.
USAGE
}

while (($# > 0)); do
  case "$1" in
    --channel)
      channel="$2"
      shift 2
      ;;
    --output)
      output_root="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$channel" != "dev" && "$channel" != "prod" ]]; then
  echo "Channel must be dev or prod." >&2
  exit 2
fi
if ! command -v vmmap >/dev/null 2>&1; then
  echo "vmmap is required and is only available on macOS." >&2
  exit 1
fi

app_name="Metagent.app"
if [[ "$channel" == "dev" ]]; then
  app_name="Metagent Dev.app"
fi
app_path="${HOME}/Applications/${app_name}"
executable_path="${app_path}/Contents/MacOS/MetagentMenuBar"
pid="$(pgrep -f "^${executable_path}$" | head -n 1 || true)"
if [[ -z "$pid" ]]; then
  echo "No running ${app_name} process found at ${executable_path}." >&2
  exit 1
fi

if [[ -z "$output_root" ]]; then
  output_root="$(mktemp -d "/private/tmp/metagent-memory-${channel}.XXXXXX")"
else
  mkdir -p "$output_root"
fi

raw_path="${output_root}/vmmap-summary.txt"
summary_path="${output_root}/summary.txt"
json_path="${output_root}/summary.json"
vmmap -summary "$pid" >"$raw_path"
python3 "$(dirname "$0")/summarize-memory.py" "$raw_path" --json-output "$json_path" \
  | tee "$summary_path"

printf 'pid: %s\n' "$pid"
printf 'vmmap: %s\n' "$raw_path"
printf 'summary: %s\n' "$summary_path"
printf 'json: %s\n' "$json_path"
