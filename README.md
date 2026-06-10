# agent-tools

Ian's local toolbox for coding-agent operations that are too specific or too new to rely on external tools alone.

The repo is intentionally boring:

- Rust owns the core filesystem and CLI behavior.
- Swift is reserved for the macOS menu bar wrapper.
- Local roots, secrets, account mappings, and generated state stay outside the repo.

## Current Tools

### `agent-tools skills`

Find projects with `.agents/skills`, generate project-root `agents.toml` files for Sentry dotagents, and sync Claude Code's `.claude/skills` symlink.

Dry run:

```bash
cargo run -p agent-tools-cli -- skills sync
```

Apply:

```bash
cargo run -p agent-tools-cli -- skills sync --apply --replace-claude-skills
```

Scan only:

```bash
cargo run -p agent-tools-cli -- skills scan --root ~/code_projects
```

Check current state:

```bash
agent-tools skills doctor
```

Install the CLI:

```bash
scripts/install-cli.sh
```

Install the background sync LaunchAgent:

```bash
agent-tools launch-agent install --program ~/.cargo/bin/agent-tools --interval 300
```

Logs:

```text
~/Library/Logs/agent-tools/skills-sync.out.log
~/Library/Logs/agent-tools/skills-sync.err.log
```

### `code-change-summary`

The existing Node-based `ccs` tool lives under `tools/code-change-summary/` for now. It is intentionally not ported to Rust yet.

### `agent-tools morph-mcp`

Manage runaway `@morphllm/morphmcp` workers from the Rust CLI.

```bash
agent-tools morph-mcp status
agent-tools morph-mcp janitor --dry-run
agent-tools morph-mcp janitor
agent-tools morph-mcp install-launch-agent --program ~/.cargo/bin/agent-tools
agent-tools morph-mcp migrate-launch-agent --program ~/.cargo/bin/agent-tools
```

See [docs/morph-mcp.md](/Users/ianwatts/code_projects/agent-tools/docs/morph-mcp.md).

## Default Roots

When no roots are passed and no config exists, `agent-tools` scans:

- `~/code_projects`
- `~/Library/CloudStorage`
- `~/Documents/Codex`

Put machine-local roots in:

```text
~/.config/agent-tools/config.toml
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

## Swift Menu Bar App

The menu bar app should be a thin SwiftUI wrapper around the Rust CLI:

- show last sync status
- choose roots
- sync now
- install/uninstall background sync
- open logs/config

It should not duplicate the scanner or dotagents logic.

Build it:

```bash
cd apps/AgentToolsMenuBar
swift build
```

Package a local `.app` bundle:

```bash
scripts/build-menu-bar-app.sh
```

## Verification

```bash
scripts/verify.sh
```

Requires `sg` from ast-grep on `PATH` for structural guardrail warnings.
