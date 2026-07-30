# Changelog

Notable changes per released version. Versions are git tags (`vX.Y.Z`); see
AGENTS.md for the release procedure.

## v0.5.0 — unreleased

- Script inventory: inspect every bundled script without running it, including
  runtime and role inference, executable state, size and hash, documentation
  references, missing files, private-path warnings, and safe symlink handling.

## v0.4.0 — 2026-07-29

- Plugins: inventory Codex and Claude Code plugins together, see ownership and
  update status, update third-party marketplace plugins on demand, and opt in
  to periodic updates.
- Model readiness: flag skills that may need review after a tracked frontier
  model release without changing Quality or Utility scores.
- Contextual Codex reviews: evaluate skills from their real project context
  and return concrete improvement guidance.
- Skill inventory stays current as roots change, preserves provider-specific
  Claude skills, and repairs incomplete or stale Claude skill links.
- Skill history treats a plugin version change as an update to one stable
  identity rather than a removal and addition.

## v0.3.0 — 2026-07-27

- Skill archiving: set a skill aside so no agent runtime sees it, then restore
  it exactly where it was — context-menu Archive/Restore in the app,
  `metagent skills archive/restore/archived` in the CLI, and
  `archive_skills`/`restore_skill`/`list_archived_skills` over MCP. Skill
  history records `archived`/`restored` as their own event kinds.
- Local installs split into a dev channel (`Metagent Dev.app`) that Sparkle
  never updates, with its own icon.
- Skill score explanations: per-skill guidance on what a score means and how to
  improve it.
- The Overview trend range is selectable and labeled with what it covers.
- Website follows system dark mode; hero images are lossless.
- Stability: inventory and scores publish atomically, evaluation and score
  refreshes are serialized, and verification runs as observable lanes.

## v0.2.1 — 2026-07-26

- Polished the disk image installer.

## v0.2.0 — 2026-07-26

- Signed, notarized DMG distribution with Sparkle auto-updates.
- Skill history: records the portfolio over time, reconstructs history that
  predates capture (git, creation dates, removal records), and shows it in the
  Overview, a History page, and Get Info.
- CLI and MCP: skill listing, duplicates, detail, and gated removal routed
  through one removal entry point.
- Repairs a real `.claude/skills` directory by migrating its contents into
  `.agents/skills` instead of replacing it.
- Codebase sizing for project roots; Settings sheet with a comment-preserving
  config writer; dormant directories no longer rated.

## v0.1.0 — 2026-07-25

- Initial release: menu bar app with skill inventory, Doctor, projection
  repair, usage analytics, duplicate detection, and skill evaluation; the
  `metagent` CLI helper; the metagent.sh landing site.
