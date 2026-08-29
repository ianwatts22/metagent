#!/usr/bin/env bash
set -euo pipefail

channel="dev"
duration=30
output_root=""
scenario="unspecified"

usage() {
  cat <<'USAGE'
Usage: scripts/measure-app-efficiency.sh [--channel dev|prod] [--duration SECONDS] [--scenario LABEL] [--output DIR]

Samples one running Metagent process once per second. The report includes app and
point-in-time observed-descendant CPU/RSS, resident memory, thread count, burst
duty cycle, memory trend, shared-database usage-index progress, local run
provenance, and a five-second stack sample. Descendant samples can miss processes
that start and exit between probes. It reads only aggregate usage metadata, not
app content or session history.
USAGE
}

while (($# > 0)); do
  case "$1" in
    --channel)
      channel="$2"
      shift 2
      ;;
    --duration)
      duration="$2"
      shift 2
      ;;
    --output)
      output_root="$2"
      shift 2
      ;;
    --scenario)
      scenario="$2"
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
if ! [[ "$duration" =~ ^[1-9][0-9]*$ ]]; then
  echo "Duration must be a positive whole number." >&2
  exit 2
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
other_app_name="Metagent Dev.app"
if [[ "$channel" == "dev" ]]; then
  app_name="Metagent Dev.app"
  other_app_name="Metagent.app"
fi
app_path="${HOME}/Applications/${app_name}"
executable_path="${app_path}/Contents/MacOS/MetagentMenuBar"
other_executable_path="${HOME}/Applications/${other_app_name}/Contents/MacOS/MetagentMenuBar"
pid="$(pgrep -f "^${executable_path}$" | head -n 1 || true)"
if [[ -z "$pid" ]]; then
  echo "No running ${app_name} process found at ${executable_path}." >&2
  exit 1
fi
other_channel_pid="$(pgrep -f "^${other_executable_path}$" | head -n 1 || true)"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
plist_path="${app_path}/Contents/Info.plist"

plist_value() {
  local key="$1"
  local value
  value="$(plutil -extract "$key" raw -o - "$plist_path" 2>/dev/null || true)"
  printf '%s\n' "${value:-unknown}"
}

repo_commit="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)"
repo_commit="${repo_commit:-unknown}"
build_commit="$(plist_value MetagentBuildCommit)"
app_version="$(plist_value CFBundleShortVersionString)"
app_build="$(plist_value CFBundleVersion)"
executable_sha256="$(shasum -a 256 "$executable_path" 2>/dev/null | awk '{print $1}' || true)"
executable_sha256="${executable_sha256:-unknown}"
os_version="$(sw_vers -productVersion 2>/dev/null || true)"
os_version="${os_version:-unknown}"
os_build="$(sw_vers -buildVersion 2>/dev/null || true)"
os_build="${os_build:-unknown}"
hardware_model="$(sysctl -n hw.model 2>/dev/null || true)"
hardware_model="${hardware_model:-unknown}"
cpu_model="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || true)"
cpu_model="${cpu_model:-unknown}"
power_source="$(pmset -g batt 2>/dev/null | awk -F"'" 'NR == 1 { print $2; exit }' || true)"
power_source="${power_source:-unknown}"
power_snapshot="$(pmset -g batt 2>/dev/null | awk 'NF { printf "%s%s", separator, $0; separator = " | " }' || true)"
power_snapshot="${power_snapshot:-unknown}"
low_power_mode="$(pmset -g 2>/dev/null | awk '$1 == "lowpowermode" { print $2; exit }' || true)"
low_power_mode="${low_power_mode:-unknown}"
thermal_snapshot="$(pmset -g therm 2>/dev/null | awk 'NF { printf "%s%s", separator, $0; separator = " | " }' || true)"
thermal_snapshot="${thermal_snapshot:-unknown}"

if [[ -z "$output_root" ]]; then
  output_root="$(mktemp -d "/private/tmp/metagent-efficiency-${channel}.XXXXXX")"
else
  mkdir -p "$output_root"
fi

samples_path="${output_root}/process-samples.csv"
summary_path="${output_root}/summary.txt"
summary_json_path="${output_root}/summary.json"
stack_path="${output_root}/stack-sample.txt"
printf '%s\n' \
  'second,cpu_percent,rss_kib,threads,processed_usage_bytes,processed_usage_delta_bytes,observed_descendant_reported_cpu_percent,observed_descendant_rss_kib,observed_descendant_processes' \
  >"$samples_path"

usage_database="${HOME}/Library/Application Support/Metagent/usage.sqlite"
processed_usage_bytes() {
  if [[ -f "$usage_database" ]] && command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 -readonly "$usage_database" \
      "SELECT value FROM skill_usage_metadata WHERE key = 'processed_bytes';" 2>/dev/null || true
  fi
}

cpu_seconds() {
  ps -p "$pid" -o time= | awk -F: '
    {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
      if (NF == 3) print ($1 * 3600) + ($2 * 60) + $3
      else print ($1 * 60) + $2
    }
  '
}

monotonic_seconds() {
  perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC -e \
    'printf "%.6f", clock_gettime(CLOCK_MONOTONIC)'
}

descendant_pids() {
  local queue=("$pid")
  local index=0
  local child
  while ((index < ${#queue[@]})); do
    while IFS= read -r child; do
      if [[ "$child" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$child"
        queue+=("$child")
      fi
    done < <(pgrep -P "${queue[$index]}" 2>/dev/null || true)
    index=$((index + 1))
  done
}

observed_descendant_resource_snapshot() {
  local descendants pid_list
  descendants="$(descendant_pids)"
  if [[ -z "$descendants" ]]; then
    printf '0.00,0,0\n'
    return
  fi
  pid_list="$(paste -sd, <<<"$descendants")"
  ps -p "$pid_list" -o %cpu=,rss= 2>/dev/null | awk '
    { cpu += $1; rss += $2; count += 1 }
    END { printf "%.2f,%d,%d\n", cpu, rss, count }
  '
}

previous_cpu_seconds="$(cpu_seconds)"
previous_processed_bytes="$(processed_usage_bytes)"
started_at="$(monotonic_seconds)"
previous_sample_at="$started_at"
for ((second = 1; second <= duration; second += 1)); do
  sleep 1
  rss="$(ps -p "$pid" -o rss= | awk '{$1=$1; print}')"
  if [[ -z "$rss" ]]; then
    echo "Metagent exited after $((second - 1)) sample(s)." >&2
    break
  fi
  current_sample_at="$(monotonic_seconds)"
  elapsed_seconds="$(awk -v current="$current_sample_at" -v started="$started_at" \
    'BEGIN { printf "%.6f", current - started }')"
  interval_seconds="$(awk -v current="$current_sample_at" -v previous="$previous_sample_at" \
    'BEGIN { printf "%.6f", current - previous }')"
  previous_sample_at="$current_sample_at"
  current_cpu_seconds="$(cpu_seconds)"
  cpu="$(awk -v current="$current_cpu_seconds" -v previous="$previous_cpu_seconds" \
    -v elapsed="$interval_seconds" \
    'BEGIN { printf "%.2f", (elapsed > 0 ? (current - previous) * 100 / elapsed : 0) }')"
  previous_cpu_seconds="$current_cpu_seconds"
  threads="$(ps -M -p "$pid" | awk 'NR > 1 { count += 1 } END { print count + 0 }')"
  current_processed_bytes="$(processed_usage_bytes)"
  processed_delta=""
  if [[ "$previous_processed_bytes" =~ ^[0-9]+$ \
        && "$current_processed_bytes" =~ ^[0-9]+$ \
        && "$current_processed_bytes" -ge "$previous_processed_bytes" ]]; then
    processed_delta=$((current_processed_bytes - previous_processed_bytes))
  fi
  if [[ "$current_processed_bytes" =~ ^[0-9]+$ ]]; then
    previous_processed_bytes="$current_processed_bytes"
  fi
  IFS=, read -r descendant_cpu descendant_rss descendant_count \
    <<<"$(observed_descendant_resource_snapshot)"
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$elapsed_seconds" "$cpu" "$rss" "$threads" "$current_processed_bytes" \
    "$processed_delta" "$descendant_cpu" "$descendant_rss" "$descendant_count" \
    >>"$samples_path"
done

sample "$pid" 5 1 -file "$stack_path" >/dev/null 2>&1 || true

summary_arguments=(
  "$samples_path"
  "$summary_path"
  "$summary_json_path"
  --channel "$channel"
  --pid "$pid"
  --scenario "$scenario"
  --repo-commit "$repo_commit"
  --build-commit "$build_commit"
  --app-version "$app_version"
  --app-build "$app_build"
  --executable-path "$executable_path"
  --executable-sha256 "$executable_sha256"
  --os-version "$os_version"
  --os-build "$os_build"
  --hardware-model "$hardware_model"
  --cpu-model "$cpu_model"
  --power-source "$power_source"
  --power-snapshot "$power_snapshot"
  --low-power-mode "$low_power_mode"
  --thermal-snapshot "$thermal_snapshot"
  --other-channel "${other_app_name%.app}"
)
if [[ "$other_channel_pid" =~ ^[0-9]+$ ]]; then
  summary_arguments+=(--other-channel-pid "$other_channel_pid")
fi
python3 "$(dirname "$0")/summarize-efficiency.py" "${summary_arguments[@]}"

printf 'samples: %s\n' "$samples_path"
printf 'stack: %s\n' "$stack_path"
printf 'summary: %s\n' "$summary_path"
printf 'json: %s\n' "$summary_json_path"
