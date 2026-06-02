import SwiftUI

@main
struct AgentToolsMenuBarApp: App {
    @StateObject private var model = AgentToolsModel()

    var body: some Scene {
        MenuBarExtra("Agent Tools", systemImage: model.systemImage) {
            Text(model.statusText)
                .font(.headline)

            if let lastRun = model.lastRunText {
                Text(lastRun)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button("Sync Skills Now") {
                model.syncNow()
            }
            .disabled(model.isRunning)

            Button("Open Config") {
                model.openConfig()
            }

            Button("Open Logs") {
                model.openLogs()
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .menuBarExtraStyle(.menu)
    }
}

