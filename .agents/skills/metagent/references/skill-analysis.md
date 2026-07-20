# Skill Analysis

Use this workflow to analyze one skill, one repository's collection, the global collection, or the combined portfolio.

## Ownership Boundary

- Metagent owns scope selection, portfolio inventory, canonical identity and provenance, duplication and overlap, usage evidence, prioritization, and lifecycle recommendations.
- Plugin Eval owns detailed static analysis and benchmarks for an individual shortlisted skill. Treat every score as Plugin Eval output, not a Metagent score.
- Skill Creator or the applicable skill-authoring guidance owns approved edits and validation.

Do not reproduce either downstream workflow inside Metagent.

## 1. Select Scope

Choose one before collecting evidence:

- `global`: user-level skills and manager state.
- `project`: one repository and its inherited/projected skills.
- `portfolio`: global skills plus every discovered project and plugin bundle in scope.

State exclusions, inaccessible roots, and whether discovery is complete. Use the Metagent app for its current inventory and Doctor surfaces. Verify supported CLI syntax before relying on it; current read-only forms include:

```bash
metagent skills scan --json
metagent skills scan --root /absolute/repository --max-depth 1 --json
metagent skills doctor --root /absolute/repository --max-depth 1 --json
```

## 2. Inventory Canonical And Projected Sources

Inspect applicable sources:

- Global canonical skills: `~/.agents/skills/` and the global skills-CLI `.skill-lock.json` v3 selected by `XDG_STATE_HOME` or `~/.agents/.skill-lock.json`.
- Project canonical skills: `<repo>/.agents/skills/`, skills-CLI `skills-lock.json` v1, and legacy/project `.agents/.skill-lock.json` when present.
- Agent-specific locations: relevant `.codex/skills`, `.claude/skills`, and `.cursor/skills` trees.
- Codex plugins: `~/.codex/plugins/cache/**/skills/` plus the owning plugin manifest/version directory.
- Dependency/config state: `agents.toml` and generated `agents.lock` where dotagents is actually present. Route dotagents-specific interpretation to its guidance; current Metagent does not generate those files.
- Other manager manifests, package metadata, or updater scripts that establish ownership.

The Metagent app/CLI currently recognizes skills under `.agents`, `.codex`, and `.claude` plus skills-cli lock variants. Plugin-cache and other-manager coverage may require direct filesystem inspection; say when inventory extends beyond current app output.

Do not double-count projections:

1. Resolve symlinks and real paths first.
2. Collapse paths that resolve to the same canonical directory.
3. For copied projections, require manager/manifest or content-hash evidence before collapsing them.
4. Keep same-name, different-content bundles as collisions until ownership and precedence are proven.

## 3. Normalize Identity And Provenance

Record these fields for each canonical skill:

- `scope`: global, project, plugin, or unknown.
- `authority`: user/project-owned, upstream package, plugin, external manager, vendored/forked, or unknown.
- `mutability`: editable, immutable/upstream-managed, explicit local exception, or unknown.
- `representation`: canonical or projection.
- `manager`: Git/repository, skills CLI, dotagents, Codex plugin, another named updater, or unknown.
- `provenance`: canonical path plus lock source/version, package/repository, ref/version/hash, and projection targets when available.

Use evidence, not directory names alone. A skills-cli lock entry is managed provenance. A missing lock entry means unmanaged; it does not prove the user authored the skill. Plugin-cache skills are plugin-managed. Explicit local ownership metadata or repository history outranks guesswork. Label conflicts and unresolved identity as unknown rather than inventing an owner.

Select the canonical physical source by resolving projections first, then using the owning manager's lock or manifest, and finally repository/global placement plus history for unmanaged skills. Treat independent same-name bundles as separate identities until evidence proves one is derived from the other.

## 4. Keep Evidence States Separate

Track each state independently:

- `available`: present and discoverable in the relevant scope.
- `configured`: declared by a manifest, project instructions, agent config, or manager.
- `loaded/read`: an active agent session demonstrably loaded or read it.
- `actually invoked`: direct session/tool evidence shows the skill guided a task.
- `verified/useful`: observed task outcomes or user evidence show it helped.

Record the evidence source and time window. Use `unknown` when session or outcome evidence is unavailable. Frequency is not usefulness, and no observed invocation is not deletion proof.

## 5. Detect Portfolio Problems And Opportunities

Check for:

- exact duplicates by canonical path or content;
- same-name collisions and likely semantic overlap from names, descriptions, triggers, and workflow boundaries;
- missing, broken, stale, or locally modified managed sources;
- global skills containing project-only paths, accounts, decisions, or workflows;
- project skills with genuinely broad use across unrelated work;
- oversized `SKILL.md` detail better deferred to `references/`;
- human-facing runbooks, background, or policy better placed in project documentation;
- weak, ambiguous, overly broad, or redundant triggers;
- manager conflicts, copied projections, and uncertain update paths.

Prefer cheap exact evidence before semantic judgment. Do not recommend deletion solely from size, age, or absent telemetry.

## 6. Shortlist Individual Evaluation

Create a shortlist before invoking Plugin Eval. Prioritize skills with high blast radius, overlap, unclear triggers, structural concerns, suspected dead weight, publication potential, or an impending edit. Do not run expensive individual evaluation across the whole portfolio by default.

For each shortlisted skill, pass the exact canonical directory rather than relying on name resolution:

```bash
plugin-eval start <canonical-skill-directory> --request "Evaluate this skill." --format markdown
plugin-eval analyze <canonical-skill-directory> --format markdown
```

Report `not run`, `completed`, `unavailable`, or `failed`, including the exact blocker. Explain scores and findings as Plugin Eval results. If Plugin Eval is missing or broken, continue with Metagent's inventory and evidence; do not fabricate a substitute score.

## 7. Recommend A Lifecycle Action

Choose one primary recommendation:

- keep;
- narrow trigger;
- move global or project;
- merge;
- rename;
- move detail to references or human-facing docs;
- vendor/fork;
- publish;
- prune candidate;
- insufficient evidence.

Tie confidence to specific provenance, trigger, structure, usage, overlap, and individual-evaluation evidence. A prune candidate still requires explicit approval before removal.

## 8. Route Approved Edits

After approval:

1. Edit the canonical source, not a projection or generated copy.
2. Use Skill Creator or the applicable authoring guidance.
3. Validate frontmatter, metadata, relative links, and bundled resources with that workflow's current validator.
4. Rerun the relevant Plugin Eval analysis or benchmark when it informed the change.
5. Recheck projections and manager state.
6. Distinguish repository changes from installed global copies, plugin-cache state, app bundles, and CLI/helper versions.

If a managed upstream skill needs local product-specific changes, prefer an explicit vendor/fork decision or upstream contribution over silently editing an immutable installation.

## Output Contract

Use a compact table, expanding evidence only for disputed or high-priority rows:

| Skill / canonical source | Scope | Owner / manager / provenance | Trigger | Usage evidence | Structural shape | Individual evaluation | Recommendation | Confidence / evidence | Next action |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `<name>`<br>`<path>` | global/project/plugin | authority, manager, lock/ref/hash | fit and overlap | available/configured/loaded/invoked/useful, with unknowns | concise/deferred/project-specific/etc. | status and evaluator-owned score | one lifecycle action | high/medium/low plus decisive evidence | smallest approved follow-up |

Close with scope coverage, unresolved evidence gaps, shortlisted evaluations, and any repository-versus-installed-state divergence.
