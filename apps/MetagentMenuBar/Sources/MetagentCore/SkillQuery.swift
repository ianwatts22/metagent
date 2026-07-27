import Foundation

// MARK: - Scope

public enum SkillQueryScope: Equatable, Hashable, Sendable {
    case project(root: String)
    case global

    /// Stable identity used by pagination cursors and report headers.
    public var key: String {
        switch self {
        case let .project(root): "project:\(root)"
        case .global: "global"
        }
    }
}

extension SkillQueryScope: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case root
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "project":
            self = .project(root: try container.decode(String.self, forKey: .root))
        case "global":
            self = .global
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "unknown skill query scope: \(other)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .project(root):
            try container.encode("project", forKey: .kind)
            try container.encode(root, forKey: .root)
        case .global:
            try container.encode("global", forKey: .kind)
        }
    }
}

// MARK: - Sorting

public enum SkillQuerySortKey: String, Codable, CaseIterable, Sendable {
    case name
    case score
    case invocations30d = "invocations_30d"
    case invocations7d = "invocations_7d"
    case totalInvocations = "total_invocations"
    case lastUsedAt = "last_used_at"
    case updatedAt = "updated_at"
    case tokenEstimate = "token_estimate"
}

public enum SkillQuerySortOrder: String, Codable, CaseIterable, Sendable {
    case ascending
    case descending
}

// MARK: - Options

public struct SkillQueryOptions: Equatable, Sendable {
    public static let defaultLimit = 50
    public static let maximumLimit = 200

    public var scope: SkillQueryScope
    public var includeProjections: Bool
    public var nameContains: String?
    public var managers: Set<String>?
    public var mutabilities: Set<String>?
    public var locations: Set<String>?
    public var scopes: Set<String>?
    public var minScore: Int?
    public var unusedOnly: Bool
    public var usedWithinDays: Int?
    public var sortKey: SkillQuerySortKey
    public var sortOrder: SkillQuerySortOrder
    public var limit: Int
    public var cursor: String?
    public var includeDescriptions: Bool

    public init(
        scope: SkillQueryScope = .global,
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
    ) {
        self.scope = scope
        self.includeProjections = includeProjections
        self.nameContains = nameContains
        self.managers = managers
        self.mutabilities = mutabilities
        self.locations = locations
        self.scopes = scopes
        self.minScore = minScore
        self.unusedOnly = unusedOnly
        self.usedWithinDays = usedWithinDays
        self.sortKey = sortKey
        self.sortOrder = sortOrder
        self.limit = limit
        self.cursor = cursor
        self.includeDescriptions = includeDescriptions
    }

    var boundedLimit: Int {
        min(max(limit, 1), Self.maximumLimit)
    }
}

// MARK: - Compact records

public struct SkillQueryItem: Codable, Equatable, Sendable {
    public let name: String
    public let description: String?
    public let path: String
    public let projectRoot: String
    public let scope: String
    public let locationLabel: String
    public let manager: String
    public let mutability: String
    public let score: Int?
    public let grade: String?
    public let invocations30d: Int
    public let invocations7d: Int
    public let totalInvocations: Int
    public let lastUsedAt: String?
    public let updatedAt: String?
    public let tokenEstimate: Int

    public init(
        name: String,
        description: String?,
        path: String,
        projectRoot: String,
        scope: String,
        locationLabel: String,
        manager: String,
        mutability: String,
        score: Int?,
        grade: String?,
        invocations30d: Int,
        invocations7d: Int,
        totalInvocations: Int,
        lastUsedAt: String?,
        updatedAt: String?,
        tokenEstimate: Int
    ) {
        self.name = name
        self.description = description
        self.path = path
        self.projectRoot = projectRoot
        self.scope = scope
        self.locationLabel = locationLabel
        self.manager = manager
        self.mutability = mutability
        self.score = score
        self.grade = grade
        self.invocations30d = invocations30d
        self.invocations7d = invocations7d
        self.totalInvocations = totalInvocations
        self.lastUsedAt = lastUsedAt
        self.updatedAt = updatedAt
        self.tokenEstimate = tokenEstimate
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case path
        case projectRoot = "project_root"
        case scope
        case locationLabel = "location_label"
        case manager
        case mutability
        case score
        case grade
        case invocations30d = "invocations_30d"
        case invocations7d = "invocations_7d"
        case totalInvocations = "total_invocations"
        case lastUsedAt = "last_used_at"
        case updatedAt = "updated_at"
        case tokenEstimate = "token_estimate"
    }
}

public struct SkillQueryPage: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let scope: SkillQueryScope
    public let generatedAt: Date
    public let sortKey: SkillQuerySortKey
    public let sortOrder: SkillQuerySortOrder
    public let items: [SkillQueryItem]
    public let totalCount: Int
    public let returnedCount: Int
    public let truncated: Bool
    public let nextCursor: String?
    public let includesDescriptions: Bool
    public let includesProjections: Bool
    public let warnings: [String]

    public init(
        scope: SkillQueryScope,
        generatedAt: Date,
        sortKey: SkillQuerySortKey,
        sortOrder: SkillQuerySortOrder,
        items: [SkillQueryItem],
        totalCount: Int,
        nextCursor: String?,
        includesDescriptions: Bool,
        includesProjections: Bool,
        warnings: [String]
    ) {
        self.schemaVersion = Self.schemaVersion
        self.scope = scope
        self.generatedAt = generatedAt
        self.sortKey = sortKey
        self.sortOrder = sortOrder
        self.items = items
        self.totalCount = totalCount
        self.returnedCount = items.count
        self.truncated = nextCursor != nil
        self.nextCursor = nextCursor
        self.includesDescriptions = includesDescriptions
        self.includesProjections = includesProjections
        self.warnings = warnings
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case scope
        case generatedAt = "generated_at"
        case sortKey = "sort_key"
        case sortOrder = "sort_order"
        case items
        case totalCount = "total_count"
        case returnedCount = "returned_count"
        case truncated
        case nextCursor = "next_cursor"
        case includesDescriptions = "includes_descriptions"
        case includesProjections = "includes_projections"
        case warnings
    }
}

// MARK: - Duplicate report

public struct SkillDuplicateMember: Codable, Equatable, Sendable {
    public let name: String
    public let path: String
    public let projectRoot: String?
    public let scope: String
    public let manager: String
    public let mutability: String
    public let suggestedRemoval: Bool

    private enum CodingKeys: String, CodingKey {
        case name
        case path
        case projectRoot = "project_root"
        case scope
        case manager
        case mutability
        case suggestedRemoval = "suggested_removal"
    }
}

public struct SkillDuplicateGroup: Codable, Equatable, Sendable {
    public let kind: SkillOverlapKind
    public let similarity: Double
    public let skillName: String
    public let members: [SkillDuplicateMember]

    private enum CodingKeys: String, CodingKey {
        case kind
        case similarity
        case skillName = "skill_name"
        case members
    }
}

public struct SkillDuplicateReport: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let scope: SkillQueryScope
    public let generatedAt: Date
    public let groupCount: Int
    public let groups: [SkillDuplicateGroup]

    public init(scope: SkillQueryScope, generatedAt: Date, groups: [SkillDuplicateGroup]) {
        self.schemaVersion = Self.schemaVersion
        self.scope = scope
        self.generatedAt = generatedAt
        self.groupCount = groups.count
        self.groups = groups
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case scope
        case generatedAt = "generated_at"
        case groupCount = "group_count"
        case groups
    }
}

// MARK: - Detail

public struct SkillDetailMetadataEntry: Codable, Equatable, Sendable {
    public let key: String
    public let value: String
}

public struct SkillDetailProvenance: Codable, Equatable, Sendable {
    public let manager: String
    public let authority: String
    public let mutability: String
    public let representation: String
    public let source: String?
    public let sourceType: String?
    public let updatedAt: String?

    private enum CodingKeys: String, CodingKey {
        case manager
        case authority
        case mutability
        case representation
        case source
        case sourceType = "source_type"
        case updatedAt = "updated_at"
    }
}

public struct SkillDetailSize: Codable, Equatable, Sendable {
    public let characterCount: Int
    public let wordCount: Int
    public let tokenEstimate: Int
    public let skillFileCharacterCount: Int
    public let skillFileTokenEstimate: Int
    public let textFileCount: Int
    public let referenceFileCount: Int
    public let scriptFileCount: Int
    public let assetFileCount: Int

    private enum CodingKeys: String, CodingKey {
        case characterCount = "character_count"
        case wordCount = "word_count"
        case tokenEstimate = "token_estimate"
        case skillFileCharacterCount = "skill_file_character_count"
        case skillFileTokenEstimate = "skill_file_token_estimate"
        case textFileCount = "text_file_count"
        case referenceFileCount = "reference_file_count"
        case scriptFileCount = "script_file_count"
        case assetFileCount = "asset_file_count"
    }
}

public struct SkillDetailUsage: Codable, Equatable, Sendable {
    public let totalInvocations: Int
    public let invocations7d: Int
    public let invocations30d: Int
    public let distinctThreads: Int
    public let firstUsedAt: String?
    public let lastUsedAt: String?

    private enum CodingKeys: String, CodingKey {
        case totalInvocations = "total_invocations"
        case invocations7d = "invocations_7d"
        case invocations30d = "invocations_30d"
        case distinctThreads = "distinct_threads"
        case firstUsedAt = "first_used_at"
        case lastUsedAt = "last_used_at"
    }
}

public struct SkillDetail: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let path: String
    public let projectRoot: String?
    public let name: String
    public let description: String?
    public let scope: String?
    public let locationLabel: String?
    public let metadata: [SkillDetailMetadataEntry]
    public let body: String?
    public let bodyTruncated: Bool
    public let bodyCharacterCount: Int
    public let provenance: SkillDetailProvenance?
    public let size: SkillDetailSize?
    public let usage: SkillDetailUsage?
    public let score: Int?
    public let grade: String?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case path
        case projectRoot = "project_root"
        case name
        case description
        case scope
        case locationLabel = "location_label"
        case metadata
        case body
        case bodyTruncated = "body_truncated"
        case bodyCharacterCount = "body_character_count"
        case provenance
        case size
        case usage
        case score
        case grade
    }
}

// MARK: - Query API

public extension MetagentCore {
    static func querySkills(
        options: SkillQueryOptions,
        now: Date = Date()
    ) throws -> SkillQueryPage {
        let scan = try scanSkillQueryScope(options.scope)
        return try querySkills(
            options: options,
            scope: scan.scope,
            projects: scan.report.projects,
            usage: loadSkillUsageSnapshot() ?? .empty,
            warnings: scan.report.warnings,
            now: now
        )
    }

    static func findDuplicateSkills(
        scope: SkillQueryScope,
        generatedAt: Date = Date()
    ) throws -> SkillDuplicateReport {
        let scan = try scanSkillQueryScope(scope)
        return duplicateReport(
            scope: scan.scope,
            projects: scan.report.projects,
            generatedAt: generatedAt
        )
    }

    static func getSkillDetail(
        path: String,
        includeBody: Bool = true,
        maxBodyCharacters: Int = 20_000,
        now: Date = Date()
    ) throws -> SkillDetail {
        let directory = try resolveSkillDirectory(path)
        let document = try loadSkillDocument(at: directory.path)

        var projectRoot: String?
        var match: SkillInventoryItem?
        var variants: [SkillInventoryItem] = []
        if let root = inferredSkillProjectRoot(directory) {
            let report = try? scanSkills(
                options: SkillScanOptions(
                    roots: [root.path],
                    maxDepth: 0,
                    respectConfiguredIgnores: false
                )
            )
            let flattened = (report?.projects ?? []).flatMap { project in
                project.skills.map { (project.root, $0) }
            }
            if let hit = flattened.first(where: { skillDirectoriesMatch($0.1, directory) }) {
                projectRoot = hit.0
                match = hit.1
                variants = flattened.map(\.1).filter { $0.name == hit.1.name }
            }
        }

        let usageSnapshot = loadSkillUsageSnapshot() ?? .empty
        let index = SkillUsageIndex(snapshot: usageSnapshot)
        let summary = match.flatMap { index.summary(for: $0) }
            ?? index.summary(forCanonicalPath: directory.path)
        let score = match.map {
            scoreSkill(
                $0,
                variants: variants.isEmpty ? [$0] : variants,
                usage: summary,
                usageCoverageComplete: usageSnapshot.isBackfillComplete,
                now: now
            )
        }

        let bodyLimit = max(0, maxBodyCharacters)
        let fullBody = document.bodyMarkdown
        let truncated = includeBody && fullBody.count > bodyLimit

        return SkillDetail(
            schemaVersion: SkillDetail.schemaVersion,
            path: directory.path,
            projectRoot: projectRoot,
            name: document.name,
            description: document.description,
            scope: match?.scope,
            locationLabel: match?.locationLabel,
            metadata: document.metadata.map {
                SkillDetailMetadataEntry(key: $0.key, value: $0.value)
            },
            body: includeBody ? String(fullBody.prefix(bodyLimit)) : nil,
            bodyTruncated: truncated,
            bodyCharacterCount: fullBody.count,
            provenance: match.map {
                SkillDetailProvenance(
                    manager: $0.manager,
                    authority: $0.authority,
                    mutability: $0.mutability,
                    representation: $0.representation,
                    source: $0.source,
                    sourceType: $0.sourceType,
                    updatedAt: $0.updatedAt
                )
            },
            size: match.map {
                SkillDetailSize(
                    characterCount: $0.characterCount,
                    wordCount: $0.wordCount,
                    tokenEstimate: $0.tokenEstimate,
                    skillFileCharacterCount: $0.skillFileCharacterCount,
                    skillFileTokenEstimate: $0.skillFileTokenEstimate,
                    textFileCount: $0.textFileCount,
                    referenceFileCount: $0.referenceFileCount,
                    scriptFileCount: $0.scriptFileCount,
                    assetFileCount: $0.assetFileCount
                )
            },
            usage: summary.map {
                SkillDetailUsage(
                    totalInvocations: $0.totalInvocations,
                    invocations7d: $0.invocations7d,
                    invocations30d: $0.invocations30d,
                    distinctThreads: $0.distinctThreads,
                    firstUsedAt: $0.firstUsedAt,
                    lastUsedAt: $0.lastUsedAt
                )
            },
            score: score?.score,
            grade: score?.grade.rawValue
        )
    }
}

// MARK: - Composition

extension MetagentCore {
    static func querySkills(
        options: SkillQueryOptions,
        scope: SkillQueryScope,
        projects: [SkillProject],
        usage: SkillUsageSnapshot,
        warnings: [String] = [],
        now: Date = Date()
    ) throws -> SkillQueryPage {
        let flattened = projects.flatMap { project in
            project.skills.map { (root: project.root, skill: $0) }
        }
        let variantsByName = Dictionary(grouping: flattened.map(\.skill), by: \.name)
        let index = SkillUsageIndex(snapshot: usage)

        let scored: [ScoredSkill] = flattened
            .filter { options.includeProjections || $0.skill.representation != "projection" }
            .map { entry in
                let summary = index.summary(for: entry.skill)
                return ScoredSkill(
                    projectRoot: entry.root,
                    skill: entry.skill,
                    usage: summary,
                    score: scoreSkill(
                        entry.skill,
                        variants: variantsByName[entry.skill.name] ?? [entry.skill],
                        usage: summary,
                        usageCoverageComplete: usage.isBackfillComplete,
                        now: now
                    )
                )
            }

        let filtered = scored.filter { matchesSkillQueryFilters($0, options: options, now: now) }
        let sorted = sortedSkillQueryResults(filtered, options: options)

        let offset = try skillQueryOffset(options: options, scope: scope)
        guard offset <= sorted.count else {
            throw skillQueryError("skill query cursor is beyond the available results")
        }
        let end = min(offset + options.boundedLimit, sorted.count)
        let nextCursor = end < sorted.count
            ? skillQueryCursor(options: options, scope: scope, offset: end)
            : nil

        return SkillQueryPage(
            scope: scope,
            generatedAt: now,
            sortKey: options.sortKey,
            sortOrder: options.sortOrder,
            items: sorted[offset..<end].map {
                $0.item(includeDescription: options.includeDescriptions)
            },
            totalCount: sorted.count,
            nextCursor: nextCursor,
            includesDescriptions: options.includeDescriptions,
            includesProjections: options.includeProjections,
            warnings: warnings
        )
    }

    static func duplicateReport(
        scope: SkillQueryScope,
        projects: [SkillProject],
        generatedAt: Date
    ) -> SkillDuplicateReport {
        let flattened = projects.flatMap { project in
            project.skills.map { (root: project.root, skill: $0) }
        }
        var byPath: [String: (root: String, skill: SkillInventoryItem)] = [:]
        for entry in flattened {
            let key = canonicalExistingPath(
                entry.skill.canonicalPath.isEmpty ? entry.skill.path : entry.skill.canonicalPath
            )
            if byPath[key] == nil { byPath[key] = entry }
        }

        let groups = detectSkillOverlaps(flattened.map(\.skill)).map { group in
            SkillDuplicateGroup(
                kind: group.kind,
                similarity: group.similarity,
                skillName: group.skillName,
                members: group.members.map { member in
                    let matched = byPath[canonicalExistingPath(member.canonicalPath)]
                    return SkillDuplicateMember(
                        name: matched?.skill.name ?? group.skillName,
                        path: matched?.skill.path ?? member.canonicalPath,
                        projectRoot: matched?.root,
                        scope: member.scope,
                        manager: member.manager,
                        mutability: matched?.skill.mutability ?? "unknown",
                        suggestedRemoval: member.suggestedRemoval
                    )
                }
            )
        }

        return SkillDuplicateReport(scope: scope, generatedAt: generatedAt, groups: groups)
    }

    private static func scanSkillQueryScope(
        _ scope: SkillQueryScope
    ) throws -> (scope: SkillQueryScope, report: SkillScanReport) {
        switch scope {
        case .global:
            return (.global, try scanPortfolio())
        case let .project(root):
            let resolved = try resolveSkillQueryRoot(root)
            let report = try scanSkills(
                options: SkillScanOptions(
                    roots: [resolved.path],
                    maxDepth: 0,
                    respectConfiguredIgnores: false
                )
            )
            return (.project(root: resolved.path), report)
        }
    }
}

// MARK: - Filtering, sorting, pagination

struct ScoredSkill {
    let projectRoot: String
    let skill: SkillInventoryItem
    let usage: SkillUsageSummary?
    let score: MetagentSkillScore

    var totalInvocations: Int { usage?.totalInvocations ?? 0 }
    var invocations7d: Int { usage?.invocations7d ?? 0 }
    var invocations30d: Int { usage?.invocations30d ?? 0 }
    var lastUsedAt: String? { usage?.lastUsedAt }

    func item(includeDescription: Bool) -> SkillQueryItem {
        SkillQueryItem(
            name: skill.name,
            description: includeDescription ? skill.description : nil,
            path: skill.path,
            projectRoot: projectRoot,
            scope: skill.scope,
            locationLabel: skill.locationLabel,
            manager: skill.manager,
            mutability: skill.mutability,
            score: score.score,
            grade: score.grade.rawValue,
            invocations30d: invocations30d,
            invocations7d: invocations7d,
            totalInvocations: totalInvocations,
            lastUsedAt: lastUsedAt,
            updatedAt: skill.updatedAt,
            tokenEstimate: skill.tokenEstimate
        )
    }
}

private func matchesSkillQueryFilters(
    _ entry: ScoredSkill,
    options: SkillQueryOptions,
    now: Date
) -> Bool {
    if let needle = options.nameContains?.trimmingCharacters(in: .whitespacesAndNewlines),
       !needle.isEmpty {
        let matchesName = entry.skill.name.localizedCaseInsensitiveContains(needle)
        let matchesDescription = entry.skill.description?
            .localizedCaseInsensitiveContains(needle) ?? false
        if !matchesName, !matchesDescription { return false }
    }
    if let managers = options.managers, !managers.contains(entry.skill.manager) { return false }
    if let mutabilities = options.mutabilities,
       !mutabilities.contains(entry.skill.mutability) { return false }
    if let locations = options.locations, !locations.contains(entry.skill.location) { return false }
    if let scopes = options.scopes, !scopes.contains(entry.skill.scope) { return false }
    if let minScore = options.minScore, entry.score.score < minScore { return false }
    if options.unusedOnly, entry.totalInvocations != 0 { return false }
    if let days = options.usedWithinDays {
        guard let lastUsedAt = entry.lastUsedAt,
              let date = MetagentCore.parseSkillUsageTimestamp(lastUsedAt),
              now.timeIntervalSince(date) <= Double(max(0, days)) * 86_400
        else { return false }
    }
    return true
}

private func sortedSkillQueryResults(
    _ entries: [ScoredSkill],
    options: SkillQueryOptions
) -> [ScoredSkill] {
    entries.sorted { left, right in
        let comparison = compareSkillQueryPrimary(left, right, key: options.sortKey)
        if comparison != .orderedSame {
            return options.sortOrder == .ascending
                ? comparison == .orderedAscending
                : comparison == .orderedDescending
        }
        // Deterministic tie-break, independent of the requested sort order.
        let names = left.skill.name.localizedCaseInsensitiveCompare(right.skill.name)
        if names != .orderedSame { return names == .orderedAscending }
        return left.skill.path < right.skill.path
    }
}

private func compareSkillQueryPrimary(
    _ left: ScoredSkill,
    _ right: ScoredSkill,
    key: SkillQuerySortKey
) -> ComparisonResult {
    switch key {
    case .name:
        left.skill.name.localizedCaseInsensitiveCompare(right.skill.name)
    case .score:
        compareQueryValues(left.score.score, right.score.score)
    case .invocations30d:
        compareQueryValues(left.invocations30d, right.invocations30d)
    case .invocations7d:
        compareQueryValues(left.invocations7d, right.invocations7d)
    case .totalInvocations:
        compareQueryValues(left.totalInvocations, right.totalInvocations)
    case .lastUsedAt:
        compareQueryValues(
            skillQueryTimestamp(left.lastUsedAt),
            skillQueryTimestamp(right.lastUsedAt)
        )
    case .updatedAt:
        compareQueryValues(
            skillQueryTimestamp(left.skill.updatedAt),
            skillQueryTimestamp(right.skill.updatedAt)
        )
    case .tokenEstimate:
        compareQueryValues(left.skill.tokenEstimate, right.skill.tokenEstimate)
    }
}

private func compareQueryValues<T: Comparable>(_ left: T, _ right: T) -> ComparisonResult {
    if left < right { return .orderedAscending }
    if left > right { return .orderedDescending }
    return .orderedSame
}

private func skillQueryTimestamp(_ value: String?) -> Date {
    guard let value, let date = MetagentCore.parseSkillUsageTimestamp(value) else {
        return .distantPast
    }
    return date
}

private struct SkillQueryCursor: Codable {
    let version: Int
    let scope: String
    let sortKey: SkillQuerySortKey
    let sortOrder: SkillQuerySortOrder
    let offset: Int
}

private extension MetagentCore {
    static func skillQueryCursor(
        options: SkillQueryOptions,
        scope: SkillQueryScope,
        offset: Int
    ) -> String {
        let cursor = SkillQueryCursor(
            version: 1,
            scope: scope.key,
            sortKey: options.sortKey,
            sortOrder: options.sortOrder,
            offset: offset
        )
        return (try? JSONEncoder().encode(cursor).base64EncodedString()) ?? ""
    }

    static func skillQueryOffset(
        options: SkillQueryOptions,
        scope: SkillQueryScope
    ) throws -> Int {
        guard let cursor = options.cursor else { return 0 }
        guard let data = Data(base64Encoded: cursor),
              let decoded = try? JSONDecoder().decode(SkillQueryCursor.self, from: data)
        else {
            throw skillQueryError("invalid skill query cursor")
        }
        guard decoded.version == 1,
              decoded.scope == scope.key,
              decoded.sortKey == options.sortKey,
              decoded.sortOrder == options.sortOrder,
              decoded.offset >= 0
        else {
            throw skillQueryError("skill query cursor does not match the requested scope and sort")
        }
        return decoded.offset
    }
}

// MARK: - Usage joins

struct SkillUsageIndex {
    private let byCanonicalPath: [String: SkillUsageSummary]
    private let byIdentity: [String: SkillUsageSummary]

    init(snapshot: SkillUsageSnapshot) {
        byCanonicalPath = Dictionary(
            grouping: snapshot.summaries.compactMap { summary -> (String, SkillUsageSummary)? in
                guard let canonicalPath = summary.canonicalPath, !canonicalPath.isEmpty else {
                    return nil
                }
                return (canonicalExistingPath(canonicalPath), summary)
            },
            by: \.0
        ).compactMapValues { values in
            values.map(\.1).max { $0.totalInvocations < $1.totalInvocations }
        }
        byIdentity = Dictionary(
            grouping: snapshot.summaries,
            by: { "\($0.skillName):\($0.scope)" }
        ).compactMapValues { values in
            values.max { $0.totalInvocations < $1.totalInvocations }
        }
    }

    func summary(for skill: SkillInventoryItem) -> SkillUsageSummary? {
        let path = skill.canonicalPath.isEmpty ? skill.path : skill.canonicalPath
        return byCanonicalPath[canonicalExistingPath(path)]
            ?? byIdentity["\(skill.name):\(skill.scope)"]
    }

    func summary(forCanonicalPath path: String) -> SkillUsageSummary? {
        byCanonicalPath[canonicalExistingPath(path)]
    }
}

private func skillDirectoriesMatch(_ skill: SkillInventoryItem, _ directory: URL) -> Bool {
    let target = canonicalExistingPath(directory.path)
    if canonicalExistingPath(skill.path) == target { return true }
    return !skill.canonicalPath.isEmpty && canonicalExistingPath(skill.canonicalPath) == target
}

private func inferredSkillProjectRoot(_ skillDirectory: URL) -> URL? {
    var current = skillDirectory
    while current.pathComponents.count > 1 {
        let parent = current.deletingLastPathComponent()
        if agentDirectoryNames.contains(current.lastPathComponent) {
            return parent.standardizedFileURL
        }
        current = parent
    }
    return nil
}

extension MetagentCore {
    static func resolveSkillQueryRoot(_ root: String) throws -> URL {
        let url = expandPath(root).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw skillQueryError("project root is not a readable directory: \(url.path)")
        }
        return url
    }

    static func resolveSkillDirectory(_ path: String) throws -> URL {
        let expanded = expandPath(path).standardizedFileURL
        let directory = expanded.lastPathComponent == "SKILL.md"
            ? expanded.deletingLastPathComponent()
            : expanded
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw skillQueryError("skill path is not a readable directory: \(directory.path)")
        }
        guard isRegularOrSymlinkedFile(directory.appendingPathComponent("SKILL.md")) else {
            throw skillQueryError("no readable SKILL.md at \(directory.path)")
        }
        return directory
    }

    static func skillQueryError(_ message: String, code: Int = 1) -> NSError {
        NSError(domain: "MetagentSkillQuery", code: code, userInfo: [
            NSLocalizedDescriptionKey: message
        ])
    }
}
