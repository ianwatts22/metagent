import Foundation
import Testing
@testable import MetagentCore

@Suite("Skill system health")
struct SkillSystemHealthTests {
    @Test("summarizes usage, tokens, age, and duplicate groups")
    func summarizesPortfolio() {
        let now = ISO8601DateFormatter().date(from: "2026-07-24T12:00:00Z")!
        let globalRoot = "/Users/tester"
        let projectRoot = "/Users/tester/code/sample"
        let projects = [
            project(
                root: globalRoot,
                skills: [
                    skill(
                        name: "alpha",
                        root: globalRoot,
                        scope: "global",
                        description: "Alpha helper",
                        bodyTokens: 100,
                        updatedAt: "2026-07-10T12:00:00Z"
                    ),
                    skill(
                        name: "shared",
                        root: globalRoot,
                        scope: "global",
                        description: "Shared helper",
                        bodyTokens: 200,
                        updatedAt: "2026-04-30T12:00:00Z"
                    ),
                ]
            ),
            project(
                root: projectRoot,
                skills: [
                    skill(
                        name: "beta",
                        root: projectRoot,
                        scope: "project",
                        description: nil,
                        bodyTokens: 300,
                        updatedAt: nil
                    ),
                    skill(
                        name: "shared",
                        root: projectRoot,
                        scope: "project",
                        description: "Shared project helper",
                        bodyTokens: 400,
                        updatedAt: "2025-12-18T12:00:00Z"
                    ),
                ]
            ),
        ]
        let usage = snapshot(
            summaries: [
                usageSummary(name: "alpha", path: "\(globalRoot)/.agents/skills/alpha", scope: "global", total: 1, last30d: 1),
                usageSummary(name: "shared", path: "\(globalRoot)/.agents/skills/shared", scope: "global", total: 4, last30d: 0),
                usageSummary(name: "shared", path: "\(projectRoot)/.agents/skills/shared", scope: "project", total: 20, last30d: 8),
            ],
            complete: true
        )

        let health = MetagentCore.skillSystemHealth(
            projects: projects,
            usage: usage,
            now: now
        )

        #expect(health.skillCount == 4)
        #expect(health.observedSkillCount == 3)
        #expect(health.active30dSkillCount == 2)
        #expect(health.neverObservedSkillCount == 1)
        #expect(health.usageCoverage == .complete)
        #expect(health.invocationDistribution == SkillInvocationDistribution(p50: 1, p75: 4, p95: 20))
        #expect(health.skillBodyTokenEstimate == 1_000)
        #expect(health.catalogTokenEstimate > 0)
        #expect(health.ageDistribution == SkillAgeDistribution(
            medianWeeks: 12,
            p75Weeks: 31,
            unknownCount: 1
        ))
        #expect(health.duplicateGroupCount == 1)
    }

    @Test("project scope excludes global skills")
    func projectScopeExcludesGlobalSkills() {
        let globalRoot = "/Users/tester"
        let projectRoot = "/Users/tester/code/sample"
        let projects = [
            project(root: globalRoot, skills: [
                skill(name: "global", root: globalRoot, scope: "global"),
            ]),
            project(root: projectRoot, skills: [
                skill(name: "local", root: projectRoot, scope: "project"),
                skill(name: "projection", root: projectRoot, scope: "project", representation: "projection"),
            ]),
        ]
        let usage = snapshot(summaries: [
            usageSummary(name: "global", path: "\(globalRoot)/.agents/skills/global", scope: "global", total: 50, last30d: 20),
            usageSummary(name: "local", path: "\(projectRoot)/.agents/skills/local", scope: "project", total: 2, last30d: 1),
        ])

        let health = MetagentCore.skillSystemHealth(
            projects: projects,
            usage: usage,
            scope: .project(root: projectRoot)
        )

        #expect(health.skillCount == 1)
        #expect(health.observedSkillCount == 1)
        #expect(health.invocationDistribution.p95 == 2)
        #expect(health.skillBodyTokenEstimate == 100)
    }

    @Test("global scope excludes project skills and reports partial coverage")
    func globalScopeExcludesProjects() {
        let globalRoot = "/Users/tester"
        let projectRoot = "/Users/tester/code/sample"
        let pluginRoot = "/Users/tester/.codex/plugins/cache/openai-curated/linear/1.0.0"
        let pluginPath = "\(pluginRoot)/skills/global"
        let projects = [
            project(root: globalRoot, skills: [
                skill(name: "global", root: globalRoot, scope: "global"),
            ]),
            project(root: projectRoot, skills: [
                skill(name: "local", root: projectRoot, scope: "project"),
            ]),
            SkillProject(
                root: pluginRoot,
                skillsDir: "\(pluginRoot)/skills",
                validSkills: ["global"],
                skills: [
                    pluginSkill(
                        name: "global",
                        path: pluginPath,
                        bodyTokens: 250
                    ),
                ]
            ),
        ]

        let health = MetagentCore.skillSystemHealth(
            projects: projects,
            usage: snapshot(
                summaries: [
                    usageSummary(
                        id: "plugin:openai-curated/linear:global",
                        name: "global",
                        path: pluginPath,
                        scope: "plugin",
                        total: 7,
                        last30d: 3
                    ),
                ],
                complete: false,
                totalBytes: 100,
                processedBytes: 40
            ),
            scope: .global(root: globalRoot)
        )

        #expect(health.skillCount == 2)
        #expect(health.observedSkillCount == 1)
        #expect(health.active30dSkillCount == 1)
        #expect(health.invocationDistribution.p95 == 7)
        #expect(health.skillBodyTokenEstimate == 350)
        #expect(health.duplicateGroupCount == 1)
        #expect(health.usageCoverage == .partial(progress: 0.4))
    }

    @Test("dormant project directories drop out of adoption rates but stay in inventory totals")
    func dormantProjectsAreNotRated() {
        let now = ISO8601DateFormatter().date(from: "2026-07-24T12:00:00Z")!
        let health = MetagentCore.skillSystemHealth(
            projects: dormancyProjects(),
            usage: dormancyUsage(),
            activity: dormancyActivity(now: now),
            now: now
        )

        #expect(health.skillCount == 4)
        #expect(health.assessedSkillCount == 2)
        #expect(health.dormantSkillCount == 2)
        #expect(health.dormantProjectCount == 1)
        #expect(health.active30dSkillCount == 1)
        #expect(health.unused30dSkillCount == 1)
        #expect(health.neverObservedSkillCount == 1)
        #expect(health.unused30dFraction == 0.5)
        // Token and age totals describe what is installed, not what is rated.
        #expect(health.skillBodyTokenEstimate == 400)
    }

    @Test("every skill stays rated when no session corpus is available")
    func missingActivityCorpusRatesEverything() {
        let now = ISO8601DateFormatter().date(from: "2026-07-24T12:00:00Z")!
        let health = MetagentCore.skillSystemHealth(
            projects: dormancyProjects(),
            usage: dormancyUsage(),
            activity: .unavailable,
            now: now
        )

        #expect(health.assessedSkillCount == 4)
        #expect(health.dormantSkillCount == 0)
        #expect(health.unused30dSkillCount == 3)
    }

    @Test("selecting a dormant directory still rates its own skills")
    func selectedProjectScopeIgnoresDormancy() {
        let now = ISO8601DateFormatter().date(from: "2026-07-24T12:00:00Z")!
        let health = MetagentCore.skillSystemHealth(
            projects: dormancyProjects(),
            usage: dormancyUsage(),
            scope: .project(root: "/Users/tester/code/dormant"),
            activity: dormancyActivity(now: now),
            now: now
        )

        #expect(health.skillCount == 2)
        #expect(health.assessedSkillCount == 2)
        #expect(health.dormantSkillCount == 0)
        #expect(health.unused30dSkillCount == 2)
    }

    @Test("session directory names fold separators, dots, and underscores")
    func sessionDirectoryNaming() {
        #expect(
            sessionDirectoryName(for: "/Users/tester/code_projects/agent-tools")
                == "-Users-tester-code-projects-agent-tools"
        )
        #expect(sessionDirectoryName(for: "/Users/tester/.agents") == "-Users-tester--agents")
    }

    private func dormancyProjects() -> [SkillProject] {
        let globalRoot = "/Users/tester"
        let activeRoot = "/Users/tester/code/active"
        let dormantRoot = "/Users/tester/code/dormant"
        return [
            project(root: globalRoot, skills: [
                skill(name: "alpha", root: globalRoot, scope: "global"),
            ]),
            project(root: activeRoot, skills: [
                skill(name: "beta", root: activeRoot, scope: "project"),
            ]),
            project(root: dormantRoot, skills: [
                skill(name: "gamma", root: dormantRoot, scope: "project"),
                skill(name: "delta", root: dormantRoot, scope: "project"),
            ]),
        ]
    }

    private func dormancyUsage() -> SkillUsageSnapshot {
        snapshot(
            summaries: [
                usageSummary(
                    name: "alpha",
                    path: "/Users/tester/.agents/skills/alpha",
                    scope: "global",
                    total: 5,
                    last30d: 2
                ),
            ],
            complete: true
        )
    }

    private func dormancyActivity(now: Date) -> ProjectActivityIndex {
        ProjectActivityIndex(
            lastActiveByRoot: [
                "/Users/tester": now,
                "/Users/tester/code/active": now.addingTimeInterval(-2 * 86_400),
                "/Users/tester/code/dormant": now.addingTimeInterval(-120 * 86_400),
            ],
            isAvailable: true
        )
    }

    private func project(root: String, skills: [SkillInventoryItem]) -> SkillProject {
        SkillProject(
            root: root,
            skillsDir: "\(root)/.agents/skills",
            validSkills: skills.map(\.name),
            skills: skills
        )
    }

    private func skill(
        name: String,
        root: String,
        scope: String,
        description: String? = "A useful skill",
        bodyTokens: Int = 100,
        updatedAt: String? = "2026-07-17T12:00:00Z",
        representation: String = "canonical"
    ) -> SkillInventoryItem {
        let kind = scope == "global" ? "user-local" : "project-local"
        return .fixture(
            name: name,
            description: description,
            path: "\(root)/.agents/skills/\(name)",
            originKind: kind,
            scope: scope,
            authority: "local",
            representation: representation,
            updatedAt: updatedAt,
            folderKind: kind,
            characterCount: bodyTokens * 4,
            wordCount: bodyTokens,
            tokenEstimate: bodyTokens
        )
    }

    private func usageSummary(
        id: String? = nil,
        name: String,
        path: String,
        scope: String,
        total: Int,
        last30d: Int
    ) -> SkillUsageSummary {
        SkillUsageSummary(
            id: id ?? "\(scope):\(name)",
            skillName: name,
            canonicalPath: path,
            scope: scope,
            totalInvocations: total,
            invocations7d: last30d,
            invocations30d: last30d,
            activeTurns: total,
            distinctThreads: total,
            repeatInvocations: 0,
            directInvocations: total,
            inferredInvocations: 0,
            firstUsedAt: "2026-01-01T00:00:00Z",
            lastUsedAt: "2026-07-24T00:00:00Z"
        )
    }

    private func pluginSkill(
        name: String,
        path: String,
        bodyTokens: Int
    ) -> SkillInventoryItem {
        .fixture(
            name: name,
            description: "Plugin-provided helper",
            path: path,
            location: "plugin",
            locationLabel: "Codex plugin",
            originKind: "codex-plugin",
            scope: "plugin",
            manager: "codex-plugin",
            authority: "openai-curated/linear",
            mutability: "managed-read-only",
            representation: "versioned-cache",
            source: "openai-curated/linear",
            sourceType: "codex-marketplace",
            ref: "1.0.0",
            updatedAt: "2026-07-17T12:00:00Z",
            folderKind: "managed",
            characterCount: bodyTokens * 4,
            wordCount: bodyTokens,
            tokenEstimate: bodyTokens
        )
    }

    private func snapshot(
        summaries: [SkillUsageSummary],
        complete: Bool = true,
        totalBytes: Int64 = 100,
        processedBytes: Int64 = 100
    ) -> SkillUsageSnapshot {
        SkillUsageSnapshot(
            summaries: summaries,
            totalInvocations: summaries.reduce(0) { $0 + $1.totalInvocations },
            totalFiles: 1,
            completedFiles: complete ? 1 : 0,
            totalBytes: totalBytes,
            processedBytes: processedBytes,
            isBackfillComplete: complete,
            isParserUpgradeBackfill: false,
            displayParserVersion: 15,
            targetParserVersion: 15,
            coverageStartedAt: "2026-01-01T00:00:00Z",
            lastUpdatedAt: "2026-07-24T00:00:00Z"
        )
    }
}
