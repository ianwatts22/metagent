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
metagent skills scan
```

Structured scan output for UI wrappers:

```bash
metagent skills scan --json
```

The JSON keeps `valid_skills` as the dotagents-compatible `.agents/skills`
set and also includes a `skills` inventory with each skill's path, location
(`.agents`, `.codex`, or `.claude`), symlink-container flag, and `.agents`
origin. `.agents` skills with a matching `.agents/.skill-lock.json` entry are
reported as `npx-skills`; other `.agents` skills are reported as `native`.

Each skill inventory row also includes table-oriented metadata:

- `folder_kind`: `native`, `npx-installed`, `codex-local`, `claude-local`, `symlinked`, or `system`
- `character_count`, `word_count`, and `token_estimate` across text files in the skill folder
- `skill_file_character_count`, `skill_file_word_count`, and `skill_file_token_estimate` for `SKILL.md`
- `text_file_count`
- `reference_file_count`, `script_file_count`, `asset_file_count`
- `other_file_count` and `other_folder_count`
- `has_openai_yaml`, `has_icon_small`, `has_icon_large`, and `has_icon_and_logo`
- optional `icon_small_path` and `icon_large_path` from `agents/openai.yaml`

Token counts are fast estimates based on roughly one token per four characters.

Dry-run sync:

```bash
metagent skills sync
```

Structured dry-run output for UI wrappers:

```bash
metagent skills sync --json
```

Apply:

```bash
metagent skills sync --apply
```

Allow migration from old copied `.claude/skills` directories:

```bash
metagent skills sync --apply --replace-claude-skills
```

Check current state:

```bash
metagent skills doctor
```

The active cache for the Mac app inventory is SQLite at
`~/Library/Application Support/Metagent/inventory.sqlite`.

Skip a parent workspace that should provide inherited skills but should not be
treated as a dotagents project:

```toml
ignore_projects = ["~/code_projects"]
```

## Safety

- Hidden skill folders are ignored because dotagents rejects names like `.system`.
- Existing root `agents.toml` is preserved unless `--rewrite-agents-toml` is passed; generated content is based on current `.agents/skills`.
- Legacy nested `.agents/agents.toml` is moved to a timestamped backup during sync.
- Existing real `.claude/skills` paths are not moved unless `--replace-claude-skills` is passed.
- Background sync should not pass `--replace-claude-skills`; that flag is for explicit migrations.
