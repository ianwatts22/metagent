# AGENTS.md

This repo contains local coding-agent tooling.

## Boundaries

- Keep reusable tooling, docs, templates, and examples in the repo.
- Keep machine-local roots, secrets, account mappings, exports, logs, generated state, and private overlays out of the repo.
- Swift is the source of truth for app/core/helper behavior.
- Keep shared behavior in `apps/MetagentMenuBar/Sources/MetagentCore`.
- The macOS UI should import `MetagentCore` directly rather than shelling out for inventory, doctor, sync, or LaunchAgent status.
- The Swift `metagent` helper is for LaunchAgents, the MCP server (`metagent mcp --stdio`), and headless use. It should stay a thin wrapper around `MetagentCore`.
- Do not reintroduce a Rust core for app behavior without an explicit product reason and updated architecture docs.

## Project Management

- Use Linear for project management. Put metagent ideas, backlog items, and follow-up tasks in the `misc` team project `metagent`: https://linear.app/social-glass/project/metagent-730ac559ca5c.
- Do not create or extend repo-local ad hoc to-do/backlog markdown for project management. Keep repo docs focused on durable architecture, commands, and operating guidance.

## Published Skill Updates

- Treat `.agents/skills/metagent/` as the source for the public and globally installed Metagent skill.
- After changing it, follow `docs/skill-publishing.md`: validate and commit, push the source, then run `npx --yes skills update metagent --global --yes` and verify the installed content and global lock entry.
- Never run the global update before the source is pushed; the skills CLI installs from GitHub and may overwrite unpushed local changes.
- If pushing is not authorized, report the repository and installed states separately rather than calling the update complete.

## Versioning and Releases

- Versions are SemVer git tags (`vX.Y.Z`): bump minor for features, patch for
  fixes. Pushing a tag runs `.github/workflows/release.yml`, which tests,
  builds, signs, notarizes, publishes the GitHub release, and commits the
  updated Sparkle appcast to `public/appcast.xml` on main.
- To release: run `scripts/verify.sh`, add the version's section to
  `CHANGELOG.md` (short, user-facing bullets), commit, then
  `git tag vX.Y.Z && git push origin main vX.Y.Z`. Watch the run with
  `gh run watch` and confirm the release assets and appcast commit landed.

## Verification

Run before considering changes done:

```bash
scripts/verify.sh
```

After changes that affect the macOS app, install and restart the verified build
with `scripts/install-app.sh --restart`, then confirm the running dev
process comes from `~/Applications/Metagent Dev.app`. Use
`scripts/dev-app.sh` during iterative UI work. Never write to
`~/Applications/Metagent.app` — that is the production install from
metagent.sh, updated only by Sparkle (see `docs/menu-bar.md`, "Release
channels").
