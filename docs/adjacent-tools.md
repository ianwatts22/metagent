# Adjacent tools and product inspiration

Metagent sits near several local agent-observability and developer-operations
tools. This is a research watchlist, not a commitment to match every feature.
We should borrow interaction patterns that make agent infrastructure easier to
understand while preserving Metagent's narrower job: skills, MCPs, project
instructions, provenance, health, and actionable cleanup.

Last reviewed: July 24, 2026.

## Blume Sidecar

[Blume](https://www.blume.codes/) is a narrow desktop sidecar for supervising
several coding-agent harnesses. Its current product surface includes:

- **Agents:** active, idle, finished, and approval-needed work across Codex,
  Claude Code, Cursor, Pi, and other harnesses.
- **Setup:** rules, skills, hooks, and agent files in one place.
- **Usage:** remaining provider capacity.
- **Improve:** local review of rules and skills with previewable suggestions.
- **Feedback:** a loop for corrections and recurring setup improvements.

Ideas worth borrowing:

- Attention-first summaries: emphasize what finished or needs intervention,
  then collapse healthy detail.
- Cross-harness language and identity instead of organizing everything around
  one vendor.
- Recommendations as reviewable proposals with explicit approve/dismiss
  actions.
- A quiet, glanceable companion surface rather than a permanent dashboard.

Boundary for Metagent: do not turn the app into another task/session manager.
Metagent can link setup and usage evidence to projects without owning live agent
orchestration.

## CodexBar

[CodexBar](https://github.com/steipete/CodexBar) is an open-source native menu
bar utility for provider quotas, reset windows, credits, cost, and service
status. It supports many providers while keeping the primary surface compact.
Its CLI mirrors the app's provider fetchers and can return JSON or serve a
localhost-only API.

Ideas worth borrowing:

- One-glance status with progressive disclosure for detailed windows and
  charts.
- Provider adapters behind one stable model.
- Shared core behavior across native UI, CLI, and machine-readable output.
- Explicit caching, refresh timeouts, and degraded states so one provider
  cannot stall the whole interface.
- Menu-bar restraint: use status icons and exceptions instead of rendering a
  full report by default.

Boundary for Metagent: quota and billing aggregation are adjacent, not core.
Usage should help explain skill and MCP utility before we expand into a general
provider-cost product.

## Readout

[Readout](https://www.readout.org/) is a broad local coding-work observability
dashboard. The installed app currently groups its surface into:

- **Monitor:** Live, Sessions, Transcripts, Tools, Costs, Setup, and Ports.
- **Workspace:** Repos, Work Graph, Repo Pulse, Timeline, Diffs, and Snapshots.
- **Config:** Skills, Agents, Memory, and Hooks.
- **Health:** Hygiene, Dependencies, Worktrees, Environment, and Lint.

Ideas worth borrowing:

- A coherent taxonomy connecting runtime activity, repository state,
  configuration, and health.
- Drill-down from a portfolio overview into one repository or configuration
  object.
- Time-based evidence such as timelines and snapshots for explaining what
  changed.
- Treating tools, skills, hooks, and memory as inspectable first-class objects.

Boundary for Metagent: Readout demonstrates the cost of breadth as well as its
value. Metagent should keep the top-level model small—Overview, Skills, MCPs,
and Projects—and reveal deeper evidence inside those objects rather than
growing a large permanent sidebar.

## Product takeaways

The strongest shared pattern is a local control plane that translates hidden
agent files and runtime evidence into a small number of decisions:

1. What is available here?
2. What is active or actually used?
3. What needs attention?
4. Who owns the fix?
5. What changed after the fix?

Near-term Metagent implications:

- Keep healthy state terse and group related findings into one action.
- Make directory scope a first-class filter across every surface.
- Preserve the same analysis contract in the app, CLI, and MCP server.
- Add before/after snapshots to cleanup and removal workflows.
- Use recommendations as reversible review flows, not automatic mutation.
- Prefer a few strong project-level summaries over exposing every raw signal at
  once.

Review these tools periodically, especially when changing Metagent's overview,
menu-bar behavior, project model, or agent-analysis surface.
