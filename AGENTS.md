# AGENTS.md

This repo contains local coding-agent tooling.

## Boundaries

- Keep reusable tooling, docs, templates, and examples in the repo.
- Keep machine-local roots, secrets, account mappings, exports, logs, generated state, and private overlays out of the repo.
- Rust is the source of truth for CLI/core behavior.
- Swift UI code should call the Rust CLI or a bundled helper binary rather than reimplementing filesystem logic.

## Verification

Run before considering changes done:

```bash
cargo fmt --check
cargo test
cargo run -p agent-tools-cli -- skills scan --max-depth 3
```

