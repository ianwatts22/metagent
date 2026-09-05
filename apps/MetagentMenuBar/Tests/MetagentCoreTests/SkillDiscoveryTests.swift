import Foundation
import XCTest
@testable import MetagentCore

final class SkillDiscoveryTests: XCTestCase {
    func testSharedInventoryIncludesMCPOnlyAndConfiguredProjectsWithinTraversalScope() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-shared-projects")
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = root.appendingPathComponent("manifest-only")
        let configured = root.appendingPathComponent("configured-only")
        let ignored = root.appendingPathComponent("ignored")
        let tooDeep = root.appendingPathComponent("nested/deep")
        let plugin = root.appendingPathComponent("plugin-package")
        for folder in [manifest, configured, ignored, tooDeep] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try "{\"mcpServers\":{\"demo\":{}}}".write(
            to: manifest.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: plugin.appendingPathComponent(".claude-plugin"),
                                                withIntermediateDirectories: true)
        try "{}".write(to: plugin.appendingPathComponent(".claude-plugin/plugin.json"),
                       atomically: true, encoding: .utf8)
        try "{}".write(to: plugin.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
        var roots = Set<String>()
        discoverProjectRoots(root: root, maxDepth: 1, ignoreProjects: [ignored.path],
                             traversalPruneRoots: [],
                             configuredProjectPaths: [configured.path, ignored.path, tooDeep.path, "/outside"],
                             projectRoots: &roots)
        XCTAssertEqual(roots, [manifest.path, configured.path])
        let report = try MetagentCore.scanSkills(options: SkillScanOptions(
            roots: [root.path], maxDepth: 1, respectConfiguredIgnores: false))
        XCTAssertEqual(report.projects.map(\.root), [manifest.path])
        XCTAssertTrue(report.projects.flatMap(\.skills).isEmpty)
    }

    func testGlobalOnlyHomeScanDoesNotRediscoverNestedProjects() throws {
        let home = try makeTemporaryRoot(prefix: "metagent-discovery-home-scope")
        defer { try? FileManager.default.removeItem(at: home) }
        let previousHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", home.path, 1)
        defer {
            if let previousHome {
                setenv("HOME", previousHome, 1)
            } else {
                unsetenv("HOME")
            }
        }

        try writeSkillFixture(
            at: home.appendingPathComponent(".agents/skills/global-skill"),
            name: "global-skill"
        )
        let nestedProject = home.appendingPathComponent("code_projects/example")
        try writeSkillFixture(
            at: nestedProject.appendingPathComponent(".agents/skills/project-skill"),
            name: "project-skill"
        )

        let globalOnly = try MetagentCore.scanHomeSkills(maxDepth: 0)
        let recursive = try MetagentCore.scanHomeSkills(maxDepth: 2)

        XCTAssertEqual(globalOnly.projects.map(\.root), [home.path])
        XCTAssertEqual(globalOnly.projects.flatMap(\.validSkills), ["global-skill"])
        XCTAssertEqual(Set(recursive.projects.map(\.root)), Set([home.path, nestedProject.path]))
    }

    func testHomeScanPrunesConfiguredRootsButKeepsOtherShallowProjects() throws {
        let home = try makeTemporaryRoot(prefix: "metagent-discovery-pruned-home")
        defer { try? FileManager.default.removeItem(at: home) }
        let previousHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", home.path, 1)
        defer {
            if let previousHome {
                setenv("HOME", previousHome, 1)
            } else {
                unsetenv("HOME")
            }
        }

        let configuredRoot = home.appendingPathComponent("code_projects")
        let configuredProject = configuredRoot.appendingPathComponent("configured")
        try writeSkillFixture(
            at: configuredProject.appendingPathComponent(".agents/skills/configured-skill"),
            name: "configured-skill"
        )
        let desktopProject = home.appendingPathComponent("Desktop/example")
        try writeSkillFixture(
            at: desktopProject.appendingPathComponent(".agents/skills/desktop-skill"),
            name: "desktop-skill"
        )
        let obsoleteProjection = desktopProject.appendingPathComponent(".codex/skills/desktop-skill")
        try FileManager.default.createDirectory(
            at: obsoleteProjection.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: obsoleteProjection,
            withDestinationURL: desktopProject.appendingPathComponent(".agents/skills/desktop-skill")
        )
        let configDirectory = home.appendingPathComponent(".config/metagent")
        try FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true
        )
        try """
        roots = ["\(configuredRoot.path)"]
        max_depth = 6
        """.write(
            to: configDirectory.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )

        let report = try MetagentCore.scanHomeSkills(
            maxDepth: 2,
            pruningConfiguredRoots: true
        )

        XCTAssertEqual(report.projects.map(\.root), [desktopProject.path])
        XCTAssertEqual(report.projects.flatMap(\.validSkills), ["desktop-skill"])

        let doctor = MetagentCore.doctor(reports: [SkillScanReport(projects: []), report])
        XCTAssertTrue(doctor.issues.contains {
            $0.projectRoot == desktopProject.path && $0.category == .projection
        })
    }

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
        var configuredRoots = Set<String>()
        discoverProjectRoots(root: worktree, maxDepth: 2, ignoreProjects: [],
                             traversalPruneRoots: [], projectRoots: &configuredRoots)
        XCTAssertTrue(configuredRoots.isEmpty, "Configured worktree roots must be excluded")
        XCTAssertTrue(isInsideGitLinkedWorktree(worktree.appendingPathComponent(".agents/skills")))
        var nestedRoots = Set<String>()
        discoverProjectRoots(root: worktree.appendingPathComponent(".agents/skills"),
                             maxDepth: 2, ignoreProjects: [], traversalPruneRoots: [],
                             projectRoots: &nestedRoots)
        XCTAssertTrue(nestedRoots.isEmpty)
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
