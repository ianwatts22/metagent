import Foundation
import XCTest
@testable import MetagentCore

final class ProjectAnalysisTests: XCTestCase {
    func testProjectSkillAuditUsesItsInventoryAndLaterRequestsRemainFresh() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-analysis-one-read")
        try writeSkillFixture(at: root.appendingPathComponent(".agents/skills/first"))
        let options = SkillScanOptions(
            roots: [root.path], maxDepth: 0, respectConfiguredIgnores: false
        )
        var reads = 0
        let audit = try MetagentCore.projectSkillAudit(options: options, readInventory: { options in
            reads += 1
            let inventory = try MetagentCore.scanSkills(options: options)
            // A second scan for Doctor would see this skill, yielding counts
            // inconsistent with the inventory returned for the same request.
            try writeSkillFixture(at: root.appendingPathComponent(".agents/skills/later"))
            return inventory
        })

        XCTAssertEqual(reads, 1)
        XCTAssertEqual(audit.skills.projects.flatMap(\.skills).map(\.name), ["first"])
        XCTAssertEqual(audit.doctor.canonicalSkillCount, 1)
        XCTAssertEqual(audit.doctor, MetagentCore.doctor(projects: audit.skills.projects))

        let later = try MetagentCore.projectSkillAudit(options: options)
        XCTAssertEqual(later.skills.projects.flatMap(\.skills).map(\.name), ["first", "later"])
        XCTAssertEqual(later.doctor.canonicalSkillCount, 2)
    }

    func testProjectSkillAuditPreservesCompleteIndependentDoctorFindings() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-analysis-audit-findings")
        let bundle = try writeSkillFixture(at: root.appendingPathComponent(".agents/skills/demo"))
        let claude = root.appendingPathComponent(".claude/skills")
        let codex = root.appendingPathComponent(".codex/skills")
        for directory in [claude, codex] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try writeSkillFixture(at: root.appendingPathComponent(".agents/skills/.hidden"))
        try FileManager.default.createSymbolicLink(at: claude.appendingPathComponent("demo"), withDestinationURL: bundle)
        try FileManager.default.createSymbolicLink(at: codex.appendingPathComponent("demo"), withDestinationURL: bundle)
        try Data("{}".utf8).write(to: root.appendingPathComponent(".agents/.skill-lock.json"))
        let options = SkillScanOptions(
            roots: [root.path], maxDepth: 0, respectConfiguredIgnores: false
        )

        let expected = try MetagentCore.doctor(options: options)
        let audit = try MetagentCore.projectSkillAudit(options: options)

        XCTAssertEqual(audit.doctor, expected)
        XCTAssertEqual(audit.doctor.canonicalSkillCount, 1)
        XCTAssertEqual(audit.doctor.representationCount, 3)
        XCTAssertEqual(audit.doctor.projectionCount, 2)
        XCTAssertTrue(audit.doctor.issues.contains { $0.summary == "Legacy skills lock ignored" })
        XCTAssertTrue(audit.doctor.issues.contains { $0.summary == "Hidden skill directory ignored" })
        XCTAssertTrue(audit.doctor.issues.contains { $0.repairAction == .repairProjection })
    }

    func testProjectSkillAuditRereadsSameSizeEditsAndRetargetedProjections() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-analysis-audit-freshness")
        let bundle = try writeSkillFixture(
            at: root.appendingPathComponent(".agents/skills/demo"), description: "First fixture"
        )
        let other = try writeSkillFixture(
            at: root.appendingPathComponent("outside/other"), description: "Other fixture"
        )
        let projection = root.appendingPathComponent(".claude/skills/demo")
        try FileManager.default.createDirectory(at: projection.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: projection, withDestinationURL: bundle)
        let manifest = bundle.appendingPathComponent("SKILL.md")
        let text = try String(contentsOf: manifest, encoding: .utf8)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: manifest.path)
        let options = SkillScanOptions(
            roots: [root.path], maxDepth: 0, respectConfiguredIgnores: false
        )
        let first = try MetagentCore.projectSkillAudit(options: options)

        let edited = text.replacingOccurrences(of: "First fixture", with: "Other fixture")
        XCTAssertEqual(text.utf8.count, edited.utf8.count)
        try edited.write(to: manifest, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: manifest.path)
        try FileManager.default.removeItem(at: projection)
        try FileManager.default.createSymbolicLink(at: projection, withDestinationURL: other)
        let later = try MetagentCore.projectSkillAudit(options: options)

        XCTAssertEqual(first.doctor.canonicalSkillCount, 1)
        XCTAssertEqual(later.doctor.canonicalSkillCount, 2)
        XCTAssertEqual(later.skills.projects.flatMap(\.skills).first { $0.location == "agents" }?.description, "Other fixture")
        XCTAssertEqual(later.skills.projects.flatMap(\.skills).first { $0.location == "claude" }?.canonicalPath, canonicalProjectPath(other))
        XCTAssertEqual(later.doctor, try MetagentCore.doctor(options: options))
    }

    func testExplicitScanCanBypassConfiguredDiscoveryIgnores() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-analysis-tests")
        try writeSkillFixture(at: root.appendingPathComponent(".agents/skills/demo"), description: "Demo skill")

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
        let root = try makeTemporaryRoot(prefix: "metagent-analysis-tests")
        let home = root.appendingPathComponent("home")
        let project = root.appendingPathComponent("project")
        let skill = project.appendingPathComponent(".agents/skills/demo")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try writeSkillFixture(at: skill, description: "Demo skill")
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
        try Data("""
        {"mcpServers":{"project-server":{}}}
        """.utf8).write(to: project.appendingPathComponent(".mcp.json"))
        try Data("{}".utf8).write(to: home.appendingPathComponent(".claude.json"))

        let codex = try makeCodexStub(in: root)

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

    func testCompactSummaryIsProjectOnlyAndOmitsFullInventories() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-analysis-tests")
        let home = root.appendingPathComponent("home")
        let project = root.appendingPathComponent("project")
        let skill = project.appendingPathComponent(".agents/skills/demo")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try writeSkillFixture(at: skill, description: "Demo skill")
        try Data("# Project instructions\n".utf8).write(to: project.appendingPathComponent("AGENTS.md"))
        try Data("""
        {
          "mcpServers":{"global-only":{}},
          "projects":{
            "\(project.path)":{"mcpServers":{"project-only":{}}}
          }
        }
        """.utf8).write(to: home.appendingPathComponent(".claude.json"))

        let codex = try makeCodexStub(in: root)

        let summary = try MetagentCore.analyzeProjectSummary(
            root: project.path,
            homeDirectory: home,
            codexExecutableOverride: codex,
            generatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let encoded = try MetagentCore.encodeJSON(summary)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertEqual(summary.schemaVersion, 3)
        XCTAssertEqual(summary.scope, "project_only")
        XCTAssertEqual(summary.counts.instructionFiles, 1)
        XCTAssertEqual(summary.counts.projectSkills, 1)
        XCTAssertEqual(summary.counts.projectMCPServers, 1)
        XCTAssertLessThanOrEqual(summary.findings.count, 5)
        XCTAssertEqual(json["schema_version"] as? Int, 3)
        XCTAssertNil(json["skills"])
        XCTAssertNil(json["plugin_skills"])
        XCTAssertNil(json["doctor"])
        XCTAssertNil(json["mcp"])
        XCTAssertNil(json["usage"])
    }

    func testSummaryCountsOneCanonicalSkillAcrossAgentAndClaudeRepresentations() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-analysis-counts")
        let skill = root.appendingPathComponent(".agents/skills/demo")
        try writeSkillFixture(at: skill, name: "demo")
        let claude = root.appendingPathComponent(".claude/skills")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: claude.appendingPathComponent("demo").path,
            withDestinationPath: "../../.agents/skills/demo"
        )

        let summary = try MetagentCore.analyzeProjectSummary(root: root.path)
        let doctor = try MetagentCore.doctor(options: SkillScanOptions(
            roots: [root.path],
            maxDepth: 0,
            respectConfiguredIgnores: false
        ))
        let listed = try MetagentCore.querySkills(options: SkillQueryOptions(
            scope: .project(root: root.path)
        ))

        XCTAssertEqual(summary.counts.projectSkills, 1)
        XCTAssertEqual(summary.counts.projectSkillRepresentations, 2)
        XCTAssertEqual(summary.counts.projectSkillProjections, 1)
        XCTAssertEqual(listed.totalCount, 1)
        XCTAssertEqual(doctor.canonicalSkillCount, 1)
        XCTAssertEqual(doctor.representationCount, 2)
        XCTAssertEqual(doctor.projectionCount, 1)
    }

    func testProjectDetailPagesAreBoundedAndCursorIsSectionSpecific() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-analysis-tests")
        let home = root.appendingPathComponent("home")
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("Sources/Feature"),
            withIntermediateDirectories: true
        )
        try Data("# Project instructions\n".utf8).write(to: project.appendingPathComponent("AGENTS.md"))
        try Data("# Feature instructions\n".utf8)
            .write(to: project.appendingPathComponent("Sources/Feature/AGENTS.md"))
        try Data("{}".utf8).write(to: home.appendingPathComponent(".claude.json"))

        let codex = try makeCodexStub(in: root)

        let firstPage = try MetagentCore.analyzeProjectDetails(
            root: project.path,
            section: .instructions,
            limit: 1,
            homeDirectory: home,
            codexExecutableOverride: codex
        )
        let cursor = try XCTUnwrap(firstPage.nextCursor)
        let secondPage = try MetagentCore.analyzeProjectDetails(
            root: project.path,
            section: .instructions,
            cursor: cursor,
            limit: 1,
            homeDirectory: home,
            codexExecutableOverride: codex
        )

        XCTAssertEqual(firstPage.scope, "project_only")
        XCTAssertEqual(firstPage.items.count, 1)
        XCTAssertEqual(secondPage.items.count, 1)
        XCTAssertNil(secondPage.nextCursor)
        XCTAssertThrowsError(try MetagentCore.analyzeProjectDetails(
            root: project.path,
            section: .skills,
            cursor: cursor,
            homeDirectory: home,
            codexExecutableOverride: codex
        ))
    }

    func testAnalysisIsolatesProjectMCPStatesAndCanonicalizesSymlinkRoots() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-analysis-tests")
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

        let codex = try makeCodexStub(in: root)

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

    private func makeCodexStub(in root: URL) throws -> URL {
        let codex = root.appendingPathComponent("codex")
        try Data("#!/bin/sh\nprintf '[]'\n".utf8).write(to: codex)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)
        return codex
    }
}
