#!/usr/bin/env bash
set -euo pipefail

channel="dev"
output_root=""
scenario=""
settle_seconds=3
sample_count=3
sample_interval_seconds=1

usage() {
  cat <<'USAGE'
Usage: scripts/profile-app-memory.sh [--channel dev|prod] [--scenario LABEL]
       [--settle SECONDS] [--samples ODD_COUNT] [--interval SECONDS]
       [--output EMPTY_DIR]

After a bounded settle, captures an odd number of read-only vmmap snapshots for
one running Metagent process. Reports median snapshot metrics, their ranges, and
the separately labeled process-lifetime peak. Existing output is never replaced.
USAGE
}

while (($# > 0)); do
  case "$1" in
    --channel)
      channel="$2"
      shift 2
      ;;
    --scenario)
      scenario="$2"
      shift 2
      ;;
    --settle)
      settle_seconds="$2"
      shift 2
      ;;
    --samples)
      sample_count="$2"
      shift 2
      ;;
    --interval)
      sample_interval_seconds="$2"
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
if ! [[ "$settle_seconds" =~ ^[0-9]+$ ]] || ((settle_seconds > 60)); then
  echo "Settle seconds must be a whole number from 0 through 60." >&2
  exit 2
fi
if ! [[ "$sample_count" =~ ^[1-9][0-9]*$ ]] \
    || ((sample_count > 9 || sample_count % 2 == 0)); then
  echo "Sample count must be an odd whole number from 1 through 9." >&2
  exit 2
fi
if ! [[ "$sample_interval_seconds" =~ ^[0-9]+$ ]] || ((sample_interval_seconds > 60)); then
  echo "Sample interval must be a whole number from 0 through 60 seconds." >&2
  exit 2
fi
if ! command -v vmmap >/dev/null 2>&1; then
  echo "vmmap is required and is only available on macOS." >&2
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
executable_sha256="$(shasum -a 256 "$executable_path" | awk '{print $1}')"

if [[ -z "$output_root" ]]; then
  output_root="$(mktemp -d "/private/tmp/metagent-memory-${channel}.XXXXXX")"
else
  mkdir -p "$output_root"
fi

if ((settle_seconds > 0)); then
  sleep "$settle_seconds"
fi

raw_paths=()
for ((sample_index = 1; sample_index <= sample_count; sample_index += 1)); do
  printf -v sample_suffix '%03d' "$sample_index"
  raw_path="${output_root}/vmmap-summary-${sample_suffix}.txt"
  vmmap -summary "$pid" >"$raw_path"
  raw_paths+=("$raw_path")
  if ((sample_index < sample_count && sample_interval_seconds > 0)); then
    sleep "$sample_interval_seconds"
  fi
done

summary_path="${output_root}/summary.txt"
json_path="${output_root}/summary.json"
summary_arguments=(
  "${raw_paths[@]}"
  --json-output "$json_path"
  --channel "$channel"
  --pid "$pid"
  --executable-path "$executable_path"
  --executable-sha256 "$executable_sha256"
  --settle-seconds "$settle_seconds"
  --sample-interval-seconds "$sample_interval_seconds"
)
if [[ -n "$scenario" ]]; then
  summary_arguments+=(--scenario "$scenario")
fi
python3 "$(dirname "$0")/summarize-memory.py" "${summary_arguments[@]}" \
  | tee "$summary_path"

printf 'output: %s\n' "$output_root"
printf 'summary: %s\n' "$summary_path"
printf 'json: %s\n' "$json_path"
