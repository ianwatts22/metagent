<p align="center">
  <img src="public/brand/wordmark.svg" alt="Metagent" width="360">
</p>

<p align="center">
  A native control center and local analysis toolkit for coding-agent skills, MCP servers, and project instructions.
</p>

Metagent answers the questions that get difficult once several agents, plugin
systems, and skill managers share one machine:

- Which skills and MCP servers are available globally or for this project?
- Who owns each skill, and which copy is canonical?
- Which skills are actually being read in retained Codex sessions?
- Which configurations need attention, and which are simply disabled?
- What should an agent know about a repository before it starts work?

The macOS app is the primary human interface. The `metagent` CLI and MCP server
expose the same Swift core to terminals and agents.

> **Status:** early developer preview for macOS 26+. Metagent is local-first and
> does not upload inventory or usage history. Optional Codex skill review sends
> only the selected, bounded skill copy to OpenAI after confirmation.

## What it includes

### Native macOS app

- One directory filter across Overview, Skills, and MCP inventory.
- Unified skill inventory and usage views with native sorting, filtering,
  multi-selection, column customization, and manager-aware removal.
- Stable **Quality**, usage-aware **Utility**, external **Plugin Eval**, and
  optional **Codex review** signals kept separate.
- Passive Codex and Claude MCP configuration health with explicit global,
  project, sign-in, approval, disabled, and unavailable states.
- Doctor findings grouped into actionable project-level cleanups.

### Project analysis CLI

Analyze the current folder or any explicit project:

```bash
metagent analyze --root /absolute/path/to/project --json
```

The report combines project instructions, skills and provenance, retained usage,
relevant MCP configuration, plugin inventory, and Doctor findings.

Narrower commands are also available:

```bash
metagent inventory --json
metagent skills scan --root /absolute/path/to/project --json
metagent skills doctor --root /absolute/path/to/project --json
metagent skills evaluate /absolute/path/to/skill --provider plugin-eval --json
metagent usage status --json
```

### Local MCP server

Agents can consume the same project-analysis contract over stdio:

```bash
metagent mcp --stdio
```

The MCP layer is intentionally thin: scanning, health, usage, and analysis remain
in `MetagentCore` rather than being reimplemented for each interface.

### Agent skill

The publishable Metagent skill lives at
[`.agents/skills/metagent/`](.agents/skills/metagent/) and teaches agents how to
reason about tool availability, skill provenance, usage evidence, and durable
instruction ownership.

Install it globally with the Skills CLI:

```bash
npx skills add ianwatts22/metagent --skill metagent --global
```

## Install from source

Requirements:

- macOS 26 or newer
- Xcode with a Swift toolchain
- an Apple Development signing identity for local app installation

Clone the repository, then install the app and command-line helper:

```bash
git clone https://github.com/ianwatts22/metagent.git
cd metagent
scripts/install-menu-bar-app.sh --restart
scripts/install-cli.sh
```

The app is installed at `~/Applications/Metagent.app`; the CLI is installed at
`~/.local/bin/metagent`.

For development:

```bash
scripts/dev-menu-bar-app.sh
```

## Data and privacy

Metagent stores generated state outside the repository:

- inventory: `~/Library/Application Support/Metagent/inventory.sqlite`
- skill usage: `~/Library/Application Support/Metagent/usage.sqlite`
- evaluations: `~/Library/Application Support/Metagent/skill-evaluations-v1.json`

Usage history is derived from observed `SKILL.md` reads in retained Codex JSONL
sessions. Metagent stores normalized identity, timestamps, thread/turn IDs, and
evidence metadata—not prompts or tool-output content. Missing telemetry is never
treated as proof that a skill is useless.

Passive MCP health reads local client configuration. It does not start servers,
contact providers, inspect secrets, or claim that a configured server was
successfully invoked.

## Architecture

Swift is the source of truth:

- `MetagentCore` owns inventory, provenance, usage, Doctor, MCP health, and
  project analysis.
- `MetagentMenuBar` imports the core directly for the native UI.
- `metagent` is a thin headless wrapper for CLI and MCP access.

Machine-local roots, secrets, account mappings, logs, and generated state stay
outside the repository. See [architecture](docs/architecture.md),
[skill provenance](docs/skill-provenance.md), [skill scoring](docs/skill-scoring.md),
and [macOS app behavior](docs/menu-bar.md) for details.

## Verify

```bash
scripts/verify.sh
```

The structural guardrails require `sg` from ast-grep on `PATH`.

## Contributing

Bug reports and focused proposals are welcome through
[GitHub Issues](https://github.com/ianwatts22/metagent/issues). Please run
`scripts/verify.sh` before opening a pull request.
