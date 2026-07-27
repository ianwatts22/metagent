# Architecture

`metagent` is now a Swift-first native Mac app with shared Swift core logic.

## Ownership

Swift owns the product core:

- skill inventory scanning across `.agents/`, `.codex/`, and `.claude`
- `.agents` provenance from `.agents/.skill-lock.json`
- skill size, word, token, resource, icon, and logo metadata
- duplicate and scope-overlap detection across distinct canonical skill bundles
- safe skill-document parsing, block-level Markdown presentation, and conflict-aware atomic edits
- SQLite inventory snapshots for fast startup
- streaming Codex session evidence and incremental skill-usage history
- deterministic portfolio scoring plus cached Plugin Eval and optional Codex review results
- skill doctor checks
- project skill-link audit, repair planning, and apply behavior
- the native macOS app UI
- the Swift `metagent` helper used by future MCP and headless entry points

Rust is no longer part of the active app architecture.

## Swift Package Layout

The active implementation lives under:

```text
apps/MetagentMenuBar/
```

Targets:

- `MetagentCore`: shared Swift core for app, helper, and future MCP server
- `MetagentMenuBar`: native SwiftUI/AppKit macOS app
- `metagent`: small Swift command helper for headless/background use

The GUI imports `MetagentCore` directly. It does not shell out to the helper for inventory, Doctor, or repair.

## Persistence

The app writes the latest skill inventory snapshot to SQLite:

```text
~/Library/Application Support/Metagent/inventory.sqlite
```

The cache is a startup and inspection optimization, not the source of truth. The filesystem remains authoritative, and Refresh performs a fresh scan before writing a new snapshot.

Skill usage is stored separately:

```text
~/Library/Application Support/Metagent/usage.sqlite
```

The usage database is an incremental local analytics index. Retained Codex JSONL
sessions provide historical `session_backfill` evidence; future runtime/OTel
evidence can use the same normalized event schema without rewriting history as
if Codex originally emitted it. File byte offsets and parser versions make the
backfill resumable and prevent full rescans. When parser semantics change, the
last usable parser generation remains visible while replacement tables rebuild;
the app swaps generations atomically only after the replacement is complete.
Repeated parser changes discard only the unfinished replacement. The app runs
the backfill at background priority, throttles after each 16 MiB of input, and
stops when current. Only usage metadata is retained—never prompt text or tool
output.

Skill evaluation results are stored separately:

```text
~/Library/Application Support/Metagent/skill-evaluations-v1.json
```

This cache contains evaluator summaries, rubric breakdowns, provider versions,
timestamps, and canonical skill-content hashes. The scoring contract and
provider boundaries are documented in [skill-scoring.md](skill-scoring.md).

Removed and archived skills live in sibling folders:

```text
~/Library/Application Support/Metagent/Removed Skills/<uuid>/
~/Library/Application Support/Metagent/Archived Skills/<skill>/
```

`Removed Skills` is the per-removal recovery record. `Archived Skills` holds
skills deliberately set aside for on/off testing: each entry carries the moved
bundle, its projection links, and an `ARCHIVE.json` manifest of original paths
that `metagent skills restore` replays. The folders stay separate because the
history backfill reads `Removed Skills` as evidence of permanent removal, and
an archived skill is expected back (see
[skill-provenance.md](skill-provenance.md), "Archiving").

## Helper Boundary

The Swift `metagent` helper exists for non-GUI entry points:

```bash
metagent config show --json
metagent skills list --global --sort invocations_30d --order desc --limit 20
metagent skills show /absolute/path/to/skill --no-body
metagent skills duplicates --global
metagent skills scan --json
metagent skills repair --apply
metagent skills doctor
metagent skills remove NAME [NAME...] --root /absolute/path/to/project
metagent skills evaluate /absolute/path/to/skill --provider plugin-eval
metagent skills evaluate /absolute/path/to/skill --provider codex
metagent usage status
metagent usage refresh
metagent analyze --root /absolute/path/to/project --json
metagent codebase --root /absolute/path/to/project --json
metagent mcp --stdio
```

The helper is intentionally subordinate to `MetagentCore`. It should stay a thin command surface over shared Swift code.

`skills list` and `skills duplicates` read the current folder by default and take
`--global` for the whole portfolio, the scope bare `skills doctor` already uses.
`skills list` returns a compact paginated projection — filters
(`--name`, `--manager`, `--mutability`, `--min-score`, `--unused`,
`--used-within-days`, `--include-projections`, `--no-descriptions`), sorting
(`--sort`, `--order`), and paging (`--limit`, `--cursor`) — rather than the full
`skills scan` inventory. `skills remove` accepts one or more names, routes each
through the shared removal resolver (canonical, standalone, or Codex plugin), and
stays a dry run unless `--apply` is supplied.

## Project Analysis and MCP

MCP should be an access layer over `MetagentCore`, not a second implementation.

`metagent analyze` emits the detailed schema-version-1 CLI report. It combines
project instruction/configuration files, project skills, installed plugin
skills, Doctor findings, passive relevant MCP state, and retained usage
summaries for matching project skills. It reports paths and metadata but does
not copy instruction contents into the report.

The stdio server is:

```bash
metagent mcp --stdio
```

It uses the pinned official MCP Swift SDK and exposes eight read-only tools plus
one gated destructive tool: `analyze_project`, `get_project_analysis_details`,
`list_skills`, `list_projects`, `find_duplicate_skills`, `get_skill`,
`measure_codebase_size`, `doctor_project`, and `remove_skills`.
`analyze_project` defaults to a compact
schema-version-2 project-only summary: counts, usage coverage, and at most five
prioritized findings. It deliberately excludes global plugin inventories and
global MCP servers. `get_project_analysis_details` retrieves one project-only
section at a time (`instructions`, `skills`, `doctor`, `mcp`, or `usage`), caps
pages at 100 records, and returns an opaque cursor when another page exists.
`list_skills` returns the same compact paginated projection as `skills list`
(`root`, `scope`, `sort`, `order`, `limit`, `cursor`, `name_contains`, `manager`,
`mutability`, `min_score`, `unused_only`, `used_within_days`,
`include_projections`, `include_descriptions`). `list_projects` is a small global
overview of every root with its skill count and per-location breakdown.
`find_duplicate_skills` takes `root` and `scope`; `get_skill` takes `path`,
`include_body`, and `max_body_characters`; `doctor_project` now takes `scope`
alongside `root`. `remove_skills` takes `skill_names`, `root`, and `apply`, which
defaults to `false`; applying is destructive, requires explicit user
confirmation for that specific removal, and moves content into recovery state
instead of hard-deleting it. All tools call `MetagentCore`; the server owns no
parallel scanner or cache. Add Rust or Python workers only for measured hot
paths or exploratory analysis that Swift plus SQLite cannot handle cleanly.

## Local State

Machine-local config belongs in:

```text
~/.config/metagent/config.toml
```

Logs belong in:

```text
~/Library/Logs/metagent/
```

Project skill ownership is intentionally small:

```text
.agents/skills/                 # physical source of truth
.claude/skills -> ../.agents/skills
skills-lock.json                # optional npx skills provenance
agents.toml / agents.lock       # optional dotagents declaration and lock evidence
```

Metagent does not generate manifests or lockfiles. `npx skills` may maintain
`skills-lock.json` for packages it installed, and dotagents may maintain
`agents.toml` plus `agents.lock`. Metagent reads both manager formats. A
self-referential dotagents path created while adopting an existing local skill
is reconciliation bookkeeping rather than manager ownership. Git tracking is
storage/version-control evidence, not proof of upstream origin. Metagent can
also recognize a deliberately small registry of third-party CLI bundle
signatures when installed content includes manager-specific, versioned
evidence; a generic `version` field is insufficient. Without an installer lock,
a distinct manager source, or a recognized signature, Metagent reports
local/unknown.
Global `~/.claude/skills` remains outside this project projection rule.

## Verification

Verification is split into composable lanes:

```bash
scripts/verify-fast.sh
scripts/verify-integration.sh
scripts/verify-release.sh
```

The strict complete gate remains:

```bash
scripts/verify.sh
```

Each lane prints stage timing, surfaces warnings from successful stages, and
shows the tail of the exact failed-stage log.
Set `METAGENT_VERIFY_KEEP_LOGS=1` to preserve successful stage logs for diagnosis.

Swift builds may need a writable module cache in sandboxed agent environments:

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/metagent-clang-cache swift build
```
