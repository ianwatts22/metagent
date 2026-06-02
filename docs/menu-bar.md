# Menu Bar App

The menu bar app is a thin SwiftUI wrapper around the Rust CLI.

Current scaffold:

- menu bar item
- status text
- `Sync Skills Now`
- `Open Config`
- `Open Logs`
- `Quit`

The app looks for the CLI in this order:

1. `AGENT_TOOLS_CLI`
2. `/opt/homebrew/bin/agent-tools`
3. `/usr/local/bin/agent-tools`
4. `~/.cargo/bin/agent-tools`
5. `env agent-tools`

Build:

```bash
cd apps/AgentToolsMenuBar
swift build
```

The next step is packaging it as a real `.app` bundle with a bundled helper binary or a first-run CLI locator.

