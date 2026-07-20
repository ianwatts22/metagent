# Skill scoring

Metagent keeps three evaluations separate because they answer different questions:

- **Metagent Score v1** measures operational trust, observed adoption, and identity clarity in the current portfolio.
- **Plugin Eval** is the score and grade emitted by the installed `plugin-eval` CLI. Metagent does not reproduce or reinterpret its formula.
- **Codex review** is an optional model judgment against a fixed rubric. It only runs after confirmation. Metagent copies up to 1 MiB of the selected skill into an isolated temporary directory, embeds its text in the review request, disables Codex tools and user configuration, confines local file access with the macOS sandbox, and sends the copied skill contents to OpenAI. It uses ChatGPT.app's native Codex binary by default; `METAGENT_CODEX` may point to another native executable.

None of these scores authorizes automatic removal or modification.

## Metagent Score v1

The score is 0–100.

### Operational integrity — 40 points

- canonical source resolved: 12
- manager known: 10
- authority known: 8
- mutability known: 5
- origin classified: 5

### Observed adoption — 40 points

- recency: 16 within 7 days, 13 within 30 days, 9 within 90 days, 5 for older observed use
- breadth: up to 12 using `log2(distinct tasks + 1)`, saturating around eight tasks
- repeats: 2 points per repeat invocation, up to 8
- volume: up to 4 using `log2(total invocations + 1)`

When retained-history coverage is incomplete and no usage is linked, adoption receives a neutral provisional 20/40 and confidence is low. Once coverage is complete, no observed use receives 0/40. This prevents missing telemetry from masquerading as evidence of non-use.

### Portfolio clarity — 20 points

- one canonical identity, including projections that resolve to it: 20
- unresolved canonical identity: 8
- multiple independent same-name sources: 6

Grades use the Plugin Eval bands for easy comparison: A ≥93, B ≥85, C ≥70, D ≥55, otherwise F.

Confidence is currently low or medium. V1 deliberately cannot claim high confidence because semantic overlap and task outcomes are not yet measured.

## Plugin Eval provider

Metagent resolves `plugin-eval` from `PATH`, with `METAGENT_PLUGIN_EVAL` as an override, and invokes:

```bash
plugin-eval analyze <canonical-skill-directory> --format json
```

The persisted record includes the returned score, grade, risk, deductions, evaluator version, evaluation time, and a hash of the canonical skill contents. Cached results are invalidated when that content changes, and cross-process cache updates are serialized so app and helper evaluations cannot overwrite one another. If the executable is unavailable or fails, Metagent reports that state instead of substituting its own logic.

## Codex review rubric

Codex assigns component scores that sum to 100:

- trigger and scope: 25
- workflow effectiveness: 25
- progressive disclosure: 20
- safety and operability: 15
- maintainability: 15

Metagent invokes `codex exec` with an ephemeral session, a read-only sandbox, a strict JSON output schema, and a five-minute timeout. It serializes a bounded copy of the skill as untrusted evidence and runs Codex from a separate empty working directory so bundled instructions are not discovered as agent policy. Metagent calculates the grade from Codex's component total using the shared grade bands.

## CLI

```bash
metagent skills evaluate /absolute/path/to/skill --provider plugin-eval
metagent skills evaluate /absolute/path/to/skill --provider codex
metagent skills evaluate /absolute/path/to/skill --provider all --json
```

Cached evaluations live in `~/Library/Application Support/Metagent/skill-evaluations-v1.json`. Canonical projections share the same record.
