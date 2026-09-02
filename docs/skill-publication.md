# Skill publication

Metagent can continuously mirror selected canonical skills into a local public
Git checkout for publication through [skills.sh](https://skills.sh).

## Contract

- `~/.agents/skills/<skill>` is the only canonical source.
- Publication is opt-in per skill. Other skills are never copied.
- The local public checkout is generated output; changes never sync back.
- Metagent reconciles selected skills on launch, manual refresh, and filesystem
  changes while the app is running.
- Readiness and privacy checks run before every replacement. A blocked update
  leaves the last safe public copy intact.
- Removing the canonical source also leaves the public copy intact. Stopping
  mirroring never deletes it.
- Metagent never commits or pushes automatically.

## Use

1. Create or clone a public Git repository. Its standard layout is
   `skills/<skill-name>/SKILL.md`.
2. In **Skills**, right-click an editable canonical skill and choose
   **Publish…**.
3. Choose the repository checkout, review readiness, and select
   **Start Publishing**.
4. Use the **Published** view to check status, sync now, open the public copy,
   or stop mirroring.
5. Use **Publish…** or **Publish Update…** to review the exact destination,
   branch, and file changes, then explicitly choose **Commit & Publish**.

Metagent blocks explicit publishing when the checkout contains unrelated work,
unpublished or diverged history, content-filter attributes applied to files it
must inspect or publish, or a preview that changed after approval. Installed
but unused filter drivers such as Git LFS are allowed. Metagent never stashes,
pulls, rebases, resets, or force-pushes. A rejected push leaves its exact local
commit available for a safe retry.

The machine-local publication map is stored at
`~/Library/Application Support/Metagent/skill-publications-v1.json`. Paths and
repository choices are intentionally not committed to this repository.

## Safety gates

Publication blocks symlinks, special files, unsafe destination paths,
credential-like filenames and content, user-home paths, invalid skill
frontmatter, missing referenced scripts, oversized bundles, overlapping source
and destination roots, and destination collisions.

Copying uses a private staging directory. Metagent revalidates and hashes the
completed staged bundle immediately before swapping it into the public checkout
so source edits during a mirror cannot bypass the safety checks.
