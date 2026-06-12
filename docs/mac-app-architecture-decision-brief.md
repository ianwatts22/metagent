# Mac App Architecture Decision Brief

Date: 2026-06-12

This is a neutral summary of the product requirements, architecture questions, and concerns Ian raised during the discussion. It intentionally does not include assistant recommendations.

## Goal

Ian wants an outside take on the right architecture for `metagent` before the app grows further. The decision is mainly about whether the project should continue as a Rust core plus Swift UI, move toward a Swift-first or Swift-only Mac app, and how MCP, persistence, analytics, and future background work should fit.

## Product Direction

- The product is expected to be primarily a native Mac app.
- The CLI may become incidental rather than the primary interface.
- MCP may become the more important agent-facing interface than a CLI.
- Ian wants to make the architectural call sooner rather than later to avoid expanding in the wrong direction.
- Ian is skeptical of an unnecessary split between a frontend and backend if the app does not need one.
- Ian has heard positive things about Rust and wants to understand whether those benefits justify keeping Rust in this project.

## Skill Inventory Requirements

Ian wants the app to clearly show where every skill is located.

Skill location should distinguish at least:

- `.agents/`
- `.codex/`
- `.claude/`

For skills in `.agents/`, Ian also wants the app to distinguish whether they were:

- installed from the `npx skills` source
- natively created

This should not be hidden or incidental metadata. Ian wants a first-class, very clear way to see this information in the app.

## Proposed Table View

Ian proposed adding a table view that shows every skill with columns such as:

- location
- provenance/source, including whether `.agents/` skills came from `npx skills` or were natively created
- what kind of folder the skill is in
- size, either raw character count or estimated word count
- token estimate for the `SKILL.md` file and everything within the skill directory
- number of reference files
- number of scripts
- count of files in any other folders
- whether the skill is configured with an icon
- whether the skill is configured with a logo, following the `skill-creator` skill conventions
- any other useful metadata that would help evaluate or manage skills

Ian questioned whether the current table-like UI is actually using a first-class Swift table element. He expects heavier table capabilities such as:

- sorting by different columns
- hiding columns
- better native table behavior
- a more serious table surface than a simple menu-bar list

Ian said this view does not necessarily need to live in the menu bar if that limits the UI. It can live in the main app instead.

## Caching And Update Concerns

Ian asked how the app currently handles inventory data:

- Is data cached?
- Is it recalculated every time?
- How often does it update?
- Does it update automatically in the background?
- Is it efficient enough to avoid unnecessary CPU/GPU/resource use?

Ian reacted to the current behavior described in the conversation as:

- no persistent cache
- no continuous UI polling
- refresh on launch
- refresh on manual Refresh
- refresh after successful sync or background-sync install actions
- last scan kept in memory until the next refresh
- LaunchAgent used for sync/repair, not UI inventory caching
- token counts estimated roughly as characters divided by four

Ian then proposed adding a database and asked whether SQLite is the right standard choice for Swift/macOS app operations.

## Rust Versus Swift Question

Ian asked whether Rust or Swift is the right mode for the app.

Concerns and questions:

- Should the project remain split between a Rust core and Swift app?
- Should this become a Swift-only app?
- Is a split frontend/backend architecture unnecessary for this product?
- If the app is primarily Mac-native, does Swift provide enough of what is needed?
- Does Rust provide enough value to justify the added architecture and build complexity?
- If switching to Swift is the right move, should that happen now before more app functionality is built on the current split?

Ian specifically framed the CLI as potentially incidental, not the center of the product.

## MCP Direction

Ian said that instead of a CLI, the future interface may mostly be MCP.

Questions raised:

- Is MCP language-agnostic in practice?
- Would an MCP server interact just as well with Swift code as with Rust code?
- If the app becomes Swift-first, can MCP still be first-class?
- Does the language choice matter for MCP beyond SDK maturity and implementation ergonomics?

## Future Analytics And Background Work

Ian asked whether Swift is good enough for future data analysis needs.

Potential future work could include:

- richer skill inventory analysis
- metadata extraction
- counts, sizes, and token estimates
- trend/history tracking
- local cache queries
- background refresh or repair workflows
- more advanced analysis later

Questions raised:

- Is Swift sufficient for the data analytics likely needed by this app?
- Would Rust be useful in the background for performance-sensitive work?
- Would Python be useful in the background for analytics or experimentation?
- Would adding Rust or Python workers later be easy enough if the app starts Swift-first?
- Should any background worker language be decided now, or only introduced if specific future workloads require it?

## Decision Criteria Ian Seems To Care About

- Keep the app efficient and avoid unnecessary background resource usage.
- Make the skill inventory highly visible, inspectable, sortable, and understandable.
- Avoid architectural complexity that does not earn its keep.
- Preserve the ability to support MCP well.
- Avoid committing too deeply to the wrong architecture before the app grows.
- Support future analysis workflows without overengineering early.
- Prefer a direction that makes the Mac app feel first-class rather than like a thin wrapper over incidental tooling.

## Questions For External Review

- If `metagent` is primarily a Mac app, should the source of truth move to Swift?
- If MCP is the primary agent interface, does Rust still need to own the core?
- Should the app use SQLite as the durable inventory/cache layer?
- Should the MCP server share the same Swift app core, or should it remain a separate Rust implementation?
- Should heavy analytics be deferred until there is evidence Swift plus SQLite is insufficient?
- What architecture minimizes future migration cost while keeping the app maintainable now?
