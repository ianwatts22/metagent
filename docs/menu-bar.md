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

Build a local `.app` bundle:

```bash
scripts/build-menu-bar-app.sh
```

The generated app is written to:

```text
dist/AgentToolsMenuBar.app
```

The next packaging step is signing/notarization and either bundling the Rust helper binary or improving first-run CLI location.
