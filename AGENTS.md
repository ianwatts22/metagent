# AGENTS.md

This repo contains local coding-agent tooling.

## Boundaries

- Keep reusable tooling, docs, templates, and examples in the repo.
- Keep machine-local roots, secrets, account mappings, exports, logs, generated state, and private overlays out of the repo.
- Rust is the source of truth for CLI/core behavior.
- Swift UI code should call the Rust CLI or a bundled helper binary rather than reimplementing filesystem logic.

## Project Management

- Use Linear for project management. Put metagent ideas, backlog items, and follow-up tasks in the `misc` team project `metagent`: https://linear.app/social-glass/project/metagent-730ac559ca5c.
- Do not create or extend repo-local ad hoc to-do/backlog markdown for project management. Keep repo docs focused on durable architecture, commands, and operating guidance.

## Verification

Run before considering changes done:

```bash
cargo fmt --check
cargo test
cargo run -p metagent-cli -- skills scan --max-depth 3
```
