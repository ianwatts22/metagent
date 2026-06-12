# Architecture

`metagent` is one repo with two frontends.

## Rust Core and CLI

Rust owns all behavior that needs to be deterministic, testable, and usable by agents:

- scanning roots for `.agents/skills`
- validating dotagents-compatible skill names
- generating project-root `agents.toml`
- preserving or backing up existing `.claude/skills`
- invoking `npx @sentry/dotagents sync`
- generating LaunchAgent plists
- managing recurring agent-runtime maintenance flows such as the morph-mcp janitor
- summarizing TypeScript/TSX code churn through `git` and `scc`
- exposing machine-readable config/status surfaces for UI wrappers

The CLI is the automation API:

```bash
metagent config show --json
metagent skills scan
metagent skills sync --apply
metagent skills doctor
metagent launch-agent install
metagent code-summary --repo /path/to/repo
metagent morph-mcp status
metagent morph-mcp janitor
```

## Swift Menu Bar

Swift owns only macOS UI:

- status display for CLI path, roots, discovered skill repos, doctor issues, and background sync
- command buttons for doctor, dry-run sync, apply sync, background install, morph-mcp status, and code summaries
- config/log shortcuts
- future root picker and notifications

The menu bar app shells out to the Rust CLI. It should not duplicate scanner, symlink, or dotagents logic.

## Local State

Machine-local config belongs in:

```text
~/.config/metagent/config.toml
```

Logs belong in:

```text
~/Library/Logs/metagent/
```

The morph-mcp janitor is project-owned by `metagent` and writes:

```text
~/Library/Logs/metagent/morph-mcp-janitor.out.log
~/Library/Logs/metagent/morph-mcp-janitor.err.log
```

Generated project state belongs in project-local dotagents files such as `agents.toml`, `agents.lock`, `.agents/.gitignore`, and `.claude/skills`.
