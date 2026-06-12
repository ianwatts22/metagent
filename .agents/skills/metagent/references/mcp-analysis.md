# MCP Analysis

Use this reference when the user asks whether an MCP is available, what tools it exposes, what instructions are attached to it, or why it behaves differently across chats.

## Principles

- Do not collapse availability into one yes/no. Report `configured`, `authenticated`, `loaded`, and `verified` separately.
- Do not treat an absent active-chat namespace as proof the MCP is not configured.
- Do not treat configuration as proof the MCP is usable.
- Prefer read-only proof before any mutation.
- Distinguish direct vendor MCPs from wrapper services. If a wrapper fails with auth noise, check whether a direct MCP path exists.
- Separate instruction sources: namespace/server metadata, individual tool descriptions, dynamic guide/help tools, local plugin-bundle guidance files, and project/global instructions.
- When all availability layers are healthy, do not print the full installed/configured/authenticated/loaded/verified matrix unless the user asks for setup details, diagnostics, or evidence. Say it is working, cite the read-only proof in one sentence, then focus on the requested inventory, instructions, or decision.

## Fast Path

1. Identify the exact target name, plugin, connector, local app, or endpoint the user means.
2. Search active tool metadata with `tool_search` when available. Use specific queries such as `"<name> MCP tools"`, `"mcp__<name>"`, and known tool names.
3. If a namespace loads, capture:
   - namespace name
   - namespace description/instructions
   - every tool name
   - each tool's short purpose
   - required arguments and notable caveats
4. Run a harmless read-only tool call that proves live usability. Examples: `whoami`, `help`, `list_*`, `get_basic_info`, `get_current_user`, or a schema/read call.
5. If the read-only call fails, classify the blocker precisely: no app/file open, not authenticated, insufficient permission, no project selected, transport unreachable, wrong account, missing active-chat load, or bad argument shape.
6. Check local config and plugin bundle only as needed to explain gaps:
   - `codex mcp list`
   - `codex mcp get <name>`
   - plugin `mcp.json`
   - plugin `README.md`
   - plugin `rules/`
   - plugin `skills/*/SKILL.md`
7. Report the full status matrix only when a layer is failing, uncertain, surprising, or explicitly requested. For a healthy MCP, keep setup state terse and move to the requested output.

## Tool Inventory

When the user asks for "every tool":

1. Use the active namespace from tool metadata if it is exposed.
2. If lazy loading is needed, call `tool_search` with multiple targeted names.
3. List tool names exactly as exposed.
4. Group related tools if the list is long, but do not omit tools.
5. Prefer role-based grouping:
   - Meta/bootstrap: guide, help, instruction, schema, or server-orientation tools.
   - Context/orientation: current file/project/page, selection, tree, basic info, and file-list tools.
   - Read/extract: screenshot, styles, code export, image extraction, data read, and inspection tools.
   - Create/edit/mutate: write, create, update, move, duplicate, delete, send, or commit tools.
   - Export/publish: explicit export, upload, publish, deploy, or share tools.
6. Do not label guide/help/basic-info tools as ordinary read tools when they primarily establish MCP usage or session context.
7. Include a caveat if the list came from docs or a plugin bundle rather than the live active namespace.

If the namespace is not exposed but config exists, say "configured but not loaded into this chat" and explain that a fresh chat/reload may be needed after setup or auth changes.

## Instruction Inventory

When the user asks what instructions are attached to an MCP, check these layers:

1. Namespace/server-level metadata: the description attached to the namespace. When reporting this layer, quote the exact text as exposed, preserving line breaks, unless the user did not ask for instruction wording.
2. Per-tool descriptions: instructions attached to individual tool schemas.
3. Dynamic guide/help tools: tools named like `get_guide`, `help`, `get_instructions`, `instructions`, or similar.
4. Local plugin-bundle guidance files: plugin `skills/`, plugin `rules/` when present, README files, and local skill bundles.
5. Project/global instructions: `AGENTS.md` and triggered skills that affect how the MCP should be used.

If the user asks for wording, quote the relevant local metadata exactly when visible. If the source is inferred from plugin files or docs rather than active tool metadata, say that.

Do not call `rules/` a first-class plugin instruction layer unless the plugin manifest or loader evidence proves it is loaded that way. In most plugin bundles, `rules/` is best reported as a bundle-local guidance/reference folder.

## Live Verification

Use a read-only live call to prove more than loaded metadata:

- Identity/account: `whoami`, `get_current_user`, `get_profile`.
- File/project context: `get_basic_info`, `list_files`, `open_file`, `get_selection`.
- Schema/capability context: `help`, `read_schema`, `list_*`.
- Local HTTP app: a simple `curl` can prove whether a localhost endpoint is listening, but it is not enough to prove agent MCP bridge usability.

For local desktop MCPs, "namespace loaded" and "desktop app has an open project/file" are different states.

## Output Template

```text
Availability
- configured: yes/no/unknown, evidence
- authenticated: yes/no/unknown, evidence
- loaded: yes/no, active namespace/tools
- verified: yes/no, read-only call result

Only include the detailed availability rows when a layer is failing, uncertain, surprising, or explicitly requested. If everything is healthy, use a one-line proof instead.

Tools
- Meta/bootstrap: tool_a, tool_b
- Context/orientation: tool_c, tool_d
- Read/extract: tool_e, tool_f
- Create/edit/mutate: tool_g, tool_h
- Export/publish: tool_i

Instructions
- namespace/server: exact metadata text when asked for instructions
- per-tool: present/absent, notable caveats
- guide/help: available topics or result
- bundle guidance: local plugin skills, rule/reference files, and README files checked

Blocker / Next
- smallest action to unblock or the durable place to save the decision
```

## Common Pitfalls

- Saying "MCP unavailable" because a tool namespace is absent in the current chat, without checking config.
- Saying "MCP works" because config exists, without a read-only live call.
- Treating a wrapper auth error as proof the vendor's direct MCP is unusable.
- Forgetting that tool surfaces can lazy-load after `tool_search`.
- Forgetting that a fresh chat or app reload may be required after MCP config/auth changes.
- Mixing user-facing conclusions with raw internal node IDs, opaque handles, or noisy schema dumps when a concise inventory is enough.
