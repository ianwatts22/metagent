#!/usr/bin/env bash
set -euo pipefail

channel="dev"
duration=30
output_root=""

usage() {
  cat <<'USAGE'
Usage: scripts/measure-app-efficiency.sh [--channel dev|prod] [--duration SECONDS] [--output DIR]

Samples one running Metagent process once per second. The report includes CPU,
resident memory, thread count, usage-index progress, and a five-second stack
sample. It reads only aggregate usage metadata, not app content or session history.
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
  output_root="$(mktemp -d "/private/tmp/metagent-efficiency-${channel}.XXXXXX")"
else
  mkdir -p "$output_root"
fi

samples_path="${output_root}/process-samples.csv"
summary_path="${output_root}/summary.txt"
stack_path="${output_root}/stack-sample.txt"
printf 'second,cpu_percent,rss_kib,threads\n' >"$samples_path"

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

previous_cpu_seconds="$(cpu_seconds)"
starting_processed_bytes="$(processed_usage_bytes)"
for ((second = 1; second <= duration; second += 1)); do
  sleep 1
  rss="$(ps -p "$pid" -o rss= | awk '{$1=$1; print}')"
  if [[ -z "$rss" ]]; then
    echo "Metagent exited after $((second - 1)) sample(s)." >&2
    break
  fi
  current_cpu_seconds="$(cpu_seconds)"
  cpu="$(awk -v current="$current_cpu_seconds" -v previous="$previous_cpu_seconds" \
    'BEGIN { printf "%.2f", (current - previous) * 100 }')"
  previous_cpu_seconds="$current_cpu_seconds"
  threads="$(ps -M -p "$pid" | awk 'NR > 1 { count += 1 } END { print count + 0 }')"
  printf '%s,%s,%s,%s\n' "$second" "$cpu" "$rss" "$threads" >>"$samples_path"
done

sample "$pid" 5 1 -file "$stack_path" >/dev/null 2>&1 || true

awk -F, -v channel="$channel" -v pid="$pid" '
  NR == 1 { next }
  {
    count += 1
    cpu_sum += $2
    rss_sum += $3
    if ($2 > cpu_max) cpu_max = $2
    if ($3 > rss_max) rss_max = $3
    if ($4 > threads_max) threads_max = $4
  }
  END {
    if (count == 0) exit 1
    printf "channel: %s\n", channel
    printf "pid: %s\n", pid
    printf "samples: %d\n", count
    printf "average_cpu_percent: %.2f\n", cpu_sum / count
    printf "peak_cpu_percent: %.2f\n", cpu_max
    printf "average_rss_mib: %.2f\n", rss_sum / count / 1024
    printf "peak_rss_mib: %.2f\n", rss_max / 1024
    printf "peak_threads: %d\n", threads_max
  }
' "$samples_path" | tee "$summary_path"

ending_processed_bytes="$(processed_usage_bytes)"
if [[ "$starting_processed_bytes" =~ ^[0-9]+$ \
      && "$ending_processed_bytes" =~ ^[0-9]+$ \
      && "$ending_processed_bytes" -ge "$starting_processed_bytes" ]]; then
  advanced_bytes=$((ending_processed_bytes - starting_processed_bytes))
  sample_count="$(awk -F, 'NR > 1 { count += 1 } END { print count + 0 }' "$samples_path")"
  average_cpu="$(awk -F, 'NR > 1 { sum += $2; count += 1 } END { if (count) printf "%.6f", sum / count }' "$samples_path")"
  awk -v bytes="$advanced_bytes" -v cpu="$average_cpu" -v samples="$sample_count" '
    BEGIN {
      mib = bytes / 1048576
      cpu_seconds = cpu * samples / 100
      printf "processed_usage_mib: %.2f\n", mib
      printf "estimated_cpu_seconds: %.2f\n", cpu_seconds
      if (mib > 0) printf "cpu_seconds_per_processed_mib: %.4f\n", cpu_seconds / mib
    }
  ' | tee -a "$summary_path"
fi

printf 'samples: %s\n' "$samples_path"
printf 'stack: %s\n' "$stack_path"
printf 'summary: %s\n' "$summary_path"
