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

    @Test("control characters in paths survive a round trip")
    func escapesControlCharacters() throws {
        let path = try temporaryConfigPath()
        let awkward = "/tmp/line\nbreak\ttab\rcarriage\u{7F}"
        try MetagentCore.saveUserConfig(MetagentConfig(roots: [awkward]), at: path)
        #expect(try parsedConfig(at: path).roots == [awkward])
    }

    @Test("a read failure never replaces an existing config")
    func readFailureDoesNotOverwriteConfig() throws {
        let path = try temporaryConfigPath()
        let invalidUTF8 = Data([0xFF, 0xFE, 0xFD])
        try invalidUTF8.write(to: path)

        #expect(throws: Error.self) {
            try MetagentCore.saveUserConfig(MetagentConfig(roots: ["/replacement"]), at: path)
        }
        #expect(try Data(contentsOf: path) == invalidUTF8)
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

    @Test("managed key names inside a table remain user-owned")
    func preservesManagedNamesInsideTables() throws {
        let path = try temporaryConfigPath()
        try """
        roots = ["/old/root"]

        [plugin]
        roots = ["/plugin/root"]
        max_depth = 99
        ignore_projects = ["/plugin/ignored"]
        """.write(to: path, atomically: true, encoding: .utf8)

        try MetagentCore.saveUserConfig(
            MetagentConfig(roots: ["/new/root"], maxDepth: 3, ignoreProjects: []),
            at: path
        )

        let written = try String(contentsOf: path, encoding: .utf8)
        #expect(!written.contains("/old/root"))
        #expect(written.contains("[plugin]"))
        #expect(written.contains("roots = [\"/plugin/root\"]"))
        #expect(written.contains("max_depth = 99"))
        #expect(written.contains("ignore_projects = [\"/plugin/ignored\"]"))
    }

    @Test("table-like lines inside multiline values do not hide later managed keys")
    func tableLikeMultilineContentDoesNotChangeScope() throws {
        let path = try temporaryConfigPath()
        try #"""
        custom_matrix = [
          [1, 2]
        ]
        custom_banner = """
        [plugin]
        """
        roots = ["/old/root"]
        max_depth = 9
        """#.write(to: path, atomically: true, encoding: .utf8)

        try MetagentCore.saveUserConfig(
            MetagentConfig(roots: ["/new/root"], maxDepth: 3),
            at: path
        )

        let written = try String(contentsOf: path, encoding: .utf8)
        #expect(written.contains("custom_matrix = ["))
        #expect(written.contains("[1, 2]"))
        #expect(written.contains("[plugin]"))
        #expect(!written.contains("/old/root"))
        #expect(!written.contains("max_depth = 9"))
        #expect(try parsedConfig(at: path).roots == ["/new/root"])
        #expect(try parsedConfig(at: path).maxDepth == 3)
    }

    @Test("quoted multiline terminators do not retain stale managed keys")
    func quotedMultilineTerminatorClosesValueContext() throws {
        let path = try temporaryConfigPath()
        try #"""
        custom = ["""foo""""]
        roots = ["/old/root"]
        max_depth = 9
        """#.write(to: path, atomically: true, encoding: .utf8)

        try MetagentCore.saveUserConfig(
            MetagentConfig(roots: ["/new/root"], maxDepth: 3),
            at: path
        )

        let written = try String(contentsOf: path, encoding: .utf8)
        #expect(written.contains(#"custom = ["""foo""""]"#))
        #expect(!written.contains("/old/root"))
        #expect(!written.contains("max_depth = 9"))
        #expect(try parsedConfig(at: path).roots == ["/new/root"])
        #expect(try parsedConfig(at: path).maxDepth == 3)
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
