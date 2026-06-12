# metagent

Ian's local toolbox for coding-agent operations that are too specific or too new to rely on external tools alone.

The repo is intentionally boring:

- Rust owns the core filesystem and CLI behavior.
- Swift is reserved for the macOS menu bar wrapper.
- Local roots, secrets, account mappings, and generated state stay outside the repo.

## Agent Skill

The publishable skill lives at [.agents/skills/metagent/SKILL.md](.agents/skills/metagent/SKILL.md).
It helps agents reason about agent workflows, MCP/tool availability, skill usage,
and durable instruction boundaries.

Once this repo is public at `ianwatts22/metagent`, it should be installable with:

```bash
npx skills add ianwatts22/metagent --skill metagent
```

## Current Tools

### `metagent skills`

Find projects with `.agents/skills`, generate project-root `agents.toml` files for Sentry dotagents, and sync Claude Code's `.claude/skills` symlink.

Dry run:

```bash
cargo run -p metagent-cli -- skills sync
```

Apply:

```bash
cargo run -p metagent-cli -- skills sync --apply --replace-claude-skills
```

Scan only:

```bash
cargo run -p metagent-cli -- skills scan --root ~/code_projects
```

Check current state:

```bash
metagent skills doctor
```

Measure which Codex skills are actually being loaded from historical sessions:

```bash
metagent skills usage --days 30
metagent skills usage --all --json
```

The usage command caches parsed session files at
`~/.local/state/metagent/skill-usage/cache.json`, keyed by file size and
mtime. Use `--refresh-cache` after changing parser logic, `--no-cache` for a
one-off cold scan, and `--cache PATH` for experiments.

Check skill file formatting and required frontmatter:

```bash
metagent skills format
```

Apply whitespace normalization for discovered skill files:

```bash
metagent skills format --apply
```

Install the CLI:

```bash
scripts/install-cli.sh
```

Install the background sync LaunchAgent:

```bash
metagent launch-agent install --program ~/.cargo/bin/metagent --interval 300
```

Logs:

```text
~/Library/Logs/metagent/skills-sync.out.log
~/Library/Logs/metagent/skills-sync.err.log
```

### `metagent code-summary`

Summarize TypeScript and TSX code churn for any git repo using `git log --numstat` and `scc`.

Running bare `metagent code-summary` prints:

- last 5 days
- this week plus previous 2 weeks
- this month plus previous month

Examples:

```bash
metagent code-summary --repo /path/to/repo --days 14
metagent code-summary --repo /path/to/repo --view weekly --periods 8
metagent code-summary --repo /path/to/repo --view monthly --periods 6 --graph mermaid
```

`ccs` remains as a CLI alias through `metagent ccs`.

Notes:

- Requires `git` and `scc` on `PATH`.
- Excludes `*.test.ts(x)`, `*.spec.ts(x)`, and `tests/` from churn by default.
- Baseline counts include TS, TS tests, TSX, TSX tests, and detected coverage summaries.

Use the Linear `misc` team project `metagent` for future fold-in candidates:
https://linear.app/social-glass/project/metagent-730ac559ca5c.

### `metagent morph-mcp`

Manage runaway `@morphllm/morphmcp` workers from the Rust CLI.

```bash
metagent morph-mcp status
metagent morph-mcp janitor --dry-run
metagent morph-mcp janitor
metagent morph-mcp install-launch-agent --program ~/.cargo/bin/metagent
metagent morph-mcp migrate-launch-agent --program ~/.cargo/bin/metagent
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

## Swift Mac App

The macOS app should be a thin SwiftUI wrapper around the Rust CLI:

- show CLI path, configured roots, repo count, skill count, doctor issues, and background sync status
- list discovered skill locations, including `.agents`, `.codex`, and `.claude` skill paths
- show whether `.agents` skills were installed by `npx skills` from `.skill-lock.json` or created natively
- run per-repo code summaries
- run doctor, dry-run sync, apply sync, background sync install, and morph-mcp status
- open logs/config

It should not duplicate the scanner or dotagents logic.

Launching `Metagent.app` opens a normal resizable app window and also keeps the menu bar extra available for quick status/actions.

Build it:

```bash
cd apps/MetagentMenuBar
swift build
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

Use `scripts/build-menu-bar-app.sh` for a repo-local build only. Use `scripts/install-menu-bar-app.sh --restart` when you want the copy macOS launches to be updated too.

## Verification

```bash
scripts/verify.sh
```

Requires `sg` from ast-grep on `PATH` for structural guardrail warnings.
