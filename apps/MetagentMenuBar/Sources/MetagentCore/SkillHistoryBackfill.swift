import Foundation

/// What the one-time reconstruction recovered, and what it could not.
public struct SkillHistoryBackfillReport: Sendable, Equatable {
    public let daysWritten: Int
    public let installEvents: Int
    public let removalEvents: Int
    public let earliestDay: String?
    public let usageCoverageStartsAt: String?
    public let skipped: Bool
    public let warnings: [String]

    public init(
        daysWritten: Int,
        installEvents: Int,
        removalEvents: Int,
        earliestDay: String?,
        usageCoverageStartsAt: String?,
        skipped: Bool,
        warnings: [String]
    ) {
        self.daysWritten = daysWritten
        self.installEvents = installEvents
        self.removalEvents = removalEvents
        self.earliestDay = earliestDay
        self.usageCoverageStartsAt = usageCoverageStartsAt
        self.skipped = skipped
        self.warnings = warnings
    }
}

/// One skill's reconstructed lifetime, assembled from filesystem and archive
/// evidence rather than from anything the app watched happen.
struct ReconstructedSkill: Sendable, Equatable {
    let key: String
    let name: String
    let scope: String
    let installedOn: String
    let removedOn: String?
}

private let historyBackfillVersion = 1
private let historyBackfillVersionKey = "backfill_version"
private let historyBackfillWindowDays = 400

public extension MetagentCore {
    /// Reconstructs history that predates capture from the three stores that
    /// already carry timestamps: canonical directory creation dates, the removal
    /// archive, and the usage event log.
    ///
    /// Everything written here is `inferred`. Metrics that describe content or
    /// configuration — tokens, scores, duplicates, Doctor, MCP — are deliberately
    /// absent for those days, because they were never recorded and guessing them
    /// would be worse than a gap.
    @discardableResult
    static func backfillSkillHistory(
        projects: [SkillProject],
        usageDatabasePath: String? = nil,
        removalArchive: URL? = nil,
        now: Date = Date(),
        calendar: Calendar = .current,
        databasePath: String? = nil,
        force: Bool = false
    ) throws -> SkillHistoryBackfillReport {
        let store = try SkillHistoryStore(path: databasePath)
        let recordedVersion = try store.metadata(historyBackfillVersionKey).flatMap(Int.init)
        if !force, recordedVersion == historyBackfillVersion {
            return SkillHistoryBackfillReport(
                daysWritten: 0,
                installEvents: 0,
                removalEvents: 0,
                earliestDay: nil,
                usageCoverageStartsAt: nil,
                skipped: true,
                warnings: []
            )
        }

        var warnings: [String] = []
        let archiveRoot = removalArchive ?? homeURL().standardizedFileURL
            .appendingPathComponent("Library/Application Support/Metagent/Removed Skills")
        let gitLifetimes = gitSkillLifetimes(projects: projects)
        let archiveRemovals = reconstructedRemovals(archive: archiveRoot)
        let installed = reconstructedInstalls(
            projects: projects,
            gitLifetimes: gitLifetimes,
            calendar: calendar
        )
        let installedByKey = Dictionary(installed.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        // Git sees deletions the archive never recorded; the archive sees
        // removals in directories git does not track. Together they cover more
        // than either alone, deduplicated by skill key.
        let archiveKeys = Set(archiveRemovals.map(\.key))
        let removals = archiveRemovals + gitOnlyRemovals(
            gitLifetimes: gitLifetimes,
            installedKeys: Set(installedByKey.keys)
        ).filter { !archiveKeys.contains($0.key) }
        let reconstructed = installed + removals.filter { removal in
            // A skill installed again at the same path has two separate
            // lifetimes. Both are kept, but only when the earlier one closed
            // before the current bundle was created, so the two can never
            // overlap and double-count the same day.
            guard let current = installedByKey[removal.key] else { return true }
            return (removal.removedOn ?? removal.installedOn) <= current.installedOn
        }

        var dayCounts: [SkillUsageDayCount] = []
        do {
            dayCounts = try skillUsageDailyCounts(
                databasePath: usageDatabasePath,
                calendar: calendar
            )
        } catch {
            warnings.append("usage history unavailable: \(error.localizedDescription)")
        }
        let usageCoverageStartsAt = dayCounts.map(\.day).min()

        guard !reconstructed.isEmpty || !dayCounts.isEmpty else {
            try store.setMetadata(historyBackfillVersionKey, String(historyBackfillVersion))
            return SkillHistoryBackfillReport(
                daysWritten: 0,
                installEvents: 0,
                removalEvents: 0,
                earliestDay: nil,
                usageCoverageStartsAt: nil,
                skipped: false,
                warnings: warnings
            )
        }

        // Reads are keyed by canonical path in the event log, which is exactly
        // the key the reconstructed portfolio uses.
        var readsByKeyDay: [String: [String: Int]] = [:]
        for count in dayCounts {
            guard let path = count.canonicalPath else { continue }
            readsByKeyDay[standardizedHistoryPath(path), default: [:]][count.day, default: 0] += count.count
        }

        let today = historyDay(now, calendar: calendar)
        let windowStart = historyDay(
            now.addingTimeInterval(-Double(historyBackfillWindowDays) * 86_400),
            calendar: calendar
        )
        let earliestSignal = [
            reconstructed.map(\.installedOn).min(),
            usageCoverageStartsAt,
        ]
        .compactMap { $0 }
        .min()
        guard let firstDay = [earliestSignal, windowStart].compactMap({ $0 }).max() else {
            try store.setMetadata(historyBackfillVersionKey, String(historyBackfillVersion))
            return SkillHistoryBackfillReport(
                daysWritten: 0,
                installEvents: 0,
                removalEvents: 0,
                earliestDay: nil,
                usageCoverageStartsAt: usageCoverageStartsAt,
                skipped: false,
                warnings: warnings
            )
        }

        var daysWritten = 0
        for day in historyDayRange(from: firstDay, through: today, calendar: calendar) {
            // Today belongs to the live capture path, which has the real
            // content metrics; an inferred row would only be overwritten.
            guard day != today else { continue }
            let alive = reconstructed.filter { skill in
                skill.installedOn <= day && (skill.removedOn.map { day < $0 } ?? true)
            }
            guard !alive.isEmpty else { continue }
            let metrics = reconstructedMetrics(
                alive: alive,
                day: day,
                readsByKeyDay: readsByKeyDay,
                hasUsageCorpus: !dayCounts.isEmpty,
                calendar: calendar
            )
            guard !metrics.isEmpty else { continue }
            let capturedAt = middayOf(day, calendar: calendar) ?? now
            try store.record(
                day: day,
                capturedAt: capturedAt,
                trigger: .backfill,
                origin: .inferred,
                metrics: metrics,
                states: nil
            )
            daysWritten += 1
        }

        func scopeKey(_ skill: ReconstructedSkill) -> String {
            skill.scope == "project"
                ? SkillHistoryScope.project(root: projectRootForSkill(skill.key)).key
                : SkillHistoryScope.global.key
        }

        let installEvents = installed.map { skill in
            let fromGit = gitLifetimes[skill.key]?.installedOn == skill.installedOn
            return SkillHistoryEvent(
                id: "added:\(skill.key):inferred",
                occurredAt: middayOf(skill.installedOn, calendar: calendar) ?? now,
                kind: .added,
                subjectKey: skill.key,
                subjectName: skill.name,
                scopeKey: scopeKey(skill),
                origin: .inferred,
                detail: ["evidence": fromGit ? "git history" : "directory creation date"]
            )
        }
        let removalEvents = removals.compactMap { skill -> SkillHistoryEvent? in
            guard let removedOn = skill.removedOn else { return nil }
            let fromGit = gitLifetimes[skill.key]?.removedOn == removedOn
            return SkillHistoryEvent(
                id: "removed:\(skill.key):inferred:\(removedOn)",
                occurredAt: middayOf(removedOn, calendar: calendar) ?? now,
                kind: .removed,
                subjectKey: skill.key,
                subjectName: skill.name,
                scopeKey: scopeKey(skill),
                origin: .inferred,
                detail: ["evidence": fromGit ? "git history" : "removal archive"]
            )
        }
        // Content changes have no filesystem equivalent: a skill's edit history
        // simply did not exist before capture unless git kept it.
        let scopeByKey = Dictionary(
            reconstructed.map { ($0.key, scopeKey($0)) },
            uniquingKeysWith: { first, _ in first }
        )
        let changeEvents = gitLifetimes.values.flatMap { lifetime in
            lifetime.changedOn.map { day in
                SkillHistoryEvent(
                    id: "content-changed:\(lifetime.skillKey):inferred:\(day)",
                    occurredAt: middayOf(day, calendar: calendar) ?? now,
                    kind: .contentChanged,
                    subjectKey: lifetime.skillKey,
                    subjectName: lifetime.name,
                    scopeKey: scopeByKey[lifetime.skillKey] ?? SkillHistoryScope.global.key,
                    origin: .inferred,
                    detail: ["evidence": "git history"]
                )
            }
        }
        try store.insertEvents(installEvents + removalEvents + changeEvents)
        try store.setMetadata(historyBackfillVersionKey, String(historyBackfillVersion))
        if let usageCoverageStartsAt {
            try store.setMetadata("usage_coverage_starts_at", usageCoverageStartsAt)
        }

        if let usageCoverageStartsAt {
            warnings.append(
                "Reconstructed adoption is bounded by retained session history, so reads before \(usageCoverageStartsAt) are not recoverable and early rates understate real use."
            )
        }
        // Per-day project dormancy is not reconstructable, so reconstructed rates
        // are computed over every skill alive that day while captured rates
        // exclude skills in directories that had gone quiet. Reconstructed
        // adoption therefore reads slightly worse than captured adoption, and the
        // step at the seam is a change of method rather than a change in the
        // portfolio.
        warnings.append(
            "Reconstructed adoption rates rate every skill alive on the day, because per-day project dormancy cannot be recovered. Captured rates exclude dormant directories, so the two are not directly comparable across the seam."
        )

        return SkillHistoryBackfillReport(
            daysWritten: daysWritten,
            installEvents: installEvents.count,
            removalEvents: removalEvents.count,
            earliestDay: firstDay,
            usageCoverageStartsAt: usageCoverageStartsAt,
            skipped: false,
            warnings: warnings
        )
    }
}

/// The same definitions the live health summary uses, evaluated as of one past
/// day. Only the metrics that timestamped evidence can support are produced.
func reconstructedMetrics(
    alive: [ReconstructedSkill],
    day: String,
    readsByKeyDay: [String: [String: Int]],
    hasUsageCorpus: Bool,
    calendar: Calendar = .current
) -> [(scope: String, metric: SkillHistoryMetric, value: Double)] {
    var metrics: [(scope: String, metric: SkillHistoryMetric, value: Double)] = []
    let windowStart = day30DaysBefore(day, calendar: calendar)
    let byScope: [(SkillHistoryScope, [ReconstructedSkill])] = [
        (.all, alive),
        (.global, alive.filter { $0.scope != "project" }),
    ]

    for (scope, skills) in byScope where !skills.isEmpty {
        metrics.append((scope.key, .portfolioSkills, Double(skills.count)))
        guard hasUsageCorpus else { continue }
        // Dormancy needs per-day project activity that is not reconstructable,
        // so every skill alive on that day is rated. This is stated rather than
        // hidden: reconstructed rates are computed on a wider denominator than
        // today's rates and are not directly comparable across the seam.
        metrics.append((scope.key, .portfolioAssessed, Double(skills.count)))
        let lifetime = skills.map { skill in
            (readsByKeyDay[skill.key] ?? [:])
                .filter { $0.key <= day }
                .values
                .reduce(0, +)
        }
        let recent = skills.map { skill in
            (readsByKeyDay[skill.key] ?? [:])
                .filter { $0.key > windowStart && $0.key <= day }
                .values
                .reduce(0, +)
        }
        let observed = lifetime.count { $0 > 0 }
        let active = recent.count { $0 > 0 }
        metrics.append((scope.key, .adoptionObserved, Double(observed)))
        metrics.append((scope.key, .adoptionActive30d, Double(active)))
        metrics.append((scope.key, .adoptionNeverObserved, Double(skills.count - observed)))
        metrics.append((scope.key, .adoptionUnused30d, Double(skills.count - active)))
        metrics.append((scope.key, .readsP50, Double(nearestRank(lifetime, percentile: 0.50) ?? 0)))
        metrics.append((scope.key, .readsP75, Double(nearestRank(lifetime, percentile: 0.75) ?? 0)))
        metrics.append((scope.key, .readsP95, Double(nearestRank(lifetime, percentile: 0.95) ?? 0)))
    }
    return metrics
}

/// Installed skills that still exist, dated by git where the skills directory is
/// tracked and by directory creation time everywhere else.
///
/// The population is taken from the same deduplication the health summary uses,
/// so a reconstructed count and a captured count describe the same set of
/// skills. Measuring a narrower population before capture began would put a
/// cliff at the seam that looks like a real event.
///
/// Git is preferred because it dates the commit that introduced a skill.
/// `st_birthtime` only says when these bytes reached this disk, which a restore,
/// a clone, or a plugin-cache extraction all reset to the wrong day. Where git
/// has nothing to say, birthtime is still better than no date at all.
func reconstructedInstalls(
    projects: [SkillProject],
    gitLifetimes: [String: GitSkillLifetime] = [:],
    calendar: Calendar = .current
) -> [ReconstructedSkill] {
    var installs: [String: ReconstructedSkill] = [:]
    for entry in canonicalHealthSkills(projects: projects, scope: .all) {
        let skill = entry.skill
        let key = standardizedHistoryPath(
            skill.canonicalPath.isEmpty ? skill.path : skill.canonicalPath
        )
        guard installs[key] == nil else { continue }
        let installedOn = gitLifetimes[key]?.installedOn
            ?? creationDate(ofDirectory: key).map { historyDay($0, calendar: calendar) }
        guard let installedOn else { continue }
        installs[key] = ReconstructedSkill(
            key: key,
            name: skill.name,
            scope: skill.scope,
            installedOn: installedOn,
            removedOn: nil
        )
    }
    return installs.values.sorted { $0.key < $1.key }
}

/// Skills git recorded as deleted that no longer exist on disk.
///
/// The removal archive only knows about removals the app performed. Anything
/// deleted by hand, by another tool, or before the archive existed is invisible
/// to it and visible here.
func gitOnlyRemovals(
    gitLifetimes: [String: GitSkillLifetime],
    installedKeys: Set<String>
) -> [ReconstructedSkill] {
    gitLifetimes.values.compactMap { lifetime -> ReconstructedSkill? in
        guard let removedOn = lifetime.removedOn,
              !installedKeys.contains(lifetime.skillKey),
              let installedOn = lifetime.installedOn
        else { return nil }
        return ReconstructedSkill(
            key: lifetime.skillKey,
            name: lifetime.name,
            scope: lifetime.skillKey.contains("/.agents/skills/")
                && !lifetime.skillKey.hasPrefix(homeURL().standardizedFileURL.path + "/.agents/")
                ? "project"
                : "global",
            installedOn: min(installedOn, removedOn),
            removedOn: removedOn
        )
    }
    .sorted { $0.key < $1.key }
}

/// Removals recorded by the recovery archive. The archive exists to restore a
/// bundle, not to be a history store, so it is read as evidence and never
/// written to here.
///
/// Moving a bundle into the archive preserves its creation date, so an archived
/// skill carries both ends of its lifetime: when it was installed and when it
/// was removed. Without the archived copy only the removal date is known, and
/// the skill is treated as installed on the day it was removed rather than
/// inventing an earlier date.
func reconstructedRemovals(
    archive: URL,
    calendar: Calendar = .current
) -> [ReconstructedSkill] {
    guard let entries = try? fileManager.contentsOfDirectory(
        at: archive,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }

    var removals: [ReconstructedSkill] = []
    for entry in entries {
        let receipt = entry.appendingPathComponent("REMOVAL.txt")
        guard let text = try? String(contentsOf: receipt, encoding: .utf8) else { continue }
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            fields[parts[0]] = parts[1]
        }
        guard let project = fields["project"],
              let name = fields["skill"],
              let removedAt = fields["removed_at"],
              let removedDate = MetagentCore.parseSkillUsageTimestamp(removedAt)
        else { continue }
        let projectURL = URL(fileURLWithPath: project)
        let isGlobal = standardizedHistoryPath(project) == homeURL().standardizedFileURL.path
        let key = standardizedHistoryPath(
            projectURL.appendingPathComponent(".agents/skills/\(name)").path
        )
        let removedOn = historyDay(removedDate, calendar: calendar)
        let archivedBundle = entry.appendingPathComponent(name).path
        let installedOn = creationDate(ofDirectory: archivedBundle)
            .map { historyDay($0, calendar: calendar) } ?? removedOn
        removals.append(ReconstructedSkill(
            key: key,
            name: name,
            scope: isGlobal ? "global" : "project",
            installedOn: min(installedOn, removedOn),
            removedOn: removedOn
        ))
    }
    return removals.sorted { $0.key < $1.key }
}

func creationDate(ofDirectory path: String) -> Date? {
    try? URL(fileURLWithPath: path)
        .resourceValues(forKeys: [.creationDateKey])
        .creationDate
}

/// Inclusive day strings from `start` through `end`.
func historyDayRange(from start: String, through end: String, calendar: Calendar = .current) -> [String] {
    guard let startDate = date(fromHistoryDay: start, calendar: calendar),
          let endDate = date(fromHistoryDay: end, calendar: calendar),
          startDate <= endDate
    else { return [] }
    var days: [String] = []
    var cursor = startDate
    while cursor <= endDate {
        days.append(historyDay(cursor, calendar: calendar))
        guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
        cursor = next
    }
    return days
}

func day30DaysBefore(_ day: String, calendar: Calendar = .current) -> String {
    guard let date = date(fromHistoryDay: day, calendar: calendar),
          let shifted = calendar.date(byAdding: .day, value: -30, to: date)
    else { return day }
    return historyDay(shifted, calendar: calendar)
}

func date(fromHistoryDay day: String, calendar: Calendar = .current) -> Date? {
    let parts = day.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    var components = DateComponents()
    components.year = parts[0]
    components.month = parts[1]
    components.day = parts[2]
    return calendar.date(from: components)
}

/// A reconstructed day is stamped at local midday rather than at the moment the
/// backfill ran, so the recorded timestamp matches the day it describes.
///
/// Midday and not midnight or end of day: the evidence establishes a date, not a
/// time, and an instant in the middle of the day survives rendering in any
/// timezone without landing on the day before or after.
func middayOf(_ day: String, calendar: Calendar = .current) -> Date? {
    guard let start = date(fromHistoryDay: day, calendar: calendar) else { return nil }
    return calendar.date(byAdding: DateComponents(hour: 12), to: start)
}
