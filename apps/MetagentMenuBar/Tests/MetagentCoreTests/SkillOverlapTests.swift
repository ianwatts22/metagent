import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
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

        let groups = matchingOverlaps([
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
        let original = try XCTUnwrap(matchingOverlaps(skills).first)
        XCTAssertTrue(original.members.contains(where: \.suggestedRemoval))
        try "print('custom')".write(to: project.appendingPathComponent("script.py"), atomically: true, encoding: .utf8)
        let customized = try XCTUnwrap(matchingOverlaps(skills).first)
        XCTAssertFalse(customized.members.contains(where: \.suggestedRemoval))
        XCTAssertNotEqual(original.members.last?.contentFingerprint, customized.members.last?.contentFingerprint)
        try "print('custom')".write(to: global.appendingPathComponent("script.py"), atomically: true, encoding: .utf8)
        XCTAssertTrue(matchingOverlaps(skills)[0].members.contains(where: \.suggestedRemoval))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: project.appendingPathComponent("script.py").path)
        XCTAssertFalse(matchingOverlaps(skills)[0].members.contains(where: \.suggestedRemoval))
    }

    func testSemanticWhitespaceCannotTriggerAutomaticRemoval() throws {
        let root = try fixtureRoot("semantic-whitespace")
        let global = try writeSkill(root: root, relativePath: "global", body: "```python\nif ready:\n    launch()\n    stop()\n```")
        let project = try writeSkill(root: root, relativePath: "project", body: "```python\nif ready:\n    launch()\nstop()\n```")
        let group = try XCTUnwrap(matchingOverlaps([
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
        let oversized = matchingOverlaps(skills)[0]
        XCTAssertFalse(oversized.members.contains(where: \.suggestedRemoval))
        XCTAssertTrue(oversized.members.allSatisfy { $0.contentFingerprint == nil })
        for directory in [global, project] {
            try FileManager.default.removeItem(at: directory.appendingPathComponent("asset.bin"))
            try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("linked.md").path, withDestinationPath: "SKILL.md")
        }
        XCTAssertFalse(matchingOverlaps(skills)[0].members.contains(where: \.suggestedRemoval))
    }

    func testDuplicateSkillsInsideOneCodexPluginSystemAreIgnored() throws {
        let root = try fixtureRoot("codex-plugin-cache")
        let body = "Use the demo workflow and verify the result."
        let first = try writeSkill(root: root, relativePath: "plugin-a/demo", body: body)
        let second = try writeSkill(root: root, relativePath: "plugin-b/demo", body: body)

        let groups = matchingOverlaps([
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

        let groups = matchingOverlaps([firstPlugin, secondPlugin])

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

        let group = try XCTUnwrap(matchingOverlaps([
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

        let group = try XCTUnwrap(matchingOverlaps([
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
        let changed = try XCTUnwrap(matchingOverlaps([
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

        let group = try XCTUnwrap(matchingOverlaps([
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

        let group = try XCTUnwrap(matchingOverlaps([
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

        XCTAssertTrue(matchingOverlaps([canonical, projection]).isEmpty)
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

        var countResolved: [String] = []
        let count = MetagentCore.countSkillOverlapGroups(skills + [projection]) { path in
            countResolved.append(path)
            return path
        }
        XCTAssertEqual(countResolved, skills.map(\.path))
        XCTAssertEqual(count, groups.count)
    }

    func testCountKeepsNormalizedNamesCrossSystemPluginsAndUnknownAuthorities() throws {
        let root = try fixtureRoot("count-eligibility")
        let codex = SkillInventoryItem.fixture(
            name: " Demo ", path: root.appendingPathComponent("codex").path,
            originKind: "codex-plugin", scope: "plugin", manager: "codex-plugin",
            authority: " Vendor/Plugin "
        )
        let claude = SkillInventoryItem.fixture(
            name: "demo", path: root.appendingPathComponent("claude").path,
            originKind: "claude-plugin", scope: "plugin", manager: "claude-plugin",
            authority: "vendor/plugin"
        )
        // Same authority is suppressed only inside the same plugin system.
        XCTAssertEqual(matchingOverlaps([codex, claude]).count, 1)
        var codexVersion = codex
        codexVersion.path = root.appendingPathComponent("codex-version").path
        codexVersion.canonicalPath = codexVersion.path
        codexVersion.authority = "vendor/plugin"
        XCTAssertTrue(matchingOverlaps([codex, codexVersion]).isEmpty)

        for authority in ["unknown", "", " \n"] {
            var first = codex
            var second = codexVersion
            first.authority = authority
            second.authority = authority
            XCTAssertEqual(matchingOverlaps([first, second]).count, 1)
        }
        var unrelated = claude
        unrelated.name = "another skill"
        XCTAssertTrue(matchingOverlaps([codex, unrelated]).isEmpty)
        XCTAssertTrue(matchingOverlaps([]).isEmpty)
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

        let group = try XCTUnwrap(matchingOverlaps([
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
        let group = try XCTUnwrap(matchingOverlaps([
            makeSkill(path: first.path, scope: "global", manager: "local"),
            makeSkill(path: second.path, scope: "global", manager: "local"),
        ]).first)

        XCTAssertEqual(group.kind, .sameName)
        XCTAssertEqual(group.similarity, 1)
    }

    func testIdenticalDocumentPreparationIsSharedButBundleEvidenceStaysIndependent() throws {
        let root = try fixtureRoot("shared-document-preparation")
        let first = try writeSkill(root: root, relativePath: "a-global", body: "Alpha shared instructions.")
        let second = try writeSkill(root: root, relativePath: "b-global", body: "Alpha shared instructions.")
        let project = try writeSkill(root: root, relativePath: "c-project", body: "Alpha shared instructions.")
        try "Project customization.".write(
            to: project.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8
        )
        let skills = [
            makeSkill(path: first.path, scope: "global", manager: "local"),
            makeSkill(path: second.path, scope: "global", manager: "local"),
            makeSkill(path: project.path, scope: "project", manager: "local"),
        ]
        var preparedTexts: [String] = []
        func detect() -> [SkillOverlapGroup] {
            MetagentCore.detectSkillOverlaps(skills, canonicalize: { $0 }) { text in
                preparedTexts.append(text)
                return ComparableSkillDocument(text: text)
            }
        }

        let initial = try XCTUnwrap(detect().first)
        XCTAssertEqual(preparedTexts.count, 1)
        XCTAssertEqual(initial.similarity, 1)
        XCTAssertEqual(initial.kind, .globalProject)
        XCTAssertEqual(Set(initial.members.compactMap(\.contentFingerprint)).count, 2)
        XCTAssertFalse(initial.members.contains(where: \.suggestedRemoval))

        // A second invocation must prepare again; no path/content state persists.
        XCTAssertEqual(detect(), [initial])
        XCTAssertEqual(preparedTexts.count, 2)

        let path = first.appendingPathComponent("SKILL.md")
        let raw = try String(contentsOf: path, encoding: .utf8)
        let modifiedAt = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: path.path)[.modificationDate] as? Date
        )
        let changed = raw.replacingOccurrences(of: "Alpha", with: "Bravo")
        XCTAssertEqual(raw.utf8.count, changed.utf8.count)
        try changed.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: path.path)

        let refreshed = try XCTUnwrap(detect().first)
        XCTAssertEqual(preparedTexts.count, 4) // Two different texts, not three paths.
        XCTAssertTrue(preparedTexts.suffix(2).contains { $0.contains("Bravo") })
        XCTAssertNotEqual(initial.members.first?.contentFingerprint, refreshed.members.first?.contentFingerprint)
    }

    func testDocumentPreparationKeysUseExactUTF8NotNormalizedOrCanonicalEquivalentText() throws {
        let root = try fixtureRoot("document-preparation-keys")
        let bodies = [
            "Read .agents/skills/demo/SKILL.md. Café instructions.",
            "Read .claude/skills/demo/SKILL.md. Café instructions.",
            "Read .agents/skills/demo/SKILL.md. Cafe\u{301} instructions.",
        ]
        let skills = try bodies.enumerated().map { index, body in
            let path = try writeSkill(root: root, relativePath: "copy-\(index)", body: body)
            return makeSkill(path: path.path, scope: "global", manager: "local")
        }
        var preparationCount = 0
        let groups = MetagentCore.detectSkillOverlaps(skills, canonicalize: { $0 }) { text in
            preparationCount += 1
            return ComparableSkillDocument(text: text)
        }
        let group = try XCTUnwrap(groups.first)

        XCTAssertEqual(preparationCount, 3)
        XCTAssertEqual(group.similarity, 1)
        XCTAssertEqual(group.kind, .sameName)
        XCTAssertEqual(Set(group.members.compactMap(\.contentFingerprint)).count, 3)
        XCTAssertFalse(group.members.contains(where: \.suggestedRemoval))
    }

    func testDocumentPreparationLifetimeIsOneOverlapGroup() throws {
        let root = try fixtureRoot("document-preparation-lifetime")
        let skills = try (0..<4).map { index in
            let path = try writeSkill(root: root, relativePath: "copy-\(index)", body: "Shared instructions.")
            var skill = makeSkill(path: path.path, scope: "global", manager: "local")
            skill.name = index < 2 ? "first" : "second"
            return skill
        }
        var preparationCount = 0
        let groups = MetagentCore.detectSkillOverlaps(skills, canonicalize: { $0 }) { text in
            preparationCount += 1
            return ComparableSkillDocument(text: text)
        }

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(preparationCount, 2)
        XCTAssertTrue(groups.allSatisfy { $0.kind == .exactDuplicate && $0.similarity == 1 })
    }

    func testDocumentPreparationBoundsRawKeysWithoutLosingPreviouslyCachedEntries() throws {
        let root = try fixtureRoot("document-preparation-budget")
        let texts = (0..<17).map { index in
            let prefix = "---\nname: demo\n---\nUnique document \(index).\n"
            return prefix + String(repeating: "x", count: 64 * 1024 - prefix.utf8.count)
        }
        var skills: [SkillInventoryItem] = []
        for (index, text) in texts.enumerated() {
            let path = root.appendingPathComponent(String(format: "%02d", index))
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try text.write(to: path.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            skills.append(makeSkill(path: path.path, scope: "global", manager: "local"))
        }
        for (name, text) in [("z-cached", texts[0]), ("z-uncached", texts[16])] {
            let path = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try text.write(to: path.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            skills.append(makeSkill(path: path.path, scope: "global", manager: "local"))
        }
        var preparationCount = 0
        let groups = MetagentCore.detectSkillOverlaps(skills, canonicalize: { $0 }) { _ in
            preparationCount += 1
            return ComparableSkillDocument(text: "")
        }

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.members.count, 19)
        // Sixteen 64-KiB keys fill the 1-MiB budget. The earlier key remains
        // reusable; the seventeenth text and its later copy both prepare.
        XCTAssertEqual(preparationCount, 18)
    }

    func testOversizedPreparationKeysFallBackWithoutChangingComparison() throws {
        let root = try fixtureRoot("document-preparation-large-key")
        let text = String(repeating: "x", count: 1024 * 1024 + 1)
        let skills = try ["first", "second"].map { name in
            let path = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try text.write(to: path.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            return makeSkill(path: path.path, scope: "global", manager: "local")
        }
        var preparationCount = 0
        let groups = MetagentCore.detectSkillOverlaps(skills, canonicalize: { $0 }) { _ in
            preparationCount += 1
            return ComparableSkillDocument(text: "same comparison")
        }

        XCTAssertEqual(preparationCount, 2)
        XCTAssertEqual(groups.first?.kind, .exactDuplicate)
        XCTAssertEqual(groups.first?.similarity, 1)
    }

    func testBundleFingerprintMatchesLegacyEncodingForNestedBinaryAndExecutableEvidence() throws {
        let root = try fixtureRoot("fingerprint-compatibility")
        let first = try writeSkill(root: root, relativePath: "global", body: "Read current evidence.")
        let second = try writeSkill(root: root, relativePath: "project", body: "Read current evidence.")
        let skills = [
            makeSkill(path: first.path, scope: "global", manager: "local"),
            makeSkill(path: second.path, scope: "project", manager: "local"),
        ]
        for directory in [first, second] {
            let nested = directory.appendingPathComponent("nested folder/évidence")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try Data((0...255).map(UInt8.init)).write(to: nested.appendingPathComponent("asset.bin"))
            try "#!/bin/sh\nexit 0\n".write(
                to: directory.appendingPathComponent("check.sh"), atomically: true, encoding: .utf8
            )
            try Data([0, 255, 13, 10]).write(to: directory.appendingPathComponent(".hidden"))
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o751], ofItemAtPath: directory.appendingPathComponent("check.sh").path
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: nested.path)
            try FileManager.default.linkItem(
                at: nested.appendingPathComponent("asset.bin"), to: directory.appendingPathComponent("hardlink.bin")
            )
        }
        func verify() throws -> SkillOverlapGroup {
            let group = try XCTUnwrap(matchingOverlaps(skills).first)
            for directory in [first, second] {
                let path = directory.resolvingSymlinksInPath().standardizedFileURL.path
                let member = try XCTUnwrap(group.members.first { $0.canonicalPath == path })
                XCTAssertEqual(member.contentFingerprint, legacyBundleFingerprint(at: directory))
                XCTAssertEqual(member.contentFingerprint?.count, 64)
            }
            return group
        }

        let initial = try verify()
        XCTAssertTrue(initial.members.contains(where: \.suggestedRemoval))
        // Read/write permissions are not encoded, but execute bits are.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: second.appendingPathComponent(".hidden").path
        )
        XCTAssertEqual(try verify(), initial)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o640], ofItemAtPath: second.appendingPathComponent("check.sh").path
        )
        let changed = try verify()
        XCTAssertFalse(changed.members.contains(where: \.suggestedRemoval))
        XCTAssertNotEqual(initial.members.last?.contentFingerprint, changed.members.last?.contentFingerprint)
    }

    func testBundleFingerprintRejectsFileDirectoryAndDanglingLinksLikeLegacy() throws {
        let root = try fixtureRoot("fingerprint-links")
        let first = try writeSkill(root: root, relativePath: "global", body: "Shared instructions.")
        let second = try writeSkill(root: root, relativePath: "project", body: "Shared instructions.")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let skills = [
            makeSkill(path: first.path, scope: "global", manager: "local"),
            makeSkill(path: second.path, scope: "project", manager: "local"),
        ]
        for target in ["SKILL.md", outside.path, "missing"] {
            let link = second.appendingPathComponent("linked")
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
            let group = try XCTUnwrap(matchingOverlaps(skills).first)
            let member = try XCTUnwrap(group.members.first { $0.scope == "project" })
            XCTAssertNil(legacyBundleFingerprint(at: second))
            XCTAssertNil(member.contentFingerprint)
            XCTAssertFalse(group.members.contains(where: \.suggestedRemoval))
            try FileManager.default.removeItem(at: link)
        }
    }

    func testBundleFingerprintRejectsFIFOWithoutReadingItLikeLegacy() throws {
        let root = try fixtureRoot("fingerprint-fifo")
        let first = try writeSkill(root: root, relativePath: "global", body: "Shared instructions.")
        let second = try writeSkill(root: root, relativePath: "project", body: "Shared instructions.")
        XCTAssertEqual(mkfifo(second.appendingPathComponent("pipe").path, 0o600), 0)
        let group = try XCTUnwrap(matchingOverlaps([
            makeSkill(path: first.path, scope: "global", manager: "local"),
            makeSkill(path: second.path, scope: "project", manager: "local"),
        ]).first)

        XCTAssertNil(legacyBundleFingerprint(at: second))
        XCTAssertNil(group.members.first { $0.scope == "project" }?.contentFingerprint)
        XCTAssertFalse(group.members.contains(where: \.suggestedRemoval))
    }

    func testMissingDocumentsAreNotExactAndAreRecheckedOnNextCall() throws {
        let root = try fixtureRoot("missing-document")
        let first = try writeSkill(root: root, relativePath: "one", body: "Shared instructions.")
        let missing = root.appendingPathComponent("two")
        let skills = [
            makeSkill(path: first.path, scope: "global", manager: "local"),
            makeSkill(path: missing.path, scope: "global", manager: "local"),
        ]
        let initial = try XCTUnwrap(matchingOverlaps(skills).first)
        XCTAssertEqual(initial.kind, .sameName)
        XCTAssertEqual(initial.similarity, 0)

        _ = try writeSkill(root: root, relativePath: "two", body: "Shared instructions.")
        XCTAssertEqual(matchingOverlaps(skills).first?.kind, .exactDuplicate)
        _ = try writeSkill(root: root, relativePath: "two", body: "Changed at the same path.")
        XCTAssertEqual(matchingOverlaps(skills).first?.kind, .sameName)
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
        let group = try XCTUnwrap(matchingOverlaps(skills).first)

        XCTAssertEqual(group.kind, .pluginReplacement)
        XCTAssertEqual(group.similarity, 1)
        XCTAssertEqual(Set(group.members.filter(\.suggestedRemoval).map(\.canonicalPath)), Set([
            root.appendingPathComponent("global-a").path,
            root.appendingPathComponent("global-b").path,
        ]))
        XCTAssertEqual(matchingOverlaps(skills.reversed()), [group])
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
        XCTAssertTrue(matchingOverlaps(skills).isEmpty)
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: second)
        let group = try XCTUnwrap(matchingOverlaps(skills).first)
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

    // Run count equality through the detailed fixtures too, including changed,
    // missing, oversized, linked, aliased, and retargeted bundles.
    private func matchingOverlaps(
        _ skills: [SkillInventoryItem],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> [SkillOverlapGroup] {
        let groups = MetagentCore.detectSkillOverlaps(skills)
        XCTAssertEqual(MetagentCore.countSkillOverlapGroups(skills), groups.count, file: file, line: line)
        return groups
    }

    private func fixtureRoot(_ name: String) throws -> URL {
        try makeTemporaryRoot(prefix: "metagent-overlap-\(name)")
    }

    // Frozen pre-optimization format: saved attention dismissals and removal
    // recommendations must retain byte-for-byte fingerprints, not merely agree
    // with another call through the new metadata path.
    private func legacyBundleFingerprint(at root: URL) -> String? {
        var hash = SHA256()
        var remainingBytes = 16 * 1024 * 1024
        var remainingEntries = 2048
        func append(_ data: Data) {
            var length = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &length) { hash.update(data: Data($0)) }
            hash.update(data: data)
        }
        func collect(_ directory: URL, prefix: String, depth: Int = 0) throws {
            guard depth <= 32 else { throw CocoaError(.fileReadTooLarge) }
            let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for child in children {
                remainingEntries -= 1
                guard remainingEntries >= 0 else { throw CocoaError(.fileReadTooLarge) }
                let relative = prefix + child.lastPathComponent
                let attributes = try FileManager.default.attributesOfItem(atPath: child.path)
                let type = attributes[.type] as? FileAttributeType
                guard type == .typeDirectory || type == .typeRegular else {
                    throw CocoaError(.fileReadUnsupportedScheme)
                }
                append(Data(relative.utf8))
                append(Data((type == .typeDirectory ? "directory" : "file").utf8))
                let executable = ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o111
                append(Data(String(executable).utf8))
                if type == .typeDirectory {
                    try collect(child, prefix: relative + "/", depth: depth + 1)
                } else {
                    let size = (attributes[.size] as? NSNumber)?.intValue ?? Int.max
                    guard size <= remainingBytes else { throw CocoaError(.fileReadTooLarge) }
                    remainingBytes -= size
                    append(try Data(contentsOf: child))
                }
            }
        }
        do {
            try collect(root, prefix: "")
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        } catch { return nil }
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
