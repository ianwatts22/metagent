# Project Skill Projection

Project skills have one physical source of truth:

```text
project/.agents/skills/<skill>/SKILL.md
project/.claude/skills -> ../.agents/skills
```

The `.claude/skills` directory is an alias, not a second collection. Adding,
editing, or removing a skill under `.agents/skills` is immediately visible to
Claude through the whole-directory symlink.

This rule applies to projects only. Metagent does not change global
`~/.claude/skills`, where Claude-specific skills may live.

## Tools And Ownership

- Unmanaged local skills can be created directly under `.agents/skills`; this
  says nothing about who originally authored or copied them.
- `npx skills add <source>` is optional and useful for public skill packages.
- `npx skills` owns `skills-lock.json` provenance for packages it installs.
- Metagent owns only discovery, Doctor findings, inventory, and the project
  `.claude/skills` symlink repair.
- Metagent does not create `agents.toml`, create `agents.lock`, or invoke
  dotagents.

The `npx skills` default install model is compatible with the whole-directory
link: the physical bundle lives under `.agents/skills`, and Claude resolves the
same directory through `.claude/skills`.

## Commands

Scan inventory:

```bash
metagent skills scan
metagent skills scan --json
```

Preview repairs without writing:

```bash
metagent skills repair
metagent skills repair --json
```

Apply safe repairs:

```bash
metagent skills repair --apply
```

Check current state:

```bash
metagent skills doctor
metagent skills doctor --json
```

Doctor reports a missing or wrong symlink as
`repair_action: repair_projection`. A real `.claude/skills` directory is a
review finding, not an automatic repair.

## Safety Rules

- Repair creates a missing `.claude/skills` symlink.
- Repair replaces an existing wrong symlink.
- Repair never replaces, moves, merges, or imports a real `.claude/skills`
  directory.
- Repair does not project the home directory and refuses to write through a
  symlinked project `.claude` directory.
- Repair never copies Claude content into `.agents`.
- `_archive` trees are pruned during discovery.
- Hidden or invalid `.agents/skills` folders remain Doctor review findings.
- No periodic background task is needed because a directory symlink remains
  current as its contents change.

## Uninstall

The Mac app inventory can uninstall one selected canonical `.agents` skill:

- Metagent creates a `Removed Skills` recovery directory before mutation.
- For skills CLI packages, Metagent saves recovery state, delegates removal to
  `npx skills remove`, and verifies that the package and lock entry are absent.
- Unmanaged bundles and their per-skill projection links are moved into Metagent's
  `Removed Skills` recovery directory.
- The whole-container `.claude/skills` projection remains in place.
- Per-skill Claude or Codex projection links are removed with local bundles;
  independent same-name bundles are retained for explicit review.
