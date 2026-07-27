# Mac App

The macOS app is the primary `metagent` product surface. It imports the shared Swift `MetagentCore` package directly and exposes both:

- a standalone resizable app window
- a menu bar extra for quick status/actions

Current surface:

- four destinations: `Overview`, `Skills`, `MCPs`, and `Projects`, held in one enclosing glass track so they read as a tab group rather than as four standalone buttons the same height as the neighbouring controls. The selected tab is a solid accent fill instead of nested glass. All destinations are scoped by one top-level directory menu; the default is all directories. The backgroundless combomark, enlarged directory scope, glass navigation capsules, and settings/diagnostics menu form one compact top control line without a shared enclosing card. Portfolio counts live in the Overview content instead of the application identity area.
- a scope-aware skill-system health summary presented as one uniform grid of Liquid Glass metric cards. Every card leads with its number and explains it underneath, so a card reads "63% — unused skills, last 30 days" rather than the reverse. The headline value carries an optional muted qualifier beside it: the raw counts behind a rate, the unit behind a token total, or the P75 behind a median. The cards are Unused skills (last 30 days), Never used, reads per rated skill, SKILL.md body tokens, estimated name-and-description catalog tokens, and age. The catalog number is explicitly an estimate rather than a claim that every client injects every description on every turn. Global scope includes globally available, system, and plugin skills; project scope excludes them. Duplicate groups appear only when there is something to review and link directly to the guided decision queue.
- status is carried by the number itself rather than by added dots, icons, meters, or card fills, so six cards never become a color field. Values tint green under 20%, yellow under 40%, orange under 60%, and red at or above 60% of the rated portfolio. `SKILL.md instructions` stays entirely neutral because inventory size has no target.
- the reads distribution is three sub-tiles inside one card, one per percentile, rather than a single crowded string. Every figure on the card, headline or percentile, uses the same shape: the number, then its qualifier in muted text beside it. Only the median tile takes a status color, because only it supports a health claim: a P50 of zero means most of the portfolio has never been read.
- the portfolio view stops rating project skills in directories with no recorded agent session in the last 30 days, so dormant work does not inflate every unused rate. Dormancy is read from Claude Code session-history metadata only: a project root is folded to its session-directory name, and the newest `.jsonl` modification time in that directory is the project's last activity. Only directory and file metadata are read, never transcript contents. Codex rollouts are not consulted, so a directory worked in exclusively through Codex reads as dormant. Installed, rated, and dormant counts appear as chips beside the section title rather than as prose. Selecting a directory explicitly rates all of its skills, and when no session corpus is indexed at all nothing is treated as dormant. Token, age, and duplicate totals always describe everything installed in scope rather than only the rated subset.
- actionable health summary with Doctor findings grouped into project-level cleanups
- contextual repair preview shown only when a fix is available
- one native inset `Skills` table with persisted `Summary`, `Review`, `Inventory`, and `Usage` presets, plus a guided `Duplicates` decision queue. The view switcher uses the same glass track and accent capsule as the main navigation rather than a segmented picker wrapped in glass, which rendered a squared selection and resized as labels changed.
- destination pages carry no title of their own, because the active tab already names them. Row counts appear as one quiet chip beside the controls. Search and the usage-lifecycle filter stay in the open; location, grouping, and source visibility live behind one `Filters` menu that reports how many of them are off their defaults.
- Plugin Eval runs by itself in the background for visible skills with no cached result, so score columns fill in without a menu command. Failures are recorded rather than retried, so one broken skill cannot loop. Re-running Plugin Eval for a single skill and the Codex review both live in the row context menu; the Codex review stays explicit and confirmed because it uploads skill contents to OpenAI.
- `Summary` shows Skill, Location, Source, a compact Upstream, numeric Weeks old, Utility, estimated tokens, and 30d Usage, ordered by 30-day usage; `Review` contains Quality, Plugin Eval, Utility, and Codex review; `Inventory` adds description, version/ref, and reference/script counts; `Usage` shows recent/all-time reads and recency; State remains an optional column
- `Duplicates` detects distinct canonical bundles with the same skill identity, while ignoring Claude/Codex projections of one canonical folder. Its compact decision queue compares installed copies, usage, location, manager, update age, and abbreviated paths; makes similarity and plugin-replacement recommendations explicit; distinguishes global skills from named project skills; expands one or two candidates across the available comparison width; lets the user mark each removable copy Keep or Remove; and routes the final selection through the existing destructive approval. Exact copies, global-plus-project copies that may be intentional for collaborators, and unresolved same-name collisions remain judgment calls.
- every installed skill can open a readable skill viewer that separates its name, description, metadata, and block-rendered Markdown instructions, including headings, paragraphs, lists, quotes, dividers, and fenced code. Editable canonical skills can switch the viewer into a focused editor for name, description, and body; changing the name also renames the canonical directory and any per-skill Claude/Codex projection links as one rollback-safe operation. Saves preserve unrelated frontmatter, use atomic writes, and refuse to overwrite a file changed after loading. The viewer's `Make Paths Portable…` action reports exact home-directory references across the bundle, replaces them with `~` only in `SKILL.md` and reference documentation, and leaves scripts/config for manual review because shell expansion is context-dependent. Managed/plugin skills remain read-only. Get Info is the metadata-only surface available from the context menu or Command-I for provenance, lifecycle metadata, content counts, scores, and the canonical path; its secondary operations are consolidated under one Actions menu. Context actions can also open the exact `SKILL.md` in its default app or open the skill folder in a detected code editor. Editable canonical skills can add or change a portable PNG icon from the context menu or Get Info using the searchable native macOS Emoji & Symbols palette, all 1,748 icons from pinned `lucide-static` 1.25.0, or an imported PNG/JPEG/HEIC image. Icon Composer exports can be imported through Image; Icon Composer itself is an authoring app, not a symbol catalog.
- historical non-plugin usage without a matching installed bundle remains available in `Usage` as `Not installed` but is hidden by default through source visibility; unmatched plugin history remains under `Codex plugins` with unknown state because it may be disabled or the plugin scan may be unavailable; inventory, evaluation, open-folder, and removal actions remain limited to installed skills
- color-coded score badges that retain a letter label for non-color accessibility; Metagent and Codex use conventional absolute grade bands while Plugin Eval keeps its evaluator-owned grade
- standardized icon-only source cells with accessible tooltips: installed Codex and Claude artwork for agent-only sources, the dotagents mark for genuine dotagents-managed sources, the Vercel mark for Skills CLI, a terminal for specifically recognized third-party CLI bundles, and restrained system glyphs for local/unknown and historical records. Ordinary Git tracking is not upstream provenance; self-referential dotagents orphan-adoption records are classified as local/unknown rather than as lifecycle ownership.
- a persisted multi-select Source menu can hide any category across every preset, including Codex plugins and genuinely Claude-only skills; global/project location and usage-lifecycle filters compose with source visibility and search
- one persisted Group by picker applies to every Skills view. Source, Location, and Upstream create native collapsible table groups without duplicating the table into separate views.
- plugin-cache pseudo-projects are omitted from the top-level directory filter; a globe means global skill availability in Skills and global client configuration in MCPs, while a folder name without an icon means project scope. An MCP configured at both levels displays `globe + project` and explains both configurations in its tooltip; its Status remains the source of truth for availability.
- Liquid Glass is the standard for interactive chrome: top-level scope, navigation, settings, search filters, picker filters, segmented view choices, refresh/review actions, duplicate decisions, and the Overview metric cards. Overview section containers stay material-free so the glass cards inside them are never glass on glass. Native inset tables and readable content cards also remain material-free so large inventories preserve scan density, selection contrast, and accessibility.
- Quality excludes usage and combines available stable signals: Plugin Eval at 60%, management confidence (source, owner, manager, canonical identity) at 20%, and optional Codex review at 20%. Missing optional evaluations are excluded and the available weights are normalized. Utility combines Quality at 70% with observed adoption at 30% for retention decisions. Calendar age is visible but is not treated as evidence of poor quality by itself. The Skills toolbar's info control exposes a concise formula on hover and opens the full formula, missing-input behavior, example math, and grade bands; individual score cells expose row-specific math.
- the Projects table rolls inventory up by directory: logical skill count, MCP count, actual Claude `.claude/skills` sharing state, genuinely Codex-only and Claude-only skill counts, and grouped Doctor issues. `Connected` means `.claude/skills` resolves to `.agents/skills`; `Independent` is allowed only for a separate global collection. Agent-only counts exclude shared `.agents/skills`; Codex-only also excludes built-in system skills.
- unified skill rows are revision-cached after inventory, usage, or evaluation updates, so changing table presets does not repeat filesystem normalization and score work
- Threads, Reads / thread, repeat usage context, and lower-frequency identity fields remain available through native column customization, persisted independently for each preset. Threads is the number of distinct retained Codex sessions with an observed skill read; Reads / thread distinguishes broad one-off use from repeated reliance within fewer sessions.
- selected-skill Plugin Eval and read-only Codex review actions, plus an explicit visible-skill Plugin Eval batch action; Codex review requires confirmation because it sends the selected skill contents to OpenAI
- native Command-click multi-selection in the Skills table, with right-click actions to read a skill, inspect metadata, open its exact `SKILL.md`, open its folder in a code editor, open skill folders with another compatible application, copy canonical paths, copy a concise improvement prompt, or approve manager-aware removal; approved standalone/local removals move the full bundle into `~/Library/Application Support/Metagent/Removed Skills`, managed removals copy it there before delegating to the owning manager, and every archive records `before.json` and `after.json` inventory snapshots; approved rows disappear optimistically, failed rows return with details, Skills CLI removals sharing one project and lockfile use one upstream batch command, and independent project/plugin queues can continue concurrently; plugin selections delegate removal of the owning plugin to Codex's plugin manager, and duplicate plugin targets collapse into one action
- one activity badge and one reload button in the top control line are the only places processing is reported or restarted. The badge covers skill scanning, session-history indexing, MCP configuration checks, and Plugin Eval in one shape, showing determinate progress where a total is known; attention states outrank work in progress, because a stalled index stays true while an unrelated scan runs. It stays hidden when the app is idle. Reload rescans skills and Doctor findings, rechecks MCP configuration, and continues indexing history. Destination pages carry no refresh control and no status line of their own; the Doctor findings sheet keeps its own rerun because it is a modal.
- menu bar Skills summary that opens the main window for the full table
- the gear opens a real Settings sheet for scan roots, ignored directories, and search depth, with directory pickers rather than hand-edited TOML. Saving rewrites only those three keys and preserves comments, commented-out experiments, and any unknown keys already in `config.toml`, then triggers a status refresh. Opening the raw configuration file and the logs remain available inside the sheet as secondary actions.
- manual refresh and Quit

Refresh behavior:

- The app loads the latest SQLite inventory snapshot at startup when one exists.
- The app refreshes status when it launches.
- The `Refresh` buttons rerun Swift core scans on demand.
- Successful link repair triggers a status refresh.
- Skill provenance is resolved from skills-CLI locks first, then genuine dotagents source declarations, specifically recognized third-party CLI bundle signatures, and agent-specific/plugin installation locations. Everything else is `Local or unknown`: editable, but without a claimed upstream. The signature registry is deliberately narrow: a generic version field or a containing Git repository never establishes external ownership. A dotagents source that points back to its own `.agents/skills/<name>` install directory is orphan-adoption bookkeeping and does not establish lifecycle ownership.
- Plugin usage matches a marketplace-aware plugin-and-skill identity across versioned cache folders. The known `openai-curated` to `openai-curated-remote` rename remains one history, while genuinely different marketplaces remain separate.
- Doctor does not treat Skills CLI lock hashes as local-integrity fingerprints. Those hashes describe source folders used for update checks, while installation can intentionally omit source-only files, so comparing them to the installed copy creates false warnings.
- The Doctor card opens the current grouped cleanups. Repairable findings show an exact preview before applying a narrowly scoped action. Obsolete Codex projection cleanup removes only stale symlinks under `.codex/skills`; canonical skill folders are never removed.
- The UI keeps the most recent scan in memory until the next refresh.
- User-facing paths abbreviate the current home directory as `~`; canonical paths remain absolute internally and on copied values.
- The latest inventory snapshot is persisted to `~/Library/Application Support/Metagent/inventory.sqlite`.
- Plugin Eval and Codex review results are persisted to `~/Library/Application Support/Metagent/skill-evaluations-v1.json`.
- Cached usage loads from `~/Library/Application Support/Metagent/usage.sqlite` immediately.
- A low-priority, resumable session backfill runs after launch. It sleeps after each 16 MiB of input, updates in bounded windows, and stops when it reaches the current end of retained Codex history.
- Parser upgrades keep the previous Usage results visible until the replacement index completes and swaps atomically.
- Once current, there is no continuous polling; launch or manual refresh processes newly appended session bytes.
- Whole-directory project symlinks stay current automatically, so there is no periodic repair agent.

Portfolio history:

- Portfolio history is recorded to `~/Library/Application Support/Metagent/history.sqlite`, kept separate from `usage.sqlite` so a parser upgrade and its atomic index swap never put recorded history at risk.
- A sample is written when a successful scan completes, at most once per local day. Repeat scans on the same day update that day in place, so an active session does not write dozens of rows. A failed scan is never recorded, because a partial inventory would read as a day when skills disappeared.
- Days with no sample stay absent. Absent is rendered as a gap and never as zero or an interpolated line, because "the app was not open" and "the number was zero" are different facts.
- Adoption metrics are omitted entirely when no session corpus is indexed. Writing zeros for an unindexed machine would later read as evidence that nothing was ever used.
- Three tables carry the record. `history_snapshots` and `history_metrics` hold one narrow row per metric per scope per day, so adding a metric never needs a migration. `history_skill_states` is a slowly-changing dimension that writes a new row only when a skill's shape changes, which keeps it small and makes it the source for change events. `history_events` holds added, removed, renamed, content-changed, source-changed, and scope-changed transitions.
- Change detection compares each capture against the recorded current state. The first capture seeds that state and deliberately emits no events, because every installed skill predates capture and would otherwise read as added that day.
- A rename is proved by the canonical directory's inode, which survives the move, rather than guessed from similar content. Two unrelated skills of the same size are never paired as a rename.
- Content change is detected from counts the inventory scan already produced, not from a content hash. Hashing every file of several hundred bundles on each scan would cost more than the signal is worth; the tradeoff is that a rewrite of identical length is missed.
- History that predates capture is reconstructed once from the stores that already carry timestamps: git history where a skills directory is tracked, canonical directory creation dates everywhere else, the `Removed Skills` archive, and the `skill_usage_events` log. Everything reconstructed is marked `inferred` and must be drawn distinguishably from what the app observed.
- Git is the strongest of those and is preferred wherever it applies. One `git log --name-status` per repository covers every skill in it, so this stays a handful of subprocesses rather than one per skill, and `~/.agents` being its own repository means the whole global collection is covered. Git dates the commit that introduced a skill, while `st_birthtime` only reports when the bytes reached this disk, which a restore, a clone, or a plugin-cache extraction all reset to the wrong day. A moved bundle is followed through renames.
- Git supplies two things nothing else can. It records deletions the archive never saw, because the archive only knows about removals the app itself performed; and it is the only source of content-change history, since a skill's edit history simply did not exist before capture unless git kept it.
- Git coverage is partial, so it is used only for per-skill facts and portfolio counts, where each skill contributes its own lifetime and mixed evidence is legitimate. Aggregate token totals are never reconstructed from it: partial coverage would understate the total and render as a decline that never happened.
- Moving a bundle into the removal archive preserves its creation date, so an archived skill supplies both ends of its lifetime and the reconstructed portfolio curve falls on removal days instead of only rising. The archive remains a recovery mechanism: history reads it as evidence and never writes to it.
- Reconstruction uses the same deduplicated population the health summary uses, so a reconstructed count and a captured count describe the same set of skills and the seam between them is not a cliff.
- Two limits are stated rather than hidden. Reconstructed adoption is bounded by retained session history, so reads before the corpus begins are unrecoverable and early rates understate real use. Per-day project dormancy is not reconstructable, so reconstructed rates rate every skill alive that day while captured rates exclude dormant directories; the step at the seam is a change of method, not a change in the portfolio.
- Tokens, catalog size, scores, duplicate counts, Doctor findings, and MCP counts describe content and configuration that is overwritten in place. They have no history before capture began and are left absent for reconstructed days.
- `metagent history sample|show|events|coverage|backfill` exposes the same paths headlessly. `history coverage` reports observed and reconstructed day counts separately.

History surfaces:

- Three surfaces read the recorded series, at three altitudes: the Overview cards say which way each number is moving, the `History` destination says what the portfolio has been doing, and Get Info says what happened to one skill.
- Each Overview metric card gains a delta against the oldest day in the 30-day window and a sparkline beneath it. The delta names the day it compared against rather than claiming an exact window it may not have, because a machine that was closed for a week has no 30-day-ago sample. A single recorded day shows no delta at all: one value is a value, not a trend, and a zero delta there would be comparing a day against itself.
- Direction is not judgment. Each card says whether rising is good, so fewer unused skills reads green and a growing catalog reads orange, while inventory size and median age stay neutral because they carry no target. The sparkline follows the number's own status colour, so a card never says one thing in the figure and another in the line beside it.
- The compact menu bar panel omits sparklines. The trend is supporting detail and the number is the fact, so the small surface keeps the number at full size instead of shrinking it to fit a line.
- The `History` destination shares the top-level directory scope and adds a 30d/90d/1y/All range control. It charts installed skills, skills not being read, and instruction and catalog size, then lists recorded changes grouped by day. Grouping is deliberate: fifty individual rows from one install session is noise, while "Jul 16 · added 6" is the fact. A day expands to its individual changes, each showing the evidence it came from.
- Gaps are drawn as gaps everywhere. Each run of consecutive recorded days is its own line segment, so days with no sample are visibly empty rather than joined through with a line nobody measured. Reconstructed stretches are dashed and dimmed so inferred evidence never reads as observed.
- Get Info gains a Timeline section for the selected skill: when it was installed, how many times it changed and when it last changed, whether it was removed, and the individual events with their evidence. This is the view that changes a keep-or-remove decision, because it shows a skill installed in April, read twice, and untouched since.

Build:

```bash
cd apps/MetagentMenuBar
CLANG_MODULE_CACHE_PATH=/private/tmp/metagent-clang-cache swift build
```

The app targets macOS 26+ so interactive chrome—navigation, scope/filter controls, toolbar actions, and confirmation entry points—uses native SwiftUI Liquid Glass consistently. Data surfaces stay quiet: native inset tables and restrained content cards preserve sorting, resizing, accessibility, persistent column customization, density, and legibility instead of turning every row into glass.

Build a local `.app` bundle:

```bash
scripts/build-app.sh
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
scripts/install-app.sh --restart
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
- `scripts/build-app.sh` rebuilds the repo-local bundle in `dist/`.
- The app bundle includes the Swift `metagent` helper under `Contents/Helpers/metagent`.
- `scripts/install-app.sh` rebuilds, copies that bundle to `~/Applications`, and can launch or restart it.
- `--launch` opens the app after install.
- `--restart` asks the existing app to quit and opens the installed copy.
- `scripts/install-cli.sh` installs the Swift helper to `~/.local/bin/metagent` for headless/MCP use.

The Overview includes a compact MCP Connections summary. Its default check is passive: Codex is read through `codex mcp list --json`, while Claude is inventoried from user and project configuration plus enabled plugin manifests. The collapsed row keeps its left-hand text to a health statement and moves the configured total to the right, beside the per-client counts it decomposes into. It only expands automatically for sign-in, unreadable configuration, or pending project approval. Intentional disabled state stays neutral. The icon-only refresh action exposes its meaning through a tooltip and accessibility label; the checked-at timestamp is intentionally omitted as low-signal chrome.

The Overview is exception-only for skill cleanup. A compact cleanup row appears
only when Doctor has an actionable finding; a healthy “no cleanup needed” card
and generic operation output are intentionally omitted. Cleanup failures stay
inside the review sheet that owns the operation.

MCP health and Doctor do not poll on a timer. Both run when the app model starts,
when the overall refresh action is used, and after a successful repair or
removal. The MCP card and MCP tab also provide an MCP-only refresh action.

The MCPs tab groups the same server name across Codex and Claude into one row and
shows its clients, passive configuration state, and global/project location. The
all-directories scope includes both levels; choosing a project shows only servers
declared for that project. This
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
scripts/dev-app.sh
```

It watches Swift sources, package metadata, the app plist, and bundled visual
assets. Each change rebuilds the app, installs it to `~/Applications`, and
restarts the real menu-bar process. This is reliable live reload rather than
in-process hot reload, so transient UI state resets after each change.

The dev loop builds the debug configuration by default so a warm reload takes
seconds; pass `--release` to iterate against the optimized build. Installer
builds outside the dev loop (`install-app.sh`, `verify.sh`) remain
release builds. For pixel-level iteration without restarting the app, open the
package in Xcode and use the `#Preview` canvases (for example the duplicate
review previews at the end of `MetagentMenuBarApp.swift`), which render the
views with mock data.

The local app uses a persistent development signature. Distribution is a
separate mode, described below.

## Distribution

Public downloads are a signed, notarized disk image. Updates after that first
install are delivered in-app by Sparkle.

The two halves are deliberately different formats. The DMG is the human
download: it opens to `Metagent.app` beside an `Applications` shortcut, which is
the install gesture people already know. The zip is what Sparkle downloads and
swaps in place, because that is the format its installer expects.

### Signing modes

`scripts/build-app.sh` signs with an `Apple Development` certificate by
default, which is enough to run the app on the machine that built it. Setting
`METAGENT_DISTRIBUTION_BUILD=1` switches it to require a `Developer ID
Application` certificate, the only identity Gatekeeper accepts for a download
and the only one the notary service will process.

Both modes apply the hardened runtime, so a runtime restriction surfaces during
local development rather than in a rejected notarization log. Only distribution
builds request Apple's secure timestamp, which keeps local builds offline-capable.

Sparkle's framework carries its own nested code — two XPC services, `Autoupdate`,
and `Updater.app`. These are signed innermost-first before the framework, the
CLI helper, and finally the app bundle; an outer signature made first would seal
a hash that no longer matches. The downloader XPC service is re-signed with
`--preserve-metadata=entitlements`, per Sparkle's own guidance. Sparkle 2.9.4
ships it without entitlements, so today that preserves an empty set; the flag is
there so a future sandboxed build is not silently stripped.

### Versioning

Sparkle decides an update exists by comparing `CFBundleVersion` against the
appcast. The checked-in `Info.plist` carries a placeholder, so distribution
builds require `METAGENT_VERSION` and `METAGENT_BUILD_NUMBER` and refuse to
proceed without them. The release workflow sets both from the tag, which keeps
the comparison monotonic and makes re-running a failed release produce an
identical build rather than a spuriously newer one.

### Release pipeline

`.github/workflows/release.yml` runs on a `v*` tag:

1. Imports the Developer ID certificate into a throwaway keychain.
2. Builds with `METAGENT_DISTRIBUTION_BUILD=1` and the tag's version.
3. Notarizes and staples the app, so the ticket travels with the download and
   Gatekeeper clears it without a network round trip.
4. Cuts `Metagent.dmg` and `Metagent.zip` from the stapled bundle, then
   notarizes and staples the disk image.
5. Generates `appcast.xml` with Sparkle's `generate_appcast`, signed with the
   EdDSA private key.
6. Uploads everything to the release and commits `public/appcast.xml`.

The feed is served from the site rather than from the release, so a bad build
can be pulled by deleting its `<item>` and redeploying. Installed copies stop
being offered the update immediately, without touching the release itself.

Delta updates are not generated: `generate_appcast` builds them by diffing
against older archives present in the same directory, and CI only has the new
one. Full updates work; deltas would need prior releases downloaded first.

### One-time setup

Generate the Sparkle key pair once, from the same `Sparkle-<version>.tar.xz`
the workflow downloads:

```bash
./bin/generate_keys
```

The public key goes in `apps/MetagentMenuBar/Info.plist` as `SUPublicEDKey`;
the private key becomes the `SPARKLE_PRIVATE_KEY` repository secret. `SUFeedURL`
in the same plist must point at the deployed `appcast.xml`. The checked-in app
now carries the production public key and feed URL; the distribution guard still
rejects missing or placeholder values rather than publishing an app that cannot
update itself.

Required repository secrets:

| Secret | Purpose |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | Developer ID Application certificate, exported as `.p12` and base64-encoded |
| `MACOS_CERTIFICATE_PASSWORD` | Password set when exporting that `.p12` |
| `APPLE_NOTARY_ID` | Apple ID used for notarization |
| `APPLE_NOTARY_PASSWORD` | App-specific password for that Apple ID |
| `APPLE_TEAM_ID` | Developer team identifier |
| `SPARKLE_PRIVATE_KEY` | EdDSA private key from `generate_keys` |

### Checking for updates by hand

Settings shows the installed version and a `Check for Updates` action. When
`SUFeedURL` is still a placeholder the app says so and stays quiet rather than
retrying an unreachable URL in the background.
