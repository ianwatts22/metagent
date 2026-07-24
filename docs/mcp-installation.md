# MCP installation

Metagent can register its stdio server with Codex and Claude through each
client's supported CLI. It does not edit either client's configuration files
directly.

```bash
# Preview the exact user-scoped change.
metagent mcp install --client codex
metagent mcp install --client claude

# Apply it.
metagent mcp install --client codex --apply
metagent mcp install --client claude --apply

# Inspect both clients, or one client.
metagent mcp status
metagent mcp status --client codex --json

# Preview and apply removal of only the entry named "metagent".
metagent mcp remove --client claude
metagent mcp remove --client claude --apply
```

Install and remove are previews unless `--apply` is present. Repeating an
install or removal is safe. Installation refuses to overwrite an existing
`metagent` entry whose command differs; remove that entry explicitly after
reviewing it, then install again.

The configured command is the resolved absolute path of the running
`metagent` executable followed by `mcp --stdio`. After an applied install,
Metagent asks the client CLI for the saved entry and performs a direct MCP
initialize/tools-list handshake with that executable.

These are deliberately separate claims:

- **configured**: the client CLI reports the expected saved entry;
- **directly verified**: the server answers the MCP protocol over stdio;
- **loaded/connected/invoked**: the client has restarted or opened a new
  session, loaded the entry, connected to it, and possibly called a tool.

Configuration and a direct handshake cannot prove the final client-runtime
states. Start a new Codex or Claude session after installation, then invoke a
read-only Metagent tool when end-to-end proof is required.

All commands accept `--json` for automation. JSON retains configuration state,
direct-verification state, whether a change occurred, the exact management
command, and the client-restart caveat.
