import Foundation
import XCTest
@testable import MetagentCore

final class SkillDiscoveryTests: XCTestCase {
    func testScanExcludesLinkedGitWorktrees() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-discovery-worktrees")
        defer { try? FileManager.default.removeItem(at: root) }

        let primary = root.appendingPathComponent("primary")
        let worktree = root.appendingPathComponent("worktrees/feature")
        try writeSkillFixture(
            at: primary.appendingPathComponent(".agents/skills/primary-skill"),
            name: "primary-skill"
        )
        try writeSkillFixture(
            at: worktree.appendingPathComponent(".agents/skills/repeated-skill"),
            name: "repeated-skill"
        )
        try FileManager.default.createDirectory(
            at: primary.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        let worktreeMetadata = root.appendingPathComponent("git-common/.git/worktrees/feature")
        try FileManager.default.createDirectory(
            at: worktreeMetadata,
            withIntermediateDirectories: true
        )
        let worktreeMarker = worktree.appendingPathComponent(".git")
        try "gitdir: ../../git-common/.git/worktrees/feature\n".write(
            to: worktreeMarker,
            atomically: true,
            encoding: .utf8
        )
        try "../../..\n".write(
            to: worktreeMetadata.appendingPathComponent("commondir"),
            atomically: true,
            encoding: .utf8
        )
        try "\(worktreeMarker.path)\n".write(
            to: worktreeMetadata.appendingPathComponent("gitdir"),
            atomically: true,
            encoding: .utf8
        )

        let report = try MetagentCore.scanSkills(options: SkillScanOptions(
            roots: [root.path],
            maxDepth: 3,
            respectConfiguredIgnores: false
        ))

        XCTAssertEqual(report.projects.map(\.root), [primary.path])
        XCTAssertEqual(report.projects.flatMap(\.validSkills), ["primary-skill"])
    }

    func testSubmoduleGitFileDoesNotLookLikeLinkedWorktree() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-discovery-submodule")
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = root.appendingPathComponent("primary/.git/modules/deps/worktrees/foo")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try "gitdir: primary/.git/modules/deps/worktrees/foo\n".write(
            to: root.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertFalse(isGitLinkedWorktree(root))
    }

    func testExplicitLinkedWorktreeRootRemainsScannable() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-discovery-explicit-worktree")
        defer { try? FileManager.default.removeItem(at: root) }
        let gitCommonName = "\(root.lastPathComponent)-git-common"
        let metadata = root.appendingPathComponent("../\(gitCommonName)/.git/worktrees/feature")
            .standardizedFileURL
        defer { try? FileManager.default.removeItem(at: metadata.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        try writeSkillFixture(
            at: root.appendingPathComponent(".agents/skills/current-project-skill"),
            name: "current-project-skill"
        )
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        let marker = root.appendingPathComponent(".git")
        try "gitdir: ../\(gitCommonName)/.git/worktrees/feature\n".write(
            to: marker,
            atomically: true,
            encoding: .utf8
        )
        try "../../..\n".write(
            to: metadata.appendingPathComponent("commondir"),
            atomically: true,
            encoding: .utf8
        )
        try "\(marker.path)\n".write(
            to: metadata.appendingPathComponent("gitdir"),
            atomically: true,
            encoding: .utf8
        )

        let report = try MetagentCore.scanSkills(options: SkillScanOptions(
            roots: [root.path],
            maxDepth: 0,
            respectConfiguredIgnores: false
        ))

        XCTAssertEqual(report.projects.map(\.root), [root.path])
        XCTAssertEqual(report.projects.flatMap(\.validSkills), ["current-project-skill"])
    }

    func testSymlinkedWorktreePathMatchesPhysicalBacklink() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-discovery-symlink-worktree")
        defer { try? FileManager.default.removeItem(at: root) }
        let physical = root.appendingPathComponent("physical")
        let alias = root.appendingPathComponent("alias")
        let metadata = root.appendingPathComponent("git-common/.git/worktrees/feature")
        try FileManager.default.createDirectory(at: physical, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: physical)
        let marker = physical.appendingPathComponent(".git")
        try "gitdir: ../git-common/.git/worktrees/feature\n".write(
            to: marker,
            atomically: true,
            encoding: .utf8
        )
        try "../../..\n".write(
            to: metadata.appendingPathComponent("commondir"),
            atomically: true,
            encoding: .utf8
        )
        try "\(marker.path)\n".write(
            to: metadata.appendingPathComponent("gitdir"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertTrue(isGitLinkedWorktree(alias))
    }
}
