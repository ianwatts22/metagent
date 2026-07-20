# Mac App

The macOS app is the primary `metagent` product surface. It imports the shared Swift `MetagentCore` package directly and exposes both:

- a standalone resizable app window
- a menu bar extra for quick status/actions

Current surface:

- three destinations: `Overview`, `Skills`, and `Usage`
- actionable health summary with Doctor findings grouped by project and cause
- contextual repair preview shown only when a fix is available
- sortable `Skills` table focused on name, project, location, source, and estimated tokens
- `Usage` table with recent and all-time reads, task/repeat context, and recency
- menu bar summaries that open the main window for the full tables
- lower-frequency Config and Logs actions in the header menu
- manual refresh and Quit

Refresh behavior:

- The app loads the latest SQLite inventory snapshot at startup when one exists.
- The app refreshes status when it launches.
- The `Refresh` buttons rerun Swift core scans on demand.
- Successful link repair triggers a status refresh.
- The Doctor card opens the current findings. `Fixable` means the finding can be fixed by the direct project symlink repair; Doctor itself remains read-only.
- The UI keeps the most recent scan in memory until the next refresh.
- The latest inventory snapshot is persisted to `~/Library/Application Support/Metagent/inventory.sqlite`.
- Cached usage loads from `~/Library/Application Support/Metagent/usage.sqlite` immediately.
- A low-priority, resumable session backfill runs after launch. It sleeps after each 8 MiB of input, updates in bounded windows, and stops when it reaches the current end of retained Codex history.
- Once current, there is no continuous polling; launch or manual refresh processes newly appended session bytes.
- Whole-directory project symlinks stay current automatically, so there is no periodic repair agent.

Build:

```bash
cd apps/MetagentMenuBar
CLANG_MODULE_CACHE_PATH=/private/tmp/metagent-clang-cache swift build
```

The app targets macOS 26+ so its primary controls can use native SwiftUI Liquid Glass while the inventory continues to use native table column customization APIs.

Build a local `.app` bundle:

```bash
scripts/build-menu-bar-app.sh
```

The build regenerates app branding from `public/brand/logo.svg` before compiling:

- `apps/MetagentMenuBar/Sources/Resources/AppIcon.icns` for Dock/Finder/app switcher
- `apps/MetagentMenuBar/Sources/Resources/MenuBarIconTemplate.pdf` for the menu bar template image
- `apps/MetagentMenuBar/Sources/Resources/MenuBarIconTemplate.svg` as the generated template source

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
- The app bundle includes the Swift `metagent` helper under `Contents/Helpers/metagent`.
- `scripts/install-menu-bar-app.sh` rebuilds, copies that bundle to `~/Applications`, and can launch or restart it.
- `--launch` opens the app after install.
- `--restart` asks the existing app to quit and opens the installed copy.
- `scripts/install-cli.sh` installs the Swift helper to `~/.local/bin/metagent` for headless/MCP use.

For iterative SwiftUI work, run:

```bash
scripts/dev-menu-bar-app.sh
```

It watches Swift sources, package metadata, the app plist, and bundled visual
assets. Each change rebuilds the app, installs it to `~/Applications`, and
restarts the real menu-bar process. This is reliable live reload rather than
in-process hot reload, so transient UI state resets after each change.

The next packaging step is signing/notarization and wiring the future MCP server entry point through the Swift helper.
