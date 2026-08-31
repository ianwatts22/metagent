# MCP inspection

The MCP inventory is passive configuration evidence. Click a server name to
open its detail sheet; this does not start or contact that server.

The first inspection transport is **Codex user-scoped stdio**. Load configuration
through `codex mcp get <name> --json`, then explicitly approve starting that exact
in-memory snapshot. Metagent does not fall back to another client's same-named
server. Project-only, disabled, authentication-required, Claude, and remote HTTP
entries show an unsupported/unavailable state instead. Client OAuth tokens are
not read or copied. Environment forwarding (`env_vars`) is unsupported; only
configured environment entries and a small non-secret runtime allowlist are used.

Starting a configured executable is code execution, even when only reading its
metadata. The approval explains that startup can access files/network or download
packages. Metagent uses executable/argument arrays without shell interpolation.
It performs `initialize`, `notifications/initialized`, and paginated `tools/list`;
it never performs `tools/call`, sampling, elicitation, resource reads, or roots
discovery. Server requests are rejected. Server text is displayed literally, not
interpreted as instructions, Markdown links, or HTML.

Inspection is a one-time observation, not a live status or evidence of the tool
set loaded inside Codex. Results stay in sheet memory only and are not sent to
analytics. Server/tool descriptions, JSON input schemas, and optional output
schemas are presented separately from configuration. MCP initialization's optional
`serverInfo.description` and optional server `instructions` are distinct fields.

## Bounds and tests

- Fifteen-second monotonic deadline; 2 MiB combined stdout/stderr budget.
- Twenty pages, 500 tools, unique tool names, cursor-cycle rejection.
- Correlated JSON-RPC responses and supported negotiated protocol versions.
- Nonblocking input and output. Cancellation checks during writes, reads, and
  pagination. Cleanup terminates the owned process group, including wrappers'
  children, escalating to SIGKILL after a short grace period.
- Raw errors, argument values, and environment values are not displayed/logged.
- Schema rendering is on demand and capped for UI responsiveness.

`MCPInspectionTests` uses only deterministic in-memory responses and local fixture
processes, never the developer's real MCPs or credentials. It covers normal and
paginated responses, malformed/uncorrelated messages, protocol mismatch, repeated
cursors/names, disabled/configuration failures, secret-safe errors, output limits,
timeouts, cancellation, and descendant cleanup. Live GUI acceptance remains a
separate requirement; headless fixtures do not prove visual layout or accessibility.

Protocol references: [lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle),
[stdio transport](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports),
[tool discovery and schemas](https://modelcontextprotocol.io/specification/2025-11-25/server/tools).
