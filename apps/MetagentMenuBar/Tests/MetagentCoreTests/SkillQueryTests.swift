import Foundation
import XCTest
@testable import MetagentCore

final class SkillQueryTests: XCTestCase {

    // MARK: - Projections

    func testProjectionsAreExcludedByDefaultAndIncludedOnRequest() throws {
        let projects = [
            makeProject(root: "/fixtures/app", skills: [
                .fixture(name: "alpha", path: "/fixtures/app/.agents/skills/alpha"),
                .fixture(
                    name: "alpha",
                    path: "/fixtures/app/.claude/skills/alpha",
                    location: "claude",
                    representation: "projection"
                )
            ])
        ]

        let canonicalOnly = try page(projects: projects, options: makeOptions())
        let withProjections = try page(
            projects: projects,
            options: makeOptions(includeProjections: true)
        )

        XCTAssertEqual(canonicalOnly.totalCount, 1)
        XCTAssertEqual(canonicalOnly.items.map(\.locationLabel), [".agents"])
        XCTAssertFalse(canonicalOnly.includesProjections)
        XCTAssertEqual(withProjections.totalCount, 2)
        XCTAssertTrue(withProjections.includesProjections)
    }

    // MARK: - Sorting

    func testNameSortIsCaseInsensitiveAndReversesWithOrder() throws {
        let projects = [
            makeProject(root: "/fixtures/app", skills: [
                .fixture(name: "Bravo", path: "/fixtures/app/.agents/skills/bravo"),
                .fixture(name: "alpha", path: "/fixtures/app/.agents/skills/alpha"),
                .fixture(name: "charlie", path: "/fixtures/app/.agents/skills/charlie")
            ])
        ]

        let ascending = try page(projects: projects, options: makeOptions())
        let descending = try page(
            projects: projects,
            options: makeOptions(sortOrder: .descending)
        )

        XCTAssertEqual(ascending.items.map(\.name), ["alpha", "Bravo", "charlie"])
        XCTAssertEqual(descending.items.map(\.name), ["charlie", "Bravo", "alpha"])
    }

    func testNumericSortKeysOrderResultsInBothDirections() throws {
        let projects = [makeProject(root: "/fixtures/app", skills: [
            .fixture(name: "alpha", path: "/fixtures/app/.agents/skills/alpha", tokenEstimate: 10),
            .fixture(name: "bravo", path: "/fixtures/app/.agents/skills/bravo", tokenEstimate: 300),
            .fixture(name: "charlie", path: "/fixtures/app/.agents/skills/charlie", tokenEstimate: 50)
        ])]
        let usage = makeUsageSnapshot([
            makeUsage(name: "alpha", path: "/fixtures/app/.agents/skills/alpha", total: 9, in7d: 1, in30d: 4),
            makeUsage(name: "bravo", path: "/fixtures/app/.agents/skills/bravo", total: 2, in7d: 2, in30d: 2),
            makeUsage(name: "charlie", path: "/fixtures/app/.agents/skills/charlie", total: 40, in7d: 0, in30d: 7)
        ])

        let byTokens = try page(
            projects: projects,
            options: makeOptions(sortKey: .tokenEstimate, sortOrder: .descending)
        )
        XCTAssertEqual(byTokens.items.map(\.tokenEstimate), [300, 50, 10])

        let byTotal = try page(
            projects: projects,
            usage: usage,
            options: makeOptions(sortKey: .totalInvocations, sortOrder: .descending)
        )
        XCTAssertEqual(byTotal.items.map(\.name), ["charlie", "alpha", "bravo"])

        let by30d = try page(
            projects: projects,
            usage: usage,
            options: makeOptions(sortKey: .invocations30d, sortOrder: .ascending)
        )
        XCTAssertEqual(by30d.items.map(\.invocations30d), [2, 4, 7])

        let by7d = try page(
            projects: projects,
            usage: usage,
            options: makeOptions(sortKey: .invocations7d, sortOrder: .descending)
        )
        XCTAssertEqual(by7d.items.map(\.invocations7d), [2, 1, 0])

        let byScore = try page(
            projects: projects,
            usage: usage,
            options: makeOptions(sortKey: .score, sortOrder: .descending)
        )
        let scores = byScore.items.compactMap(\.score)
        XCTAssertEqual(scores.count, 3)
        XCTAssertEqual(scores, scores.sorted(by: >))
    }

    func testTimestampSortKeysPlaceMissingValuesFirstWhenAscending() throws {
        let projects = [makeProject(root: "/fixtures/app", skills: [
            .fixture(
                name: "alpha",
                path: "/fixtures/app/.agents/skills/alpha",
                updatedAt: "2026-05-01T00:00:00Z"
            ),
            .fixture(name: "bravo", path: "/fixtures/app/.agents/skills/bravo", updatedAt: nil),
            .fixture(
                name: "charlie",
                path: "/fixtures/app/.agents/skills/charlie",
                updatedAt: "2026-06-01T00:00:00Z"
            )
        ])]
        let usage = makeUsageSnapshot([
            makeUsage(
                name: "alpha",
                path: "/fixtures/app/.agents/skills/alpha",
                total: 1,
                lastUsedAt: "2026-01-02T00:00:00Z"
            ),
            makeUsage(
                name: "charlie",
                path: "/fixtures/app/.agents/skills/charlie",
                total: 1,
                lastUsedAt: "2026-03-02T00:00:00Z"
            )
        ])

        let byUpdated = try page(
            projects: projects,
            options: makeOptions(sortKey: .updatedAt, sortOrder: .ascending)
        )
        XCTAssertEqual(byUpdated.items.map(\.name), ["bravo", "alpha", "charlie"])

        let byLastUsed = try page(
            projects: projects,
            usage: usage,
            options: makeOptions(sortKey: .lastUsedAt, sortOrder: .descending)
        )
        XCTAssertEqual(byLastUsed.items.map(\.name), ["charlie", "alpha", "bravo"])
    }

    func testTiesBreakOnNameThenPathRegardlessOfSortOrder() throws {
        let skills: [SkillInventoryItem] = [
            .fixture(name: "shared", path: "/fixtures/app/.agents/skills/z-shared", tokenEstimate: 7),
            .fixture(name: "shared", path: "/fixtures/app/.agents/skills/a-shared", tokenEstimate: 7),
            .fixture(name: "another", path: "/fixtures/app/.agents/skills/another", tokenEstimate: 7)
        ]
        let forward = [makeProject(root: "/fixtures/app", skills: skills)]
        let reversed = [makeProject(root: "/fixtures/app", skills: skills.reversed())]

        for order in SkillQuerySortOrder.allCases {
            let options = makeOptions(sortKey: .tokenEstimate, sortOrder: order)
            let first = try page(projects: forward, options: options)
            let second = try page(projects: reversed, options: options)
            XCTAssertEqual(first.items.map(\.path), second.items.map(\.path))
            XCTAssertEqual(
                first.items.map(\.path),
                [
                    "/fixtures/app/.agents/skills/another",
                    "/fixtures/app/.agents/skills/a-shared",
                    "/fixtures/app/.agents/skills/z-shared"
                ]
            )
        }
    }

    // MARK: - Pagination

    func testCursorPaginationCoversEveryResultExactlyOnce() throws {
        let skills = (0..<7).map { index in
            SkillInventoryItem.fixture(
                name: "skill-\(index)",
                path: "/fixtures/app/.agents/skills/skill-\(index)"
            )
        }
        let projects = [makeProject(root: "/fixtures/app", skills: skills)]

        var options = makeOptions(limit: 3)
        var collected: [String] = []
        var pages = 0
        while true {
            let result = try page(projects: projects, options: options)
            XCTAssertEqual(result.totalCount, 7)
            XCTAssertEqual(result.returnedCount, result.items.count)
            collected.append(contentsOf: result.items.map(\.name))
            pages += 1
            guard let next = result.nextCursor else {
                XCTAssertFalse(result.truncated)
                break
            }
            XCTAssertTrue(result.truncated)
            options.cursor = next
            XCTAssertLessThan(pages, 10)
        }

        XCTAssertEqual(pages, 3)
        XCTAssertEqual(collected, skills.map(\.name).sorted())
        XCTAssertEqual(Set(collected).count, collected.count)
    }

    func testTotalCountReflectsFilteringBeforePagination() throws {
        let projects = [makeProject(root: "/fixtures/app", skills: [
            .fixture(name: "keep-one", path: "/fixtures/app/.agents/skills/keep-one"),
            .fixture(name: "keep-two", path: "/fixtures/app/.agents/skills/keep-two"),
            .fixture(name: "drop", path: "/fixtures/app/.agents/skills/drop")
        ])]

        let result = try page(
            projects: projects,
            options: makeOptions(nameContains: "keep", limit: 1)
        )

        XCTAssertEqual(result.totalCount, 2)
        XCTAssertEqual(result.items.count, 1)
        XCTAssertNotNil(result.nextCursor)
    }

    func testCursorIsRejectedWhenTheSortChanges() throws {
        let projects = [makeProject(root: "/fixtures/app", skills: [
            .fixture(name: "alpha", path: "/fixtures/app/.agents/skills/alpha"),
            .fixture(name: "bravo", path: "/fixtures/app/.agents/skills/bravo")
        ])]
        let first = try page(projects: projects, options: makeOptions(limit: 1))
        let cursor = try XCTUnwrap(first.nextCursor)

        XCTAssertThrowsError(
            try page(
                projects: projects,
                options: makeOptions(sortKey: .score, limit: 1, cursor: cursor)
            )
        )
        XCTAssertThrowsError(
            try page(projects: projects, options: makeOptions(limit: 1, cursor: "not-base64"))
        )
    }

    func testLimitIsClampedToTheSupportedRange() {
        XCTAssertEqual(makeOptions(limit: 0).boundedLimit, 1)
        XCTAssertEqual(makeOptions(limit: -5).boundedLimit, 1)
        XCTAssertEqual(makeOptions(limit: 5_000).boundedLimit, 200)
        XCTAssertEqual(makeOptions().boundedLimit, 50)
    }

    // MARK: - Filters

    func testNameContainsMatchesNameOrDescriptionCaseInsensitively() throws {
        let projects = [makeProject(root: "/fixtures/app", skills: [
            .fixture(name: "Deploy", description: "ship it", path: "/fixtures/app/.agents/skills/deploy"),
            .fixture(name: "notes", description: "DEPLOYMENT helper", path: "/fixtures/app/.agents/skills/notes"),
            .fixture(name: "other", description: "unrelated", path: "/fixtures/app/.agents/skills/other")
        ])]

        let result = try page(projects: projects, options: makeOptions(nameContains: "deploy"))

        XCTAssertEqual(result.items.map(\.name), ["Deploy", "notes"])
    }

    func testManagerMutabilityLocationAndScopeFiltersAreAnded() throws {
        let projects = [makeProject(root: "/fixtures/app", skills: [
            .fixture(
                name: "alpha",
                path: "/fixtures/app/.agents/skills/alpha",
                manager: "local",
                mutability: "editable"
            ),
            .fixture(
                name: "bravo",
                path: "/fixtures/app/.agents/skills/bravo",
                manager: "codex-plugin",
                mutability: "managed-read-only"
            ),
            .fixture(
                name: "charlie",
                path: "/fixtures/app/.claude/skills/charlie",
                location: "claude",
                locationLabel: ".claude",
                scope: "global",
                manager: "local",
                mutability: "editable"
            )
        ])]

        XCTAssertEqual(
            try page(projects: projects, options: makeOptions(managers: ["local"]))
                .items.map(\.name),
            ["alpha", "charlie"]
        )
        XCTAssertEqual(
            try page(projects: projects, options: makeOptions(mutabilities: ["managed-read-only"]))
                .items.map(\.name),
            ["bravo"]
        )
        XCTAssertEqual(
            try page(projects: projects, options: makeOptions(locations: ["claude"]))
                .items.map(\.name),
            ["charlie"]
        )
        XCTAssertEqual(
            try page(
                projects: projects,
                options: makeOptions(managers: ["local"], scopes: ["project"])
            ).items.map(\.name),
            ["alpha"]
        )
    }

    func testUnusedOnlyAndUsedWithinDaysUseJoinedUsage() throws {
        let projects = [makeProject(root: "/fixtures/app", skills: [
            .fixture(name: "alpha", path: "/fixtures/app/.agents/skills/alpha"),
            .fixture(name: "bravo", path: "/fixtures/app/.agents/skills/bravo"),
            .fixture(name: "charlie", path: "/fixtures/app/.agents/skills/charlie")
        ])]
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let recent = ISO8601DateFormatter().string(from: now.addingTimeInterval(-2 * 86_400))
        let stale = ISO8601DateFormatter().string(from: now.addingTimeInterval(-90 * 86_400))
        let usage = makeUsageSnapshot([
            makeUsage(
                name: "alpha",
                path: "/fixtures/app/.agents/skills/alpha",
                total: 5,
                lastUsedAt: recent
            ),
            makeUsage(
                name: "bravo",
                path: "/fixtures/app/.agents/skills/bravo",
                total: 3,
                lastUsedAt: stale
            )
        ])

        XCTAssertEqual(
            try page(projects: projects, usage: usage, options: makeOptions(unusedOnly: true), now: now)
                .items.map(\.name),
            ["charlie"]
        )
        XCTAssertEqual(
            try page(
                projects: projects,
                usage: usage,
                options: makeOptions(usedWithinDays: 7),
                now: now
            ).items.map(\.name),
            ["alpha"]
        )
    }

    func testMissingUsageIsReportedAsZeroRatherThanNil() throws {
        let projects = [makeProject(root: "/fixtures/app", skills: [
            .fixture(name: "alpha", path: "/fixtures/app/.agents/skills/alpha")
        ])]

        let item = try XCTUnwrap(try page(projects: projects, options: makeOptions()).items.first)

        XCTAssertEqual(item.totalInvocations, 0)
        XCTAssertEqual(item.invocations7d, 0)
        XCTAssertEqual(item.invocations30d, 0)
        XCTAssertNil(item.lastUsedAt)
    }

    func testMinScoreKeepsOnlySkillsAtOrAboveTheThreshold() throws {
        let projects = [makeProject(root: "/fixtures/app", skills: [
            .fixture(
                name: "rich",
                description: "A thorough description of when to use this skill.",
                path: "/fixtures/app/.agents/skills/rich",
                manager: "local",
                authority: "user",
                updatedAt: "2026-05-01T00:00:00Z"
            ),
            .fixture(name: "bare", description: nil, path: "/fixtures/app/.agents/skills/bare")
        ])]

        let all = try page(projects: projects, options: makeOptions(sortKey: .score, sortOrder: .descending))
        let scores = all.items.compactMap(\.score)
        XCTAssertEqual(scores.count, 2)
        let threshold = try XCTUnwrap(scores.first)
        XCTAssertGreaterThan(threshold, try XCTUnwrap(scores.last))

        let filtered = try page(projects: projects, options: makeOptions(minScore: threshold))
        XCTAssertEqual(filtered.totalCount, 1)
        XCTAssertEqual(filtered.items.map(\.name), ["rich"])
    }

    // MARK: - Payload shape

    func testDescriptionsAreOmittedFromTheJSONWhenNotRequested() throws {
        let projects = [makeProject(root: "/fixtures/app", skills: [
            .fixture(
                name: "alpha",
                description: "a long description that should disappear",
                path: "/fixtures/app/.agents/skills/alpha"
            )
        ])]

        let withDescriptions = try page(projects: projects, options: makeOptions())
        let withoutDescriptions = try page(
            projects: projects,
            options: makeOptions(includeDescriptions: false)
        )
        let compact = try XCTUnwrap(
            String(data: MetagentCore.encodeJSON(withoutDescriptions), encoding: .utf8)
        )

        XCTAssertNotNil(withDescriptions.items.first?.description)
        XCTAssertNil(withoutDescriptions.items.first?.description)
        XCTAssertFalse(compact.contains("\"description\""))
        XCTAssertTrue(compact.contains("\"location_label\""))
        XCTAssertTrue(compact.contains("\"invocations_30d\""))
    }

    // MARK: - Scanning integration

    func testProjectScopeQueryReadsSkillsFromDisk() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-skill-query")
        try writeSkillFixture(
            at: root.appendingPathComponent(".agents/skills/alpha"),
            name: "alpha",
            description: "First skill"
        )
        try writeSkillFixture(
            at: root.appendingPathComponent(".agents/skills/bravo"),
            name: "bravo",
            description: "Second skill"
        )

        let result = try MetagentCore.querySkills(
            options: SkillQueryOptions(scope: .project(root: root.path))
        )

        XCTAssertEqual(result.items.map(\.name), ["alpha", "bravo"])
        XCTAssertEqual(result.totalCount, 2)
        XCTAssertEqual(result.scope, .project(root: root.resolvingSymlinksInPath().path))
    }

    func testProjectScopeQueryRejectsAMissingRoot() {
        XCTAssertThrowsError(
            try MetagentCore.querySkills(
                options: SkillQueryOptions(scope: .project(root: "/fixtures/does-not-exist"))
            )
        )
    }

    // MARK: - Duplicates

    func testDuplicateDetectionGroupsSameNamedSkills() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-skill-query-dupes")
        let body = "Use this workflow to inspect a project and verify the result."
        let global = try writeSkillFixture(
            at: root.appendingPathComponent("home/.agents/skills/demo"),
            name: "demo",
            body: body
        )
        let project = try writeSkillFixture(
            at: root.appendingPathComponent("app/.agents/skills/demo"),
            name: "demo",
            body: body
        )
        try writeSkillFixture(
            at: root.appendingPathComponent("app/.agents/skills/solo"),
            name: "solo",
            body: body
        )

        let report = MetagentCore.duplicateReport(
            scope: .global,
            projects: [
                makeProject(root: root.appendingPathComponent("home").path, skills: [
                    .fixture(name: "demo", path: global.path, scope: "global")
                ]),
                makeProject(root: root.appendingPathComponent("app").path, skills: [
                    .fixture(name: "demo", path: project.path, scope: "project"),
                    .fixture(name: "solo", path: root.appendingPathComponent("app/.agents/skills/solo").path)
                ])
            ],
            generatedAt: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(report.groupCount, 1)
        let group = try XCTUnwrap(report.groups.first)
        XCTAssertEqual(group.skillName, "demo")
        XCTAssertEqual(group.kind, .globalProject)
        XCTAssertEqual(Set(group.members.map(\.scope)), ["global", "project"])
        XCTAssertEqual(Set(group.members.map(\.name)), ["demo"])
        XCTAssertEqual(Set(group.members.map(\.mutability)), ["editable"])
        XCTAssertTrue(group.members.allSatisfy { $0.projectRoot != nil })
        XCTAssertFalse(group.members.contains { $0.suggestedRemoval })
    }

    // MARK: - Detail

    func testSkillDetailTruncatesLongBodiesAndReportsTheFullLength() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-skill-detail")
        let body = String(repeating: "abcdefghij", count: 400)
        let directory = try writeSkillFixture(
            at: root.appendingPathComponent(".agents/skills/demo"),
            name: "demo",
            description: "Demo skill",
            body: body
        )

        let truncated = try MetagentCore.getSkillDetail(
            path: directory.path,
            maxBodyCharacters: 120
        )
        let full = try MetagentCore.getSkillDetail(path: directory.path)
        let withoutBody = try MetagentCore.getSkillDetail(
            path: directory.appendingPathComponent("SKILL.md").path,
            includeBody: false
        )

        XCTAssertEqual(truncated.name, "demo")
        XCTAssertEqual(truncated.description, "Demo skill")
        XCTAssertEqual(truncated.bodyCharacterCount, body.count)
        XCTAssertTrue(truncated.bodyTruncated)
        XCTAssertEqual(truncated.body?.count, 120)
        XCTAssertFalse(full.bodyTruncated)
        XCTAssertEqual(full.body?.count, body.count)
        XCTAssertNil(withoutBody.body)
        XCTAssertFalse(withoutBody.bodyTruncated)
        XCTAssertEqual(withoutBody.bodyCharacterCount, body.count)
        XCTAssertEqual(withoutBody.path, directory.path)
    }

    func testSkillDetailIncludesInventoryProvenanceAndSize() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-skill-detail-meta")
        let directory = try writeSkillFixture(
            at: root.appendingPathComponent(".agents/skills/demo"),
            name: "demo",
            description: "Demo skill",
            body: "Body text."
        )

        let detail = try MetagentCore.getSkillDetail(path: directory.path)

        XCTAssertEqual(detail.projectRoot, root.resolvingSymlinksInPath().path)
        XCTAssertEqual(detail.scope, "project")
        XCTAssertEqual(detail.locationLabel, ".agents")
        XCTAssertEqual(detail.provenance?.representation, "canonical")
        XCTAssertEqual(detail.provenance?.mutability, "editable")
        XCTAssertNotNil(detail.score)
        XCTAssertNotNil(detail.grade)
        XCTAssertGreaterThan(detail.size?.characterCount ?? 0, 0)
    }

    func testSkillDetailRejectsPathsThatAreNotSkills() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-skill-detail-invalid")
        XCTAssertThrowsError(try MetagentCore.getSkillDetail(path: root.path))
        XCTAssertThrowsError(
            try MetagentCore.getSkillDetail(path: root.appendingPathComponent("missing").path)
        )
    }

    // MARK: - Helpers

    private func page(
        projects: [SkillProject],
        usage: SkillUsageSnapshot = .empty,
        options: SkillQueryOptions,
        now: Date = Date(timeIntervalSince1970: 1_780_000_000)
    ) throws -> SkillQueryPage {
        try MetagentCore.querySkills(
            options: options,
            scope: options.scope,
            projects: projects,
            usage: usage,
            now: now
        )
    }

    private func makeOptions(
        includeProjections: Bool = false,
        nameContains: String? = nil,
        managers: Set<String>? = nil,
        mutabilities: Set<String>? = nil,
        locations: Set<String>? = nil,
        scopes: Set<String>? = nil,
        minScore: Int? = nil,
        unusedOnly: Bool = false,
        usedWithinDays: Int? = nil,
        sortKey: SkillQuerySortKey = .name,
        sortOrder: SkillQuerySortOrder = .ascending,
        limit: Int = SkillQueryOptions.defaultLimit,
        cursor: String? = nil,
        includeDescriptions: Bool = true
    ) -> SkillQueryOptions {
        SkillQueryOptions(
            scope: .project(root: "/fixtures/app"),
            includeProjections: includeProjections,
            nameContains: nameContains,
            managers: managers,
            mutabilities: mutabilities,
            locations: locations,
            scopes: scopes,
            minScore: minScore,
            unusedOnly: unusedOnly,
            usedWithinDays: usedWithinDays,
            sortKey: sortKey,
            sortOrder: sortOrder,
            limit: limit,
            cursor: cursor,
            includeDescriptions: includeDescriptions
        )
    }

    private func makeProject(root: String, skills: [SkillInventoryItem]) -> SkillProject {
        SkillProject(
            root: root,
            skillsDir: root + "/.agents/skills",
            validSkills: skills.map(\.name).sorted(),
            skills: skills
        )
    }

    private func makeUsage(
        name: String,
        path: String,
        scope: String = "project",
        total: Int = 0,
        in7d: Int = 0,
        in30d: Int = 0,
        lastUsedAt: String = "2026-01-01T00:00:00Z"
    ) -> SkillUsageSummary {
        SkillUsageSummary(
            id: "project:\(path):\(name)",
            skillName: name,
            canonicalPath: path,
            scope: scope,
            totalInvocations: total,
            invocations7d: in7d,
            invocations30d: in30d,
            activeTurns: total,
            distinctThreads: total,
            repeatInvocations: 0,
            directInvocations: total,
            inferredInvocations: 0,
            firstUsedAt: "2026-01-01T00:00:00Z",
            lastUsedAt: lastUsedAt
        )
    }

    private func makeUsageSnapshot(_ summaries: [SkillUsageSummary]) -> SkillUsageSnapshot {
        SkillUsageSnapshot(
            summaries: summaries,
            totalInvocations: summaries.reduce(0) { $0 + $1.totalInvocations },
            totalFiles: 1,
            completedFiles: 1,
            totalBytes: 1,
            processedBytes: 1,
            isBackfillComplete: true,
            isParserUpgradeBackfill: false,
            displayParserVersion: 1,
            targetParserVersion: 1,
            coverageStartedAt: "2026-01-01T00:00:00Z",
            lastUpdatedAt: "2026-07-01T00:00:00Z"
        )
    }
}
