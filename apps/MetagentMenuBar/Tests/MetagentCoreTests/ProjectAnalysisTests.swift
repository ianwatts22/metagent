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

    func testDetailSectionsReadOnlyTheirRequiredDependencies() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-detail-readers")
        try writeSkillFixture(at: root.appendingPathComponent(".agents/skills/demo"))
        let instruction = ProjectInstructionFile(path: root.appendingPathComponent("AGENTS.md").path, kind: "agents", byteCount: 10)
        let expectedReads: [ProjectAnalysisSection: [String]] = [
            .instructions: ["instructions"], .skills: ["inventory"],
            .doctor: ["inventory"], .mcp: ["mcp"], .usage: ["inventory", "usage"]
        ]
        let observedAt = Date(timeIntervalSince1970: 1_000)

        for section in ProjectAnalysisSection.allCases {
            var reads: [String] = []
            let page = try MetagentCore.projectAnalysisDetailPage(
                root: root.path, section: section, generatedAt: observedAt,
                readInstructions: { url in
                    reads.append("instructions")
                    XCTAssertEqual(url.path, canonicalProjectPath(root))
                    return [instruction]
                },
                readInventory: { options in
                    reads.append("inventory")
                    XCTAssertEqual(options.roots, [canonicalProjectPath(root)])
                    XCTAssertEqual(options.maxDepth, 0)
                    XCTAssertFalse(options.respectConfiguredIgnores)
                    return try MetagentCore.scanSkills(options: options)
                },
                readMCP: { url, _, _, date in
                    reads.append("mcp")
                    XCTAssertEqual(url.path, canonicalProjectPath(root))
                    XCTAssertEqual(date, observedAt)
                    return MCPHealthSnapshot(observedAt: date)
                },
                readUsage: { reads.append("usage"); return nil }
            )
            XCTAssertEqual(reads, expectedReads[section], "\(section) read unrelated inputs")
            XCTAssertEqual(page.root, canonicalProjectPath(root))
            XCTAssertEqual(page.generatedAt, observedAt)
        }
    }

    func testMalformedAndMismatchedCursorsSkipAllSectionReads() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-detail-cursors")
        let matching = canonicalProjectPath(root)
        let cases: [(String, String)] = [
            ("not-base64", "invalid project analysis detail cursor"),
            (Data("{}".utf8).base64EncodedString(), "invalid project analysis detail cursor"),
            (try makeDetailCursor(root: matching, section: .instructions, version: 2), "project analysis detail cursor does not match the requested root and section"),
            (try makeDetailCursor(root: matching + "/other", section: .instructions), "project analysis detail cursor does not match the requested root and section"),
            (try makeDetailCursor(root: matching, section: .skills), "project analysis detail cursor does not match the requested root and section"),
            (try makeDetailCursor(root: matching, section: .instructions, offset: -1), "project analysis detail cursor does not match the requested root and section")
        ]
        var reads = 0
        for (cursor, expectedError) in cases {
            XCTAssertThrowsError(try MetagentCore.projectAnalysisDetailPage(
                root: root.path, section: .instructions, cursor: cursor,
                readInstructions: { _ in reads += 1; return [] },
                readInventory: { _ in reads += 1; return SkillScanReport(projects: [], warnings: []) },
                readMCP: { _, _, _, _ in reads += 1; return MCPHealthSnapshot() },
                readUsage: { reads += 1; return nil }
            )) { error in
                let error = error as NSError
                XCTAssertEqual(error.domain, "MetagentProjectAnalysis")
                XCTAssertEqual(error.code, 2)
                XCTAssertEqual(error.localizedDescription, expectedError)
            }
        }
        XCTAssertEqual(reads, 0)

        // An invalid root retains precedence over a malformed cursor.
        XCTAssertThrowsError(try MetagentCore.projectAnalysisDetailPage(
            root: root.appendingPathComponent("missing").path,
            section: .instructions, cursor: "not-base64"
        )) { XCTAssertEqual(($0 as NSError).code, 1) }

        // Out-of-range offsets must read the current section before rejecting.
        XCTAssertThrowsError(try MetagentCore.projectAnalysisDetailPage(
            root: root.path, section: .instructions,
            cursor: makeDetailCursor(root: matching, section: .instructions, offset: 1),
            readInstructions: { _ in reads += 1; return [] }
        )) { XCTAssertEqual($0.localizedDescription, "detail cursor is beyond the available instructions items") }
        XCTAssertEqual(reads, 1)
    }

    func testDetailPagesMatchCompleteReportAcrossSectionsAndCanonicalRoots() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-detail-equivalence")
        let project = root.appendingPathComponent("project")
        let alias = root.appendingPathComponent("alias")
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        for name in ["item10", "item2", "item1"] {
            try writeSkillFixture(at: project.appendingPathComponent(".agents/skills/\(name)"))
        }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: project)
        let projection = project.appendingPathComponent(".claude/skills/item1")
        try FileManager.default.createDirectory(at: projection.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: projection, withDestinationURL: project.appendingPathComponent(".agents/skills/item1"))
        try Data("# Instructions\n".utf8).write(to: project.appendingPathComponent("AGENTS.md"))
        try FileManager.default.createDirectory(at: project.appendingPathComponent("Sources/Feature"), withIntermediateDirectories: true)
        try Data("# Nested\n".utf8).write(to: project.appendingPathComponent("Sources/Feature/AGENTS.md"))
        try Data("{\"mcpServers\":{\"local-a\":{},\"local-b\":{}}}".utf8).write(to: project.appendingPathComponent(".mcp.json"))
        try Data("{\"mcpServers\":{\"global-only\":{}}}".utf8).write(to: home.appendingPathComponent(".claude.json"))
        let codex = try makeCodexStub(in: root)
        let date = Date(timeIntervalSince1970: 1_000)
        let report = try MetagentCore.analyzeProject(root: alias.path, homeDirectory: home, codexExecutableOverride: codex, generatedAt: date)
        let expected: [ProjectAnalysisSection: [ProjectAnalysisDetailItem]] = [
            .instructions: report.instructions.map(ProjectAnalysisDetailItem.instruction),
            .skills: report.skills.projects.flatMap(\.skills).sorted().map(ProjectAnalysisDetailItem.skill),
            .doctor: report.doctor.issues.filter { $0.severity != .ok }.map(ProjectAnalysisDetailItem.doctor),
            .mcp: report.mcp.projectOnly(at: report.root).servers.map(ProjectAnalysisDetailItem.mcp),
            .usage: report.usage.summaries.map(ProjectAnalysisDetailItem.usage)
        ]

        for section in ProjectAnalysisSection.allCases {
            var cursor: String?
            var collected: [ProjectAnalysisDetailItem] = []
            repeat {
                let offset = collected.count
                let page = try MetagentCore.analyzeProjectDetails(
                    root: alias.path, section: section, cursor: cursor, limit: 1,
                    homeDirectory: home, codexExecutableOverride: codex, generatedAt: date
                )
                let allItems = try XCTUnwrap(expected[section])
                let end = min(offset + 1, allItems.count)
                let expectedPage = ProjectAnalysisDetailPage(
                    root: report.root, generatedAt: date, section: section,
                    items: Array(allItems[offset..<end]),
                    nextCursor: end < allItems.count
                        ? try makeDetailCursor(root: report.root, section: section, offset: end)
                        : nil
                )
                XCTAssertEqual(try normalizedPageJSON(page), try normalizedPageJSON(expectedPage))
                collected += page.items
                cursor = page.nextCursor
            } while cursor != nil
            XCTAssertEqual(collected, expected[section])
        }
    }

    func testDetailLimitClampsAndAcceptsCurrentEndOffset() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-detail-limit")
        let instructions = (0..<101).map {
            ProjectInstructionFile(path: "fixture-\($0)", kind: "agents", byteCount: Int64($0))
        }
        let small = try MetagentCore.projectAnalysisDetailPage(
            root: root.path, section: .instructions, limit: 0,
            readInstructions: { _ in instructions }
        )
        let large = try MetagentCore.projectAnalysisDetailPage(
            root: root.path, section: .instructions, limit: Int.max,
            readInstructions: { _ in instructions }
        )
        let end = try MetagentCore.projectAnalysisDetailPage(
            root: root.path, section: .instructions,
            cursor: makeDetailCursor(root: canonicalProjectPath(root), section: .instructions, offset: 101),
            readInstructions: { _ in instructions }
        )
        XCTAssertEqual(small.items, [ProjectAnalysisDetailItem.instruction(instructions[0])])
        XCTAssertEqual(large.items, Array(instructions.prefix(100)).map(ProjectAnalysisDetailItem.instruction))
        XCTAssertNotNil(small.nextCursor)
        XCTAssertNotNil(large.nextCursor)
        XCTAssertTrue(end.items.isEmpty)
        XCTAssertNil(end.nextCursor)
    }

    func testDetailSkillAndDoctorRequestsRereadSameSizeEditsAndProjectionChanges() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-detail-freshness")
        let skill = try writeSkillFixture(at: root.appendingPathComponent(".agents/skills/demo"), description: "First fixture")
        let other = try writeSkillFixture(at: root.appendingPathComponent("external/other"), description: "Other fixture")
        let projection = root.appendingPathComponent(".claude/skills/demo")
        try FileManager.default.createDirectory(at: projection.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: projection, withDestinationURL: skill)
        let manifest = skill.appendingPathComponent("SKILL.md")
        let text = try String(contentsOf: manifest, encoding: .utf8)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: manifest.path)
        let first = try MetagentCore.analyzeProjectDetails(root: root.path, section: .skills)

        let edited = text.replacingOccurrences(of: "First fixture", with: "Other fixture")
        XCTAssertEqual(edited.utf8.count, text.utf8.count)
        try edited.write(to: manifest, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: manifest.path)
        try FileManager.default.removeItem(at: projection)
        try FileManager.default.createSymbolicLink(at: projection, withDestinationURL: other)
        let later = try MetagentCore.analyzeProjectDetails(root: root.path, section: .skills)
        let doctor = try MetagentCore.analyzeProjectDetails(root: root.path, section: .doctor)
        let inventory = try MetagentCore.scanSkills(options: SkillScanOptions(roots: [canonicalProjectPath(root)], maxDepth: 0, respectConfiguredIgnores: false))
        XCTAssertNotEqual(first.items, later.items)
        XCTAssertEqual(later.items, inventory.projects.flatMap(\.skills).sorted().map(ProjectAnalysisDetailItem.skill))
        XCTAssertEqual(doctor.items, MetagentCore.doctor(projects: inventory.projects).issues.filter { $0.severity != .ok }.map(ProjectAnalysisDetailItem.doctor))
    }

    func testMCPDetailsReadCurrentConfigurationWhileOtherSectionsNeverQueryCodex() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-detail-mcp")
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let config = root.appendingPathComponent(".mcp.json")
        try Data("{\"mcpServers\":{\"first\":{}}}".utf8).write(to: config)
        let marker = root.appendingPathComponent("queries")
        let codex = root.appendingPathComponent("codex")
        try Data("#!/bin/sh\nprintf 'query\\n' >> '\(marker.path)'\nprintf '[]'\n".utf8).write(to: codex)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)
        for section in [ProjectAnalysisSection.instructions, .skills, .doctor, .usage] {
            _ = try MetagentCore.analyzeProjectDetails(root: root.path, section: section, homeDirectory: home, codexExecutableOverride: codex)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let first = try MetagentCore.analyzeProjectDetails(root: root.path, section: .mcp, homeDirectory: home, codexExecutableOverride: codex)
        try Data("{\"mcpServers\":{\"later\":{}}}".utf8).write(to: config)
        let later = try MetagentCore.analyzeProjectDetails(root: root.path, section: .mcp, homeDirectory: home, codexExecutableOverride: codex)
        XCTAssertEqual(first.items.compactMap { if case let .mcp(server) = $0 { server.name } else { nil } }, ["first"])
        XCTAssertEqual(later.items.compactMap { if case let .mcp(server) = $0 { server.name } else { nil } }, ["later"])
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "query\nquery\n")
    }

    func testUsageDetailsRereadUsageAndCurrentCanonicalProjectMembership() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-detail-usage")
        let project = root.appendingPathComponent("project")
        let item2 = try writeSkillFixture(at: project.appendingPathComponent(".agents/skills/item2"))
        let item10 = try writeSkillFixture(at: project.appendingPathComponent(".agents/skills/item10"))
        let external = try writeSkillFixture(at: root.appendingPathComponent("external/demo"))
        let replacement = try writeSkillFixture(at: root.appendingPathComponent("external/replacement"))
        let projection = project.appendingPathComponent(".claude/skills/demo")
        try FileManager.default.createDirectory(at: projection.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: projection, withDestinationURL: external)
        let first2 = usageSummary(name: "item2", path: canonicalProjectPath(item2), invocations: 5)
        let first10 = usageSummary(name: "item10", path: canonicalProjectPath(item10), invocations: 5)
        let projected = usageSummary(name: "external", path: canonicalProjectPath(external), invocations: 10)
        let replaced = usageSummary(name: "replacement", path: canonicalProjectPath(replacement), invocations: 20)
        let unrelated = usageSummary(name: "unrelated", path: canonicalProjectPath(root.appendingPathComponent("unrelated")), invocations: 100)
        let unidentified = usageSummary(name: "unidentified", path: nil, invocations: 100)
        var current = usageSnapshot([first10, unrelated, unidentified, replaced, first2, projected])
        var reads = 0
        let readUsage = { reads += 1; return Optional(current) }
        let first = try MetagentCore.projectAnalysisDetailPage(
            root: project.path, section: .usage, limit: 1, readUsage: readUsage
        )
        let second = try MetagentCore.projectAnalysisDetailPage(
            root: project.path, section: .usage, cursor: first.nextCursor, limit: 100, readUsage: readUsage
        )
        XCTAssertEqual(first.items, [.usage(projected)])
        XCTAssertEqual(second.items, [.usage(first2), .usage(first10)])
        XCTAssertNil(second.nextCursor)

        let updated2 = usageSummary(name: "item2", path: canonicalProjectPath(item2), invocations: 30)
        current = usageSnapshot([updated2, first10, projected, replaced, unrelated, unidentified])
        try FileManager.default.removeItem(at: projection)
        try FileManager.default.createSymbolicLink(at: projection, withDestinationURL: replacement)
        let later = try MetagentCore.projectAnalysisDetailPage(
            root: project.path, section: .usage, limit: 100, readUsage: readUsage
        )
        XCTAssertEqual(later.items, [.usage(updated2), .usage(replaced), .usage(first10)])
        XCTAssertEqual(reads, 3)
    }

    func testInstructionDetailsRereadCurrentFilesWithoutCrossRequestCache() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-detail-instructions")
        let instruction = root.appendingPathComponent("AGENTS.md")
        try Data("First\n".utf8).write(to: instruction)
        let first = try MetagentCore.analyzeProjectDetails(root: root.path, section: .instructions)
        try Data("Longer instructions\n".utf8).write(to: instruction)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        let nested = root.appendingPathComponent("Sources/AGENTS.md")
        try Data("Nested\n".utf8).write(to: nested)
        let later = try MetagentCore.analyzeProjectDetails(root: root.path, section: .instructions)
        XCTAssertEqual(first.items.count, 1)
        XCTAssertEqual(later.items, [
            .instruction(ProjectInstructionFile(path: canonicalProjectPath(instruction), kind: "agents", byteCount: 20)),
            .instruction(ProjectInstructionFile(path: canonicalProjectPath(nested), kind: "agents", byteCount: 7))
        ])
    }

    private func usageSummary(name: String, path: String?, invocations: Int) -> SkillUsageSummary {
        SkillUsageSummary(
            id: name, skillName: name, canonicalPath: path, scope: "project",
            totalInvocations: invocations + 1, invocations7d: 2, invocations30d: invocations,
            activeTurns: 3, distinctThreads: 4, repeatInvocations: 5,
            directInvocations: 6, inferredInvocations: 7,
            firstUsedAt: "2026-01-01T00:00:00Z", lastUsedAt: "2026-01-02T00:00:00Z"
        )
    }

    private func usageSnapshot(_ summaries: [SkillUsageSummary]) -> SkillUsageSnapshot {
        SkillUsageSnapshot(
            summaries: summaries, totalInvocations: 100, totalFiles: 2, completedFiles: 2,
            totalBytes: 200, processedBytes: 200, isBackfillComplete: true,
            isParserUpgradeBackfill: false, displayParserVersion: 1, targetParserVersion: 1,
            coverageStartedAt: "2026-01-01T00:00:00Z", lastUpdatedAt: "2026-01-02T00:00:00Z"
        )
    }

    private func makeDetailCursor(root: String, section: ProjectAnalysisSection, offset: Int = 0, version: Int = 1) throws -> String {
        try JSONSerialization.data(withJSONObject: [
            "version": version, "root": root, "section": section.rawValue, "offset": offset
        ]).base64EncodedString()
    }

    private func normalizedPageJSON(_ page: ProjectAnalysisDetailPage) throws -> NSDictionary {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: MetagentCore.encodeJSON(page)) as? [String: Any])
        if let cursor = page.nextCursor {
            let data = try XCTUnwrap(Data(base64Encoded: cursor))
            json["next_cursor"] = try JSONSerialization.jsonObject(with: data)
        }
        return json as NSDictionary
    }

    private func makeCodexStub(in root: URL) throws -> URL {
        let codex = root.appendingPathComponent("codex")
        try Data("#!/bin/sh\nprintf '[]'\n".utf8).write(to: codex)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)
        return codex
    }
}
