# Project Skill Projection

Project skills have one physical source of truth:

```text
project/.agents/skills/<skill>/SKILL.md
project/.claude/skills/<personal-skill> -> ../../.agents/skills/<personal-skill>
```

The `.claude/skills` directory is a real provider container. Metagent links
project-owned skills into it one child at a time. This lets Claude-specific
overrides coexist with shared skills and lets the Skills CLI manage its own
child links without the two tools replacing each other's container.

An existing whole-directory `.claude/skills -> ../.agents/skills` projection is
still valid and remains untouched. New repairs use child links.

This rule applies to projects only. Metagent does not change global
`~/.claude/skills`, where Claude-specific skills may live.

## Tools And Ownership

- Unmanaged local skills can be created directly under `.agents/skills`; this
  says nothing about who originally authored or copied them.
- `npx skills add <source>` is optional and useful for public skill packages.
- `npx skills` owns `skills-lock.json` provenance for packages it installs.
- Metagent owns discovery, Doctor findings, inventory, and missing Claude child
  links for project skills absent from `skills-lock.json`.
- Metagent ignores names recorded in `skills-lock.json`; their Claude links
  remain exclusively owned by the Skills CLI.
- Metagent does not create `agents.toml` or `agents.lock`. It reads them as
  provenance and invokes dotagents only after an explicitly approved removal.

The `npx skills` default install model already creates its own provider links.
Metagent reads its lock only to avoid claiming those names.

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

Doctor reports missing personal child links as
`repair_action: repair_projection`. A real `.claude/skills` directory is the
normal container. Existing provider overrides are preserved; files and
conflicting symlinks are review findings without an automatic repair.

## Safety Rules

- Repair creates `.claude/skills` as a directory when a personal link is needed.
- Repair creates only absent child links for valid `.agents/skills` names not
  recorded in `skills-lock.json`.
- Repair removes dangling personal child links whose same-name `.agents` skill
  no longer exists, while leaving Skills CLI names alone.
- Repair never replaces, moves, merges, or imports existing Claude content.
- Repair preserves real same-name Claude directories as provider-specific
  overrides and reports other same-name collisions for manual review.
- Repair does not project the home directory and refuses to write through a
  symlinked project `.claude` directory.
- Repair never copies Claude content into `.agents`.
- `_archive` trees are pruned during discovery.
- Hidden or invalid `.agents/skills` folders remain Doctor review findings.
- Doctor and Repair reconcile newly added personal skills. No second lockfile is
  needed because `.agents/skills` and `skills-lock.json` are the sources of truth.

## Uninstall

The Mac app inventory can uninstall one selected canonical `.agents` skill:

- Metagent creates a `Removed Skills` recovery directory before mutation.
- For skills CLI packages, Metagent saves recovery state, delegates removal to
  `npx skills remove`, and verifies that the package and lock entry are absent.
- Dotagents entries are removed through dotagents after recovery state is saved.
- Unmanaged bundles and their per-skill projection links are moved into Metagent's
  `Removed Skills` recovery directory.
- Existing whole-container projections remain in place.
- Per-skill Claude or Codex projection links are removed with local bundles;
  independent same-name bundles are retained for explicit review.
