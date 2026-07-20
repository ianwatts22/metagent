# metagent

A native control center for inspecting and maintaining coding-agent skills.

The repo is intentionally boring:

- Swift owns the native Mac app, shared core logic, SQLite inventory cache, and small command helper.
- MCP should be an access layer over the Swift core, not a second implementation.
- Local roots, secrets, account mappings, and generated state stay outside the repo.

## Agent Skill

The publishable skill lives at [.agents/skills/metagent/SKILL.md](.agents/skills/metagent/SKILL.md).
It helps agents reason about agent workflows, MCP/tool availability, skill usage,
and durable instruction boundaries.

Once this repo is public at `ianwatts22/metagent`, it should be installable with:

```bash
npx skills add ianwatts22/metagent --skill metagent
```

See [docs/skill-publishing.md](docs/skill-publishing.md) for the publication and local-install checklist.

## Current Tools

### Swift Mac App

The macOS app is the primary product surface:

- scans `.agents`, `.codex`, and `.claude` skill locations directly through `MetagentCore`
- shows whether `.agents` skills were installed by `npx skills` from `.skill-lock.json` or created natively
- shows skill size, word, token, reference, script, asset, icon, and logo metadata
- stores the latest inventory snapshot in SQLite at `~/Library/Application Support/Metagent/inventory.sqlite`
- incrementally indexes retained Codex session evidence into `~/Library/Application Support/Metagent/usage.sqlite`
- shows 7-day, 30-day, and all-time skill reads, active turns, threads, repeats, recency, and coverage
- runs Doctor, read-only repair previews, direct project skill-link repair, and maintenance actions from Swift

Launching `Metagent.app` opens a normal resizable app window and keeps the menu bar extra available for quick status/actions.

Build it:

```bash
cd apps/MetagentMenuBar
CLANG_MODULE_CACHE_PATH=/private/tmp/metagent-clang-cache swift build
```

Package a local `.app` bundle:

```bash
scripts/build-menu-bar-app.sh
```

Install it into the user Applications folder so Spotlight can find it:

```bash
scripts/install-menu-bar-app.sh --restart
```

During iterative app development, rebuild and restart automatically:

```bash
scripts/dev-menu-bar-app.sh
```

That installs:

```text
~/Applications/Metagent.app
```

### `metagent` Swift Helper

The command helper is built from the same Swift package and exists for future MCP and headless agent access. It is not the app's backend.

Install it:

```bash
scripts/install-cli.sh
```

Current helper commands:

```bash
metagent config show --json
metagent skills scan --json
metagent skills repair
metagent skills repair --apply
metagent skills doctor
metagent usage status
metagent usage refresh
```

The future MCP entry point is reserved as:

```bash
metagent mcp --stdio
```

### `metagent skills`

Find projects with `.agents/skills` and ensure Claude Code sees the same skills through `.claude/skills -> ../.agents/skills`.

Dry run:

```bash
cd apps/MetagentMenuBar
swift run metagent skills repair
```

Apply:

```bash
cd apps/MetagentMenuBar
swift run metagent skills repair --apply
```

Scan only:

```bash
cd apps/MetagentMenuBar
swift run metagent skills scan --root ~/code_projects
```

Check current state:

```bash
metagent skills doctor
```

Repair only creates a missing project symlink or replaces a wrong symlink. It never
replaces a real `.claude/skills` directory and never copies Claude content into
`.agents`. Whole-directory links remain current automatically when skills are added
or removed, so no background sync is needed.

### `metagent usage`

Inspect the cached skill-usage index or process a bounded incremental batch:

```bash
metagent usage status
metagent usage refresh --max-bytes 67108864 --max-files 100
```

Historical rows use `session_backfill` provenance and are derived from observed
`SKILL.md` reads in retained Codex JSONL sessions. They are not fabricated OTel
events. Metagent stores normalized skill identity, time, thread, turn, and
evidence metadata; it does not store prompt or tool-output content.

Use the Linear `misc` team project `metagent` for future fold-in candidates:
https://linear.app/social-glass/project/metagent-730ac559ca5c.

## Default Roots

When no roots are passed and no config exists, `metagent` scans:

- `~/code_projects`
- `~/Library/CloudStorage`
- `~/Documents/Codex`

Put machine-local roots in:

```text
~/.config/metagent/config.toml
```

Example:

```toml
roots = [
  "~/code_projects",
  "~/Library/CloudStorage",
  "~/Documents/Codex",
]
max_depth = 6
ignore_projects = []
```

## Verification

```bash
scripts/verify.sh
```

Requires `sg` from ast-grep on `PATH` for structural guardrail warnings.
