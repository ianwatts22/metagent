# Performance testing

Metagent has an opt-in performance lane for the core work behind an app refresh:

- skill discovery across 24 projects and 192 skill bundles;
- Doctor analysis of the same portfolio;
- codebase measurement across 251 tracked files and 10,000 source/test lines;
- cold usage backfill across 10 session files and 300 observed skill reads.
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
This keeps the current index moving toward complete coverage without restoring
the old sustained full-core parser loop. The app still prioritizes the most
recent session files, and an explicit refresh remains immediate; the slower
cadence primarily affects convergence of old retained history.

These tests return immediately unless `METAGENT_RUN_PERFORMANCE_TESTS=1`, which
the script sets. Normal `scripts/verify.sh --fast` runs still compile the tests
but do not execute the filesystem benchmarks.

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
scripts/measure-app-efficiency.sh --channel dev --duration 60
```

It samples CPU, resident memory, and thread count once per second, then writes a
five-second stack sample. Keep the generated summary, CSV, and stack sample as a
before result; run the same command on the same Mac, power mode, app state, and
duration after the change. Compare both average and peak values. A lower average
with the same peak can still mean the app returns to idle faster.

Process sampling cannot attribute wakeups or file-system activity. For those,
record the same scenario with Xcode Instruments' Time Profiler and File Activity
templates. Compare idle samples, wakeups, reads, and writes on the same machine;
do not compare their absolute values across different Macs. Activity Monitor's
Energy tab is useful as a long-window warning, but its “Energy Impact” score is
not a stable benchmark. Xcode's Power Profiler template is not supported for a
macOS process, so do not use it as an automated Metagent gate.
