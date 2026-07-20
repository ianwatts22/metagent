# AGENTS.md

This repo contains local coding-agent tooling.

## Boundaries

- Keep reusable tooling, docs, templates, and examples in the repo.
- Keep machine-local roots, secrets, account mappings, exports, logs, generated state, and private overlays out of the repo.
- Swift is the source of truth for app/core/helper behavior.
- Keep shared behavior in `apps/MetagentMenuBar/Sources/MetagentCore`.
- The macOS UI should import `MetagentCore` directly rather than shelling out for inventory, doctor, sync, or LaunchAgent status.
- The Swift `metagent` helper is for LaunchAgents, future MCP, and headless use. It should stay a thin wrapper around `MetagentCore`.
- Do not reintroduce a Rust core for app behavior without an explicit product reason and updated architecture docs.

## Project Management

- Use Linear for project management. Put metagent ideas, backlog items, and follow-up tasks in the `misc` team project `metagent`: https://linear.app/social-glass/project/metagent-730ac559ca5c.
- Do not create or extend repo-local ad hoc to-do/backlog markdown for project management. Keep repo docs focused on durable architecture, commands, and operating guidance.

## Published Skill Updates

- Treat `.agents/skills/metagent/` as the source for the public and globally installed Metagent skill.
- After changing it, follow `docs/skill-publishing.md`: validate and commit, push the source, then run `npx --yes skills update metagent --global --yes` and verify the installed content and global lock entry.
- Never run the global update before the source is pushed; the skills CLI installs from GitHub and may overwrite unpushed local changes.
- If pushing is not authorized, report the repository and installed states separately rather than calling the update complete.

## Verification

Run before considering changes done:

```bash
scripts/verify.sh
```

After changes that affect the macOS app, install and restart the verified build
with `scripts/install-menu-bar-app.sh --restart`, then confirm the running
process comes from `~/Applications/Metagent.app`. Use
`scripts/dev-menu-bar-app.sh` during iterative UI work.
