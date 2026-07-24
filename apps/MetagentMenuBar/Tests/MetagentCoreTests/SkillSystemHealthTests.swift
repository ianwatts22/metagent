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
        let projects = [
            project(root: globalRoot, skills: [
                skill(name: "global", root: globalRoot, scope: "global"),
            ]),
            project(root: projectRoot, skills: [
                skill(name: "local", root: projectRoot, scope: "project"),
            ]),
        ]

        let health = MetagentCore.skillSystemHealth(
            projects: projects,
            usage: snapshot(
                summaries: [],
                complete: false,
                totalBytes: 100,
                processedBytes: 40
            ),
            scope: .global(root: globalRoot)
        )

        #expect(health.skillCount == 1)
        #expect(health.usageCoverage == .partial(progress: 0.4))
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
        let path = "\(root)/.agents/skills/\(name)"
        return SkillInventoryItem(
            name: name,
            description: description,
            path: path,
            location: "agents",
            locationLabel: ".agents",
            originKind: scope == "global" ? "user-local" : "project-local",
            scope: scope,
            manager: "local",
            authority: "local",
            mutability: "editable",
            representation: representation,
            canonicalPath: path,
            source: nil,
            sourceType: nil,
            sourceURL: nil,
            ref: nil,
            installedAt: nil,
            updatedAt: updatedAt,
            symlinkedContainer: false,
            folderKind: scope == "global" ? "user-local" : "project-local",
            characterCount: bodyTokens * 4,
            wordCount: bodyTokens,
            tokenEstimate: bodyTokens,
            skillFileCharacterCount: bodyTokens * 4,
            skillFileWordCount: bodyTokens,
            skillFileTokenEstimate: bodyTokens,
            textFileCount: 1,
            referenceFileCount: 0,
            scriptFileCount: 0,
            assetFileCount: 0,
            otherFileCount: 0,
            otherFolderCount: 0,
            hasOpenAIYaml: false,
            hasIconSmall: false,
            hasIconLarge: false,
            hasIconAndLogo: false,
            iconSmallPath: nil,
            iconLargePath: nil
        )
    }

    private func usageSummary(
        name: String,
        path: String,
        scope: String,
        total: Int,
        last30d: Int
    ) -> SkillUsageSummary {
        SkillUsageSummary(
            id: "\(scope):\(name)",
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
