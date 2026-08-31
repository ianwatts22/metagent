# Publishing the `metagent` Skill

This repo publishes the `metagent` skill for `npx skills` / skills.sh consumers.
The durable source is [.agents/skills/metagent/SKILL.md](../.agents/skills/metagent/SKILL.md).

## Publishing selected skills from the app

In **Skills → Published**, choose one canonical `~/.agents/skills` skill and a
separate, existing Git checkout. Previous destinations can be reused. **Start
Local Mirroring** checks the bundle and copies only that skill to
`skills/<destination-name>`; source-file changes continue to mirror one way.
The broader private skills directory is never exported. Stopping mirroring
leaves the last copy in place. Nothing commits, pushes, changes repository
visibility, or runs an install automatically.

Each card separates **mirror state** from an explicit **Check Git Status**:

- **Local changes to commit** includes staged, unstaged, untracked, and ignored
  files in this skill only. Ignored files need review before publishing.
- **Committed; no remote tracking branch** also covers a detached checkout.
- **Matches / differs from known upstream** compares this skill's committed
  tree with the locally stored remote tracking ref, not the whole repository.
  No fetch is run. Even a match is not proof of the current remote contents,
  public visibility, or skills.sh indexing.

Checks are user-triggered, run off the UI thread with a five-second deadline,
and display their check time. There is no background Git polling. A new mirror
snapshot invalidates an old result; changes made directly in Git require
another check. Git index writes, fsmonitor hooks, and network protocols are
disabled. Only existing Git configuration-location environment variables are
forwarded; injected config/routing/token variables are not. Effective local,
global, and system content filters cause a fail-closed result before status
checks, without executing those helpers. Attribute configuration is retained
so stripping user configuration cannot silently change Git's interpretation.

A credential-free GitHub `origin` and a supported current `SKILL.md` name
provide repository/skills.sh links and a copyable, single-skill install command.
Renaming the destination folder does not change the manifest's install name.
The command installs from the repository's default branch; use the explicit
Publish review before sharing it. A link is a destination, not a verified
live listing, and private repositories cannot be installed by unauthenticated
users. Metagent explicitly marks per-skill install counts unavailable until
official API-backed reporting exists; it never substitutes a guessed number.

## What "published" means

skills.sh has no separate upload or publish endpoint. A valid skill in a public
GitHub repository is indexed after the skills CLI installs it and sends its
anonymous install event. Metagent's canonical pages are:

- [repository page](https://skills.sh/ianwatts22/metagent)
- [skill page](https://skills.sh/ianwatts22/metagent/metagent)

The public metric is **installs**, not downloads or active users. It comes from
hourly deduplicated CLI telemetry and excludes telemetry-disabled and CI
installs. See the [skills.sh FAQ](https://skills.sh/docs/faq) and
[privacy details](https://skills.sh/privacy).

The [official catalog API](https://skills.sh/docs/api) exposes per-skill install
counts, stable IDs, file hashes, and audits, but requires a short-lived Vercel
OIDC token. A native app should read that data through a small authenticated,
cached service rather than scrape skill pages or embed a renewable bearer
credential. Until that service exists, link to the canonical skill page and use
the zero-auth repository badge for a repository-level install total.

## Publish Checklist

1. Keep the skill portable.
   - Remove private paths, account-specific facts, local logs, generated state, and one-off debugging residue.
   - Keep repo-specific implementation details in this repo's docs, not in the skill.

2. Validate local discovery from the repo root.

   ```bash
   npx --yes skills add . --list
   ```

   Expected result: one available skill named `metagent`.

3. Make the GitHub repository public and tag it for discovery.

   ```bash
   gh repo edit ianwatts22/metagent --add-topic agent-skills
   gh repo view ianwatts22/metagent --json name,url,isPrivate,repositoryTopics
   ```

4. Push the skill source to GitHub.

   ```bash
   git push origin main
   ```

5. Verify remote discovery.

   ```bash
   npx --yes skills add ianwatts22/metagent --list
   ```

   Expected result: the installer clones `https://github.com/ianwatts22/metagent.git`
   and lists `metagent`.

6. Install the published skill locally.

   ```bash
   npx --yes skills add ianwatts22/metagent --skill metagent
   ```

7. For subsequent published changes, push first and then update the managed global installation.

   ```bash
   npx --yes skills update metagent --global --yes
   ```

   Do not update before pushing: this command reads the GitHub source recorded in
   the global skills lock and can overwrite unpushed local changes.

## Local State Checks

`npx skills` records installed marketplace skills in
`${XDG_STATE_HOME}/skills/.skill-lock.json` when `XDG_STATE_HOME` is set,
otherwise `~/.agents/.skill-lock.json`. When dotagents manifests remain present,
Metagent reads `agents.toml` / `agents.lock` as ownership evidence and can
delegate an explicitly approved removal to dotagents. They do not replace the
skills CLI lock as the publishing source of truth.

After replacing an older local skill, check the skills CLI lock:

```bash
rg -n 'agent-meta|metagent|ianwatts22/metagent' ~/.agents/.skill-lock.json
```

For the `agent-meta` to `metagent` migration, the intended end state is:

- `~/.agents/skills/metagent/SKILL.md` exists.
- `~/.agents/.skill-lock.json` points `metagent` at `ianwatts22/metagent`.
- `~/.agents/skills/agent-meta` does not exist.

Legacy `~/.agents/agents.toml` and `~/.agents/agents.lock` files may still exist
on an older machine. Metagent treats their declarations as provenance while
they remain present; review and trash them explicitly if dotagents no longer
owns those entries rather than silently merging formats. Use
`scripts/retire-dotagents-state.sh` to verify that every declaration is
self-referential and preview the exact cleanup before applying it. Retain
the active lock at `${XDG_STATE_HOME}/skills/.skill-lock.json` when
`XDG_STATE_HOME` is set; otherwise retain `~/.agents/.skill-lock.json`, along
with the installed skill directories.

If a running agent session was started before installation, its loaded skill
inventory may stay stale until a new session starts.
