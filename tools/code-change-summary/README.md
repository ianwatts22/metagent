# code-change-summary

Standalone code churn summary CLI.

## Tools

### CLI

Summarize `ts` and `tsx` code churn for any git repo using `git log --numstat` and `scc`.

Running bare `ccs` prints an overview snapshot:
- last 5 days
- this week plus previous 2 weeks
- this month plus previous month

Examples:

```bash
ccs --repo /path/to/repo --days 14
ccs --repo /path/to/repo --view weekly --periods 8
ccs --repo /path/to/repo --view monthly --periods 6 --graph mermaid
```

Notes:
- Requires `git` and `scc` on `PATH`
- Excludes `*.test.ts(x)`, `*.spec.ts(x)`, and `tests/` by default
- Excludes common generated/build/worktree directories from the codebase baseline scan
- Top summary now includes file and line counts for `tsx`, `tsx tests`, `ts`, and `ts tests`
- Coverage is auto-detected from common summary artifacts such as `coverage/coverage-summary.json`
- Churn output still excludes tests by default unless `--include-tests` is passed
- Use `--view` and `--periods` when you want a single focused window instead of the default overview
- The default overview includes ASCII trend graphs; use `--graph none` to suppress them
