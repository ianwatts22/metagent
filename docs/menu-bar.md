# Mac App

The macOS app is the primary `metagent` product surface. It imports the shared Swift `MetagentCore` package directly and exposes both:

- a standalone resizable app window
- a menu bar extra for quick status/actions

Current surface:

- three destinations: `Overview`, `Skills`, and `MCPs`, all scoped by one top-level directory picker; the default is all directories
- actionable health summary with Doctor findings grouped into project-level cleanups
- contextual repair preview shown only when a fix is available
- one native inset `Skills` table with persisted `Summary`, `Review`, `Inventory`, and `Usage` presets; presets change default columns and sorting while preserving one shared selection, context menu, search, and filter surface
- `Summary` shows Skill, stable Metagent Score, Plugin Eval Score, and estimated tokens, ordered by 30-day usage; `Review` adds the usage-adjusted Portfolio and Codex review scores; `Inventory` emphasizes location and source; `Usage` shows recent/all-time reads and recency; State remains an optional column
- historical non-plugin usage without a matching installed bundle remains available in `Usage` as `Not installed` but is hidden by default through source visibility; unmatched plugin history remains under `Codex plugins` with unknown state because it may be disabled or the plugin scan may be unavailable; inventory, evaluation, open-folder, and removal actions remain limited to installed skills
- color-coded score badges that retain a letter label for non-color accessibility; Metagent and Codex use conventional absolute grade bands while Plugin Eval keeps its evaluator-owned grade
- standardized icon-only source cells with accessible tooltips: installed Codex and Claude artwork for their sources, the dotagents mark for legacy dotagents declarations, the Vercel mark for Skills CLI, and restrained system glyphs for Git, local, and historical records; a dotagents path declaration means a legacy manifest points at a local bundle, not that dotagents downloaded it
- a persisted multi-select Source menu can hide any category across every preset, including all Codex plugin skills; global/project location and usage-lifecycle filters compose with source visibility and search
- plugin-cache pseudo-projects are omitted from the top-level directory filter; Skills and MCP tables use one Location convention: a globe for global availability and a folder name, without an icon, for project scope
- Metagent Score is the stable structural score: operational integrity and portfolio clarity are normalized to 100. Portfolio preserves the usage-adjusted 60-point structure plus 40-point observed-adoption calculation for retention decisions without conflating usage with intrinsic quality.
- unified skill rows are revision-cached after inventory, usage, or evaluation updates, so changing table presets does not repeat filesystem normalization and score work
- task/repeat usage context and lower-frequency identity fields remain available through native column customization, persisted independently for each preset
- selected-skill Plugin Eval and read-only Codex review actions, plus an explicit visible-skill Plugin Eval batch action; Codex review requires confirmation because it sends the selected skill contents to OpenAI
- native Command-click multi-selection in the Skills table, with right-click actions to open skill folders, choose a compatible application, copy canonical paths, copy a concise improvement prompt, or approve manager-aware removal; plugin selections delegate removal of the owning plugin to Codex's plugin manager, and duplicate plugin targets collapse into one action
- menu bar Skills summary that opens the main window for the full table
- lower-frequency Config and Logs actions in the header menu
- manual refresh and Quit

Refresh behavior:

- The app loads the latest SQLite inventory snapshot at startup when one exists.
- The app refreshes status when it launches.
- The `Refresh` buttons rerun Swift core scans on demand.
- Successful link repair triggers a status refresh.
- Skill provenance is resolved from skills-CLI locks first, then dotagents manifests/locks, Git repository evidence, and finally explicit user/project-local placement. Agent-specific standalone and plugin sources retain their named manager instead of falling back to `origin unknown`.
- Doctor does not treat Skills CLI lock hashes as local-integrity fingerprints. Those hashes describe source folders used for update checks, while installation can intentionally omit source-only files, so comparing them to the installed copy creates false warnings.
- The Doctor card opens the current grouped cleanups. Repairable findings show an exact preview before applying a narrowly scoped action. Obsolete Codex projection cleanup removes only stale symlinks under `.codex/skills`; canonical skill folders are never removed.
- The UI keeps the most recent scan in memory until the next refresh.
- The latest inventory snapshot is persisted to `~/Library/Application Support/Metagent/inventory.sqlite`.
- Plugin Eval and Codex review results are persisted to `~/Library/Application Support/Metagent/skill-evaluations-v1.json`.
- Cached usage loads from `~/Library/Application Support/Metagent/usage.sqlite` immediately.
- A low-priority, resumable session backfill runs after launch. It sleeps after each 16 MiB of input, updates in bounded windows, and stops when it reaches the current end of retained Codex history.
- Parser upgrades keep the previous Usage results visible until the replacement index completes and swaps atomically.
- Once current, there is no continuous polling; launch or manual refresh processes newly appended session bytes.
- Whole-directory project symlinks stay current automatically, so there is no periodic repair agent.

Build:

```bash
cd apps/MetagentMenuBar
CLANG_MODULE_CACHE_PATH=/private/tmp/metagent-clang-cache swift build
```

The app targets macOS 26+ so its primary controls can use native SwiftUI Liquid Glass while its data surfaces use native inset tables, sorting, resizing, accessibility, and persistent column customization.

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

Local installation requires an Apple Development code-signing identity. The
build automatically uses it when exactly one valid identity exists in the login
keychain, or uses `METAGENT_CODE_SIGN_IDENTITY` when explicitly set. If multiple
valid development identities exist, set the variable to the intended
certificate hash. Create an identity in Xcode under Settings > Accounts >
Manage Certificates if none exists.

The Apple-anchored designated requirement lets macOS recognize rebuilt versions
as the same app and preserve privacy grants. The first launch after switching
from an ad-hoc or self-signed build may request folder access once.

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

The Overview includes a compact MCP Connections summary. Its default check is passive: Codex is read through `codex mcp list --json`, while Claude is inventoried from user and project configuration plus enabled plugin manifests. The collapsed row shows configured counts and only expands automatically for sign-in, unreadable configuration, or pending project approval. Intentional disabled state stays neutral. The icon-only refresh action exposes its meaning through a tooltip and accessibility label; the checked-at timestamp is intentionally omitted as low-signal chrome.

The Overview is exception-only for skill cleanup. A compact cleanup row appears
only when Doctor has an actionable finding; a healthy “no cleanup needed” card
and generic operation output are intentionally omitted. Cleanup failures stay
inside the review sheet that owns the operation.

MCP health and Doctor do not poll on a timer. Both run when the app model starts,
when the overall refresh action is used, and after a successful repair or
removal. The MCP card and MCP tab also provide an MCP-only refresh action.

The MCPs tab groups the same server name across Codex and Claude into one row and
shows its clients, passive configuration state, and global/project location. The
top-level directory scope keeps globally applicable servers plus servers declared
for the selected project. This
inventory does not report tool, invocation, or token counts yet: tool discovery
requires connecting to each server, and the current session index does not
attribute calls or turn-wide token totals to individual MCP servers. Those fields
must come from explicit runtime telemetry rather than UI-time log scans.

“Configured” and “no known issues” do not mean a server was connected or a tool was invoked. Metagent does not start MCP processes, contact providers, refresh OAuth, inspect secrets, or claim live verification during the Overview check. Per-server details preserve that distinction and direct sign-in or unavailable states back to the owning client.

Pending Claude project servers retain their project paths. Their `Resolve…`
action opens a new Terminal in the relevant project and starts `claude`, where
Claude presents its normal project trust prompt. Deleted project-history entries
are ignored so Metagent never offers an action for a missing worktree. Metagent
does not approve the server, edit the manifest, or authenticate on the user's
behalf. Pending servers are grouped into one actionable row per project,
including when the same server name is awaiting approval in several projects.

For iterative SwiftUI work, run:

```bash
scripts/dev-menu-bar-app.sh
```

It watches Swift sources, package metadata, the app plist, and bundled visual
assets. Each change rebuilds the app, installs it to `~/Applications`, and
restarts the real menu-bar process. This is reliable live reload rather than
in-process hot reload, so transient UI state resets after each change.

The local app uses a persistent development signature. Distribution signing
and notarization remain separate future packaging work.
