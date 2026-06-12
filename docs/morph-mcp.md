# Morph MCP Janitor

`metagent morph-mcp` manages runaway `@morphllm/morphmcp` background
workers spawned by local agent sessions.

The repo implementation is the canonical source:

```bash
metagent morph-mcp status
metagent morph-mcp janitor --dry-run
metagent morph-mcp janitor
metagent morph-mcp install-launch-agent --program ~/.cargo/bin/metagent
metagent morph-mcp migrate-launch-agent --program ~/.cargo/bin/metagent
```

## Policy

The janitor is conservative by design.

- It counts actual morph worker commands: `npm exec @morphllm/morphmcp` and
  `node .../morph-mcp`.
- It does not count parent agent commands that only mention `morph-mcp` in MCP
  config JSON.
- Routine cleanup only kills detached processes that were previously observed
  as Codex-owned workers.
- Attached cleanup trims Codex-owned workers when the pool is above size limits
  and individual workers are old and idle. On Codex Desktop, these workers are
  usually parented to the long-lived app server rather than to a single visible
  chat, so Codex-owned does not prove a worker is still needed.
- `--dry-run` reports eligible kills without refreshing state or sending
  signals.
- Claude-owned or other non-Codex workers are counted in status but are not
  eligible for cleanup unless they become a known detached Codex-owned identity.

The locally observed `@morphllm/morphmcp` package was already current at
`0.8.183` when this policy was tightened, and the upstream docs/package metadata
did not expose a changelog entry or lifecycle fix for accumulated MCP workers.
The janitor policy is therefore still needed as local process hygiene.

Default thresholds:

| Setting | Default |
| --- | --- |
| `MAX_PCPU` | `1.0` |
| `ORPHAN_MIN_AGE_SEC` | `900` |
| `ORPHAN_MAX_KILL_PER_KIND` | `6` |
| `EMERGENCY_NODE_KEEP` | `8` |
| `EMERGENCY_NPM_KEEP` | `8` |
| `EMERGENCY_TOTAL_KEEP` | `16` |
| `EMERGENCY_MIN_AGE_SEC` | `1800` |
| `EMERGENCY_MAX_KILL_PER_KIND` | `4` |

The janitor stores process identity state in:

```text
~/.local/state/metagent/morph-mcp-janitor/known_codex_pids.txt
```

Override `STATE_DIR` or `KNOWN_CODEX_PIDS_FILE` only for testing or temporary
diagnostics. Cleanup thresholds intentionally ignore environment variables so
stale LaunchAgent plists cannot pin old policy values.

## LaunchAgent

Install or reload the project-owned LaunchAgent:

```bash
metagent morph-mcp install-launch-agent --program ~/.cargo/bin/metagent
```

The project-owned job label is:

```text
com.ianwatts.metagent.morph-mcp-janitor
```

To switch a stale machine from the old `codex-morphmcp` job to the
project-owned job:

```bash
metagent morph-mcp migrate-launch-agent --program ~/.cargo/bin/metagent
```

That command merges old known-process state into the project state before the
new janitor can run, then writes and loads the project-owned plist, unloads the
legacy job, and moves the legacy plist to Trash.

`metagent morph-mcp status` reports legacy details only if a legacy job or
legacy artifact is detected.

It writes:

```text
~/Library/LaunchAgents/com.ianwatts.metagent.morph-mcp-janitor.plist
~/Library/Logs/metagent/morph-mcp-janitor.out.log
~/Library/Logs/metagent/morph-mcp-janitor.err.log
```

The plist sets `PATH` only. Cleanup policy thresholds live in the binary
defaults.

Uninstall unloads the project-owned job and moves its plist to Trash:

```bash
metagent morph-mcp uninstall-launch-agent
```
