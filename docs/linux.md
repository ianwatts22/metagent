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

The binary links the Swift runtime and Foundation statically. It needs glibc
2.35 or newer (Ubuntu 22.04+, Debian 12+) and `libcurl4`, which the MCP SDK's
networking layer requires.

## Data directory

On Linux, Metagent follows the XDG base-directory convention:
`$XDG_DATA_HOME/metagent`, or `~/.local/share/metagent` when that is unset.
`METAGENT_DATA_DIR` overrides the location on every platform, which is how to
point an ephemeral container at a persistent volume.

## What differs from macOS

The helper behaves the same except where macOS supplies something Linux does
not:

- **Usage catalog reuse.** macOS keeps the usage-source catalog warm between
  background refreshes with FSEvents. Linux has no passive equivalent wired
  in yet, so every refresh rediscovers session files. Results are identical;
  repeated refreshes over large session histories are slower.
- **Directory scans** use the portable Foundation walk instead of Darwin's
  `getattrlistbulk` fast path. macOS package bundles and Finder-hidden flags do
  not exist on Linux.
- **Skill icons** are checked for a structurally valid PNG header instead of a
  full ImageIO decode.
- **Skill evaluation** (`skills evaluate`) runs evaluators under macOS
  `sandbox-exec`, so it is unavailable on Linux.
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

# The release artifact: static Swift runtime, stripped.
scripts/build-linux-cli.sh --output dist/metagent
scripts/smoke-mcp-stdio.sh dist/metagent
```

The `Linux` GitHub workflow runs the test suite and the stdio smoke test in a
`swift:6.2-jammy` container on every pull request. Releases attach
`metagent-linux-x86_64.tar.gz` and `metagent-linux-aarch64.tar.gz`, each with a
`.sha256` file.
