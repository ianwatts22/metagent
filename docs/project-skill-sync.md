# Project skill sync

Copy chosen global skill bundles into a project's `.agents/skills` so a fresh
or cloud checkout has the same files. This is a local, explicit copy operation,
not public skill publishing or continuous background mirroring.

## App

In **Projects**, choose **Sync Global Skills…** from a project's context menu.
The toolbar action uses the current project scope, or asks you to choose a
folder. Pick the global collection (`~/.agents/skills`, `~/.codex/skills`, or
`~/.claude/skills`), select up to 32 bundles, and choose **Preview files**.
Review the exact destinations, included files, removed obsolete copied files,
and warnings before choosing **Copy**.

The picker reads only the selected home-level collection. It never scans the
project portfolio or plugin caches. Linked projections and built-in `.system`
skills are excluded: choose the physical canonical collection instead. A
collection choice disambiguates same-name global bundles; an existing project
copy cannot silently switch to another source collection.

## Helper

```bash
# Preview only: no files or Git state change.
metagent skills sync-to-project git-hygiene deployment-workflow \
  --root /absolute/path/to/project --json

# After reviewing the preview, copy only those selected bundles.
metagent skills sync-to-project git-hygiene deployment-workflow \
  --root /absolute/path/to/project --apply --json

# Select direct Codex global bundles explicitly, not plugin/runtime copies.
metagent skills sync-to-project example --collection codex \
  --root /absolute/path/to/project
```

`--root` is required and must identify an existing physical folder. The default
source collection is `agents`; `--collection` takes `agents`, `codex`, or
`claude`. The names are folder names in that collection, not ambiguous portfolio
search results. JSON success contains `applied`, `plan`, `copiedNames`, and
`updatedNames`. A blocked preview exits nonzero with the preview JSON; other
operation failures return one `{"error":"…"}` object. No file content or
credential value is included in these reports.

## What reaches cloud

Copying is not enough: review the Git diff, commit the selected
`.agents/skills/<name>` folders and `.agents/project-skills.json`, and push the
commit through the project's normal workflow. Metagent never stages, commits,
pushes, changes visibility, force-adds ignored paths, or runs Git hooks to
prepare a copy. If the project's ignore policy excludes these files, they will
remain local until you deliberately change that policy.

Skills keep their full included scripts, references, assets and metadata, plus
regular file permissions (including executable status). Recognized generated directories (`.git`, `.build`,
`.cache`, `node_modules`, `__pycache__`) and `.DS_Store` are excluded and reported
in the preview. Symlinks, special files and likely credential files/content
block copying. Limits are 10 MiB per file, 50 MiB per bundle, 100 MiB per
selection, 4,096 entries per bundle, and 32 nested directories.

Copying does **not** move outside dependencies into the project, rewrite skill
instructions, install tools, or make a private skill safe to publish. Home
paths and global-skill references are visible portability warnings, not proof
that all dependencies were found. Review the selected content for private
accounts, internal context and unrecognized secrets before committing it.

## Refresh and conflicts

The portable `.agents/project-skills.json` file records only a format version,
skill folder names, source collection identifiers and content hashes. It
contains no absolute home/source paths, account mappings, or private overlays.
Keep it with the copied bundles so later refreshes can prove ownership.

A refresh is another explicit preview and copy. Identical owned bundles are a
no-op. An updated source replaces only selected, unchanged Metagent-owned
copies; the preview lists obsolete copied files that will disappear. Existing
project-owned bundles, local edits (including added generated files), missing
previously copied bundles, changed collection identities, manager-owned names,
and invalid ownership state fail closed. Unselected bundles are never deleted
or updated. Source, destination or manifest changes after preview invalidate
that preview. Files are staged, rechecked, and replaced with rollback backups;
if rollback cannot safely restore the original bundles, the error names the
retained recovery folder rather than discarding it.

## Avoiding local duplicates

Ordinary Git tracking does not provide a portable “GitHub-only, never local”
file property. Tracked copies normally appear locally as well as in cloud
checkouts, and an agent may list both the global and project bundle.

[Git sparse-checkout](https://git-scm.com/docs/git-sparse-checkout) can omit
tracked paths in one local worktree, but this is advanced, worktree-specific
configuration—not a repository-wide promise. Precise exclusions require
non-cone patterns (which Git discourages), and merges/rebases can materialize
omitted paths. Review the tradeoff and existing sparse settings yourself;
Metagent does not configure this workaround. Do not use low-level
`assume-unchanged`/`skip-worktree` tricks as an ignore policy; Git's
[update-index guidance](https://git-scm.com/docs/git-update-index) explains why
they do not reliably ignore tracked changes.
