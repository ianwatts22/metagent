# Architecture

`metagent` is now a Swift-first native Mac app with shared Swift core logic.

## Ownership

Swift owns the product core:

- skill inventory scanning across `.agents/`, `.codex/`, and `.claude`
- `.agents` provenance from `.agents/.skill-lock.json`
- skill size, word, token, resource, icon, and logo metadata
- SQLite inventory snapshots for fast startup
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

## Helper Boundary

The Swift `metagent` helper exists for non-GUI entry points:

```bash
metagent config show --json
metagent skills scan --json
metagent skills repair --apply
metagent skills doctor
```

The helper is intentionally subordinate to `MetagentCore`. It should stay a thin command surface over shared Swift code.

## MCP Direction

MCP should be an access layer over `MetagentCore`, not a second implementation.

The reserved shape is:

```bash
metagent mcp --stdio
```

The MCP server should share the Swift core and SQLite cache with the app. Add Rust or Python workers only for measured hot paths or exploratory analysis that Swift plus SQLite cannot handle cleanly.

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
```

Metagent does not generate manifests or lockfiles. `npx skills` may maintain
`skills-lock.json` for packages it installed; native local skills need no manager
state. Global `~/.claude/skills` remains outside this project projection rule.

## Verification

Use:

```bash
scripts/verify.sh
```

Swift builds may need a writable module cache in sandboxed agent environments:

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/metagent-clang-cache swift build
```
