import Foundation
import SwiftUI

@MainActor
final class AgentToolsModel: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var statusText = "Ready"
    @Published private(set) var lastRunText: String?
    @Published private(set) var systemImage = "wrench.and.screwdriver"

    private let fileManager = FileManager.default

    func syncNow() {
        guard !isRunning else { return }
        isRunning = true
        statusText = "Syncing skills..."
        systemImage = "arrow.triangle.2.circlepath"

        Task {
            let result = await runAgentTools(arguments: ["skills", "sync", "--apply"])
            isRunning = false
            lastRunText = Self.timestamp()

            if result.exitCode == 0 {
                statusText = "Skills in sync"
                systemImage = "checkmark.circle"
            } else {
                statusText = "Sync failed"
                systemImage = "exclamationmark.triangle"
            }
        }
    }

    func openConfig() {
        let configURL = homeURL()
            .appending(path: ".config")
            .appending(path: "agent-tools")
            .appending(path: "config.toml")
        NSWorkspace.shared.open(configURL)
    }

    func openLogs() {
        let logsURL = homeURL()
            .appending(path: "Library")
            .appending(path: "Logs")
            .appending(path: "agent-tools")
        NSWorkspace.shared.open(logsURL)
    }

    private func runAgentTools(arguments: [String]) async -> ProcessResult {
        await Task.detached {
            let process = Process()
            let cliPath = Self.cliPath()

            if cliPath == "/usr/bin/env" {
                process.executableURL = URL(fileURLWithPath: cliPath)
                process.arguments = ["agent-tools"] + arguments
            } else {
                process.executableURL = URL(fileURLWithPath: cliPath)
                process.arguments = arguments
            }

            let output = Pipe()
            let error = Pipe()
            process.standardOutput = output
            process.standardError = error

            do {
                try process.run()
                process.waitUntilExit()
                return ProcessResult(exitCode: process.terminationStatus)
            } catch {
                return ProcessResult(exitCode: 127)
            }
        }.value
    }

    nonisolated private static func cliPath() -> String {
        if let override = ProcessInfo.processInfo.environment["AGENT_TOOLS_CLI"],
           !override.isEmpty
        {
            return override
        }

        let candidates = [
            "/opt/homebrew/bin/agent-tools",
            "/usr/local/bin/agent-tools",
            "\(NSHomeDirectory())/.cargo/bin/agent-tools"
        ]

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }

        return "/usr/bin/env"
    }

    nonisolated private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return "Last run \(formatter.string(from: Date()))"
    }

    private func homeURL() -> URL {
        fileManager.homeDirectoryForCurrentUser
    }
}

struct ProcessResult {
    let exitCode: Int32
}
