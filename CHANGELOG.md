# Changelog

Notable changes per released version. Versions are git tags (`vX.Y.Z`); see
AGENTS.md for the release procedure.

## v0.6.0 — 2026-08-30

- Faster launch and navigation reuse cached inventory, usage, and Skills rows
  instead of rebuilding them on every visit. Duplicate comparisons reuse
  normalized skill identities and pair results within each scan.
- Background history indexing uses bounded, paced work and fewer repeated
  maintenance cycles, with smaller slices under Low Power Mode or thermal
  pressure. Manual refresh stays immediate.
- Performance regression coverage now checks core workloads, native interaction
  readiness, and measurement accuracy, with full verification on pull requests.
- MCP attention rows have clearer labels and an Authenticate action that opens
  the supported terminal authentication flow. MCP icons are consistent, and
  Command-comma opens Settings.
- MCP clients now get canonical skill counts, typed and paginated project roots,
  structured errors, preview-first restores, and actionable unreadable-file details.

- Model readiness is visible in the Skills table: OpenAI and Anthropic badges
  flag skills last changed or reviewed before each provider's newest tracked
  frontier release. Hover for the exact model, release date, review baseline,
  and model-catalog check time.
- Anonymous, aggregate PostHog analytics cover app launch, inventory scans, and
  skill publishing outcomes. Inventory, skill content, paths, accounts, logs,
  prompts, and screen recordings are never sent, and Settings has a full
  opt-out.
- Published Skills now has a direct skill picker, and Sync stays disabled until
  at least one skill is selected for local mirroring.
- Publish or update a mirrored skill from an exact file-and-branch preview;
  Metagent blocks unrelated or divergent Git state and never rebases or
  force-pushes.
- Overview puts skill, duplicate, and MCP connection actions ahead of passive
  charts, with one Review path instead of competing Review and Resolve buttons.
- Agent run timing now counts direct user-requested tasks rather than automation,
  subagent, guardian, or copied pre-fork history.
- Settings has a pinned, unclipped header, and app-owned sheets close before
  Sparkle installs or relaunches an update.
- Launch polish adds a signed-DMG quick start, visible Mac requirements, honest
  local-first privacy copy, accessible Skills tabs, and a large social preview.

## v0.5.0 — 2026-08-25

- Publish selected global skills from the app into an existing public Git
  checkout. Metagent keeps the copy in sync one way as files change, while
  commits and pushes remain under the user's control.
- Duplicate review now gives each project copy an explicit removal choice when
  the same skill is also installed globally. Nothing is selected or removed
  automatically, and the final approval step remains required.
- Broad inventory scans ignore linked Git worktrees, so temporary development
  copies no longer inflate project and skill counts.
- Operation warnings keep their failure details so the warning button always
  explains what failed.

- Script inventory: inspect every bundled script without running it, including
  runtime and role inference, executable state, size and hash, documentation
  references, missing files, private-path warnings, and safe symlink handling.
- Release reliability: notarization can use a CI-native App Store Connect Team
  API key and validates credentials before starting an expensive release build.

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
