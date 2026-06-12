# Mac App

The macOS app is a thin SwiftUI wrapper around the Rust CLI. It exposes both:

- a standalone resizable app window
- a menu bar extra for quick status/actions

Current surface:

- standalone app window that opens when launching `Metagent.app`
- persistent menu bar window
- CLI path, configured roots, discovered repo count, skill count, doctor issue count, and background sync status
- `Skills` menu with `.agents`, `.codex`, and `.claude` skill locations
- `.agents` skill origin badges from `.skill-lock.json`: `npx skills` source or native
- main-window `Inventory` table built with SwiftUI `Table`, sortable columns, native selection, and column resize/reorder/visibility customization
- menu bar `Inventory` section that opens the main app window for the full table
- per-repo code summaries
- `Refresh Status`
- `Doctor`
- `Dry Run Sync`
- `Sync Skills Now`
- `Install Background Sync`
- `Open Config`
- `Open Logs`
- `Restart App`
- structured dry-run preview with summary counts, per-project actions, warnings, and optional raw CLI output
- first-class skill inventory table with location, origin, folder kind, size, estimated tokens, resource counts, and icon/logo metadata
- last command output preview for non-sync commands
- `Quit`

Refresh behavior:

- The app refreshes status when it launches.
- The `Refresh` buttons rerun the CLI scans on demand.
- Successful skill sync and background-sync install actions trigger a status refresh.
- The UI keeps the most recent scan in memory until the next refresh.
- There is no continuous polling, persistent inventory cache, or automatic background rescan in the app.
- The LaunchAgent is for sync/repair, not for app UI inventory caching.

The app looks for the CLI in this order:

1. `METAGENT_CLI`
2. `/opt/homebrew/bin/metagent`
3. `/usr/local/bin/metagent`
4. `~/.cargo/bin/metagent`
5. `env metagent`

Build:

```bash
cd apps/MetagentMenuBar
swift build
```

The app targets macOS 14.4+ so the inventory can use SwiftUI's native table column customization APIs.

Build a local `.app` bundle:

```bash
scripts/build-menu-bar-app.sh
```

The generated app is written to:

```text
dist/MetagentMenuBar.app
```

Install the app where macOS and Spotlight can find it:

```bash
scripts/install-menu-bar-app.sh --restart
```

The installed app is written to:

```text
~/Applications/Metagent.app
```

Local deployment model:

- Source changes do not update a running app automatically.
- `scripts/build-menu-bar-app.sh` rebuilds the repo-local bundle in `dist/`.
- `scripts/install-menu-bar-app.sh` rebuilds, copies that bundle to `~/Applications`, and can launch or restart it.
- `--launch` opens the app after install.
- `--restart` asks the existing app to quit and opens the installed copy.
- CLI changes still need `scripts/install-cli.sh` so the installed menu bar app can find the updated `metagent` binary.

The next packaging step is signing/notarization and either bundling the Rust helper binary or improving first-run CLI location/root picking.
