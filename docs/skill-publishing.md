# Publishing the `metagent` Skill

This repo publishes the `metagent` skill for `npx skills` / skills.sh consumers.
The durable source is [.agents/skills/metagent/SKILL.md](../.agents/skills/metagent/SKILL.md).

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
`~/.agents/.skill-lock.json`. Metagent no longer invokes dotagents or treats
`agents.toml` / `agents.lock` as active ownership state.

After replacing an older local skill, check the skills CLI lock:

```bash
rg -n 'agent-meta|metagent|ianwatts22/metagent' ~/.agents/.skill-lock.json
```

For the `agent-meta` to `metagent` migration, the intended end state is:

- `~/.agents/skills/metagent/SKILL.md` exists.
- `~/.agents/.skill-lock.json` points `metagent` at `ianwatts22/metagent`.
- `~/.agents/skills/agent-meta` does not exist.

Legacy dotagents files may still exist on an older machine. They are inert to
Metagent and should be reviewed and trashed explicitly rather than silently
merged into current provenance.

If a running agent session was started before installation, its loaded skill
inventory may stay stale until a new session starts.
