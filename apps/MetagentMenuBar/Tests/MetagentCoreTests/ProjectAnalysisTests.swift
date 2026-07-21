import Foundation
import XCTest
@testable import MetagentCore

final class ProjectAnalysisTests: XCTestCase {
    func testExplicitScanCanBypassConfiguredDiscoveryIgnores() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-analysis-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = root.appendingPathComponent(".agents/skills/demo")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try Data("---\nname: demo\ndescription: Demo skill\n---\n".utf8)
            .write(to: skill.appendingPathComponent("SKILL.md"))

        let config = MetagentConfig(roots: [root.path], ignoreProjects: [root.path])
        let excluded = try MetagentCore.scanSkills(
            options: SkillScanOptions(roots: [root.path], maxDepth: 0),
            config: config
        )
        let explicit = try MetagentCore.scanSkills(
            options: SkillScanOptions(
                roots: [root.path],
                maxDepth: 0,
                respectConfiguredIgnores: false
            ),
            config: config
        )

        XCTAssertTrue(excluded.projects.isEmpty)
        XCTAssertEqual(explicit.projects.flatMap(\.skills).map(\.name), ["demo"])
    }

    func testAnalysisCombinesProjectInstructionsSkillsDoctorAndScopedMCP() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-analysis-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let project = root.appendingPathComponent("project")
        let skill = project.appendingPathComponent(".agents/skills/demo")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try Data("# Project instructions\n".utf8).write(to: project.appendingPathComponent("AGENTS.md"))
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("Sources/Feature"),
            withIntermediateDirectories: true
        )
        try Data("# Feature instructions\n".utf8)
            .write(to: project.appendingPathComponent("Sources/Feature/AGENTS.md"))
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("vendor/dependency"),
            withIntermediateDirectories: true
        )
        try Data("# Dependency instructions\n".utf8)
            .write(to: project.appendingPathComponent("vendor/dependency/AGENTS.md"))
        try Data("---\nname: demo\ndescription: Demo skill\n---\n".utf8)
            .write(to: skill.appendingPathComponent("SKILL.md"))
        try Data("""
        {"mcpServers":{"project-server":{}}}
        """.utf8).write(to: project.appendingPathComponent(".mcp.json"))
        try Data("{}".utf8).write(to: home.appendingPathComponent(".claude.json"))

        let codex = root.appendingPathComponent("codex")
        try Data("#!/bin/sh\nprintf '[]'\n".utf8).write(to: codex)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)

        let report = try MetagentCore.analyzeProject(
            root: project.path,
            homeDirectory: home,
            codexExecutableOverride: codex,
            generatedAt: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertEqual(report.root, project.path)
        XCTAssertEqual(Set(report.instructions.map(\.kind)), ["agents", "mcp-config"])
        XCTAssertEqual(
            report.instructions.filter { $0.kind == "agents" }.map(\.path),
            [
                project.appendingPathComponent("AGENTS.md").path,
                project.appendingPathComponent("Sources/Feature/AGENTS.md").path
            ]
        )
        XCTAssertEqual(report.skills.projects.flatMap(\.skills).map(\.name), ["demo"])
        XCTAssertEqual(report.mcp.servers.map(\.name), ["project-server"])
        XCTAssertEqual(report.mcp.servers.first?.state, .pendingApproval)
        XCTAssertEqual(report.mcp.servers.first?.projectPaths, [project.path])
        XCTAssertTrue(report.usage.summaries.isEmpty)
        XCTAssertGreaterThan(report.doctor.issues.count, 0)
    }

    func testAnalysisRejectsMissingRoot() {
        XCTAssertThrowsError(try MetagentCore.analyzeProject(
            root: "/tmp/metagent-missing-\(UUID().uuidString)"
        ))
    }

    func testAnalysisIsolatesProjectMCPStatesAndCanonicalizesSymlinkRoots() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-analysis-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let first = root.appendingPathComponent("first")
        let firstAlias = root.appendingPathComponent("first-alias")
        let second = root.appendingPathComponent("second")
        for directory in [home, first, second] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(at: firstAlias, withDestinationURL: first)
        try Data("""
        {
          "mcpServers":{"global":{}},
          "projects":{
            "\(firstAlias.path)":{
              "mcpServers":{"first-only":{},"shared":{}},
              "disabledMcpServers":["first-disabled"]
            },
            "\(second.path)":{
              "mcpServers":{"second-only":{},"shared":{},"second-disabled":{}},
              "disabledMcpServers":["shared","second-disabled"]
            }
          }
        }
        """.utf8).write(to: home.appendingPathComponent(".claude.json"))
        try Data("""
        {"mcpServers":{"first-pending":{}}}
        """.utf8).write(to: first.appendingPathComponent(".mcp.json"))
        try Data("""
        {"mcpServers":{"second-pending":{}}}
        """.utf8).write(to: second.appendingPathComponent(".mcp.json"))

        let codex = root.appendingPathComponent("codex")
        try Data("#!/bin/sh\nprintf '[]'\n".utf8).write(to: codex)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)

        let firstReport = try MetagentCore.analyzeProject(
            root: firstAlias.path,
            homeDirectory: home,
            codexExecutableOverride: codex
        )
        let secondReport = try MetagentCore.analyzeProject(
            root: second.path,
            homeDirectory: home,
            codexExecutableOverride: codex
        )
        let firstStates = Dictionary(uniqueKeysWithValues: firstReport.mcp.servers.map { ($0.name, $0.state) })
        let secondStates = Dictionary(uniqueKeysWithValues: secondReport.mcp.servers.map { ($0.name, $0.state) })

        XCTAssertEqual(firstReport.root, first.path)
        XCTAssertEqual(firstStates, [
            "first-only": .configured,
            "first-pending": .pendingApproval,
            "global": .configured,
            "shared": .configured
        ])
        XCTAssertEqual(secondStates, [
            "global": .configured,
            "second-disabled": .disabled,
            "second-only": .configured,
            "second-pending": .pendingApproval,
            "shared": .disabled
        ])
    }
}
