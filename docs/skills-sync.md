# Skills Sync

The goal is not bidirectional file sync.

The goal is project discovery plus dotagents setup:

```text
project/.agents/skills/<skill>/SKILL.md
project/agents.toml
project/.claude/skills -> ../.agents/skills
```

`project/.agents/skills` remains canonical. Claude Code sees those skills through the `.claude/skills` symlink created or repaired by Sentry dotagents.

## Commands

Scan:

```bash
agent-tools skills scan
```

Dry-run sync:

```bash
agent-tools skills sync
```

Apply:

```bash
agent-tools skills sync --apply
```

Allow migration from old copied `.claude/skills` directories:

```bash
agent-tools skills sync --apply --replace-claude-skills
```

Check current state:

```bash
agent-tools skills doctor
```

Skip a parent workspace that should provide inherited skills but should not be
treated as a dotagents project:

```toml
ignore_projects = ["~/code_projects"]
```

## Safety

- Hidden skill folders are ignored because dotagents rejects names like `.system`.
- Existing `agents.toml` is preserved unless `--rewrite-agents-toml` is passed.
- Existing real `.claude/skills` paths are not moved unless `--replace-claude-skills` is passed.
- Background sync should not pass `--replace-claude-skills`; that flag is for explicit migrations.
