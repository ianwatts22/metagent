# Linux and cloud containers

The macOS app is the human interface. The `metagent` helper (CLI and MCP
server) also builds and runs on Linux, so agents in cloud containers and on
Ubuntu hosts get the same inventory, Doctor, usage, and project analysis.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/ianwatts22/metagent/main/scripts/install-linux.sh | sh
```

The script downloads `metagent-linux-<arch>.tar.gz` from the latest GitHub
release (x86_64 or aarch64), verifies its SHA-256, and installs to
`~/.local/bin/metagent`. Options:

- `--version vX.Y.Z` installs a specific release.
- `--dir PATH` (or `METAGENT_INSTALL_DIR`) changes the install directory.
- `--mcp claude` or `--mcp codex` also registers the MCP server with that
  client (`metagent mcp install --client ... --apply`).

For a cloud agent environment, put the one-liner in the environment's setup
script, for example `... | sh -s -- --mcp claude`.

Release binaries are fully static: they are built against musl with Swift's
Static Linux SDK, so they have no shared-library dependencies and run on any
x86_64 or aarch64 Linux, including Alpine and slim container images.

## Data directory

On Linux, Metagent follows the XDG base-directory convention:
`$XDG_DATA_HOME/metagent`, or `~/.local/share/metagent` when that is unset.
`METAGENT_DATA_DIR` overrides the location on every platform, which is how to
point an ephemeral container at a persistent volume.

## What differs from macOS

The helper behaves the same except where macOS supplies something Linux does
not:

- **Usage catalog reuse.** macOS keeps the usage-source catalog warm between
  background refreshes with FSEvents. Linux rediscovers session files on each
  refresh; parsing stays incremental through the saved cursors. A refresh over
  20,000 session files takes about a third of a second, so no watcher is used.
- **Directory scans** use the portable Foundation walk instead of Darwin's
  `getattrlistbulk` fast path. macOS package bundles and Finder-hidden flags do
  not exist on Linux.
- **Skill icons** are checked for a structurally valid PNG header instead of a
  full ImageIO decode.
- **Skill evaluation.** `--provider plugin-eval` works as on macOS.
  `--provider codex` uses `codex` from `PATH` (or `METAGENT_CODEX`). macOS
  also wraps Codex in a `sandbox-exec` profile; Linux has no equivalent, so
  Codex's own `--sandbox read-only` mode is the enforcing layer.
- **Power awareness.** Background maintenance treats a host with no battery,
  or one on mains power, as externally powered.

## Building from source

Linux builds need a Swift 6.2 toolchain. SQLite is bundled through
`swift-toolchain-sqlite` and crypto comes from `swift-crypto`, so no system
development packages are required.

```bash
cd apps/MetagentMenuBar
swift build --product metagent
swift test

# Quick build: static Swift runtime, but needs glibc and libcurl at runtime.
scripts/build-linux-cli.sh --output dist/metagent

# The release artifact: fully static against musl (needs Swift 6.2.4).
scripts/install-static-linux-sdk.sh
scripts/build-linux-cli.sh --static --output dist/metagent
scripts/smoke-mcp-stdio.sh dist/metagent
```

The `Linux` GitHub workflow runs the test suite and the stdio smoke test in a
`swift:6.2-jammy` container on every pull request. It also builds the static
binary and smoke-tests it on Alpine. Releases attach
`metagent-linux-x86_64.tar.gz` and `metagent-linux-aarch64.tar.gz`, each with a
`.sha256` file.
