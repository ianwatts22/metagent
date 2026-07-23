import Foundation
import XCTest
@testable import MetagentCore

final class SkillOverlapTests: XCTestCase {
    func testPluginReplacementSuggestsRemovingSimilarGlobalStandalone() throws {
        let root = try fixtureRoot("plugin")
        defer { try? FileManager.default.removeItem(at: root) }
        let standalone = try writeSkill(
            root: root,
            relativePath: "global/demo",
            body: "Use the demo workflow. First inspect the project. Then run the demo tool and verify the result."
        )
        let plugin = try writeSkill(
            root: root,
            relativePath: "plugin/demo",
            body: "Use the demo workflow. First inspect the project. Then run the bundled demo tool and verify the result."
        )

        let groups = MetagentCore.detectSkillOverlaps([
            makeSkill(path: standalone.path, scope: "global", manager: "local"),
            makeSkill(path: plugin.path, scope: "plugin", manager: "codex-plugin"),
        ])

        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.kind, .pluginReplacement)
        XCTAssertGreaterThan(group.similarity, 0.55)
        XCTAssertEqual(group.members.filter(\.suggestedRemoval).map(\.canonicalPath), [standalone.path])
    }

    func testGlobalProjectCopyIsInformationalEvenWhenContentsMatch() throws {
        let root = try fixtureRoot("scopes")
        defer { try? FileManager.default.removeItem(at: root) }
        let body = "Use this workflow to inspect a project and verify the result."
        let global = try writeSkill(root: root, relativePath: "global/demo", body: body)
        let project = try writeSkill(root: root, relativePath: "project/demo", body: body)

        let group = try XCTUnwrap(MetagentCore.detectSkillOverlaps([
            makeSkill(path: global.path, scope: "global", manager: "local"),
            makeSkill(path: project.path, scope: "project", manager: "local"),
        ]).first)

        XCTAssertEqual(group.kind, .globalProject)
        XCTAssertFalse(group.members.contains(where: \.suggestedRemoval))
    }

    func testSimilarStandaloneCopiesDoNotMakeDissimilarPluginAReplacement() throws {
        let root = try fixtureRoot("plugin-pair")
        defer { try? FileManager.default.removeItem(at: root) }
        let body = "Use the local workflow to inspect the project and verify the local result."
        let globalOne = try writeSkill(root: root, relativePath: "global-one/demo", body: body)
        let globalTwo = try writeSkill(root: root, relativePath: "global-two/demo", body: body)
        let plugin = try writeSkill(
            root: root,
            relativePath: "plugin/demo",
            body: "Translate nautical charts into a compact weather briefing for an ocean crossing."
        )

        let group = try XCTUnwrap(MetagentCore.detectSkillOverlaps([
            makeSkill(path: globalOne.path, scope: "global", manager: "local"),
            makeSkill(path: globalTwo.path, scope: "global", manager: "local"),
            makeSkill(path: plugin.path, scope: "plugin", manager: "codex-plugin"),
        ]).first)

        XCTAssertEqual(group.kind, .sameName)
        XCTAssertFalse(group.members.contains(where: \.suggestedRemoval))
    }

    func testCaseSensitiveCommandsAreNotExactDuplicates() throws {
        let root = try fixtureRoot("case-sensitive")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try writeSkill(
            root: root,
            relativePath: "one/demo",
            body: "Run API_TOKEN=secret demo verify."
        )
        let second = try writeSkill(
            root: root,
            relativePath: "two/demo",
            body: "Run api_token=secret demo verify."
        )

        let group = try XCTUnwrap(MetagentCore.detectSkillOverlaps([
            makeSkill(path: first.path, scope: "global", manager: "local"),
            makeSkill(path: second.path, scope: "global", manager: "local"),
        ]).first)

        XCTAssertEqual(group.kind, .sameName)
    }

    func testProjectionOfSameCanonicalBundleIsNotADuplicate() throws {
        let root = try fixtureRoot("projection")
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = try writeSkill(root: root, relativePath: "global/demo", body: "Fixture")

        let canonical = makeSkill(path: skill.path, scope: "global", manager: "local")
        var projection = makeSkill(path: root.appendingPathComponent("claude/demo").path, scope: "global", manager: "local")
        projection.canonicalPath = skill.path
        projection.representation = "projection"

        XCTAssertTrue(MetagentCore.detectSkillOverlaps([canonical, projection]).isEmpty)
    }

    func testSkillDocumentSeparatesFrontmatterDescriptionAndBody() throws {
        let root = try fixtureRoot("reader")
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = root.appendingPathComponent("demo")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try """
        ---
        name: demo
        description: A readable fixture.
        version: 2.4.0
        disable-model-invocation: false
        ---

        # Demo

        Follow the **instructions**.
        """.write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let document = try MetagentCore.loadSkillDocument(at: skill.path)

        XCTAssertEqual(document.name, "demo")
        XCTAssertEqual(document.description, "A readable fixture.")
        XCTAssertEqual(document.metadata.map(\.key), ["Version", "Disable Model Invocation"])
        XCTAssertTrue(document.bodyMarkdown.hasPrefix("# Demo"))
        XCTAssertFalse(document.bodyMarkdown.contains("description:"))
    }

    func testSkillDocumentUpdatePreservesOtherMetadataAndMarkdownLines() throws {
        let root = try fixtureRoot("editor")
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = root.appendingPathComponent("demo")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try """
        ---
        name: demo
        description: Old description.
        version: 2.4.0
        allowed-tools:
          - Read
        ---

        # Old heading

        Old body.
        """.write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let original = try MetagentCore.loadSkillDocument(at: skill.path)

        let updated = try MetagentCore.updateSkillDocument(
            at: skill.path,
            expectedRawText: original.rawText,
            name: "demo-renamed",
            description: "First line.\nSecond line.",
            bodyMarkdown: "# New heading\n\n- First\n- Second"
        )

        XCTAssertEqual(updated.name, "demo-renamed")
        XCTAssertEqual(updated.description, "First line.\nSecond line.")
        XCTAssertEqual(updated.bodyMarkdown, "# New heading\n\n- First\n- Second")
        XCTAssertEqual(updated.metadata.map(\.key), ["Version"])
        XCTAssertTrue(updated.rawText.contains("allowed-tools:"))
        XCTAssertTrue(updated.rawText.contains("  - Read"))
    }

    func testSkillDocumentUpdateRejectsConcurrentChanges() throws {
        let root = try fixtureRoot("editor-conflict")
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = try writeSkill(root: root, relativePath: "demo", body: "Original.")
        let original = try MetagentCore.loadSkillDocument(at: skill.path)
        try original.rawText
            .replacingOccurrences(of: "Original.", with: "Changed elsewhere.")
            .write(
                to: skill.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )

        XCTAssertThrowsError(try MetagentCore.updateSkillDocument(
            at: skill.path,
            expectedRawText: original.rawText,
            name: original.name,
            description: original.description ?? "",
            bodyMarkdown: "My edit."
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("changed on disk"))
        }
    }

    func testSkillMarkdownBlocksPreserveReadableStructure() {
        let blocks = MetagentCore.skillMarkdownBlocks("""
        # Heading

        First paragraph
        continues here.

        - One
        - Two

        ```bash
        echo hello
        echo world
        ```
        """)

        XCTAssertEqual(blocks.count, 5)
        XCTAssertEqual(blocks[0].kind, .heading(level: 1))
        XCTAssertEqual(blocks[1].text, "First paragraph continues here.")
        XCTAssertEqual(blocks[2].kind, .unorderedListItem)
        XCTAssertEqual(blocks[3].kind, .unorderedListItem)
        XCTAssertEqual(blocks[4].kind, .code(language: "bash"))
        XCTAssertEqual(blocks[4].text, "echo hello\necho world")
    }

    private func fixtureRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-overlap-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeSkill(root: URL, relativePath: String, body: String) throws -> URL {
        let directory = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try """
        ---
        name: demo
        description: Demo workflow.
        ---

        \(body)
        """.write(to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return directory
    }

    private func makeSkill(path: String, scope: String, manager: String) -> SkillInventoryItem {
        SkillInventoryItem(
            name: "demo",
            description: "Demo workflow.",
            path: path,
            location: manager == "codex-plugin" ? "plugin" : "agents",
            locationLabel: manager == "codex-plugin" ? "Plugin" : ".agents",
            originKind: manager == "codex-plugin" ? "codex-plugin" : "user-local",
            scope: scope,
            manager: manager,
            authority: manager == "codex-plugin" ? "demo@openai-curated" : "unknown",
            mutability: manager == "codex-plugin" ? "managed-read-only" : "editable",
            representation: "canonical",
            canonicalPath: path,
            source: nil,
            sourceType: nil,
            sourceURL: nil,
            ref: nil,
            installedAt: nil,
            updatedAt: nil,
            symlinkedContainer: false,
            folderKind: "fixture",
            characterCount: 100,
            wordCount: 20,
            tokenEstimate: 25,
            skillFileCharacterCount: 100,
            skillFileWordCount: 20,
            skillFileTokenEstimate: 25,
            textFileCount: 1,
            referenceFileCount: 0,
            scriptFileCount: 0,
            assetFileCount: 0,
            otherFileCount: 0,
            otherFolderCount: 0,
            hasOpenAIYaml: false,
            hasIconSmall: false,
            hasIconLarge: false,
            hasIconAndLogo: false,
            iconSmallPath: nil,
            iconLargePath: nil
        )
    }
}
