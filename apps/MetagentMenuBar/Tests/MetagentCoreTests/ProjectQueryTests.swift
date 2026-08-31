import Foundation
import XCTest
@testable import MetagentCore

final class ProjectQueryTests: XCTestCase {
    func testDefaultsToProjectsAndUsesCanonicalCounts() throws {
        let home = URL(fileURLWithPath: "/fixtures/home")
        var projection = SkillInventoryItem.fixture(
            name: "alpha",
            path: "/fixtures/app/.claude/skills/alpha",
            location: "claude",
            representation: "projection"
        )
        projection.canonicalPath = "/fixtures/app/.agents/skills/alpha"
        let report = SkillScanReport(projects: [
            project(root: home.path, skills: [
                .fixture(name: "global", path: "/fixtures/home/.agents/skills/global", scope: "global")
            ]),
            project(root: "/fixtures/app", skills: [
                .fixture(name: "alpha", path: "/fixtures/app/.agents/skills/alpha"),
                projection
            ]),
            project(root: "/fixtures/plugin", skills: [
                .fixture(
                    name: "plugin-skill",
                    path: "/fixtures/plugin/skills/plugin-skill",
                    location: "plugin",
                    originKind: "codex-plugin",
                    manager: "codex-plugin",
                    representation: "versioned-cache"
                )
            ])
        ])

        let page = try MetagentCore.queryProjects(
            options: ProjectQueryOptions(),
            report: report,
            homeDirectory: home
        )

        XCTAssertEqual(page.schemaVersion, 2)
        XCTAssertEqual(page.projectCount, 1)
        XCTAssertEqual(page.skillCount, 1)
        XCTAssertEqual(page.representationCount, 2)
        XCTAssertEqual(page.projects.first?.rootKind, .project)
        XCTAssertEqual(page.projects.first?.skillCount, 1)
        XCTAssertEqual(page.projects.first?.representationCount, 2)
        XCTAssertEqual(page.projects.first?.projectionCount, 1)
        XCTAssertEqual(page.projects.first?.locations, ["agents": 1])
    }

    func testAllKindsAreTypedAndPaginationIsStable() throws {
        let home = URL(fileURLWithPath: "/fixtures/home")
        let report = SkillScanReport(projects: [
            project(root: home.path, skills: [
                .fixture(name: "global", path: "/fixtures/home/.agents/skills/global", scope: "global")
            ]),
            project(root: "/fixtures/app", skills: [
                .fixture(name: "app", path: "/fixtures/app/.agents/skills/app")
            ]),
            project(root: "/fixtures/plugin", skills: [
                .fixture(
                    name: "plugin",
                    path: "/fixtures/plugin/skills/plugin",
                    location: "plugin",
                    originKind: "codex-plugin",
                    manager: "codex-plugin"
                )
            ])
        ])
        let kinds = Set(ProjectRootKind.allCases)
        var options = ProjectQueryOptions(kinds: kinds, limit: 1)
        var roots: [String] = []
        var rootKinds: [ProjectRootKind] = []

        while true {
            let page = try MetagentCore.queryProjects(
                options: options,
                report: report,
                homeDirectory: home
            )
            XCTAssertEqual(page.projectCount, 3)
            XCTAssertLessThanOrEqual(page.returnedCount, 1)
            roots.append(contentsOf: page.projects.map(\.root))
            rootKinds.append(contentsOf: page.projects.map(\.rootKind))
            guard let cursor = page.nextCursor else { break }
            options.cursor = cursor
        }

        XCTAssertEqual(roots, roots.sorted())
        XCTAssertEqual(Set(rootKinds), kinds)
        XCTAssertEqual(Set(roots).count, 3)
    }

    func testProjectionOnlySkillCountsAsOneLogicalSkill() throws {
        let home = URL(fileURLWithPath: "/fixtures/home")
        var projection = SkillInventoryItem.fixture(
            name: "shared",
            path: "/fixtures/app/.claude/skills/shared",
            location: "claude",
            representation: "projection"
        )
        projection.canonicalPath = "/fixtures/home/.agents/skills/shared"
        let report = SkillScanReport(projects: [
            project(root: "/fixtures/app", skills: [projection])
        ])

        let page = try MetagentCore.queryProjects(
            options: ProjectQueryOptions(),
            report: report,
            homeDirectory: home
        )

        XCTAssertEqual(page.skillCount, 1)
        XCTAssertEqual(page.representationCount, 1)
        XCTAssertEqual(page.projects.first?.skillCount, 1)
        XCTAssertEqual(page.projects.first?.projectionCount, 1)
        XCTAssertEqual(page.projects.first?.locations, ["claude": 1])
    }

    func testCursorRejectsKindChangesAndMalformedInput() throws {
        let home = URL(fileURLWithPath: "/fixtures/home")
        let report = SkillScanReport(projects: [
            project(root: "/fixtures/a", skills: [.fixture(path: "/fixtures/a/.agents/skills/demo")]),
            project(root: "/fixtures/b", skills: [.fixture(path: "/fixtures/b/.agents/skills/demo")])
        ])
        let first = try MetagentCore.queryProjects(
            options: ProjectQueryOptions(limit: 1),
            report: report,
            homeDirectory: home
        )
        let cursor = try XCTUnwrap(first.nextCursor)

        XCTAssertThrowsError(try MetagentCore.queryProjects(
            options: ProjectQueryOptions(kinds: [.global], cursor: cursor),
            report: report,
            homeDirectory: home
        ))
        XCTAssertThrowsError(try MetagentCore.queryProjects(
            options: ProjectQueryOptions(cursor: "not-a-cursor"),
            report: report,
            homeDirectory: home
        ))
    }

    private func project(root: String, skills: [SkillInventoryItem]) -> SkillProject {
        SkillProject(
            root: root,
            skillsDir: root + "/.agents/skills",
            validSkills: skills.filter { $0.location == "agents" && $0.representation != "projection" }
                .map(\.name),
            skills: skills
        )
    }
}
