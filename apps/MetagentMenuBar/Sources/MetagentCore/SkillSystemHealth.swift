import Foundation

public enum SkillSystemHealthScope: Sendable, Equatable {
    case all
    case global(root: String)
    case project(root: String)
}

public enum SkillUsageCoverage: Sendable, Equatable {
    case complete
    case updating(progress: Double)
    case partial(progress: Double)
    case unavailable
}

public struct SkillInvocationDistribution: Sendable, Equatable {
    public let p50: Int
    public let p75: Int
    public let p95: Int

    public init(p50: Int, p75: Int, p95: Int) {
        self.p50 = p50
        self.p75 = p75
        self.p95 = p95
    }
}

public struct SkillAgeDistribution: Sendable, Equatable {
    public let medianWeeks: Int?
    public let p75Weeks: Int?
    public let unknownCount: Int

    public init(medianWeeks: Int?, p75Weeks: Int?, unknownCount: Int) {
        self.medianWeeks = medianWeeks
        self.p75Weeks = p75Weeks
        self.unknownCount = unknownCount
    }
}

public struct SkillSystemHealth: Sendable, Equatable {
    public let skillCount: Int
    public let observedSkillCount: Int
    public let active30dSkillCount: Int
    public let neverObservedSkillCount: Int
    public let usageCoverage: SkillUsageCoverage
    public let invocationDistribution: SkillInvocationDistribution
    public let skillBodyTokenEstimate: Int
    public let catalogTokenEstimate: Int
    public let ageDistribution: SkillAgeDistribution
    public let duplicateGroupCount: Int

    public init(
        skillCount: Int,
        observedSkillCount: Int,
        active30dSkillCount: Int,
        neverObservedSkillCount: Int,
        usageCoverage: SkillUsageCoverage,
        invocationDistribution: SkillInvocationDistribution,
        skillBodyTokenEstimate: Int,
        catalogTokenEstimate: Int,
        ageDistribution: SkillAgeDistribution,
        duplicateGroupCount: Int
    ) {
        self.skillCount = skillCount
        self.observedSkillCount = observedSkillCount
        self.active30dSkillCount = active30dSkillCount
        self.neverObservedSkillCount = neverObservedSkillCount
        self.usageCoverage = usageCoverage
        self.invocationDistribution = invocationDistribution
        self.skillBodyTokenEstimate = skillBodyTokenEstimate
        self.catalogTokenEstimate = catalogTokenEstimate
        self.ageDistribution = ageDistribution
        self.duplicateGroupCount = duplicateGroupCount
    }

    public static let empty = SkillSystemHealth(
        skillCount: 0,
        observedSkillCount: 0,
        active30dSkillCount: 0,
        neverObservedSkillCount: 0,
        usageCoverage: .unavailable,
        invocationDistribution: SkillInvocationDistribution(p50: 0, p75: 0, p95: 0),
        skillBodyTokenEstimate: 0,
        catalogTokenEstimate: 0,
        ageDistribution: SkillAgeDistribution(medianWeeks: nil, p75Weeks: nil, unknownCount: 0),
        duplicateGroupCount: 0
    )

    public var observedFraction: Double {
        guard skillCount > 0 else { return 0 }
        return Double(observedSkillCount) / Double(skillCount)
    }
}

public extension MetagentCore {
    static func skillSystemHealth(
        projects: [SkillProject],
        usage: SkillUsageSnapshot,
        scope: SkillSystemHealthScope = .all,
        now: Date = Date()
    ) -> SkillSystemHealth {
        let scopedSkills = canonicalHealthSkills(projects: projects, scope: scope)
        let usageByPath = Dictionary(
            usage.summaries.compactMap { summary -> (String, SkillUsageSummary)? in
                guard let path = summary.canonicalPath else { return nil }
                return (standardizedHealthPath(path), summary)
            },
            uniquingKeysWith: preferredUsageSummary
        )
        let usageByPlugin = Dictionary(
            usage.summaries.compactMap { summary in
                pluginHealthIdentity(id: summary.id, path: summary.canonicalPath).map { ($0, summary) }
            },
            uniquingKeysWith: preferredUsageSummary
        )

        let matchedUsage = scopedSkills.map { skill -> SkillUsageSummary? in
            let path = standardizedHealthPath(
                skill.canonicalPath.isEmpty ? skill.path : skill.canonicalPath
            )
            return usageByPath[path]
                ?? pluginHealthIdentity(skill: skill).flatMap { usageByPlugin[$0] }
        }
        let invocationCounts = matchedUsage.map { $0?.totalInvocations ?? 0 }
        let knownAges = scopedSkills.compactMap { skill -> Int? in
            guard let updatedAt = skill.updatedAt,
                  let updatedDate = parseHealthDate(updatedAt)
            else { return nil }
            let days = Calendar.current.dateComponents([.day], from: updatedDate, to: now).day ?? 0
            return max(0, days) / 7
        }
        let overlaps = detectSkillOverlaps(scopedSkills)

        return SkillSystemHealth(
            skillCount: scopedSkills.count,
            observedSkillCount: matchedUsage.count { ($0?.totalInvocations ?? 0) > 0 },
            active30dSkillCount: matchedUsage.count { ($0?.invocations30d ?? 0) > 0 },
            neverObservedSkillCount: matchedUsage.count { ($0?.totalInvocations ?? 0) == 0 },
            usageCoverage: healthCoverage(usage),
            invocationDistribution: SkillInvocationDistribution(
                p50: nearestRank(invocationCounts, percentile: 0.50) ?? 0,
                p75: nearestRank(invocationCounts, percentile: 0.75) ?? 0,
                p95: nearestRank(invocationCounts, percentile: 0.95) ?? 0
            ),
            skillBodyTokenEstimate: scopedSkills.reduce(0) { $0 + max(0, $1.skillFileTokenEstimate) },
            catalogTokenEstimate: scopedSkills.reduce(0) { total, skill in
                total + estimatedCatalogTokens(name: skill.name, description: skill.description)
            },
            ageDistribution: SkillAgeDistribution(
                medianWeeks: nearestRank(knownAges, percentile: 0.50),
                p75Weeks: nearestRank(knownAges, percentile: 0.75),
                unknownCount: scopedSkills.count - knownAges.count
            ),
            duplicateGroupCount: overlaps.count
        )
    }
}

private func canonicalHealthSkills(
    projects: [SkillProject],
    scope: SkillSystemHealthScope
) -> [SkillInventoryItem] {
    let filtered = projects.flatMap { project in
        project.skills.filter { skill in
            guard skill.representation != "projection" else { return false }
            switch scope {
            case .all:
                return true
            case let .global(root):
                return standardizedHealthPath(project.root) == standardizedHealthPath(root)
                    && skill.scope != "project"
            case let .project(root):
                return standardizedHealthPath(project.root) == standardizedHealthPath(root)
                    && skill.scope == "project"
            }
        }
    }

    return Dictionary(
        filtered.map { skill in
            let path = skill.canonicalPath.isEmpty ? skill.path : skill.canonicalPath
            return (standardizedHealthPath(path), skill)
        },
        uniquingKeysWith: preferredHealthSkill
    )
    .values
    .sorted()
}

private func preferredHealthSkill(
    _ left: SkillInventoryItem,
    _ right: SkillInventoryItem
) -> SkillInventoryItem {
    let priority = ["canonical": 0, "versioned-cache": 1, "projection": 2]
    return priority[left.representation, default: 3] <= priority[right.representation, default: 3]
        ? left
        : right
}

private func preferredUsageSummary(
    _ left: SkillUsageSummary,
    _ right: SkillUsageSummary
) -> SkillUsageSummary {
    left.totalInvocations >= right.totalInvocations ? left : right
}

private func healthCoverage(_ usage: SkillUsageSnapshot) -> SkillUsageCoverage {
    guard usage.totalFiles > 0 else { return .unavailable }
    if usage.isBackfillComplete { return .complete }
    let progress = usage.totalBytes > 0
        ? min(1, max(0, Double(usage.processedBytes) / Double(usage.totalBytes)))
        : 0
    return usage.isParserUpgradeBackfill
        ? .updating(progress: progress)
        : .partial(progress: progress)
}

private func nearestRank(_ values: [Int], percentile: Double) -> Int? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let rank = max(1, Int(ceil(percentile * Double(sorted.count))))
    return sorted[min(sorted.count - 1, rank - 1)]
}

private func estimatedCatalogTokens(name: String, description: String?) -> Int {
    let text = [name, description]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    guard !text.isEmpty else { return 0 }
    return max(1, Int(ceil(Double(text.count) / 4)))
}

private func standardizedHealthPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
}

private func parseHealthDate(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
}

private func pluginHealthIdentity(skill: SkillInventoryItem) -> String? {
    guard skill.location == "plugin" else { return nil }
    return pluginHealthIdentity(path: skill.canonicalPath)?.key
}

private func pluginHealthIdentity(id: String, path: String?) -> String? {
    guard let path, let pathIdentity = pluginHealthIdentity(path: path) else { return nil }
    let parts = id.split(separator: ":", maxSplits: 2).map(String.init)
    guard parts.count == 3, parts[0] == "plugin", parts[2] == pathIdentity.skill else {
        return nil
    }
    return [pathIdentity.owner, pathIdentity.plugin].contains(parts[1])
        ? pathIdentity.key
        : nil
}

private func pluginHealthIdentity(
    path: String
) -> (owner: String, plugin: String, skill: String, key: String)? {
    let url = URL(fileURLWithPath: path)
    let components = url.pathComponents
    guard let skillsIndex = components.lastIndex(of: "skills"),
          skillsIndex >= 4,
          components[skillsIndex - 4] == "cache"
    else { return nil }
    let marketplace = MetagentCore.normalizedPluginMarketplace(components[skillsIndex - 3])
    let plugin = components[skillsIndex - 2]
    let skill = url.lastPathComponent
    let owner = "\(marketplace)/\(plugin)"
    return (owner, plugin, skill, "\(owner):\(skill)")
}
