# Skill scoring

Metagent exposes four related signals because they answer different questions:

- **Quality** is the stable aggregate of available structural and evaluator evidence, excluding usage.
- **Utility** combines Quality with observed adoption from retained Codex history.
- **Plugin Eval** is the score and grade emitted by the installed `plugin-eval` CLI. Metagent does not reproduce or reinterpret its formula.
- **Codex review** is an optional model judgment against a fixed rubric. It only runs after confirmation. Metagent runs Codex read-only inside the skill's project (or, for global skills, from the home directory) and points it at the skill by path, so Codex reads the skill and its surroundings itself and the judgment reflects fit and overlap, not the skill in a vacuum. User configuration is ignored, writes and the obvious credential stores are blocked by the macOS sandbox, and what Codex reads is sent to OpenAI. It uses ChatGPT.app's native Codex binary by default; `METAGENT_CODEX` may point to another native executable.

None of these scores authorizes automatic removal or modification.

## Quality

Quality is a stable 0–100 weighted mean. Plugin Eval is the primary signal at
60%, management confidence contributes 20%, and optional Codex review
contributes 20%. Missing optional evaluations are excluded rather than treated
as zero, and the remaining weights are normalized. Usage changes and simple
calendar age do not change Quality.

The percentages are weights in Metagent's aggregate, not descriptions of each
evaluator's internal formula. For example, when Plugin Eval is 81, management
confidence is 100, and no Codex review exists, Quality is
`(81 × 60 + 100 × 20) / 80 = 86`.

### Plugin Eval — 60% of Quality when available

Plugin Eval is a separate deterministic evaluator. It starts from 100 and
deducts points for concrete findings. Its skill checks include invalid or
missing frontmatter, weak trigger descriptions, broken relative links,
oversized skill instructions, excessive token budgets, and missing progressive
disclosure. Errors, warnings, and informational findings have different
penalties. Metagent stores the score Plugin Eval returns; it does not recreate
or reinterpret that formula.

### Management confidence — 20% of Quality

This is not a judgment of the writing or usefulness of the skill. It asks
whether Metagent can safely identify and manage it: do we know the canonical
bundle, its source, owning manager, authority, mutability, and whether
same-named copies resolve to one identity? A high score means removal, updates,
and provenance are less ambiguous.

#### Operational integrity — 40 points

- canonical source resolved: 12
- manager known: 10
- authority known: 8
- mutability known: 5
- origin classified: 5

#### Portfolio clarity — 20 points

- one canonical identity, including projections that resolve to it: 20
- unresolved canonical identity: 8
- multiple independent same-name sources: 6

## Utility

Utility weights Quality at 70% and observed adoption at 30%. It is intended for
retention decisions, where both intrinsic quality and demonstrated use matter.
Review advisories stay separate because a changed external environment is not
evidence that the skill's quality or demonstrated utility changed.

### Observed adoption — 40 points

- recency: 16 within 7 days, 13 within 30 days, 9 within 90 days, 5 for older observed use
- breadth: up to 12 using `log2(distinct threads + 1)`, saturating around eight threads
- repeats: 2 points per repeat invocation, up to 8
- volume: up to 4 using `log2(total invocations + 1)`

When retained-history coverage is incomplete and no usage is linked, adoption receives a neutral provisional 20/40 and confidence is low. Once coverage is complete, no observed use receives 0/40. This prevents missing telemetry from masquerading as evidence of non-use.

Quality, Utility, and Codex grades use conventional fixed bands: A ≥90, B ≥80, C ≥70, D ≥60, otherwise F. They are absolute, not relative to the rest of the portfolio.

`Weeks old` is shown as lifecycle evidence but does not reduce either score. A
stable skill may remain correct for months. A tracked model release after the
skill's last change can create a separate review advisory, but does not change
Quality or Utility.

## Advisories

Advisories are Metagent-authored findings, separate from evaluator deductions.
They record that the world changed after the skill — not that the content is
defective — so they do not change Quality or Utility. Each advisory states how
it clears.

### Model-release staleness

Metagent polls the community model database at https://models.dev/api.json (no
auth) at most once per day, caching to
`~/Library/Application Support/Metagent/model-releases-v1.json`. A failed poll
keeps the cache. Only significant releases are kept: text-output models whose
id does not read as a size, speed, or modality variant (`-mini`, `-flash`,
`-realtime`, embeddings, and similar are dropped). Tracked providers default to
Anthropic and OpenAI and are configurable in Settings.

A skill whose last recorded change predates the newest tracked release gets a
review advisory. Skills with no update timestamp get no advisory; staleness is
an ordering claim and needs a date to stand on.

The advisory's remediation is deliberately directional: newer frontier models
need less prescription, so the review should look first for guidance to
delete, not add — over-describing and over-prescribing solutions can limit the
model.

The advisory clears when the skill changes after the newest tracked release,
or when it is explicitly marked reviewed (Score Analysis → "Mark Reviewed — No
Changes Needed"). Affirmations persist in
`~/Library/Application Support/Metagent/model-release-affirmations-v1.json`.
If a later review then finds real over-prescription, that lands on Quality
through Plugin Eval's own deductions, as usual.

Plugin Eval remains evaluator-owned and may return a different letter for the same numeric score. Its current fixed bands are A ≥93, B ≥85, C ≥70, D ≥55, otherwise F; Metagent preserves that returned grade rather than silently reinterpreting it.

Utility confidence is currently low or medium. V2 deliberately cannot claim high confidence because semantic overlap and task outcomes are not yet measured.

## Plugin Eval provider

Metagent resolves `plugin-eval` from `PATH`, with `METAGENT_PLUGIN_EVAL` as an override, and invokes:

```bash
plugin-eval analyze <canonical-skill-directory> --format json
```

The persisted record includes the returned score, grade, risk, deductions, evaluator version, evaluation time, and a hash of the canonical skill contents. Cached results are invalidated when that content changes, and cross-process cache updates are serialized so app and helper evaluations cannot overwrite one another. If the executable is unavailable or fails, Metagent reports that state instead of substituting its own logic.

View Skill and Get Info expose the complete current evidence behind these
scores. The detail view reconciles the normalized Quality and Utility formulas,
shows every management-confidence component, lists each Plugin Eval penalty and
its provider-authored remediation, and includes the Codex rubric dimensions,
summary, strengths, risks, and recommendation when available. Its **Fix first**
list ranks current Plugin Eval deductions by point penalty and then severity;
Metagent does not generate replacement findings. If installed content changes,
the old evaluator result is marked stale and excluded until it is run again.

## Codex review rubric

Codex assigns component scores that sum to 100:

- trigger and scope: 25
- workflow effectiveness: 25
- progressive disclosure: 20
- safety and operability: 15
- maintainability: 15

Metagent invokes `codex exec` with an ephemeral session, a read-only sandbox, a strict JSON output schema, and a ten-minute timeout. The review is by reference: the prompt names the skill's path and Codex reads the skill and its surroundings itself with read-only tools, from the skill's project root (global skills run from the home directory so every skills location is visible). This lets the review judge fit with project conventions, duplication against sibling skills, and trigger collisions. The prompt frames everything Codex reads as untrusted evidence, never instructions; an OS-level `sandbox-exec` profile independently blocks all writes outside the review's temporary directory and denies the obvious credential stores (`~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.kube`, Keychains, `~/.netrc`, `~/.npmrc`, `~/.git-credentials`). Selecting several skills reviews them all in one Codex session — one chat in Codex history, one review object returned per skill, each hash-checked and stored independently so a single bad skill fails alone. The review is contextual by design, so its score can legitimately change when the surrounding context changes, not only when the skill does. Metagent calculates the grade from Codex's component total using the shared grade bands.

## CLI

```bash
metagent skills evaluate /absolute/path/to/skill --provider plugin-eval
metagent skills evaluate /absolute/path/to/skill --provider codex
metagent skills evaluate /absolute/path/to/skill --provider all --json
```

Cached evaluations live in `~/Library/Application Support/Metagent/skill-evaluations-v1.json`. Canonical projections share the same record.
