# Architecture

`agent-tools` is one repo with two frontends.

## Rust Core and CLI

Rust owns all behavior that needs to be deterministic, testable, and usable by agents:

- scanning roots for `.agents/skills`
- validating dotagents-compatible skill names
- generating project-root `agents.toml`
- preserving or backing up existing `.claude/skills`
- invoking `npx @sentry/dotagents sync`
- generating LaunchAgent plists

The CLI is the automation API:

```bash
agent-tools skills scan
agent-tools skills sync --apply
agent-tools skills doctor
agent-tools launch-agent install
```

## Swift Menu Bar

Swift owns only macOS UI:

- status display
- sync button
- config/log shortcuts
- future root picker and notifications

The menu bar app shells out to the Rust CLI. It should not duplicate scanner, symlink, or dotagents logic.

## Local State

Machine-local config belongs in:

```text
~/.config/agent-tools/config.toml
```

Logs belong in:

```text
~/Library/Logs/agent-tools/
```

Generated project state belongs in project-local dotagents files such as `agents.toml`, `agents.lock`, `.agents/.gitignore`, and `.claude/skills`.

