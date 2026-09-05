import Foundation
import XCTest
@testable import MetagentCore

final class SkillOverlapTests: XCTestCase {
    func testPluginReplacementDoesNotSuggestRemovingMerelySimilarGlobalStandalone() throws {
        let root = try fixtureRoot("plugin")
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
        XCTAssertFalse(group.members.contains(where: \.suggestedRemoval))
    }

    func testAutomaticRemovalRequiresIdenticalWholeBundles() throws {
        let root = try fixtureRoot("bundle-equality")
        let global = try writeSkill(root: root, relativePath: "global", body: "Run the script.")
        let project = try writeSkill(root: root, relativePath: "project", body: "Run the script.")
        let skills = [
            makeSkill(path: global.path, scope: "global", manager: "local"),
            makeSkill(path: project.path, scope: "project", manager: "local"),
        ]
        let original = try XCTUnwrap(MetagentCore.detectSkillOverlaps(skills).first)
        XCTAssertTrue(original.members.contains(where: \.suggestedRemoval))
        try "print('custom')".write(to: project.appendingPathComponent("script.py"), atomically: true, encoding: .utf8)
        let customized = try XCTUnwrap(MetagentCore.detectSkillOverlaps(skills).first)
        XCTAssertFalse(customized.members.contains(where: \.suggestedRemoval))
        XCTAssertNotEqual(original.members.last?.contentFingerprint, customized.members.last?.contentFingerprint)
        try "print('custom')".write(to: global.appendingPathComponent("script.py"), atomically: true, encoding: .utf8)
        XCTAssertTrue(MetagentCore.detectSkillOverlaps(skills)[0].members.contains(where: \.suggestedRemoval))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: project.appendingPathComponent("script.py").path)
        XCTAssertFalse(MetagentCore.detectSkillOverlaps(skills)[0].members.contains(where: \.suggestedRemoval))
    }

    func testSemanticWhitespaceCannotTriggerAutomaticRemoval() throws {
        let root = try fixtureRoot("semantic-whitespace")
        let global = try writeSkill(root: root, relativePath: "global", body: "```python\nif ready:\n    launch()\n    stop()\n```")
        let project = try writeSkill(root: root, relativePath: "project", body: "```python\nif ready:\n    launch()\nstop()\n```")
        let group = try XCTUnwrap(MetagentCore.detectSkillOverlaps([
            makeSkill(path: global.path, scope: "global", manager: "local"),
            makeSkill(path: project.path, scope: "project", manager: "local"),
        ]).first)
        XCTAssertEqual(group.similarity, 1)
        XCTAssertFalse(group.members.contains(where: \.suggestedRemoval))
    }

    func testOversizedOrLinkedBundlesDoNotSuggestRemoval() throws {
        let root = try fixtureRoot("bounded-bundles")
        let global = try writeSkill(root: root, relativePath: "global", body: "Shared instructions.")
        let project = try writeSkill(root: root, relativePath: "project", body: "Shared instructions.")
        let skills = [
            makeSkill(path: global.path, scope: "global", manager: "local"),
            makeSkill(path: project.path, scope: "project", manager: "local"),
        ]
        for directory in [global, project] {
            try Data(repeating: 0, count: 16 * 1024 * 1024 + 1).write(to: directory.appendingPathComponent("asset.bin"))
        }
        let oversized = MetagentCore.detectSkillOverlaps(skills)[0]
        XCTAssertFalse(oversized.members.contains(where: \.suggestedRemoval))
        XCTAssertTrue(oversized.members.allSatisfy { $0.contentFingerprint == nil })
        for directory in [global, project] {
            try FileManager.default.removeItem(at: directory.appendingPathComponent("asset.bin"))
            try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("linked.md").path, withDestinationPath: "SKILL.md")
        }
        XCTAssertFalse(MetagentCore.detectSkillOverlaps(skills)[0].members.contains(where: \.suggestedRemoval))
    }

    func testDuplicateSkillsInsideOneCodexPluginSystemAreIgnored() throws {
        let root = try fixtureRoot("codex-plugin-cache")
        let body = "Use the demo workflow and verify the result."
        let first = try writeSkill(root: root, relativePath: "plugin-a/demo", body: body)
        let second = try writeSkill(root: root, relativePath: "plugin-b/demo", body: body)

        let groups = MetagentCore.detectSkillOverlaps([
            makeSkill(path: first.path, scope: "plugin", manager: "codex-plugin"),
            makeSkill(path: second.path, scope: "plugin", manager: "codex-plugin"),
        ])

        XCTAssertTrue(groups.isEmpty)
    }

    func testDuplicateSkillsInsideOneClaudePluginSystemAreIgnored() throws {
        let root = try fixtureRoot("claude-plugin-cache")
        let body = "Use the demo workflow and verify the result."
        let first = try writeSkill(
            root: root,
            relativePath: ".claude/plugins/cache/vendor/first/1.0.0/skills/demo",
            body: body
        )
        let second = try writeSkill(
            root: root,
            relativePath: ".claude/plugins/cache/vendor/second/1.0.0/skills/demo",
            body: body
        )

        var firstPlugin = makeSkill(path: first.path, scope: "global", manager: "claude")
        firstPlugin.authority = "demo@vendor"
        var secondPlugin = makeSkill(path: second.path, scope: "global", manager: "claude")
        secondPlugin.authority = "demo@vendor"

        let groups = MetagentCore.detectSkillOverlaps([firstPlugin, secondPlugin])

        XCTAssertTrue(groups.isEmpty)
    }

    func testSameNamedSkillsFromDistinctPluginAuthoritiesRemainVisible() throws {
        let root = try fixtureRoot("distinct-plugin-authorities")
        let first = try writeSkill(
            root: root,
            relativePath: "plugin-a/demo",
            body: "Use the first plugin workflow and verify the result."
        )
        let second = try writeSkill(
            root: root,
            relativePath: "plugin-b/demo",
            body: "Use a different plugin workflow and inspect its output."
        )
        var firstPlugin = makeSkill(path: first.path, scope: "plugin", manager: "codex-plugin")
        firstPlugin.authority = "first@vendor"
        var secondPlugin = makeSkill(path: second.path, scope: "plugin", manager: "codex-plugin")
        secondPlugin.authority = "second@vendor"

        let group = try XCTUnwrap(MetagentCore.detectSkillOverlaps([
            firstPlugin,
            secondPlugin,
        ]).first)

        XCTAssertEqual(group.kind, .sameName)
        XCTAssertEqual(Set(group.members.map(\.authority)), ["first@vendor", "second@vendor"])
    }

    func testGlobalProjectCopySuggestsRemovingOnlyTheExactProjectCopy() throws {
        let root = try fixtureRoot("scopes")
        let body = "Use this workflow to inspect a project and verify the result."
        let global = try writeSkill(root: root, relativePath: "global/demo", body: body)
        let project = try writeSkill(root: root, relativePath: "project/demo", body: body)

        let group = try XCTUnwrap(MetagentCore.detectSkillOverlaps([
            makeSkill(path: global.path, scope: "global", manager: "local"),
            makeSkill(path: project.path, scope: "project", manager: "local"),
        ]).first)

        XCTAssertEqual(group.kind, .globalProject)
        XCTAssertEqual(group.members.filter(\.suggestedRemoval).map(\.canonicalPath), [project.path])

        try "Use this workflow to inspect a project and verify a different result."
            .write(
                to: project.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )
        let changed = try XCTUnwrap(MetagentCore.detectSkillOverlaps([
            makeSkill(path: global.path, scope: "global", manager: "local"),
            makeSkill(path: project.path, scope: "project", manager: "local"),
        ]).first)
        XCTAssertFalse(changed.members.contains(where: \.suggestedRemoval))
    }

    func testSimilarStandaloneCopiesDoNotMakeDissimilarPluginAReplacement() throws {
        let root = try fixtureRoot("plugin-pair")
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
        let skill = try writeSkill(root: root, relativePath: "global/demo", body: "Fixture")

        let canonical = makeSkill(path: skill.path, scope: "global", manager: "local")
        var projection = makeSkill(path: root.appendingPathComponent("claude/demo").path, scope: "global", manager: "local")
        projection.canonicalPath = skill.path
        projection.representation = "projection"

        XCTAssertTrue(MetagentCore.detectSkillOverlaps([canonical, projection]).isEmpty)
    }

    func testCanonicalizationWorkIsLinearInInventorySize() throws {
        let root = try fixtureRoot("resolution-count")
        let skills = (0..<192).map { index in
            SkillInventoryItem.fixture(
                name: "skill-\(index % 8)",
                path: root.appendingPathComponent("project-\(index / 8)/skill-\(index % 8)").path
            )
        }
        var projection = skills[0]
        projection.representation = "projection"
        var resolved: [String] = []
        let groups = MetagentCore.detectSkillOverlaps(skills + [projection]) { path in
            resolved.append(path)
            return path
        }

        XCTAssertEqual(resolved, skills.map(\.path))
        XCTAssertEqual(groups.count, 8)
        XCTAssertTrue(groups.allSatisfy { $0.members.count == 24 })
    }

    func testCanonicalAliasesKeepPreferredRepresentativeAndOriginalTieOrder() throws {
        let root = try fixtureRoot("canonical-alias")
        let target = try writeSkill(root: root, relativePath: "target", body: "Shared instructions.")
        let other = try writeSkill(root: root, relativePath: "other", body: "Shared instructions.")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        var firstPlugin = makeSkill(path: target.path, scope: "plugin", manager: "codex-plugin")
        firstPlugin.authority = "first-plugin"
        var laterPlugin = makeSkill(path: alias.path, scope: "plugin", manager: "codex-plugin")
        laterPlugin.authority = "later-plugin"

        let group = try XCTUnwrap(MetagentCore.detectSkillOverlaps([
            makeSkill(path: alias.path, scope: "global", manager: "local"),
            firstPlugin,
            laterPlugin,
            makeSkill(path: other.path, scope: "global", manager: "local"),
        ]).first)

        XCTAssertEqual(group.members.count, 2)
        XCTAssertEqual(group.members.first?.canonicalPath, target.path)
        XCTAssertEqual(group.members.first?.authority, "first-plugin")
        XCTAssertEqual(group.members.filter(\.suggestedRemoval).map(\.canonicalPath), [other.path])
    }

    func testProviderPathNormalizationOnlyAffectsVocabularySimilarity() throws {
        let root = try fixtureRoot("provider-normalization")
        let first = try writeSkill(root: root, relativePath: "one", body: "Read .agents/skills/demo/SKILL.md.\nThen verify.")
        let second = try writeSkill(root: root, relativePath: "two", body: "Read .claude/skills/demo/SKILL.md.  Then verify.")
        let group = try XCTUnwrap(MetagentCore.detectSkillOverlaps([
            makeSkill(path: first.path, scope: "global", manager: "local"),
            makeSkill(path: second.path, scope: "global", manager: "local"),
        ]).first)

        XCTAssertEqual(group.kind, .sameName)
        XCTAssertEqual(group.similarity, 1)
    }

    func testMissingDocumentsAreNotExactAndAreRecheckedOnNextCall() throws {
        let root = try fixtureRoot("missing-document")
        let first = try writeSkill(root: root, relativePath: "one", body: "Shared instructions.")
        let missing = root.appendingPathComponent("two")
        let skills = [
            makeSkill(path: first.path, scope: "global", manager: "local"),
            makeSkill(path: missing.path, scope: "global", manager: "local"),
        ]
        let initial = try XCTUnwrap(MetagentCore.detectSkillOverlaps(skills).first)
        XCTAssertEqual(initial.kind, .sameName)
        XCTAssertEqual(initial.similarity, 0)

        _ = try writeSkill(root: root, relativePath: "two", body: "Shared instructions.")
        XCTAssertEqual(MetagentCore.detectSkillOverlaps(skills).first?.kind, .exactDuplicate)
        _ = try writeSkill(root: root, relativePath: "two", body: "Changed at the same path.")
        XCTAssertEqual(MetagentCore.detectSkillOverlaps(skills).first?.kind, .sameName)
    }

    func testMixedPluginsKeepPerMemberSuggestionsAndPairMaximum() throws {
        let root = try fixtureRoot("mixed-plugins")
        let alpha = "apple apricot avocado banana blackberry blueberry cherry coconut cranberry date fig grape guava"
        let beta = "anchor barge buoy canal captain cargo compass crew deck ferry harbor hull marina rudder sail vessel"
        let unrelated = "algebra arithmetic calculus cosine derivative equation exponent formula fraction integral logarithm matrix polynomial quotient sine tangent vector"
        let fixtures: [(String, String, String, String)] = [
            ("plugin-a", "plugin", "codex-plugin", alpha),
            ("plugin-b", "plugin", "codex-plugin", beta),
            ("global-a", "global", "local", alpha),
            ("global-b", "global", "local", beta),
            ("project-a", "project", "local", alpha),
            ("unrelated", "global", "local", unrelated),
        ]
        let skills = try fixtures.map { name, scope, manager, body in
            let path = try writeSkill(root: root, relativePath: name, body: body)
            return makeSkill(path: path.path, scope: scope, manager: manager)
        }
        let group = try XCTUnwrap(MetagentCore.detectSkillOverlaps(skills).first)

        XCTAssertEqual(group.kind, .pluginReplacement)
        XCTAssertEqual(group.similarity, 1)
        XCTAssertEqual(Set(group.members.filter(\.suggestedRemoval).map(\.canonicalPath)), Set([
            root.appendingPathComponent("global-a").path,
            root.appendingPathComponent("global-b").path,
        ]))
        XCTAssertEqual(MetagentCore.detectSkillOverlaps(skills.reversed()), [group])
    }

    func testSymlinkRetargetIsObservedBetweenCalls() throws {
        let root = try fixtureRoot("retarget")
        let first = try writeSkill(root: root, relativePath: "one", body: "Shared instructions.")
        let second = try writeSkill(root: root, relativePath: "two", body: "Shared instructions.")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
        let skills = [
            makeSkill(path: first.path, scope: "global", manager: "local"),
            makeSkill(path: alias.path, scope: "global", manager: "local"),
        ]
        XCTAssertTrue(MetagentCore.detectSkillOverlaps(skills).isEmpty)
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: second)
        let group = try XCTUnwrap(MetagentCore.detectSkillOverlaps(skills).first)
        XCTAssertEqual(group.kind, .exactDuplicate)
        XCTAssertEqual(Set(group.members.map(\.canonicalPath)), Set([first.path, second.path]))
    }

    func testSkillDocumentSeparatesFrontmatterDescriptionAndBody() throws {
        let root = try fixtureRoot("reader")
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
        XCTAssertEqual(updated.directoryPath, root.appendingPathComponent("demo-renamed").path)
        XCTAssertEqual(updated.description, "First line.\nSecond line.")
        XCTAssertEqual(updated.bodyMarkdown, "# New heading\n\n- First\n- Second")
        XCTAssertEqual(updated.metadata.map(\.key), ["Version"])
        XCTAssertTrue(updated.rawText.contains("allowed-tools:"))
        XCTAssertTrue(updated.rawText.contains("  - Read"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: skill.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("demo-renamed/SKILL.md").path
        ))
    }

    func testSkillDocumentRoundTripsQuotedYAMLScalars() throws {
        let root = try fixtureRoot("quoted-editor")
        let skill = root.appendingPathComponent("demo")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try """
        ---
        name: demo
        description: "Use \\"quoted\\" values, a \\\\ path, a line\\x20break \\U0001F600, JSON \\uD83D\\uDE00, and controls \\0\\a\\v\\e.\\nSecond line."
        ---

        Original body.
        """.write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let original = try MetagentCore.loadSkillDocument(at: skill.path)

        XCTAssertEqual(original.name, "demo")
        let expectedDescription = "Use \"quoted\" values, a \\ path, a line break 😀, JSON 😀, and controls \u{0}\u{7}\u{B}\u{1B}.\nSecond line."
        XCTAssertEqual(original.description, expectedDescription)
        XCTAssertEqual(
            skillDescription(from: original.rawText),
            expectedDescription
        )

        let updated = try MetagentCore.updateSkillDocument(
            at: skill.path,
            expectedRawText: original.rawText,
            name: original.name,
            description: original.description ?? "",
            bodyMarkdown: "Updated body."
        )

        XCTAssertEqual(updated.name, original.name)
        XCTAssertEqual(updated.description, original.description)
        XCTAssertEqual(updated.bodyMarkdown, "Updated body.")
        XCTAssertFalse(updated.rawText.unicodeScalars.contains {
            [0x00, 0x07, 0x0B, 0x1B].contains($0.value)
        })
    }

    func testSkillDocumentRenamePreservesProjectionLinks() throws {
        let root = try fixtureRoot("editor-projection")
        let skill = root.appendingPathComponent(".agents/skills/demo")
        let projection = root.appendingPathComponent(".claude/skills/demo")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: projection.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        ---
        name: demo
        description: Projected demo.
        ---

        Original body.
        """.write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: projection.path,
            withDestinationPath: "../../.agents/skills/demo"
        )
        let original = try MetagentCore.loadSkillDocument(at: skill.path)

        let updated = try MetagentCore.updateSkillDocument(
            at: skill.path,
            expectedRawText: original.rawText,
            name: "renamed-demo",
            description: original.description ?? "",
            bodyMarkdown: original.bodyMarkdown
        )

        let renamedSkill = root.appendingPathComponent(".agents/skills/renamed-demo")
        let renamedProjection = root.appendingPathComponent(".claude/skills/renamed-demo")
        XCTAssertEqual(updated.directoryPath, renamedSkill.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: projection.path))
        XCTAssertEqual(
            renamedProjection.resolvingSymlinksInPath().standardizedFileURL.path,
            renamedSkill.path
        )
    }

    func testSkillDocumentSupportsCaseOnlyDirectoryRename() throws {
        let root = try fixtureRoot("case-only-rename")
        let skill = root.appendingPathComponent("Demo")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try """
        ---
        name: Demo
        description: Demo description.
        ---

        Body.
        """.write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let original = try MetagentCore.loadSkillDocument(at: skill.path)

        let updated = try MetagentCore.updateSkillDocument(
            at: skill.path,
            expectedRawText: original.rawText,
            name: "demo",
            description: original.description ?? "",
            bodyMarkdown: original.bodyMarkdown
        )

        XCTAssertEqual(updated.name, "demo")
        XCTAssertEqual(updated.directoryPath, root.appendingPathComponent("demo").path)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path),
            ["demo"]
        )
    }

    func testPortablePathScanOnlyAutomaticallyChangesDocumentation() throws {
        let root = try fixtureRoot("portable-paths")
        let skill = root.appendingPathComponent("demo")
        let references = skill.appendingPathComponent("references")
        let scripts = skill.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: references, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        try """
        ---
        name: demo
        description: Use \(home)/code_projects.
        ---

        Read \(home)/Documents.
        """.write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "See \(home)/notes and \(home). Keep \(home)2, /mnt/backup\(home)/notes, and <\(home)> portable."
            .write(to: references.appendingPathComponent("guide.md"), atomically: true, encoding: .utf8)
        try "#!/bin/zsh\ncd '\(home)/code_projects'\n"
            .write(to: scripts.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)

        let scan = try MetagentCore.scanSkillForPersonalPaths(at: skill.path)
        XCTAssertEqual(scan.replaceableOccurrenceCount, 5)
        XCTAssertEqual(scan.reviewOccurrenceCount, 1)

        let report = try MetagentCore.replacePersonalPathsWithTilde(at: skill.path)
        XCTAssertEqual(report.replacedOccurrenceCount, 5)
        XCTAssertTrue(try String(
            contentsOf: skill.appendingPathComponent("SKILL.md"),
            encoding: .utf8
        ).contains("~/code_projects"))
        let updatedReference = try String(
            contentsOf: references.appendingPathComponent("guide.md"),
            encoding: .utf8
        )
        XCTAssertTrue(updatedReference.contains("~/notes"))
        XCTAssertTrue(updatedReference.contains("~."))
        XCTAssertTrue(updatedReference.contains("<~>"))
        XCTAssertTrue(updatedReference.contains("\(home)2"))
        XCTAssertTrue(updatedReference.contains("/mnt/backup\(home)/notes"))
        XCTAssertTrue(try String(
            contentsOf: scripts.appendingPathComponent("run.sh"),
            encoding: .utf8
        ).contains(home))
    }

    func testPortablePathScanDoesNotTreatAncestorReferencesAsSkillDocumentation() throws {
        let ancestor = try fixtureRoot("references")
        let skill = ancestor.appendingPathComponent("project/.agents/skills/demo")
        let scripts = skill.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        try """
        ---
        name: demo
        description: Demo.
        ---
        """.write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "config \(home)/bin"
            .write(to: scripts.appendingPathComponent("config.txt"), atomically: true, encoding: .utf8)

        let scan = try MetagentCore.scanSkillForPersonalPaths(at: skill.path)

        XCTAssertEqual(scan.replaceableOccurrenceCount, 0)
        XCTAssertEqual(scan.reviewOccurrenceCount, 1)
    }

    func testSkillDocumentRenameRejectsExistingFolder() throws {
        let root = try fixtureRoot("editor-collision")
        let skill = try writeSkill(root: root, relativePath: "demo", body: "Original.")
        _ = try writeSkill(root: root, relativePath: "taken", body: "Existing.")
        let original = try MetagentCore.loadSkillDocument(at: skill.path)

        XCTAssertThrowsError(try MetagentCore.updateSkillDocument(
            at: skill.path,
            expectedRawText: original.rawText,
            name: "taken",
            description: original.description ?? "",
            bodyMarkdown: original.bodyMarkdown
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("already exists"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: skill.appendingPathComponent("SKILL.md").path))
    }

    func testSkillDocumentUpdateRejectsConcurrentChanges() throws {
        let root = try fixtureRoot("editor-conflict")
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

    func testSkillMarkdownBlocksRespectFenceKindAndLength() {
        let blocks = MetagentCore.skillMarkdownBlocks("""
        ~~~swift
        print("tilde")
        ~~~

        ````markdown
        ```nested
        content
        ```
        ````
        """)

        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].kind, .code(language: "swift"))
        XCTAssertEqual(blocks[0].text, "print(\"tilde\")")
        XCTAssertEqual(blocks[1].kind, .code(language: "markdown"))
        XCTAssertEqual(blocks[1].text, "```nested\ncontent\n```")
    }

    private func fixtureRoot(_ name: String) throws -> URL {
        try makeTemporaryRoot(prefix: "metagent-overlap-\(name)")
    }

    private func writeSkill(root: URL, relativePath: String, body: String) throws -> URL {
        try writeSkillFixture(
            at: root.appendingPathComponent(relativePath),
            description: "Demo workflow.",
            body: body
        )
    }

    private func makeSkill(path: String, scope: String, manager: String) -> SkillInventoryItem {
        let isPlugin = manager == "codex-plugin"
        return .fixture(
            description: "Demo workflow.",
            path: path,
            location: isPlugin ? "plugin" : "agents",
            locationLabel: isPlugin ? "Plugin" : ".agents",
            originKind: isPlugin ? "codex-plugin" : "user-local",
            scope: scope,
            manager: manager,
            authority: isPlugin ? "demo@openai-curated" : "unknown",
            mutability: isPlugin ? "managed-read-only" : "editable"
        )
    }
}
