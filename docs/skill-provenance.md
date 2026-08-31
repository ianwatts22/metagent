# Skill Provenance and Removal

Metagent keeps overwrite risk separate from presumed authorship. An unlocked folder is not automatically user-authored; it is unmanaged with unknown authority until stronger evidence exists.

Every inventory entry carries these independent fields:

- `scope`: `global`, `project`, `plugin`, or `system`
- `manager`: `local`, `skills-cli`, `codex`, `codex-plugin`, or an external manager
- `authority`: the known package/plugin authority, or `unknown`
- `mutability`: `editable` or `managed-read-only`
- `representation`: `canonical`, `projection`, or `versioned-cache`
- `canonical_path`: the symlink-resolved identity used to recognize projections

## Ownership evidence

Metagent reads exactly one skills CLI lock per scope:

- global: `${XDG_STATE_HOME}/skills/.skill-lock.json` when `XDG_STATE_HOME` is set, otherwise `~/.agents/.skill-lock.json`
- project: `<project>/skills-lock.json`

The locks are not merged. A root-level global `skills-lock.json` or nested project `.agents/.skill-lock.json` is legacy state; Doctor reports it for review instead of silently treating it as ownership evidence.

An `.agents/skills` bundle found in the applicable lock is `skills-cli` managed and read-only. An unlocked physical bundle is `local` managed and editable, but its upstream remains unknown. `local` means “no active installer evidence,” not “confirmed authored by this user.” Ordinary Git tracking records where files are versioned; it does not prove where a skill originally came from and is therefore not an upstream source.

Physical `.codex/skills/.system` bundles are Codex system skills. Other physical `.codex/skills` bundles are Codex-installed. Symlinks into `.agents/skills` inherit the canonical bundle's manager and authority and are represented as projections.

Dotagents ownership requires a declaration whose source is distinct from the
installed skill path. Dotagents may adopt an orphan skill by writing a
self-referential `path:.agents/skills/<name>` entry during `sync`; that entry is
bookkeeping, not evidence that dotagents owns the content. Metagent classifies
those adopted bundles from stronger evidence such as Skills CLI locks or a
distinct declared source. A distinct external `path:` source remains
`dotagents · local`, while non-path sources remain `dotagents · managed`.

To retire obsolete self-referential dotagents state without touching any skill
or projection, preview the repository utility first:

```bash
scripts/retire-dotagents-state.sh ~/.agents /absolute/path/to/project
scripts/retire-dotagents-state.sh --apply ~/.agents /absolute/path/to/project
```

The apply mode refuses distinct sources, requires the macOS Trash, and preserves
non-empty generated ignore files for manual review.

Installed Codex plugins are discovered from `codex plugin list --json`, then their active bundled skills are inventoried from the matching versioned cache when available. They are always `codex-plugin`, `managed-read-only`, and never eligible for content edits or Metagent deletion.

## Removal

Preview any removal first:

```bash
metagent skills remove SKILL --root PROJECT
```

Apply it explicitly:

```bash
metagent skills remove SKILL --root PROJECT --apply
```

For a local skill, Metagent moves the canonical bundle and its per-skill projections to `~/Library/Application Support/Metagent/Removed Skills/`.

For a skills CLI package, Metagent first copies the bundle and applicable lock files into the same recovery area, invokes `npx skills remove`, verifies both the bundle and lock entry are absent, and removes dangling per-skill projections. Independent same-name bundles are retained.

Codex system, Codex-installed, and plugin-cache skills remain read-only and cannot be removed through Metagent.

## Archiving

Archiving sets a skill aside without removing it, for testing how agents
perform with a skill on versus off. Because every runtime (Claude Code, Codex,
and any other `.agents` consumer) discovers skills by directory presence, the
move disables the skill uniformly — no per-runtime toggles.

Preview, apply, list, and restore:

```bash
metagent skills archive SKILL --root PROJECT
metagent skills archive SKILL --root PROJECT --apply
metagent skills archived
metagent skills restore SKILL
```

Applying moves the canonical bundle and its per-skill projection links to
`~/Library/Application Support/Metagent/Archived Skills/SKILL/`, alongside an
`ARCHIVE.json` manifest recording every original path. Restore replays the
manifest: the bundle returns to its canonical path and each projection link
goes back where it was, then the archive entry is cleared. Because the bundle
returns to the same canonical path, saved evaluations re-attach on restore.

Only pure-file-move targets are eligible: canonical local bundles and
standalone `.codex`/`.claude` bundles. Managed skills (skills-cli, dotagents)
and Codex plugins are refused, because archiving them would desync their
manager state.

Skill history records these transitions as `archived` and `restored` events,
distinct from `removed` and `added`. The archive lives beside — not inside —
`Removed Skills`, so the history backfill never mistakes a parked skill for a
permanent removal.

The menu bar app offers Archive… in the skill context menu, and an
"Archived · N" toolbar menu (visible only while the archive is non-empty) for
restoring. The MCP server exposes the same operations as `archive_skills`,
`restore_skill`, and `list_archived_skills`.

## Agent access

Analyze one project's agent setup:

```bash
metagent analyze --root /absolute/path/to/project --json
```

The complete current inventory is available without the UI:

```bash
metagent inventory --json
```

For MCP clients, configure the installed binary as a local stdio server:

```bash
metagent mcp --stdio
```

The server exposes the shared analysis, skill query, project query, duplicate,
archive, restore, Doctor, and codebase-sizing surfaces. Read tools wrap the same
`MetagentCore` implementation used by the CLI and app. Mutations are preview
first and require explicit approval for the exact plan. The default project
analysis is a compact project-only summary with no global plugin or MCP noise;
use `get_project_analysis_details` with a section and optional cursor for
bounded records.
