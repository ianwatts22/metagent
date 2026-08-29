# Performance testing

Metagent has an opt-in performance lane for the core work behind an app refresh:

- skill discovery across 24 projects and 192 skill bundles;
- Doctor analysis of the same portfolio;
- an app-shaped inventory refresh combining configured roots with a pruned
  shallow home scan;
- codebase measurement across 251 tracked files and 10,000 source/test lines;
- cold usage backfill across 10 session files and 300 observed skill reads;
- usage parsing across 20,000 irrelevant token/message records surrounding 40
  observed skill reads;
- convergence of a 36-session backlog through three bounded refresh slices.

Run it from the repository root:

```bash
scripts/verify-performance.sh
```

The lane builds optimized code in release mode, enables the test-only hooks used
by the existing suite, and reports Apple XCTest wall-clock, CPU, peak memory,
and storage metrics. It also writes a machine-readable JSON result in
`/private/tmp`. It runs five measured iterations by default. Override the count
when investigating variance:

```bash
METAGENT_PERFORMANCE_ITERATIONS=10 scripts/verify-performance.sh
```

The suite has broad latency budgets that catch large slowdowns without claiming
that every Mac has the same speed. If a slower reference machine needs it, set a
multiplier instead of weakening the shared budgets:

```bash
METAGENT_PERFORMANCE_BUDGET_MULTIPLIER=2 scripts/verify-performance.sh
```

For tighter same-machine regression checks, save one good result outside the
repository and compare later runs against it:

```bash
METAGENT_PERFORMANCE_RESULT_PATH=/private/tmp/metagent-baseline.json \
  scripts/verify-performance.sh
METAGENT_PERFORMANCE_BASELINE=/private/tmp/metagent-baseline.json \
  METAGENT_PERFORMANCE_MAX_REGRESSION_PERCENT=15 \
  scripts/verify-performance.sh
```

Every matched metric uses lower-is-better comparison. The noisy non-peak
physical-memory delta is excluded; peak memory remains enforced. New scenarios
do not fail against an older baseline until that baseline contains the same
metric. Small clock, CPU, and disk measurements below fixed noise floors are
also excluded from percentage comparisons.

The fixtures are generated locally, contain fixed shapes and content, and do not
read the user's portfolio, session history, network, or credentials. Fixture
creation is outside the measured blocks except for the SQLite database creation
that is part of a cold usage backfill.

## Usage freshness and energy pacing

An explicit refresh reads at most 8 MiB or 12 session files before returning.
If history remains, the app continues with background maintenance instead of
waiting for another launch. Normal maintenance reads at most 8 MiB or 12 files,
then waits at least 45 seconds. Low Power Mode or serious thermal pressure cuts
that to 2 MiB or 4 files and waits at least 180 seconds.

Production and dev builds share one SQLite lease. Only one process performs a
maintenance slice in each interval; an explicit user refresh is never deferred.
Within each background slice, normal maintenance yields for 25 milliseconds
after each 512 KiB and constrained maintenance yields for 50 milliseconds after
each 256 KiB. This adds cooperative pacing between parsed records without
throttling explicit user refreshes or reducing the amount of history each
maintenance wake processes.
This keeps the current index moving toward complete coverage without restoring
the old sustained full-core parser loop. The app still prioritizes the most
recent session files, and an explicit refresh remains immediate; the slower
cadence primarily affects convergence of old retained history.

These tests return immediately unless `METAGENT_RUN_PERFORMANCE_TESTS=1`, which
the script sets. Normal `scripts/verify.sh --fast` runs still compile the tests
but do not execute the filesystem benchmarks. `scripts/verify.sh --release`
and the tagged-release workflow run one measured iteration as a broad regression
gate; CI also preserves the complete JSON measurement as a release-run artifact.

Use precise results as a same-machine trend, not as a universal speed claim. Compare the
same macOS and Xcode versions, release configuration, power mode, and iteration
count. XCTest records measurements but this lane does not enforce one shared
millisecond budget because local and CI hardware differ. Add machine-specific
baselines only after enough runs establish normal variance. The peak-memory
metric is process-wide for the XCTest runner, so compare complete lane runs in
the same test order rather than comparing one isolated test with a suite run.

## Running-app efficiency

The XCTest lane measures bounded core operations. Use the process sampler for
idle and whole-app behavior after installing and starting the selected channel:

```bash
scripts/measure-app-efficiency.sh \
  --channel dev \
  --duration 60 \
  --scenario idle-overview
```

It samples CPU, resident memory, and thread count once per second, then writes a
five-second stack sample plus text and JSON summaries. The summaries include
time-weighted CPU p50/p95/p99, active duty cycle, longest active burst,
time-weighted RSS average/p95, RSS growth/trend, point-in-time observed-descendant
CPU/RSS, and shared-database usage-index throughput. Descendant CPU percentiles
are explicitly sample-weighted because `ps` reports point-in-time process values;
short-lived work that starts and exits between probes can be missed. Use
Instruments when complete descendant attribution matters.

The default active-burst threshold is 2% CPU. Process CPU time is exposed by
macOS in centisecond increments, so a 1% threshold at a roughly one-second
sample interval is too close to the clock's quantization step for stable idle
duty-cycle comparisons.

Sample intervals use the monotonic clock, so probe overhead does not inflate CPU
percentages, duty cycle, burst length, or memory trend. Usage progress belongs
to the SQLite database shared by production and dev. The report labels it as
global throughput and does not divide the selected app's CPU by that shared
progress. A second running channel is recorded as provenance, but the database
metric still cannot be attributed to either channel.

The JSON report records the requested scenario, repository and built-app commit,
app version/build, executable path and SHA-256, macOS version/build, hardware and
CPU models, power source, Low Power Mode, thermal snapshot, whether the other
channel was running, and actual monotonic elapsed time. Keep those fields with a
baseline: results are not directly comparable when important provenance differs.
Together these distinguish a controlled refresh burst from frequent wakeups that
happen to have the same average CPU, and distinguish a temporary allocation peak
from sustained memory growth.

Keep the generated summary, JSON, CSV, and stack sample as a before result; run
the same command on the same Mac, power mode, app state, and duration after the
change. A supplied output directory must be new or empty. Compare average CPU,
p95 CPU, active duty cycle, longest burst, and RSS
trend together. A lower average with the same peak can still be a real win when
the duty cycle and longest burst show that the app returns to idle faster. Treat
RSS trend as a leak signal to investigate over a longer run, not proof of a leak
from one short sample.

Process sampling cannot attribute wakeups or file-system activity. For those,
record the same scenario with Xcode Instruments' Time Profiler and File Activity
templates. Compare idle samples, wakeups, reads, and writes on the same machine;
do not compare their absolute values across different Macs. Activity Monitor's
Energy tab is useful as a long-window warning, but its “Energy Impact” score is
not a stable benchmark. Xcode's Power Profiler template is not supported for a
macOS process, so do not use it as an automated Metagent gate.

For retained-memory work, capture vmmap's physical, live-allocation, and
fragmentation views together:

```bash
scripts/profile-app-memory.sh \
  --channel dev \
  --scenario skills-before \
  --output /private/tmp/metagent-memory-skills-before
```

The default run waits three seconds, captures three snapshots one second apart,
and reports medians plus observed ranges. `--settle`, `--samples`, and
`--interval` can tune that bounded window; the sample count must stay odd and at
most nine so the median is an observed snapshot. A supplied `--output`
directory must be new or empty, and the profiler refuses to replace an existing
before result. The text and JSON summaries record the scenario, channel, PID,
exact executable and its SHA-256, app and OS versions, process launch time,
capture times, and sampling parameters. The summarizer also rejects a sample
set whose process identity, version, launch time, or OS changes mid-capture.

Compare the same app view, window size, power mode, settle and sample settings
before and after a change. Include a return to a lighter view under a distinct
scenario such as `overview-after-skills`; a view-cycle that releases most live
allocations is different from a growing retained heap. Prefer the median live
malloc allocation, allocation count, fragmentation, and current physical
footprint together. RSS alone includes reclaimable and fragmented pages.

`process_lifetime_peak_physical_footprint_mib` is explicitly the highest value
since that app process launched, not the peak of the sampled scenario. Compare
it only across freshly launched processes that ran the same ordered scenario;
do not use it to compare two views captured in one process.
