import Foundation
import Testing
@testable import MetagentCore

@Suite("Project activity")
struct ProjectActivityTests {
    @Test("matches Claude directory encoding for all punctuation")
    func matchesClaudeDirectoryEncoding() {
        #expect(
            sessionDirectoryName(for: "/Users/test/Library/Application Support/agent_tools/site.dev@work")
                == "-Users-test-Library-Application-Support-agent-tools-site-dev-work"
        )
    }

    @Test("finds activity for project roots containing spaces and at signs")
    func scansEncodedSessionDirectory() throws {
        let sessions = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-activity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sessions) }
        let root = "/Users/test/Library/CloudStorage/GoogleDrive-name@example.com/My Project"
        let sessionDirectory = sessions.appendingPathComponent(sessionDirectoryName(for: root))
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try Data().write(to: sessionDirectory.appendingPathComponent("session.jsonl"))

        let index = MetagentCore.scanProjectActivity(
            roots: [root],
            sessionsDirectory: sessions
        )

        #expect(index.isAvailable)
        #expect(index.lastActiveByRoot.keys.contains(standardizedActivityPath(root)))
    }
}
