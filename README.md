# metagent

Ian's local toolbox for coding-agent operations that are too specific or too new to rely on external tools alone.

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
- runs doctor, dry-run sync, apply sync, background sync install, and maintenance actions from Swift

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

That installs:

```text
~/Applications/Metagent.app
```

### `metagent` Swift Helper

The command helper is built from the same Swift package and exists for LaunchAgents, future MCP, and headless agent access. It is not the app's backend.

Install it:

```bash
scripts/install-cli.sh
```

Current helper commands:

```bash
metagent config show --json
metagent skills scan --json
metagent skills sync
metagent skills sync --apply
metagent skills doctor
metagent launch-agent status
metagent launch-agent install
```

The future MCP entry point is reserved as:

```bash
metagent mcp --stdio
```

### `metagent skills`

Find projects with `.agents/skills`, generate project-root `agents.toml` files for Sentry dotagents, and sync Claude Code's `.claude/skills` symlink.

Dry run:

```bash
cd apps/MetagentMenuBar
swift run metagent skills sync
```

Apply:

```bash
cd apps/MetagentMenuBar
swift run metagent skills sync --apply --replace-claude-skills
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

Install the background sync LaunchAgent:

```bash
metagent launch-agent install --program ~/.local/bin/metagent --interval 300
```

Logs:

```text
~/Library/Logs/metagent/skills-sync.out.log
~/Library/Logs/metagent/skills-sync.err.log
```

Use the Linear `misc` team project `metagent` for future fold-in candidates:
https://linear.app/social-glass/project/metagent-730ac559ca5c.

### `metagent morph-mcp`

Inspect local `@morphllm/morphmcp` workers from the Swift helper.

```bash
metagent morph-mcp status
```

See [docs/morph-mcp.md](docs/morph-mcp.md).

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
agents = ["claude", "codex", "cursor"]
ignore_projects = []
```

## Verification

```bash
scripts/verify.sh
```

Requires `sg` from ast-grep on `PATH` for structural guardrail warnings.
