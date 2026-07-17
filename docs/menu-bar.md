# Mac App

The macOS app is the primary `metagent` product surface. It imports the shared Swift `MetagentCore` package directly and exposes both:

- a standalone resizable app window
- a menu bar extra for quick status/actions

Current surface:

- standalone app window that opens when launching `Metagent.app`
- persistent menu bar window
- Swift core status, configured roots, discovered repo count, skill count, and actionable Doctor summary
- `Skills` menu with `.agents`, `.codex`, and `.claude` skill locations
- `.agents` skill origin badges from `.skill-lock.json`: `npx skills` source or native
- main-window `Inventory` table built with SwiftUI `Table`, sortable columns, native selection, and column resize/reorder/visibility customization
- menu bar `Inventory` section that opens the main app window for the full table
- `Refresh Status`
- `Doctor` findings grouped by project and cause, with repair guidance and technical details
- `Preview Repair`
- `Apply Repair`
- `Open Config`
- `Open Logs`
- `Restart App`
- structured dry-run preview with summary counts, per-project actions, warnings, and optional raw output
- explicit Repair explanation: Preview is read-only; Apply only creates or replaces project `.claude/skills` symlinks
- first-class skill inventory table with location, origin, folder kind, size, estimated tokens, resource counts, and icon/logo metadata
- last action output preview for other commands
- `Quit`

Refresh behavior:

- The app loads the latest SQLite inventory snapshot at startup when one exists.
- The app refreshes status when it launches.
- The `Refresh` buttons rerun Swift core scans on demand.
- Successful link repair triggers a status refresh.
- The Doctor card opens the current findings. `Repairable` means the finding can be fixed by the direct project symlink repair; Doctor itself remains read-only.
- The UI keeps the most recent scan in memory until the next refresh.
- The latest inventory snapshot is persisted to `~/Library/Application Support/Metagent/inventory.sqlite`.
- There is no continuous polling or automatic background rescan in the app.
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
