# Morph MCP Status

`metagent morph-mcp status` is a Swift helper command that inspects local
`@morphllm/morphmcp` worker processes.

```bash
metagent morph-mcp status
```

The command reports:

- matching `npm exec @morphllm/morphmcp` and `node .../morph-mcp` process lines
- whether the old project janitor LaunchAgent plist exists

The previous Rust janitor commands have been retired from the active command
surface during the Swift-first migration. If cleanup comes back, it should be
implemented in `MetagentCore` and exposed through the Swift helper.
