#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_source="$repo_root/apps/MetagentMenuBar"

source "$repo_root/scripts/lib.sh"
setup_swift_build_env

if ! xcrun xcodebuild -version >/dev/null 2>&1; then
  echo "Metagent performance tests require the full Xcode toolchain." >&2
  exit 1
fi

export METAGENT_RUN_PERFORMANCE_TESTS=1
export SWIFT_DETERMINISTIC_HASHING=1
performance_iterations="${METAGENT_PERFORMANCE_ITERATIONS:-5}"
if ! [[ "$performance_iterations" =~ ^[0-9]+$ ]]; then
  echo "METAGENT_PERFORMANCE_ITERATIONS must be a whole number." >&2
  exit 2
fi
if ((performance_iterations < 1)); then
  performance_iterations=1
elif ((performance_iterations > 20)); then
  performance_iterations=20
fi
export METAGENT_PERFORMANCE_ITERATIONS="$performance_iterations"

PYTHONDONTWRITEBYTECODE=1 \
  python3 -m unittest discover -s "$repo_root/scripts/tests" -p 'test_*.py'

cd "$app_source"
performance_log="$(mktemp /private/tmp/metagent-performance-log.XXXXXX)"
performance_result="${METAGENT_PERFORMANCE_RESULT_PATH:-$(mktemp /private/tmp/metagent-performance-result.XXXXXX)}"
swift test \
  --disable-sandbox \
  --configuration release \
  -Xswiftc -DDEBUG \
  --filter MetagentCorePerformanceTests 2>&1 | tee "$performance_log"

summary_arguments=(
  "$performance_log"
  "$performance_result"
  --max-regression-percent "${METAGENT_PERFORMANCE_MAX_REGRESSION_PERCENT:-20}"
  --git-commit "$(git -C "$repo_root" rev-parse HEAD)"
  --iterations "$performance_iterations"
)
if [[ -n "${METAGENT_PERFORMANCE_BASELINE:-}" ]]; then
  summary_arguments+=(--baseline "$METAGENT_PERFORMANCE_BASELINE")
fi
python3 "$repo_root/scripts/summarize-performance.py" "${summary_arguments[@]}"
