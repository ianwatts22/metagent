---
name: metagent
description: Analyze tooling, MCP/plugin availability, skill portfolios, and instruction ownership. Use when diagnosing tool or namespace availability; auditing skill provenance, overlap, use, or lifecycle; or deciding where guidance belongs.
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

For a single skill, one project's collection, or the combined global/project/plugin portfolio, read [references/skill-analysis.md](references/skill-analysis.md). Use it to normalize canonical identity and ownership, assess overlap and usage evidence, shortlist individual evaluations, and make lifecycle recommendations without treating missing telemetry as proof of non-use.

## Routing

- Use `$tech-stack` for application frameworks, SDKs, app scaffolding, dependencies, and observability.
- Use `$tool-stack` for desktop apps, CLIs, editors, viewers, and non-code workflow tools.
- Use `$dotagents` for `agents.toml`, `agents.lock`, dotagents-managed skills or MCPs, and dotagents sync/doctor workflows.
- Use `$local-machine` for persistent helpers, LaunchAgents, process cleanup, power commands, and machine-level runtime operations.
- Use `$openai-docs` for current Codex, OpenAI API, Apps SDK, Agents SDK, or product-surface behavior.
- Use `$skill-creator` or applicable authoring guidance for approved skill edits and validation.

Report evidence, uncertainty, and the smallest useful next action. Keep healthy state matrices terse unless the user asks for setup details or proof.
