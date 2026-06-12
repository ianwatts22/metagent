---
name: metagent
description: Analyze and improve AI-agent workflows, MCP servers, plugin/tool surfaces, skill usage, and durable instruction boundaries. Use when debugging MCP or connector availability, enumerating available tools, extracting namespace/server/tool instructions, distinguishing configured/authenticated/loaded/verified states, auditing skill dead weight, or deciding where agent-specific guidance should live.
---

# Metagent

## Overview

Use this skill for meta-work about agents and agent-facing tool surfaces. Keep it practical: prove what exists, where instructions came from, what is usable in this session, and what durable surface should own any follow-up change.

## Core Workflow

1. Start from the actual agent workflow or MCP under discussion, not the tool category.
2. Separate these states before making claims:
   - `installed`: files, app, CLI, plugin, package, or skill exists on disk.
   - `configured`: Codex, dotagents, app, or project config points at it.
   - `authenticated`: credentials, OAuth, local permissions, or app login work.
   - `loaded`: the active chat exposes a namespace/tool surface or skill metadata for it.
   - `verified`: a read-only live call proves it works for the current file, project, account, or workflow.
3. Prefer direct native MCP/plugin namespaces when mounted in the active chat. Prefer a stable CLI when it is documented, scriptable, and gives better evidence than an MCP.
4. Use `rg`, `fd`, local plugin bundles, config files, lockfiles, and read-only tool calls before proposing a new workflow or wrapper.
5. Keep global instructions broad and reusable. Put repo-specific facts in the project repo, project `AGENTS.md`, project docs, or project skills.

## MCP Analysis

For MCP availability, tool inventory, namespace instructions, dynamic guide/help tools, and active-session boundaries, read [references/mcp-analysis.md](references/mcp-analysis.md).

## Skill Analysis

For skill inventory, pruning, trigger quality, or marketplace readiness:

1. Separate `available`, `configured`, `loaded/read`, and `actually used`.
2. Check `SKILL.md` metadata first; trigger behavior depends on `name` and `description`.
3. Check `agents.toml`, lockfiles, scanner output, package-manager metadata, and recent real usage before recommending deletion.
4. Prefer pruning, merging, renaming, or moving repo-specific detail into project skills/docs over adding new global guidance.
5. When preparing a skill for sharing, keep it portable: remove local paths, private account facts, project-only decisions, generated logs, and one-off debugging residue.
6. Validate that an external installer can discover the skill from its repo layout before calling it publishable.

## Routing

- Use app-stack guidance for application framework choices, OpenAI Agents SDK usage, MCP templates in a starter app, repo scaffolding, and application observability.
- Use local tool-choice guidance for desktop apps, CLIs, editors, viewers, and non-code workflow tools when the work is not specifically about agent behavior or MCP/tool-surface analysis.
- Use dotagents guidance for `agents.toml`, global/project skill dependency management, dotagents MCP declarations, and sync/doctor workflows.
- Use local-maintenance guidance for persistent helper scripts, LaunchAgents, process cleanup, and machine-level agent runtime maintenance.
- Use current official product docs for Codex, OpenAI API, Apps SDK, Agents SDK, or product-surface behavior.
- Use current skill-authoring guidance when creating or changing skills; validate metadata and keep edits scoped.

## Output Shape

For agent/MCP investigations, report:

- `configured`: what config or bundle proves it exists.
- `authenticated`: what login, token, OAuth, or permission check proves access.
- `loaded`: whether the active chat exposes the namespace/tools or skill metadata.
- `verified`: the read-only call that actually worked, or the exact blocker.
- `instructions`: exact namespace/server metadata when asked, plus per-tool, dynamic guide/help, and bundle guidance sources checked.
- `next`: the smallest action to make the tool usable or the durable place to store the decision.

For skill audits, report:

- `source`: local path, repo source, package source, and lockfile evidence when available.
- `trigger`: whether the name/description matches real user phrasing and task boundaries.
- `usage`: what evidence exists for loaded/read/actual use, and what remains unknown.
- `shape`: whether the skill is portable, concise, and free of private or repo-specific clutter.
- `next`: prune, merge, rename, move, publish, or leave unchanged.

If all availability layers are healthy, do not print the full status matrix unless the user asked for setup details. Give a concise working-state note, then focus on the requested inventory, instructions, or decision.
