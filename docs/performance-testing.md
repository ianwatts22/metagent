# Performance testing

Metagent has an opt-in performance lane for the core work behind an app refresh:

- skill discovery across 24 projects and 192 skill bundles;
- Doctor analysis of the same portfolio;
- duplicate-skill comparison across eight same-name groups of 24 skills each,
  with discovery excluded from the measured work;
- dual configured-root and pruned shallow-home inventory discovery;
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

The overlap workload measures document reads, normalization, and pairwise
similarity together. A separate deterministic test requires one canonical-path
resolution per non-projection input, preventing filesystem work from growing
with the number of pairs. Documents are reread on each invocation; same-path
edits, missing files that appear, and retargeted symlinks must remain fresh.

The dual-root discovery benchmark intentionally stops at deterministic core
filesystem work. It does not claim to cover the external Codex plugin process,
SwiftUI publication, or snapshot persistence; use the running-app sampler for
those whole-app stages.

The performance lane also runs `skillTablePresentationPerformanceProxy`
explicitly. That deterministic model-layer proxy compares the old repeated
filter/sort row pipeline with the shared one-pass pipeline. It is not a SwiftUI
render benchmark and is not evidence of input-to-present latency.

The native interaction probe services the main run loop while waiting for app
termination, launch completion, and exact-PID registration. AppKit's
[`runningApplications`](https://developer.apple.com/documentation/appkit/nsworkspace/runningapplications)
registry only updates when that loop runs; sleep-only polling can falsely report
that an exited app is still running. The compiled probe self-test checks queued
run-loop delivery and monotonic timeout behavior without Accessibility access.

## Usage freshness and energy pacing

An explicit refresh reads at most 8 MiB or 12 session files before returning.
If history remains, the app continues with background maintenance instead of
waiting for another launch. The first normal-power continuation reads at most
8 MiB or 12 files after 45 seconds. Once that continuation has built the reusable
source catalog, catch-up consolidates three slices into one 24 MiB or 36-file
wake every 135 seconds. The byte and file rates are unchanged, but two of every
three repeated database, snapshot, cache, and UI update cycles disappear. Low
Power Mode or serious thermal pressure uses 2 MiB or 4 files every 180 seconds.

Production and dev builds share one SQLite lease. The normal-power lease remains
45 seconds even during the 135-second catch-up cadence, so fewer timer wakeups do
not lengthen cross-process exclusion. The constrained lease is 180 seconds. Only
one process performs a maintenance slice in each lease interval; an explicit
user refresh is never deferred. Deadlines use monotonic uptime and advance from
the prior deadline so slice duration does not reduce sustained throughput.
Maintenance timers allow roughly one-ninth of their interval as tolerance, up
to 30 seconds, so macOS can coalesce wakeups.
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
  --scenario settled-idle-overview
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
  --scenario overview-before-skills \
  --output /private/tmp/metagent-memory-before
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

## Product targets versus measured baselines

[`scripts/app-performance-budgets.json`](../scripts/app-performance-budgets.json)
records the initial product targets separately from measurement output. They are
all `proposed` today:

- common tab, filter, or sort input-to-Accessibility-content-ready p95 at or
  below 150 ms, with 100 ms as the desired center of the range;
- warm process launch to an Accessibility-ready window at or below 1 second;
- cold process launch to the same ready point at or below 2 seconds;
- settled Overview average CPU at or below 0.5%, time-weighted p95 at or below
  1%, and no sampled 20% CPU burst lasting longer than one second;
- no more than 5 MiB of retained live malloc allocations after an Overview →
  Skills → Overview view cycle;
- manual Reload returning to its enabled ready state within 3 seconds at p95.

These are intended product constraints, not claims about the current app and
not release gates. Keep current measured values in timestamped artifacts rather
than copying them into this file. Promote one budget to `enforced` only after
repeated same-machine runs prove that its observable, scenario preparation, and
normal variance are trustworthy. `--include-proposed` is an explicit local
stress check; it does not silently turn proposed targets into release gates.

## Installed-app interaction measurements

The interaction harness drives the installed app through macOS Accessibility:

```bash
scripts/measure-app-interactions.sh \
  --channel dev \
  --scenario tabs \
  --iterations 5 \
  --output /private/tmp/metagent-tabs-$(date +%Y%m%d-%H%M%S)

scripts/measure-app-interactions.sh \
  --channel dev \
  --scenario common-interactions \
  --iterations 5 \
  --output /private/tmp/metagent-common-interactions-$(date +%Y%m%d-%H%M%S)

scripts/measure-app-interactions.sh \
  --channel dev \
  --scenario refresh \
  --iterations 5 \
  --output /private/tmp/metagent-refresh-$(date +%Y%m%d-%H%M%S)
```

The selected app must be running with its main window open. The Codex or
terminal host needs macOS Accessibility permission. Navigation, search, and
filter controls use exact Accessibility identifiers; the harness never falls
back to inferred geometry or fixed screen coordinates. A cached native Swift
probe talks to `AXUIElement` directly and applies
`AXUIElementSetMessagingTimeout` both process-wide and to the target app, so one
unresponsive Accessibility request has a hard per-call bound. The shell also
enforces an independent process-group inactivity timeout five seconds beyond
`--timeout`. Progress on stderr resets that watchdog. A timeout fails the
entire run and preserves only the partial raw file for diagnosis; no summary is
emitted. The compiled helper is content- and Swift-toolchain-addressed under
the current user's private temporary directory; it adds no shipped app
dependency. The cache is keyed by source and Swift compiler version, rejects a
symbolic-link root, and is accessible only to its owning user.

Tab results retain `tab_input_to_selected_state_ms` as an event-loop diagnostic,
but the product budget uses the stronger view-specific
`tab_input_to_ax_content_ready_ms`. The `common-interactions` scenario also
measures filter and primary-column sort input until the exact ordered content
and semantic sort state are exposed through Accessibility after SwiftUI
reconciliation. Sort completion requires both a changed content-ready token and
the expected `AXSortDirection`. Toggle and restore are recorded as one atomic
pair: if restore does not complete, neither half becomes a sample. Empty
inventory sections are recorded as structured skips; at least one real table
sort must complete or the scenario fails with an explicit fixture-gap error. A
section whose primary column is not the retained active sort is also skipped,
rather than changing the user's saved table preference just to produce a sample.
These observables do not claim the first painted or composited pixel.

Filter results retain the end-to-end
`filter_input_to_ax_content_ready_ms` product observable and split it into three
diagnostics: time inside the option's `AXPress` call, time after that call until
the control exposes its new value, and time after that call until the section's
semantic content-ready token changes. Compare those phases before optimizing a
slow filter. If control and content become ready together, the delay precedes
app reconciliation (for example, menu dismissal); if content trails the control,
the app's filter or presentation work is the likely target.

Reload is stronger: a valid sample must observe the Reload control leave its
enabled ready state and then return. A refresh that finishes too quickly for
that transition to be observed fails the scenario rather than inventing a
completion duration.

### Launch to ready

Launch measurement intentionally changes the selected channel's process state
and leaves it running:

```bash
# Performs one unmeasured prewarm launch, stops it, then measures relaunches.
scripts/measure-app-interactions.sh \
  --channel dev --scenario launch-warm --iterations 5 \
  --output /private/tmp/metagent-launch-warm-$(date +%Y%m%d-%H%M%S)

# The selected app must already be stopped. Run after reboot/install when that
# is the cold condition being studied.
scripts/measure-app-interactions.sh \
  --channel dev --scenario launch-cold --iterations 1 \
  --output /private/tmp/metagent-launch-cold-$(date +%Y%m%d-%H%M%S)
```

Ready means the main `Metagent` window and its navigation row are exposed
through Accessibility. It does not mean background indexing has completed.
The harness uses system uptime for monotonic durations. It cannot flush or
prove macOS filesystem, dynamic-linker, and disk caches, so `launch-cold` is a
declared scenario precondition rather than a cache-manipulation claim. Use one
cold iteration; repeated launches are warm by definition.

All interaction artifacts include the same repository, bundle, executable,
OS, hardware, CPU, and power provenance as the process sampler. A supplied
output directory must be new or empty.

## Evaluating the complete budget shape

Use a controlled five-minute Overview idle run for energy pacing:

```bash
scripts/measure-app-efficiency.sh \
  --channel dev --duration 300 --scenario settled-idle-overview \
  --output /private/tmp/metagent-idle-overview-$(date +%Y%m%d-%H%M%S)
```

Its summary now includes the count and longest duration of contiguous sampled
bursts at or above 20% CPU in addition to the 2% active-duty metrics. A burst
longer than one second is counted only when the monotonic sample intervals add
up to more than one second; one isolated quantized sample is not stretched into
a recurring burst.

For retained Skills memory, keep one process alive and capture both settled
Overview states around a manual Overview → Skills → Overview cycle:

```bash
scripts/profile-app-memory.sh \
  --channel dev --scenario overview-before-skills \
  --output /private/tmp/metagent-memory-before-$(date +%Y%m%d-%H%M%S)

# Open Skills, exercise the normal table once, return to Overview, then:
scripts/profile-app-memory.sh \
  --channel dev --scenario overview-after-skills \
  --output /private/tmp/metagent-memory-after-$(date +%Y%m%d-%H%M%S)
```

The budget checker rejects before/after memory artifacts from different
process launches, executables, builds, channels, or OS versions. It compares
median `malloc.allocated_mib`, which is the live heap; it does not substitute
RSS or process-lifetime peak.

Combine whatever artifacts a scenario produced:

```bash
scripts/check-app-performance-budgets.py \
  --interactions /private/tmp/metagent-launch-warm-TIMESTAMP/summary.json \
  --interactions /private/tmp/metagent-common-interactions-TIMESTAMP/summary.json \
  --interactions /private/tmp/metagent-refresh-TIMESTAMP/summary.json \
  --efficiency /private/tmp/metagent-idle-overview-TIMESTAMP/summary.json \
  --memory-before /private/tmp/metagent-memory-before-TIMESTAMP/summary.json \
  --memory-after /private/tmp/metagent-memory-after-TIMESTAMP/summary.json
```

Default evaluation reports proposed targets and observed values without failing
on them; only entries explicitly marked `enforced` can fail. To see which
current measurements miss the proposed product target, add
`--include-proposed`. That mode exits nonzero on a miss and remains opt-in.
Supplying `--output` writes a new JSON evaluation and refuses to replace an
existing file. The checker also validates scenario labels: settled Overview CPU
must come from a label containing `settled`, `idle`, and `overview`; memory must
be an Overview-before and Overview-after-Skills pair from the same process; and
interaction metrics must match their launch or refresh scenario. The explicit
`--allow-scenario-mismatch` escape hatch exists for investigations, not routine
gating, and should be recorded with the result whenever used.

Remaining gaps are explicit: first-pixel and compositor completion after
tab/filter/sort input, complete attribution of short-lived child processes,
wakeup and file-I/O counts without Instruments, and truly controlled cold OS
cache state. Core-only benchmarks must not be used as substitutes for those
observables.
