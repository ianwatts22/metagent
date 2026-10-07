import Foundation
import XCTest
@testable import MetagentCore

final class ProjectSkillSyncTests: XCTestCase {
    func testPreviewIsReadOnlyAndSelectedFullBundleCopiesWithPortableOwnership() throws {
        let fixture = try ProjectSyncFixture()
        defer { fixture.remove() }
        let selected = try fixture.skill("chosen")
        _ = try fixture.skill("unselected")
        try fixture.write("references/context.md", in: selected, data: Data("Shared context.\n".utf8))
        let script = try fixture.write("scripts/run.sh", in: selected, data: Data("#!/bin/sh\nprintf 'fixture'\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let icon = Data([0, 1, 2, 255])
        try fixture.write("assets/icon.bin", in: selected, data: icon)
        try fixture.write("node_modules/never-copy.txt", in: selected, data: Data("Generated.".utf8))

        let plan = try fixture.preview(["chosen", "chosen"])
        XCTAssertEqual(plan.items.count, 1)
        XCTAssertEqual(plan.items.first?.action, .copy)
        XCTAssertTrue(plan.canApply)
        XCTAssertEqual(plan.items.first?.files.map(\.relativePath), ["SKILL.md", "assets/icon.bin", "references/context.md", "scripts/run.sh"])
        XCTAssertTrue(plan.items.first?.findings.contains { $0.id.hasPrefix("excluded:") } == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.project.appendingPathComponent(".agents").path))

        let report = try MetagentCore.applyProjectSkillSync(plan)
        XCTAssertEqual(report.copiedNames, ["chosen"])
        XCTAssertEqual(try Data(contentsOf: fixture.destination("chosen/assets/icon.bin")), icon)
        XCTAssertEqual(try Data(contentsOf: fixture.destination("chosen/scripts/run.sh")), try Data(contentsOf: script))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: fixture.destination("chosen/scripts/run.sh").path)[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination("unselected").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination("chosen/node_modules").path))
        let manifest = try String(contentsOf: fixture.manifest, encoding: .utf8)
        XCTAssertFalse(manifest.contains(fixture.root.path))
        XCTAssertFalse(manifest.contains("sourcePath"))
        XCTAssertFalse(manifest.contains("/Users/"))
        XCTAssertTrue(manifest.contains("contentHash"))
        XCTAssertTrue(manifest.contains("agents"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: selected.appendingPathComponent("SKILL.md").path))
    }

    func testRefreshIsNoOpAndUpdatesOnlySelectedUnmodifiedCopies() throws {
        let fixture = try ProjectSyncFixture()
        defer { fixture.remove() }
        let first = try fixture.skill("first")
        _ = try fixture.skill("second")
        try fixture.write("old.md", in: first, data: Data("Old reference".utf8))
        _ = try MetagentCore.applyProjectSkillSync(fixture.preview(["first", "second"]))
        let secondBefore = try Data(contentsOf: fixture.destination("second/SKILL.md"))
        let manifestBefore = try Data(contentsOf: fixture.manifest)
        let noOp = try fixture.preview(["first", "second"])
        XCTAssertEqual(noOp.items.map(\.action), [.unchanged, .unchanged])
        _ = try MetagentCore.applyProjectSkillSync(noOp)
        XCTAssertEqual(try Data(contentsOf: fixture.manifest), manifestBefore)

        try FileManager.default.removeItem(at: first.appendingPathComponent("old.md"))
        try fixture.write("references/new.md", in: first, data: Data("New reference".utf8))
        let update = try fixture.preview(["first"])
        XCTAssertEqual(update.items.first?.action, .update)
        XCTAssertEqual(update.items.first?.removedFiles, ["old.md"])
        let report = try MetagentCore.applyProjectSkillSync(update)
        XCTAssertEqual(report.updatedNames, ["first"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination("first/old.md").path))
        XCTAssertEqual(try Data(contentsOf: fixture.destination("second/SKILL.md")), secondBefore)
        XCTAssertTrue(try String(contentsOf: fixture.manifest, encoding: .utf8).contains("second"))
    }

    func testUnknownExistingAndEditedProjectSkillsStayUntouched() throws {
        let fixture = try ProjectSyncFixture()
        defer { fixture.remove() }
        _ = try fixture.skill("owned")
        _ = try fixture.skill("existing")
        try writeSkillFixture(at: fixture.destination("existing"), name: "existing", body: "Project sentinel.")
        let existingBefore = try Data(contentsOf: fixture.destination("existing/SKILL.md"))
        XCTAssertEqual(try fixture.preview(["existing"]).items.first?.action, .blocked)
        _ = try MetagentCore.applyProjectSkillSync(fixture.preview(["owned"]))
        try fixture.write(".cache/project-notes.md", in: fixture.destination("owned"), data: Data("Preserve even generated project additions.".utf8))
        let edited = try fixture.preview(["owned"])
        XCTAssertFalse(edited.canApply)
        XCTAssertThrowsError(try MetagentCore.applyProjectSkillSync(edited))
        XCTAssertEqual(try Data(contentsOf: fixture.destination("existing/SKILL.md")), existingBefore)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.destination("owned/.cache/project-notes.md").path))
    }

    func testSourceDestinationAndOwnershipChangesInvalidatePreview() throws {
        for change in ["source", "destination", "manifest"] {
            let fixture = try ProjectSyncFixture()
            defer { fixture.remove() }
            let source = try fixture.skill("demo")
            _ = try MetagentCore.applyProjectSkillSync(fixture.preview(["demo"]))
            try fixture.write("reference.md", in: source, data: Data("Source update.".utf8))
            let plan = try fixture.preview(["demo"])
            switch change {
            case "source": try fixture.write("reference.md", in: source, data: Data("Changed after preview.".utf8))
            case "destination": try fixture.write("local.md", in: fixture.destination("demo"), data: Data("Local edit after preview.".utf8))
            default: try Data("{\"version\":99,\"skills\":{}}".utf8).write(to: fixture.manifest)
            }
            let destinationBefore = try Data(contentsOf: fixture.destination("demo/SKILL.md"))
            XCTAssertThrowsError(try MetagentCore.applyProjectSkillSync(plan), change)
            XCTAssertEqual(try Data(contentsOf: fixture.destination("demo/SKILL.md")), destinationBefore)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination("demo/reference.md").path))
        }
    }

    func testMissingOwnedCopyRequiresManualReviewNotAutomaticRestore() throws {
        let fixture = try ProjectSyncFixture()
        defer { fixture.remove() }
        _ = try fixture.skill("demo")
        _ = try MetagentCore.applyProjectSkillSync(fixture.preview(["demo"]))
        try FileManager.default.removeItem(at: fixture.destination("demo"))
        XCTAssertEqual(try fixture.preview(["demo"]).items.first?.action, .blocked)
    }

    func testGitPortablePermissionIdentityAndFinderMetadataDoNotBlockRefresh() throws {
        let fixture = try ProjectSyncFixture()
        defer { fixture.remove() }
        _ = try fixture.skill("demo")
        _ = try MetagentCore.applyProjectSkillSync(fixture.preview(["demo"]))
        let file = fixture.destination("demo/SKILL.md")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try fixture.write(".DS_Store", in: fixture.destination("demo"), data: Data("Finder metadata fixture".utf8))
        let manifestBefore = try Data(contentsOf: fixture.manifest)
        let unchanged = try fixture.preview(["demo"])
        XCTAssertEqual(unchanged.items.first?.action, .unchanged)
        _ = try MetagentCore.applyProjectSkillSync(unchanged)
        XCTAssertEqual(try Data(contentsOf: fixture.manifest), manifestBefore)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.destination("demo/.DS_Store").path))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        XCTAssertFalse(try fixture.preview(["demo"]).canApply, "Executable-status changes remain meaningful project edits.")
    }

    func testProjectLockFailsBusyAndSerializedRetriesPreserveDistinctOwnership() throws {
        let fixture = try ProjectSyncFixture()
        defer { fixture.remove() }
        _ = try fixture.skill("alpha")
        _ = try fixture.skill("beta")
        let alpha = try fixture.preview(["alpha"])
        let staleBeta = try fixture.preview(["beta"])
        try withProjectSkillSyncLock(projectRoot: fixture.project.path) {
            for plan in [alpha, staleBeta] {
                XCTAssertThrowsError(try MetagentCore.applyProjectSkillSync(plan)) { error in
                    XCTAssertTrue(error.localizedDescription.contains("Another Metagent sync"))
                }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.project.appendingPathComponent(".agents").path))
        }
        _ = try MetagentCore.applyProjectSkillSync(alpha)
        XCTAssertThrowsError(try MetagentCore.applyProjectSkillSync(staleBeta))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination("beta").path))
        _ = try MetagentCore.applyProjectSkillSync(fixture.preview(["beta"]))
        XCTAssertEqual(try fixture.preview(["alpha", "beta"]).items.map(\.action), [.unchanged, .unchanged])
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.manifest)) as? [String: Any])
        let skills = try XCTUnwrap(manifest["skills"] as? [String: Any])
        XCTAssertEqual(Set(skills.keys), ["alpha", "beta"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.project.appendingPathComponent(".agents").path).sorted(), ["project-skills.json", "skills"])
    }

    func testManifestCapacityIsRejectedBeforeCopyingAndOversizeReadsStayBounded() throws {
        let fixture = try ProjectSyncFixture()
        defer { fixture.remove() }
        _ = try fixture.skill("new-skill")
        try FileManager.default.createDirectory(at: fixture.manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let entries = Dictionary(uniqueKeysWithValues: (0..<4_096).map { index in
            ("existing-\(index)", ["collection": "agents", "contentHash": String(repeating: "0", count: 64)])
        })
        let bytes = try JSONSerialization.data(withJSONObject: ["version": 1, "skills": entries])
        try bytes.write(to: fixture.manifest)
        XCTAssertThrowsError(try fixture.preview(["new-skill"])) { error in
            XCTAssertTrue(error.localizedDescription.contains("ownership record limit"))
        }
        XCTAssertEqual(try Data(contentsOf: fixture.manifest), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination("").path))
        let oversized = bytes + Data(repeating: 0x20, count: 1_024 * 1_024)
        try oversized.write(to: fixture.manifest)
        XCTAssertThrowsError(try fixture.preview(["new-skill"]))
        XCTAssertEqual(try Data(contentsOf: fixture.manifest), oversized)
    }

    func testUnknownOwnershipFieldsAndFutureManagerLockVersionsRemainUntouched() throws {
        let fixture = try ProjectSyncFixture()
        defer { fixture.remove() }
        _ = try fixture.skill("demo")
        _ = try MetagentCore.applyProjectSkillSync(fixture.preview(["demo"]))
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.manifest)) as? [String: Any])
        manifest["projectNotes"] = "User-owned extension; never discard it."
        let changed = try JSONSerialization.data(withJSONObject: manifest)
        try changed.write(to: fixture.manifest)
        XCTAssertThrowsError(try fixture.preview(["demo"]))
        XCTAssertEqual(try Data(contentsOf: fixture.manifest), changed)
        try FileManager.default.removeItem(at: fixture.manifest)
        let lock = fixture.project.appendingPathComponent("skills-lock.json")
        let futureLock = Data("{\"version\":99,\"skills\":{}}".utf8)
        try futureLock.write(to: lock)
        XCTAssertThrowsError(try fixture.preview(["demo"]))
        XCTAssertEqual(try Data(contentsOf: lock), futureLock)
    }

    func testLinkedAndDanglingDestinationPathsNeverWriteOutsideProject() throws {
        for path in [".agents", ".agents/skills", ".agents/skills/demo", ".agents/project-skills.json"] {
            let fixture = try ProjectSyncFixture()
            defer { fixture.remove() }
            _ = try fixture.skill("demo")
            let outside = fixture.root.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let link = fixture.project.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            do {
                let plan = try fixture.preview(["demo"])
                XCTAssertFalse(plan.canApply, path)
                XCTAssertThrowsError(try MetagentCore.applyProjectSkillSync(plan))
            } catch { /* root/manifest failures are also closed previews */ }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        }
        let fixture = try ProjectSyncFixture()
        defer { fixture.remove() }
        _ = try fixture.skill("demo")
        try FileManager.default.createDirectory(at: fixture.destination("") , withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.destination("demo"), withDestinationURL: fixture.root.appendingPathComponent("absent"))
        XCTAssertFalse(try fixture.preview(["demo"]).canApply)
    }

    func testLinkedBundleFilesAndSpecialFilesAreRejectedWithoutReadingThem() throws {
        let fixture = try ProjectSyncFixture()
        defer { fixture.remove() }
        let source = try fixture.skill("demo")
        let outside = fixture.root.appendingPathComponent("outside.txt")
        try Data("External sentinel.".utf8).write(to: outside)
        let link = source.appendingPathComponent("reference.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertFalse(try fixture.preview(["demo"]).canApply)
        try FileManager.default.removeItem(at: link)
        let fifo = source.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertFalse(try fixture.preview(["demo"]).canApply)
        XCTAssertEqual(try Data(contentsOf: outside), Data("External sentinel.".utf8))
    }

    func testCredentialFilesBlockWhileOutsideDependenciesAreVisibleWarnings() throws {
        let fixture = try ProjectSyncFixture()
        defer { fixture.remove() }
        let source = try fixture.skill("demo", body: "Read ~/.agents/skills/shared/SKILL.md and /Users/example/project/context.md first.")
        let warning = try fixture.preview(["demo"])
        XCTAssertTrue(warning.canApply)
        XCTAssertTrue(warning.items[0].findings.contains { $0.id.hasPrefix("outside-skill-reference:") && $0.severity == .warning })
        XCTAssertTrue(warning.items[0].findings.contains { $0.id.hasPrefix("personal-path:") && $0.severity == .warning })
        try fixture.write(".env", in: source, data: Data("FIXTURE_ONLY=yes".utf8))
        XCTAssertFalse(try fixture.preview(["demo"]).canApply)
        try FileManager.default.removeItem(at: source.appendingPathComponent(".env"))
        // Synthetic recognizer sample, deliberately not an actual credential.
        let syntheticKey = "sk-" + String(repeating: "x", count: 24)
        try fixture.write("config.md", in: source, data: Data(syntheticKey.utf8))
        let blocked = try fixture.preview(["demo"])
        XCTAssertFalse(blocked.canApply)
        XCTAssertFalse(try String(data: JSONEncoder().encode(blocked), encoding: .utf8)!.contains(syntheticKey))
    }

    func testMissingReferencedScriptsAreExplicitWarningsNotHiddenDependencies() throws {
        let fixture = try ProjectSyncFixture()
        defer { fixture.remove() }
        _ = try fixture.skill("demo", body: "Run scripts/missing.sh after reading ~/.agents/skills/shared/SKILL.md.")
        let plan = try fixture.preview(["demo"])
        XCTAssertTrue(plan.canApply)
        XCTAssertTrue(plan.items[0].findings.contains { $0.id.hasPrefix("missing-script:") && $0.message.contains("scripts/missing.sh") })
    }

    func testManagerOwnershipAndUnreadableLocksFailClosed() throws {
        for name in ["skills-lock.json", "agents.toml", "agents.lock", ".agents/.skill-lock.json"] {
            let fixture = try ProjectSyncFixture()
            defer { fixture.remove() }
            _ = try fixture.skill("demo")
            let path = fixture.project.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let content = name == "skills-lock.json" ? "{\"version\":1,\"skills\":{\"demo\":{\"source\":\"fixture/repo\",\"sourceType\":\"github\",\"computedHash\":\"fixture\"}}}" : "external-manager-sentinel"
            try Data(content.utf8).write(to: path)
            do {
                let plan = try fixture.preview(["demo"])
                XCTAssertFalse(plan.canApply, name)
            } catch { /* malformed ownership fails closed */ }
            XCTAssertEqual(try Data(contentsOf: path), Data(content.utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination("demo").path))
        }
    }

    func testPickerReadsOnlyDirectCanonicalBundlesAndCollectionIdentityCannotSwitch() throws {
        let fixture = try ProjectSyncFixture()
        defer { fixture.remove() }
        let source = try fixture.skill("demo")
        try FileManager.default.createSymbolicLink(at: fixture.global.appendingPathComponent("projected"), withDestinationURL: source)
        try writeSkillFixture(at: fixture.global.appendingPathComponent(".system/builtin"), name: "builtin")
        XCTAssertEqual(try MetagentCore.projectSyncSkillNames(in: fixture.global), ["demo"])
        _ = try MetagentCore.applyProjectSkillSync(fixture.preview(["demo"]))
        let otherCollection = try MetagentCore.previewProjectSkillSync(projectRoot: fixture.project.path, skillNames: ["demo"], globalSkillsRoot: fixture.global.path, collection: .codex)
        XCTAssertFalse(otherCollection.canApply)
    }

    func testReplacedPinnedRootCannotRedirectApply() throws {
        for target in ["project", "global"] {
            let fixture = try ProjectSyncFixture()
            defer { fixture.remove() }
            _ = try fixture.skill("demo")
            let plan = try fixture.preview(["demo"])
            let original = target == "project" ? fixture.project : fixture.global
            try FileManager.default.moveItem(at: original, to: fixture.root.appendingPathComponent("retained-\(target)"))
            let outside = fixture.root.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: original, withDestinationURL: outside)
            XCTAssertThrowsError(try MetagentCore.applyProjectSkillSync(plan))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        }
    }

    func testPhysicalDirectoryReplacementInvalidatesOtherwiseIdenticalPreview() throws {
        for target in ["project", "global"] {
            let fixture = try ProjectSyncFixture()
            defer { fixture.remove() }
            _ = try fixture.skill("demo")
            let plan = try fixture.preview(["demo"])
            let original = target == "project" ? fixture.project : fixture.global
            let retained = fixture.root.appendingPathComponent("retained-\(target)")
            try FileManager.default.moveItem(at: original, to: retained)
            try FileManager.default.copyItem(at: retained, to: original)
            let replacement = try fixture.preview(["demo"])
            XCTAssertEqual(replacement.items, plan.items, "Content checks alone must not grant permission to a replacement directory.")
            XCTAssertNotEqual(replacement, plan)
            XCTAssertThrowsError(try MetagentCore.applyProjectSkillSync(plan))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.project.appendingPathComponent(".agents").path))
            if target == "project" {
                XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: retained.path).isEmpty)
            }
            _ = try MetagentCore.applyProjectSkillSync(replacement)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.destination("demo/SKILL.md").path))
        }
    }

    func testMidCopyDirectorySwapLeavesReplacementUntouchedAndRollsBackOriginal() throws {
        for (target, owned) in [("project", false), ("project", true), ("agents", true), ("skills", true)] {
            let fixture = try ProjectSyncFixture()
            defer { fixture.remove() }
            let source = try fixture.skill("demo")
            if owned { _ = try MetagentCore.applyProjectSkillSync(fixture.preview(["demo"])) }
            let originalBytes = owned ? try Data(contentsOf: fixture.destination("demo/SKILL.md")) : nil
            let originalManifest = owned ? try Data(contentsOf: fixture.manifest) : nil
            try fixture.write("updated.md", in: source, data: Data("Synthetic source update.".utf8))
            let plan = try fixture.preview(["demo"])
            let original = target == "project" ? fixture.project
                : fixture.project.appendingPathComponent(target == "agents" ? ".agents" : ".agents/skills")
            let snapshot = fixture.root.appendingPathComponent("pre-apply-snapshot")
            let retained = fixture.root.appendingPathComponent("retained-\(target)")
            try FileManager.default.copyItem(at: original, to: snapshot)
            XCTAssertThrowsError(try applyProjectSkillSyncTransaction(plan, beforeManifestCommit: {
                try FileManager.default.moveItem(at: original, to: retained)
                try FileManager.default.moveItem(at: snapshot, to: original)
            }))
            if owned {
                XCTAssertEqual(try Data(contentsOf: fixture.destination("demo/SKILL.md")), originalBytes)
                XCTAssertEqual(try Data(contentsOf: fixture.manifest), originalManifest)
                let retainedSkill = retained.appendingPathComponent(
                    target == "project" ? ".agents/skills/demo" : target == "agents" ? "skills/demo" : "demo")
                XCTAssertEqual(try Data(contentsOf: retainedSkill.appendingPathComponent("SKILL.md")), originalBytes)
                XCTAssertFalse(FileManager.default.fileExists(atPath: retainedSkill.appendingPathComponent("updated.md").path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination("demo/updated.md").path))
            } else {
                XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.project.path).isEmpty)
                XCTAssertFalse(FileManager.default.fileExists(atPath: retained.appendingPathComponent(".agents/skills/demo").path))
            }
        }
    }

    func testRootSwapWithConcurrentEditKeepsRecoveryInTheRetainedOriginal() throws {
        let fixture = try ProjectSyncFixture()
        defer { fixture.remove() }
        let source = try fixture.skill("demo")
        _ = try MetagentCore.applyProjectSkillSync(fixture.preview(["demo"]))
        let manifestBefore = try Data(contentsOf: fixture.manifest)
        let originalBytes = try Data(contentsOf: fixture.destination("demo/SKILL.md"))
        let snapshot = fixture.root.appendingPathComponent("snapshot")
        let retained = fixture.root.appendingPathComponent("retained-project")
        try FileManager.default.copyItem(at: fixture.project, to: snapshot)
        try fixture.write("updated.md", in: source, data: Data("Synthetic source update.".utf8))
        let plan = try fixture.preview(["demo"])
        XCTAssertThrowsError(try applyProjectSkillSyncTransaction(plan, beforeManifestCommit: {
            try FileManager.default.moveItem(at: fixture.project, to: retained)
            try FileManager.default.moveItem(at: snapshot, to: fixture.project)
            try fixture.write("concurrent.md", in: retained.appendingPathComponent(".agents/skills/demo"),
                              data: Data("Preserve concurrent edits.".utf8))
        })) { error in
            XCTAssertTrue(error.localizedDescription.contains("recovery bundles remain"))
            XCTAssertTrue(error.localizedDescription.contains(retained.path))
        }
        XCTAssertEqual(try Data(contentsOf: fixture.manifest), manifestBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination("demo/updated.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.appendingPathComponent(".agents/skills/demo/concurrent.md").path))
        let agents = retained.appendingPathComponent(".agents")
        let recovery = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: agents.path)
            .first { $0.hasPrefix(".metagent-project-skills-") })
        XCTAssertEqual(try Data(contentsOf: agents.appendingPathComponent("\(recovery)/backup/demo/SKILL.md")), originalBytes)
    }

    func testPostCommitDirectorySwapReportsRetainedSkillsAndManifestLocations() throws {
        for target in ["project", "agents", "skills"] {
            let fixture = try ProjectSyncFixture()
            defer { fixture.remove() }
            let source = try fixture.skill("demo")
            _ = try MetagentCore.applyProjectSkillSync(fixture.preview(["demo"]))
            try fixture.write("updated.md", in: source, data: Data("Synthetic source update.".utf8))
            let plan = try fixture.preview(["demo"])
            let original = target == "project" ? fixture.project
                : fixture.project.appendingPathComponent(target == "agents" ? ".agents" : ".agents/skills")
            let retained = fixture.root.appendingPathComponent("retained-\(target)")
            let retainedSkills = retained.appendingPathComponent(
                target == "project" ? ".agents/skills" : target == "agents" ? "skills" : "")
            let retainedAgents = target == "project" ? retained.appendingPathComponent(".agents")
                : target == "agents" ? retained : fixture.project.appendingPathComponent(".agents")
            var copyError: Error?
            XCTAssertThrowsError(try applyProjectSkillSyncTransaction(plan, afterManifestCommit: {
                try FileManager.default.moveItem(at: original, to: retained)
                try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
            })) { error in
                copyError = error
            }
            let detail = try XCTUnwrap(copyError).localizedDescription
            // F_GETPATH reports the actual filesystem spelling, which can
            // differ from a Foundation URL's temporary-directory alias.
            let skillsPath = try XCTUnwrap(try ProjectSkillSyncDirectory(retainedSkills).currentPath())
            let agentsPath = try XCTUnwrap(try ProjectSkillSyncDirectory(retainedAgents).currentPath())
            XCTAssertTrue(detail.contains("The copy committed"))
            XCTAssertTrue(detail.contains("Copied skills: \(skillsPath)"), detail)
            XCTAssertTrue(detail.contains("Ownership manifest directory: \(agentsPath)"), detail)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: original.path).isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: retainedSkills.appendingPathComponent("demo/updated.md").path))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: retainedAgents.path)
                .contains { $0.hasPrefix(".metagent-project-skills-") })
        }
    }

    func testOpenOriginalFileEditsBeforeCommitAreRestoredAndAfterCommitAreRetained() throws {
        for afterCommit in [false, true] {
            let fixture = try ProjectSyncFixture()
            defer { fixture.remove() }
            let source = try fixture.skill("demo")
            _ = try MetagentCore.applyProjectSkillSync(fixture.preview(["demo"]))
            let originalFile = fixture.destination("demo/SKILL.md")
            let originalBytes = try Data(contentsOf: originalFile)
            let oldManifest = try Data(contentsOf: fixture.manifest)
            let editor = try FileHandle(forWritingTo: originalFile)
            defer { try? editor.close() }
            try fixture.write("updated.md", in: source, data: Data("Synthetic source update.".utf8))
            let plan = try fixture.preview(["demo"])
            let edit = Data("\nConcurrent editor content must survive.\n".utf8)
            let writeThroughRetainedHandle = {
                _ = try editor.seekToEnd()
                try editor.write(contentsOf: edit)
            }
            XCTAssertThrowsError(try applyProjectSkillSyncTransaction(plan,
                beforeManifestCommit: afterCommit ? nil : writeThroughRetainedHandle,
                afterManifestCommit: afterCommit ? writeThroughRetainedHandle : nil)) { error in
                XCTAssertTrue(error.localizedDescription.contains("original project skill changed"))
                XCTAssertEqual(error.localizedDescription.contains("The copy committed"), afterCommit)
            }
            if afterCommit {
                let agents = fixture.project.appendingPathComponent(".agents")
                let recovery = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: agents.path)
                    .first { $0.hasPrefix(".metagent-project-skills-") })
                XCTAssertEqual(try Data(contentsOf: agents.appendingPathComponent("\(recovery)/backup/demo/SKILL.md")), originalBytes + edit)
                XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.destination("demo/updated.md").path))
                XCTAssertNotEqual(try Data(contentsOf: fixture.manifest), oldManifest)
            } else {
                XCTAssertEqual(try Data(contentsOf: originalFile), originalBytes + edit)
                XCTAssertEqual(try Data(contentsOf: fixture.manifest), oldManifest)
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination("demo/updated.md").path))
            }
        }
    }

    func testInvalidSelectionOverlapAndFileLimitsAreBounded() throws {
        let fixture = try ProjectSyncFixture()
        defer { fixture.remove() }
        let source = try fixture.skill("demo")
        for names in [[], ["../escape"], ["Demo"], (0..<33).map { "skill-\($0)" }] {
            XCTAssertThrowsError(try fixture.preview(names))
        }
        XCTAssertThrowsError(try MetagentCore.previewProjectSkillSync(projectRoot: fixture.root.path, skillNames: ["demo"], globalSkillsRoot: fixture.global.path))
        let huge = source.appendingPathComponent("large.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: huge.path, contents: nil))
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(publicationMaximumFileBytes + 1))
        try handle.close()
        XCTAssertFalse(try fixture.preview(["demo"]).canApply)
    }

    func testFreshCloneContainsSelectedResourcesWithoutAnyGlobalCorpus() throws {
        let fixture = try ProjectSyncFixture()
        defer { fixture.remove() }
        let selected = try fixture.skill("cloud-ready")
        _ = try fixture.skill("private-unselected")
        let scriptBytes = Data("#!/bin/sh\n# Synthetic fixture, never executed.\n".utf8)
        let referenceBytes = Data("Portable synthetic instructions.".utf8)
        try fixture.write("scripts/run.sh", in: selected, data: scriptBytes)
        try fixture.write("references/guide.md", in: selected, data: referenceBytes)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: selected.appendingPathComponent("SKILL.md").path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: selected.appendingPathComponent("scripts/run.sh").path)
        _ = try MetagentCore.applyProjectSkillSync(fixture.preview(["cloud-ready"]))
        try fixture.git(["init", "--initial-branch=main", "--template="], at: fixture.project)
        try fixture.git(["add", "--", ".agents/skills/cloud-ready", ".agents/project-skills.json"], at: fixture.project)
        try fixture.git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "Synthetic project skills"], at: fixture.project)
        let clone = fixture.root.appendingPathComponent("fresh-cloud-checkout")
        try fixture.git(["clone", "--no-local", "--template=", fixture.project.path, clone.path], at: fixture.root)
        let refresh = try MetagentCore.previewProjectSkillSync(projectRoot: clone.path, skillNames: ["cloud-ready"], globalSkillsRoot: fixture.global.path)
        XCTAssertEqual(refresh.items.first?.action, .unchanged, "Git-normalized file modes must retain ownership in a fresh checkout.")
        _ = try MetagentCore.applyProjectSkillSync(refresh)
        let scriptPermissions = (try FileManager.default.attributesOfItem(atPath: clone.appendingPathComponent(".agents/skills/cloud-ready/scripts/run.sh").path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(scriptPermissions & 0o100, 0o100)
        try FileManager.default.removeItem(at: fixture.global)
        XCTAssertEqual(try Data(contentsOf: clone.appendingPathComponent(".agents/skills/cloud-ready/scripts/run.sh")), scriptBytes)
        XCTAssertEqual(try Data(contentsOf: clone.appendingPathComponent(".agents/skills/cloud-ready/references/guide.md")), referenceBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: clone.appendingPathComponent(".agents/skills/cloud-ready/SKILL.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: clone.appendingPathComponent(".agents/skills/private-unselected").path))
        XCTAssertFalse(try String(contentsOf: clone.appendingPathComponent(".agents/project-skills.json"), encoding: .utf8).contains(fixture.root.path))
    }

    func testFailedBatchRollsBackNewCopiesAndRestoresOriginalOwnedBundle() throws {
        let fixture = try ProjectSyncFixture()
        defer { fixture.remove() }
        let source = try fixture.skill("existing")
        _ = try fixture.skill("new-copy")
        _ = try MetagentCore.applyProjectSkillSync(fixture.preview(["existing"]))
        let manifestBefore = try Data(contentsOf: fixture.manifest)
        let original = try Data(contentsOf: fixture.destination("existing/SKILL.md"))
        try fixture.write("updated.md", in: source, data: Data("Updated source.".utf8))
        let plan = try fixture.preview(["existing", "new-copy"])
        XCTAssertThrowsError(try applyProjectSkillSyncTransaction(plan, beforeManifestCommit: {
            throw NSError(domain: "SyntheticFixture", code: 1)
        }))
        XCTAssertEqual(try Data(contentsOf: fixture.manifest), manifestBefore)
        XCTAssertEqual(try Data(contentsOf: fixture.destination("existing/SKILL.md")), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination("existing/updated.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination("new-copy").path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.project.appendingPathComponent(".agents").path).contains { $0.hasPrefix(".metagent-project-skills-") })
    }

    func testRollbackRetainsRecoveryIfAnotherWriterEditsInstalledCopy() throws {
        let fixture = try ProjectSyncFixture()
        defer { fixture.remove() }
        let source = try fixture.skill("demo")
        _ = try MetagentCore.applyProjectSkillSync(fixture.preview(["demo"]))
        let original = try Data(contentsOf: fixture.destination("demo/SKILL.md"))
        try fixture.write("updated.md", in: source, data: Data("Updated source.".utf8))
        let plan = try fixture.preview(["demo"])
        XCTAssertThrowsError(try applyProjectSkillSyncTransaction(plan, beforeManifestCommit: {
            try fixture.write("concurrent-edit.md", in: fixture.destination("demo"), data: Data("Never discard concurrent project edits.".utf8))
            throw NSError(domain: "SyntheticFixture", code: 1)
        })) { error in
            XCTAssertTrue(error.localizedDescription.contains("recovery bundles remain"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.destination("demo/concurrent-edit.md").path))
        let agents = fixture.project.appendingPathComponent(".agents")
        let recovery = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: agents.path).first { $0.hasPrefix(".metagent-project-skills-") })
        XCTAssertEqual(try Data(contentsOf: agents.appendingPathComponent("\(recovery)/backup/demo/SKILL.md")), original)
    }
}

final class ProjectSkillFollowTests: XCTestCase {
    func testGlobalChangeUpdatesProjectCopyAndOwnershipHashThenSettles() throws {
        let fixture = try ProjectSyncFixture()
        defer { fixture.remove() }
        let source = try fixture.skill("demo")
        _ = try MetagentCore.applyProjectSkillSync(fixture.preview(["demo"]))
        let manifestBefore = try Data(contentsOf: fixture.manifest)
        try fixture.write("references/new.md", in: source, data: Data("Global update.".utf8))

        let report = fixture.follow()
        XCTAssertTrue(report.applied)
        XCTAssertEqual(report.projects.map(\.updatedNames), [["demo"]])
        XCTAssertFalse(report.needsAttention)
        XCTAssertEqual(try Data(contentsOf: fixture.destination("demo/references/new.md")), Data("Global update.".utf8))
        let manifestAfter = try Data(contentsOf: fixture.manifest)
        XCTAssertNotEqual(manifestAfter, manifestBefore)
        let sourceHash = try XCTUnwrap(fixture.preview(["demo"]).items.first?.sourceHash)
        XCTAssertTrue(String(decoding: manifestAfter, as: UTF8.self).contains(sourceHash))
        XCTAssertFalse(String(decoding: manifestAfter, as: UTF8.self).contains(fixture.root.path))

        // The refresh that follows an update must find nothing to do.
        let settled = fixture.follow()
        XCTAssertEqual(settled.updatedCount, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.manifest), manifestAfter)
    }

    func testLocalEditBlocksAndLeavesProjectCopyUntouched() throws {
        let fixture = try ProjectSyncFixture()
        defer { fixture.remove() }
        let source = try fixture.skill("demo")
        _ = try MetagentCore.applyProjectSkillSync(fixture.preview(["demo"]))
        try fixture.write("local.md", in: fixture.destination("demo"), data: Data("Project edit.".utf8))
        try fixture.write("global.md", in: source, data: Data("Global update.".utf8))
        let manifestBefore = try Data(contentsOf: fixture.manifest)

        let report = fixture.follow()
        XCTAssertEqual(report.updatedCount, 0)
        XCTAssertTrue(report.needsAttention)
        XCTAssertEqual(report.projects.first?.blocked.map(\.name), ["demo"])
        XCTAssertTrue(report.projects.first?.blocked.first?.reason.contains("not an unchanged Metagent copy") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.destination("demo/local.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination("demo/global.md").path))
        XCTAssertEqual(try Data(contentsOf: fixture.manifest), manifestBefore)
    }

    func testBlockedSkillDoesNotStopOtherSkillsFromUpdating() throws {
        let fixture = try ProjectSyncFixture()
        defer { fixture.remove() }
        let alpha = try fixture.skill("alpha")
        let beta = try fixture.skill("beta")
        _ = try MetagentCore.applyProjectSkillSync(fixture.preview(["alpha", "beta"]))
        try fixture.write(".env", in: alpha, data: Data("FIXTURE_ONLY=yes".utf8))
        try fixture.write("global.md", in: beta, data: Data("Global update.".utf8))

        let report = fixture.follow()
        XCTAssertEqual(report.projects.first?.updatedNames, ["beta"])
        XCTAssertEqual(report.projects.first?.blocked.map(\.name), ["alpha"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination("alpha/.env").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.destination("beta/global.md").path))
        XCTAssertFalse(try JSONEncoder().encode(report).isEmpty)
    }

    func testDeletedGlobalSourceKeepsProjectCopyAndReportsIt() throws {
        let fixture = try ProjectSyncFixture()
        defer { fixture.remove() }
        let source = try fixture.skill("demo")
        _ = try MetagentCore.applyProjectSkillSync(fixture.preview(["demo"]))
        let copyBefore = try Data(contentsOf: fixture.destination("demo/SKILL.md"))
        let manifestBefore = try Data(contentsOf: fixture.manifest)
        try FileManager.default.removeItem(at: source)

        let report = fixture.follow()
        XCTAssertEqual(report.projects.first?.blocked.map(\.name), ["demo"])
        XCTAssertTrue(report.projects.first?.blocked.first?.reason.contains("no longer exists") == true)
        XCTAssertEqual(try Data(contentsOf: fixture.destination("demo/SKILL.md")), copyBefore)
        XCTAssertEqual(try Data(contentsOf: fixture.manifest), manifestBefore)
    }

    func testUnchangedSkillsAndProjectsWithoutManifestWriteNothing() throws {
        let fixture = try ProjectSyncFixture()
        defer { fixture.remove() }
        _ = try fixture.skill("demo")
        let unsynced = fixture.root.appendingPathComponent("unsynced")
        try FileManager.default.createDirectory(at: unsynced, withIntermediateDirectories: true)
        _ = try MetagentCore.applyProjectSkillSync(fixture.preview(["demo"]))
        let agents = fixture.project.appendingPathComponent(".agents")
        let manifestBefore = try Data(contentsOf: fixture.manifest)
        let modifiedBefore = try FileManager.default.attributesOfItem(atPath: fixture.destination("demo/SKILL.md").path)[.modificationDate] as? Date

        let report = MetagentCore.refreshSyncedProjectSkills(projectRoots: [fixture.project.path, unsynced.path]) { _ in fixture.global.path }
        XCTAssertEqual(report.projects.map(\.projectRoot), [fixture.project.path])
        XCTAssertEqual(report.updatedCount, 0)
        XCTAssertFalse(report.needsAttention)
        XCTAssertEqual(report.projects.first?.deferredNames, [])
        XCTAssertEqual(try Data(contentsOf: fixture.manifest), manifestBefore)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: fixture.destination("demo/SKILL.md").path)[.modificationDate] as? Date, modifiedBefore)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: agents.path).sorted(), ["project-skills.json", "skills"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: unsynced.appendingPathComponent(".agents").path))
    }

    func testPreviewOnlyAndBusyProjectChangeNothing() throws {
        let fixture = try ProjectSyncFixture()
        defer { fixture.remove() }
        let source = try fixture.skill("demo")
        _ = try MetagentCore.applyProjectSkillSync(fixture.preview(["demo"]))
        try fixture.write("global.md", in: source, data: Data("Global update.".utf8))

        let preview = fixture.follow(apply: false)
        XCTAssertFalse(preview.applied)
        XCTAssertEqual(preview.projects.first?.updatedNames, ["demo"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination("demo/global.md").path))

        try withProjectSkillSyncLock(projectRoot: fixture.project.path) {
            let busy = fixture.follow()
            XCTAssertEqual(busy.projects.first?.deferredNames, ["demo"])
            XCTAssertEqual(busy.updatedCount, 0)
            XCTAssertFalse(busy.needsAttention, "A busy project retries on the next refresh.")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination("demo/global.md").path))
        XCTAssertEqual(fixture.follow().projects.first?.updatedNames, ["demo"])
    }
}

private struct ProjectSyncFixture {
    let root: URL
    let global: URL
    let project: URL
    var manifest: URL { project.appendingPathComponent(".agents/project-skills.json") }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("metagent-project-sync-\(UUID().uuidString)").resolvingSymlinksInPath()
        global = root.appendingPathComponent("synthetic-global/skills")
        project = root.appendingPathComponent("project")
        for path in [global, project] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func destination(_ path: String) -> URL { project.appendingPathComponent(".agents/skills").appendingPathComponent(path) }
    func skill(_ name: String, body: String = "Synthetic portable skill.") throws -> URL {
        let skill = global.appendingPathComponent(name)
        try writeSkillFixture(at: skill, name: name, body: body)
        return skill
    }
    @discardableResult func write(_ relative: String, in directory: URL, data: Data) throws -> URL {
        let path = directory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: path)
        return path
    }
    func preview(_ names: [String]) throws -> ProjectSkillSyncPlan {
        try MetagentCore.previewProjectSkillSync(projectRoot: project.path, skillNames: names, globalSkillsRoot: global.path)
    }
    func follow(apply: Bool = true) -> ProjectSkillFollowReport {
        MetagentCore.refreshSyncedProjectSkills(projectRoots: [project.path], apply: apply) { _ in global.path }
    }
    func git(_ arguments: [String], at directory: URL) throws {
        let result = try runSubprocess(
            executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: [
                "-i", "PATH=/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null",
                "GIT_TERMINAL_PROMPT=0", "GIT_NO_LAZY_FETCH=1", "/usr/bin/git", "--no-optional-locks",
                "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "commit.gpgsign=false",
                "-C", directory.path,
            ] + arguments, timeout: 10
        )
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.status, 0, String(decoding: result.standardError, as: UTF8.self))
    }
}
