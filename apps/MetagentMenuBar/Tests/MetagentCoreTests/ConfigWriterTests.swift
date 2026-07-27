import Foundation
import Testing
@testable import MetagentCore

@Suite("Config writer")
struct ConfigWriterTests {
    @Test("saving replaces managed keys and preserves everything else")
    func preservesUnmanagedContent() throws {
        let path = try temporaryConfigPath()
        try """
        # keep this note
        roots = [
          "/old/one",
          "/old/two"
        ]
        max_depth = 9
        # roots = ["/a commented experiment"]
        custom_future_key = "preserve me"
        ignore_projects = ["/old/ignored"]
        """.write(to: path, atomically: true, encoding: .utf8)

        try MetagentCore.saveUserConfig(
            MetagentConfig(roots: ["/new/root"], maxDepth: 3, ignoreProjects: ["/new/ignored"]),
            at: path
        )

        let written = try String(contentsOf: path, encoding: .utf8)
        #expect(written.contains("# keep this note"))
        #expect(written.contains("custom_future_key = \"preserve me\""))
        #expect(written.contains("# roots = [\"/a commented experiment\"]"))
        #expect(!written.contains("/old/one"))
        #expect(!written.contains("/old/two"))
        #expect(!written.contains("/old/ignored"))
        #expect(!written.contains("max_depth = 9"))

        let reread = try parsedConfig(at: path)
        #expect(reread.roots == ["/new/root"])
        #expect(reread.maxDepth == 3)
        #expect(reread.ignoreProjects == ["/new/ignored"])
    }

    @Test("saving creates a readable file when none exists")
    func writesFreshConfig() throws {
        let path = try temporaryConfigPath()
        try MetagentCore.saveUserConfig(
            MetagentConfig(roots: ["/one", "/two"], maxDepth: 0, ignoreProjects: []),
            at: path
        )

        let reread = try parsedConfig(at: path)
        #expect(reread.roots == ["/one", "/two"])
        #expect(reread.maxDepth == 0)
        #expect(reread.ignoreProjects.isEmpty)
    }

    @Test("quotes and backslashes in paths survive a round trip")
    func escapesAwkwardPaths() throws {
        let path = try temporaryConfigPath()
        let awkward = #"/tmp/we"ird\path"#
        try MetagentCore.saveUserConfig(MetagentConfig(roots: [awkward]), at: path)
        #expect(try parsedConfig(at: path).roots == [awkward])
    }

    @Test("rewriting twice is stable")
    func repeatedSavesAreStable() throws {
        let path = try temporaryConfigPath()
        let config = MetagentConfig(roots: ["/one"], maxDepth: 2, ignoreProjects: ["/two"])
        try MetagentCore.saveUserConfig(config, at: path)
        let first = try String(contentsOf: path, encoding: .utf8)
        try MetagentCore.saveUserConfig(config, at: path)
        #expect(try String(contentsOf: path, encoding: .utf8) == first)
    }

    @Test("brackets inside quoted array values do not consume later settings")
    func quotedBracketsDoNotChangeArrayDepth() throws {
        let path = try temporaryConfigPath()
        try """
        roots = [
          "/old/[unfinished",
          '/old/]literal'
        ]
        custom_future_key = "preserve me"
        """.write(to: path, atomically: true, encoding: .utf8)

        try MetagentCore.saveUserConfig(MetagentConfig(roots: ["/new/root"]), at: path)

        let written = try String(contentsOf: path, encoding: .utf8)
        #expect(written.contains("custom_future_key = \"preserve me\""))
        #expect(!written.contains("/old/[unfinished"))
        #expect(!written.contains("/old/]literal"))
    }

    /// Reads the file back through the same parsing helpers `loadUserConfig`
    /// uses, without depending on the process-wide home directory.
    private func parsedConfig(at path: URL) throws -> MetagentConfig {
        let text = uncommentedConfigText(try String(contentsOf: path, encoding: .utf8))
        return MetagentConfig(
            roots: try parseStringArray(key: "roots", text: text) ?? [],
            maxDepth: try parseInteger(key: "max_depth", text: text) ?? 6,
            ignoreProjects: try parseStringArray(key: "ignore_projects", text: text) ?? []
        )
    }

    private func temporaryConfigPath() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("metagent-config-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("config.toml")
    }
}
