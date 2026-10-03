import Foundation
import XCTest
@testable import MetagentCore

final class SkillInventoryStatsTests: XCTestCase {
    func testASCIICountsMatchSwiftForEveryByteAndCRLFBoundary() {
        let bytes = (0..<128).map { String(UnicodeScalar($0)!) }
        let lineEndings = ["", "\r", "\n", "\r\n", "\r\r\n", "\n\r\n", "\r\n\r"]
        let inputs = bytes + bytes.map { "left\($0)right" }
            + lineEndings.flatMap { first in lineEndings.map { "a\(first)b\($0)c" } }
            + [String(repeating: "ASCII words\r\n", count: 1_000) + "e\u{301} 👩🏽‍💻"]
        for text in inputs {
            let counts = skillTextCounts(text)
            XCTAssertEqual(counts.characters, text.count)
            XCTAssertEqual(counts.words, text.split(whereSeparator: \.isWhitespace).count)
        }
    }

    func testTextCountsPreserveWhitespaceAndUnicodeGraphemeSemantics() {
        let inputs = [
            "", "   \t\n\r\n", "single", " first\tsecond\nthird ",
            "café 東京 👩🏽‍💻 e\u{301} 🇺🇸", "one\u{00a0}two\u{2003}three",
            "white\u{2003}\u{301}space", "a\r\nb\u{2028}c\u{2029}d",
            "zero\u{0}width\u{200b}joiner\u{2060}text",
            String(repeating: "ASCII words with tabs\tand lines\n", count: 1_000),
            String(repeating: "Unicode café 東京 👩🏽‍💻 e\u{301}\r\n", count: 1_000),
        ]
        for text in inputs {
            let counts = skillTextCounts(text)
            XCTAssertEqual(counts.characters, text.count)
            XCTAssertEqual(counts.words, text.split(whereSeparator: \.isWhitespace).count)
        }
    }

    func testOneBundleReadPreservesEveryRepresentationAndContainmentResult() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-shared-stats")
        let bundle = try makeBundle(in: root)
        let nestedAlias = root.appendingPathComponent(".codex/skills/nested/renamed")
        try FileManager.default.createDirectory(at: nestedAlias.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: nestedAlias, withDestinationURL: bundle)
        let outside = root.appendingPathComponent("outside.sh")
        try "private sentinel".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: bundle.appendingPathComponent("scripts/outside.sh"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: bundle.appendingPathComponent("scripts/broken.sh"), withDestinationURL: root.appendingPathComponent("absent"))
        try "#!/bin/sh\nexit 0\n".write(to: bundle.appendingPathComponent("assets/inside.sh"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: bundle.appendingPathComponent("scripts/inside.sh"), withDestinationURL: bundle.appendingPathComponent("assets/inside.sh"))
        var reads: [String] = []
        let project = try readProjectSkills(root: root, readStats: {
            reads.append(canonicalProjectPath($0))
            return skillStats($0)
        })
        XCTAssertEqual(project.skills.count, 4)
        XCTAssertEqual(reads, [canonicalProjectPath(bundle)])
        let canonical = try XCTUnwrap(project.skills.first { $0.location == "agents" })
        for item in project.skills {
            // Resolve the bundle for content; each representation still keeps
            // its own name, ownership, paths, and icon references.
            let independent = makeSkillItem(
                name: item.name, path: URL(fileURLWithPath: item.path), location: item.location,
                originKind: item.originKind, scope: item.scope, manager: item.manager,
                authority: item.authority, mutability: item.mutability,
                representation: item.representation, canonicalPath: item.canonicalPath,
                origin: nil,
                evidence: item.location == "agents"
                    ? canonicalSkillOwnership(scope: item.scope, skillLock: nil, dotagents: nil) : nil,
                symlinkedContainer: item.symlinkedContainer,
                inherited: item.representation == "projection" ? canonical : nil
            )
            XCTAssertEqual(item, independent)
            XCTAssertEqual(item.iconSmallPath, URL(fileURLWithPath: item.path).appendingPathComponent("../shared/icon.svg").standardizedFileURL.path)
            let scripts = try XCTUnwrap(item.scriptInventory).scripts
            XCTAssertEqual(scripts.first { $0.relativePath == "scripts/outside.sh" }?.containment, .escapesBundle)
            XCTAssertNil(scripts.first { $0.relativePath == "scripts/outside.sh" }?.sha256)
            XCTAssertEqual(scripts.first { $0.relativePath == "scripts/broken.sh" }?.containment, .brokenSymlink)
            XCTAssertEqual(scripts.first { $0.relativePath == "scripts/inside.sh" }?.containment, .bundledSymlink)
        }
        XCTAssertEqual(project.skills.first { $0.path == nestedAlias.path }?.name, "renamed")
        XCTAssertEqual(canonical.mutability, "editable")
        XCTAssertTrue(project.skills.filter { $0.location != "agents" }.allSatisfy { $0.mutability == "managed-read-only" })
    }

    func testProjectionOnlyInventoryReadsTheResolvedBundle() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-projection-only-stats")
        let outside = try writeSkillFixture(
            at: root.appendingPathComponent("external/demo"), description: "shared external bundle",
            body: "Read scripts/demo.py."
        )
        try FileManager.default.createDirectory(at: outside.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try "#!/usr/bin/env python3\nprint('fixture')\n".write(to: outside.appendingPathComponent("scripts/demo.py"), atomically: true, encoding: .utf8)
        for location in ["codex", "claude"] {
            let projection = root.appendingPathComponent(".\(location)/skills/demo")
            try FileManager.default.createDirectory(at: projection.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: projection, withDestinationURL: outside)
        }
        var reads: [String] = []
        let project = try readProjectSkills(root: root, readStats: {
            reads.append($0.path)
            return skillStats($0)
        })
        XCTAssertEqual(reads, [canonicalProjectPath(outside)])
        XCTAssertEqual(project.skills.count, 2)
        for item in project.skills {
            XCTAssertEqual(item.description, "shared external bundle")
            XCTAssertGreaterThan(item.characterCount, 0)
            XCTAssertEqual(item.scriptInventory?.scripts.first?.referencedBy, ["SKILL.md"])
        }
    }

    func testLaterScansRereadSameSizeEditsEvenWithUnchangedModificationDates() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-fresh-stats")
        let bundle = try makeBundle(in: root)
        let document = bundle.appendingPathComponent("SKILL.md")
        let script = bundle.appendingPathComponent("scripts/demo.py")
        let metadata = bundle.appendingPathComponent("agents/openai.yaml")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        for path in [document, script, metadata] {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path.path)
        }
        let first = try readProjectSkills(root: root)
        let before = try XCTUnwrap(first.skills.first)
        let firstHash = before.scriptInventory?.scripts.first?.sha256
        let replacements = [
            (document, "first", "newer"),
            (script, "one", "two"),
            (metadata, "shared", "second"),
        ]
        for (path, old, new) in replacements {
            let original = try String(contentsOf: path, encoding: .utf8)
            let replacement = original.replacingOccurrences(of: old, with: new)
            XCTAssertEqual(original.utf8.count, replacement.utf8.count)
            try replacement.write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path.path)
        }
        let second = try readProjectSkills(root: root)
        XCTAssertEqual(second.skills.count, 3)
        for item in second.skills {
            XCTAssertEqual(item.description, "newer")
            XCTAssertEqual(item.characterCount, before.characterCount)
            XCTAssertEqual(item.updatedAt, before.updatedAt)
            XCTAssertNotEqual(item.scriptInventory?.scripts.first?.sha256, firstHash)
            XCTAssertEqual(item.iconSmallPath, URL(fileURLWithPath: item.path).appendingPathComponent("../second/icon.svg").standardizedFileURL.path)
        }
    }

    func testSameNamedIndependentBundlesAndRetargetedProjectionRemainDistinct() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-distinct-stats")
        let agents = try writeSkillFixture(at: root.appendingPathComponent(".agents/skills/demo"), description: "canonical first")
        let codex = try writeSkillFixture(at: root.appendingPathComponent(".codex/skills/demo"), description: "independent second")
        let claude = root.appendingPathComponent(".claude/skills/demo")
        try FileManager.default.createDirectory(at: claude.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: claude, withDestinationURL: agents)
        var reads: [String] = []
        let first = try readProjectSkills(root: root, readStats: {
            reads.append(canonicalProjectPath($0))
            return skillStats($0)
        })
        XCTAssertEqual(Set(reads), [canonicalProjectPath(agents), canonicalProjectPath(codex)])
        XCTAssertEqual(reads.count, 2)
        XCTAssertEqual(first.skills.first { $0.location == "claude" }?.description, "canonical first")
        XCTAssertEqual(first.skills.first { $0.location == "codex" }?.description, "independent second")
        try FileManager.default.removeItem(at: claude)
        try FileManager.default.createSymbolicLink(at: claude, withDestinationURL: codex)
        let second = try readProjectSkills(root: root)
        let projection = try XCTUnwrap(second.skills.first { $0.location == "claude" })
        XCTAssertEqual(projection.canonicalPath, canonicalProjectPath(codex))
        XCTAssertEqual(projection.description, "independent second")
    }

    private func makeBundle(in root: URL) throws -> URL {
        let bundle = try writeSkillFixture(
            at: root.appendingPathComponent(".agents/skills/demo"), description: "first",
            body: "Unicode café 東京. Run scripts/demo.py and scripts/inside.sh."
        )
        for directory in ["scripts", "references", "agents", "assets"] {
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        try "#!/usr/bin/env python3\nprint('one')\n".write(to: bundle.appendingPathComponent("scripts/demo.py"), atomically: true, encoding: .utf8)
        try "More Unicode 👩🏽‍💻 reference words.\n".write(to: bundle.appendingPathComponent("references/guide.md"), atomically: true, encoding: .utf8)
        try "interface:\n  icon_small: ../shared/icon.svg\n  icon_large: ./assets/logo.svg\n".write(to: bundle.appendingPathComponent("agents/openai.yaml"), atomically: true, encoding: .utf8)
        for location in ["codex", "claude"] {
            let directory = root.appendingPathComponent(".\(location)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if location == "claude" {
                try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("skills"), withDestinationURL: root.appendingPathComponent(".agents/skills"))
            } else {
                try FileManager.default.createDirectory(at: directory.appendingPathComponent("skills"), withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("skills/demo"), withDestinationURL: bundle)
            }
        }
        return bundle
    }
}
