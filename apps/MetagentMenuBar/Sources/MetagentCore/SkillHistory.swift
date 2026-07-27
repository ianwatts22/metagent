import Foundation
import SQLite3

/// Which slice of the portfolio a recorded metric describes.
///
/// The same keys the Overview scope menu already uses, flattened to a string so
/// a new scope never needs a schema change.
public enum SkillHistoryScope: Sendable, Equatable, Hashable {
    case all
    case global
    case project(root: String)

    public var key: String {
        switch self {
        case .all: "all"
        case .global: "global"
        case let .project(root): "project:\(standardizedHistoryPath(root))"
        }
    }

    public init?(key: String) {
        switch key {
        case "all": self = .all
        case "global": self = .global
        default:
            guard key.hasPrefix("project:") else { return nil }
            self = .project(root: standardizedHistoryPath(
                String(key.dropFirst("project:".count))
            ))
        }
    }

    var healthScope: SkillSystemHealthScope {
        switch self {
        case .all: .all
        case .global: .global(root: homeURL().standardizedFileURL.path)
        case let .project(root): .project(root: standardizedHistoryPath(root))
        }
    }
}

/// What caused a sample to be written. Recorded so a launch sample can be told
/// apart from one forced by a removal or rename.
public enum SkillHistoryTrigger: String, Sendable, Equatable {
    case launch
    case refresh
    case mutation
    case cli
    case backfill
}

/// Whether the app watched something happen or inferred it after the fact.
///
/// Inferred rows come from filesystem creation dates, the removal archive, and
/// the usage event log. They are real evidence but weaker than an observed
/// transition, and every surface that draws them must be able to say so.
public enum SkillHistoryOrigin: String, Sendable, Equatable {
    case observed
    case inferred
}

public enum SkillHistoryEventKind: String, Sendable, Equatable, CaseIterable {
    case added
    case removed
    case renamed
    case contentChanged = "content-changed"
    case sourceChanged = "source-changed"
    case scopeChanged = "scope-changed"
}

/// Every metric the history layer records.
///
/// Raw string values are the on-disk contract; renaming a case would orphan its
/// recorded series, so these are append-only in practice.
public enum SkillHistoryMetric: String, Sendable, Equatable, CaseIterable {
    case portfolioSkills = "portfolio.skills"
    case portfolioAssessed = "portfolio.assessed"
    case portfolioDormantSkills = "portfolio.dormant_skills"
    case portfolioDormantProjects = "portfolio.dormant_projects"
    case adoptionObserved = "adoption.observed"
    case adoptionActive30d = "adoption.active_30d"
    case adoptionNeverObserved = "adoption.never_observed"
    case adoptionUnused30d = "adoption.unused_30d"
    case readsP50 = "reads.p50"
    case readsP75 = "reads.p75"
    case readsP95 = "reads.p95"
    case tokensSkillBody = "tokens.skill_body"
    case tokensCatalog = "tokens.catalog"
    case ageMedianWeeks = "age.median_weeks"
    case ageP75Weeks = "age.p75_weeks"
    case ageUnknown = "age.unknown"
    case duplicateGroups = "duplicates.groups"
    case mcpConfigured = "mcp.configured"
    case mcpAttention = "mcp.attention"
    case doctorWarnings = "doctor.warnings"
    case doctorFailures = "doctor.failures"

    /// Metrics the backfill can reconstruct from timestamped evidence. Anything
    /// outside this set describes content or configuration that is overwritten
    /// in place, so it has no history before capture began.
    public static let reconstructable: Set<SkillHistoryMetric> = [
        .portfolioSkills,
        .portfolioAssessed,
        .adoptionObserved,
        .adoptionActive30d,
        .adoptionNeverObserved,
        .adoptionUnused30d,
        .readsP50,
        .readsP75,
        .readsP95,
    ]
}

/// One recorded value, with enough provenance for a chart to shade it.
public struct SkillHistoryPoint: Sendable, Equatable {
    public let day: String
    public let capturedAt: Date
    public let origin: SkillHistoryOrigin
    public let value: Double

    public init(day: String, capturedAt: Date, origin: SkillHistoryOrigin, value: Double) {
        self.day = day
        self.capturedAt = capturedAt
        self.origin = origin
        self.value = value
    }
}

public struct SkillHistoryEvent: Sendable, Equatable, Identifiable {
    public let id: String
    public let occurredAt: Date
    public let kind: SkillHistoryEventKind
    public let subjectKey: String
    public let subjectName: String
    public let scopeKey: String
    public let origin: SkillHistoryOrigin
    public let detail: [String: String]

    public init(
        id: String,
        occurredAt: Date,
        kind: SkillHistoryEventKind,
        subjectKey: String,
        subjectName: String,
        scopeKey: String,
        origin: SkillHistoryOrigin,
        detail: [String: String] = [:]
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.kind = kind
        self.subjectKey = subjectKey
        self.subjectName = subjectName
        self.scopeKey = scopeKey
        self.origin = origin
        self.detail = detail
    }
}

public struct SkillHistoryCaptureReport: Sendable, Equatable {
    public let day: String
    public let isNewDay: Bool
    public let metricsWritten: Int
    public let events: [SkillHistoryEvent]

    public init(day: String, isNewDay: Bool, metricsWritten: Int, events: [SkillHistoryEvent]) {
        self.day = day
        self.isNewDay = isNewDay
        self.metricsWritten = metricsWritten
        self.events = events
    }
}

public struct SkillHistoryCoverage: Sendable, Equatable {
    public let firstObservedDay: String?
    public let lastObservedDay: String?
    public let firstInferredDay: String?
    public let observedDayCount: Int
    public let inferredDayCount: Int
    public let eventCount: Int

    /// Whether anything at all has been recorded, regardless of the window a
    /// caller happens to be looking at. A control that appears only when the
    /// current window has data would vanish the moment someone narrowed it.
    public var hasAnyRecord: Bool {
        observedDayCount > 0 || inferredDayCount > 0
    }

    public static let empty = SkillHistoryCoverage(
        firstObservedDay: nil,
        lastObservedDay: nil,
        firstInferredDay: nil,
        observedDayCount: 0,
        inferredDayCount: 0,
        eventCount: 0
    )
}

/// A skill's recorded shape over one interval. A new row is written only when
/// something in the tuple changes, so the table stays small and doubles as the
/// source for change events.
struct SkillHistoryState: Sendable, Equatable {
    let skillKey: String
    let name: String
    let scope: String
    let location: String
    let manager: String
    let source: String
    let contentFingerprint: String
    let fileIdentity: String
    let tokenEstimate: Int
    let upstreamUpdatedAt: String

    /// A change signal built from counts the inventory scan already computed.
    ///
    /// This is deliberately not a content hash: hashing every file of several
    /// hundred bundles on each scan would cost more than the signal is worth.
    /// It detects edits that change size or shape, and misses same-length
    /// rewrites.
    init(skill: SkillInventoryItem) {
        let key = standardizedHistoryPath(
            skill.canonicalPath.isEmpty ? skill.path : skill.canonicalPath
        )
        skillKey = key
        fileIdentity = directoryIdentity(key) ?? ""
        name = skill.name
        scope = skill.scope
        location = skill.location
        manager = skill.manager
        source = skill.source ?? ""
        contentFingerprint = [
            skill.skillFileCharacterCount,
            skill.skillFileWordCount,
            skill.characterCount,
            skill.wordCount,
            skill.referenceFileCount,
            skill.scriptFileCount,
            (skill.description ?? "").count,
        ]
        .map(String.init)
        .joined(separator: "-")
        tokenEstimate = skill.skillFileTokenEstimate
        upstreamUpdatedAt = skill.updatedAt ?? ""
    }

    init(
        skillKey: String,
        name: String,
        scope: String,
        location: String,
        manager: String,
        source: String,
        contentFingerprint: String,
        fileIdentity: String,
        tokenEstimate: Int,
        upstreamUpdatedAt: String
    ) {
        self.skillKey = skillKey
        self.name = name
        self.scope = scope
        self.location = location
        self.manager = manager
        self.source = source
        self.contentFingerprint = contentFingerprint
        self.fileIdentity = fileIdentity
        self.tokenEstimate = tokenEstimate
        self.upstreamUpdatedAt = upstreamUpdatedAt
    }
}

/// Volume and inode of a directory, which stay the same when it is renamed or
/// moved within a volume. This is what makes a rename provable rather than
/// guessed from similar-looking content.
func directoryIdentity(_ path: String) -> String? {
    guard let values = try? URL(fileURLWithPath: path)
        .resourceValues(forKeys: [.fileResourceIdentifierKey]),
        let identifier = values.fileResourceIdentifier
    else { return nil }
    return String(describing: identifier)
}

public extension MetagentCore {
    /// Records one sample of the current portfolio.
    ///
    /// At most one sample exists per local day: repeated captures on the same
    /// day update it in place, so an active session does not write forty rows.
    /// Days the app never ran stay absent, and absent must render as a gap
    /// rather than as zero.
    @discardableResult
    static func captureSkillHistory(
        projects: [SkillProject],
        usage: SkillUsageSnapshot,
        activity: ProjectActivityIndex = .unavailable,
        doctorIssues: [DoctorIssue] = [],
        mcp: MCPHealthSnapshot? = nil,
        trigger: SkillHistoryTrigger,
        scopes: [SkillHistoryScope]? = nil,
        now: Date = Date(),
        calendar: Calendar = .current,
        databasePath: String? = nil
    ) throws -> SkillHistoryCaptureReport {
        let store = try SkillHistoryStore(path: databasePath)
        let capturedScopes = scopes ?? defaultHistoryScopes(projects: projects)
        var metrics: [(scope: String, metric: SkillHistoryMetric, value: Double)] = []

        for scope in capturedScopes {
            let health = skillSystemHealth(
                projects: projects,
                usage: usage,
                scope: scope.healthScope,
                activity: activity,
                now: now
            )
            // A scope with nothing installed contributes no rows: a project that
            // has never held a skill should not draw a flat zero line beside
            // scopes that mean something.
            guard health.skillCount > 0 else { continue }
            for (metric, value) in healthMetrics(health) {
                metrics.append((scope.key, metric, value))
            }
        }

        // Doctor and MCP describe the whole machine rather than one scope, so
        // they are recorded once against `all`.
        let warnings = doctorIssues.count { $0.severity == .warning }
        let failures = doctorIssues.count { $0.severity == .failure }
        metrics.append((SkillHistoryScope.all.key, .doctorWarnings, Double(warnings)))
        metrics.append((SkillHistoryScope.all.key, .doctorFailures, Double(failures)))
        if let mcp, mcp.observedAt != .distantPast {
            metrics.append((SkillHistoryScope.all.key, .mcpConfigured, Double(mcp.configuredCount)))
            metrics.append((SkillHistoryScope.all.key, .mcpAttention, Double(mcp.attention.count)))
        }

        let states = canonicalHistoryStates(projects: projects)
        return try store.record(
            day: historyDay(now, calendar: calendar),
            capturedAt: now,
            trigger: trigger,
            origin: .observed,
            metrics: metrics,
            states: states
        )
    }

    static func skillHistorySeries(
        metric: SkillHistoryMetric,
        scope: SkillHistoryScope = .all,
        since: Date? = nil,
        databasePath: String? = nil
    ) throws -> [SkillHistoryPoint] {
        try SkillHistoryStore(path: databasePath).series(
            metric: metric,
            scopeKey: scope.key,
            since: since
        )
    }

    static func skillHistoryEvents(
        since: Date? = nil,
        scope: SkillHistoryScope? = nil,
        limit: Int = 200,
        databasePath: String? = nil
    ) throws -> [SkillHistoryEvent] {
        try SkillHistoryStore(path: databasePath).events(
            since: since,
            scopeKey: scope?.key,
            limit: limit
        )
    }

    static func skillHistoryCoverage(databasePath: String? = nil) throws -> SkillHistoryCoverage {
        try SkillHistoryStore(path: databasePath).coverage()
    }
}

/// Global plus every project that actually holds skills. Plugin-cache
/// pseudo-projects are excluded for the same reason they are hidden from the
/// directory filter.
func defaultHistoryScopes(projects: [SkillProject]) -> [SkillHistoryScope] {
    var scopes: [SkillHistoryScope] = [.all, .global]
    let projectRoots = projects
        .filter { project in project.skills.contains { $0.scope == "project" } }
        .map(\.root)
    for root in Set(projectRoots).sorted() {
        scopes.append(.project(root: root))
    }
    return scopes
}

func healthMetrics(_ health: SkillSystemHealth) -> [(SkillHistoryMetric, Double)] {
    var metrics: [(SkillHistoryMetric, Double)] = [
        (.portfolioSkills, Double(health.skillCount)),
        (.portfolioAssessed, Double(health.assessedSkillCount)),
        (.portfolioDormantSkills, Double(health.dormantSkillCount)),
        (.portfolioDormantProjects, Double(health.dormantProjectCount)),
        (.tokensSkillBody, Double(health.skillBodyTokenEstimate)),
        (.tokensCatalog, Double(health.catalogTokenEstimate)),
        (.duplicateGroups, Double(health.duplicateGroupCount)),
        (.ageUnknown, Double(health.ageDistribution.unknownCount)),
    ]
    // Adoption is only meaningful against an indexed corpus. Writing zeros for
    // an unindexed machine would later read as "nothing was ever used".
    if health.usageCoverage != .unavailable {
        metrics.append(contentsOf: [
            (SkillHistoryMetric.adoptionObserved, Double(health.observedSkillCount)),
            (.adoptionActive30d, Double(health.active30dSkillCount)),
            (.adoptionNeverObserved, Double(health.neverObservedSkillCount)),
            (.adoptionUnused30d, Double(health.unused30dSkillCount)),
            (.readsP50, Double(health.invocationDistribution.p50)),
            (.readsP75, Double(health.invocationDistribution.p75)),
            (.readsP95, Double(health.invocationDistribution.p95)),
        ])
    }
    if let median = health.ageDistribution.medianWeeks {
        metrics.append((.ageMedianWeeks, Double(median)))
    }
    if let p75 = health.ageDistribution.p75Weeks {
        metrics.append((.ageP75Weeks, Double(p75)))
    }
    return metrics
}

/// One state row per skill bundle, using the same deduplication the health
/// summary uses so the state table and the recorded counts describe one set.
func canonicalHistoryStates(projects: [SkillProject]) -> [SkillHistoryState] {
    var states: [String: SkillHistoryState] = [:]
    for entry in canonicalHealthSkills(projects: projects, scope: .all) {
        let state = SkillHistoryState(skill: entry.skill)
        states[state.skillKey] = state
    }
    return states.values.sorted { $0.skillKey < $1.skillKey }
}

func historyDay(_ date: Date, calendar: Calendar = .current) -> String {
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    return String(
        format: "%04d-%02d-%02d",
        components.year ?? 0,
        components.month ?? 0,
        components.day ?? 0
    )
}

func standardizedHistoryPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
}

// MARK: - Store

final class SkillHistoryStore {
    let path: URL

    init(path: String?) throws {
        if let path {
            self.path = URL(fileURLWithPath: path)
        } else {
            self.path = homeURL().standardizedFileURL
                .appendingPathComponent("Library/Application Support/Metagent/history.sqlite")
        }
        try fileManager.createDirectory(
            at: self.path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    /// Writes one day's metrics and folds the skill states into the
    /// slowly-changing-dimension table, returning whatever changed as events.
    @discardableResult
    func record(
        day: String,
        capturedAt: Date,
        trigger: SkillHistoryTrigger,
        origin: SkillHistoryOrigin,
        metrics: [(scope: String, metric: SkillHistoryMetric, value: Double)],
        states: [SkillHistoryState]?
    ) throws -> SkillHistoryCaptureReport {
        var db: OpaquePointer?
        try open(&db)
        defer { sqlite3_close(db) }
        try createSchema(db)
        try exec(db, "BEGIN IMMEDIATE;")
        do {
            let existing = try snapshotID(db, day: day)
            let isNewDay = existing == nil
            // An inferred sample never overwrites an observed one: reconstructed
            // evidence is weaker than what the app actually watched.
            if let existing, try snapshotOrigin(db, id: existing) == .observed, origin == .inferred {
                try exec(db, "COMMIT;")
                return SkillHistoryCaptureReport(
                    day: day,
                    isNewDay: false,
                    metricsWritten: 0,
                    events: []
                )
            }
            let snapshotID = try upsertSnapshot(
                db,
                day: day,
                capturedAt: capturedAt,
                trigger: trigger,
                origin: origin,
                existing: existing
            )
            try deleteMetrics(db, snapshotID: snapshotID)
            for metric in metrics {
                try insertMetric(
                    db,
                    snapshotID: snapshotID,
                    scopeKey: metric.scope,
                    metric: metric.metric,
                    value: metric.value
                )
            }
            var events: [SkillHistoryEvent] = []
            if let states {
                events = try applyStates(
                    db,
                    states: states,
                    at: capturedAt,
                    origin: origin
                )
            }
            try exec(db, "COMMIT;")
            return SkillHistoryCaptureReport(
                day: day,
                isNewDay: isNewDay,
                metricsWritten: metrics.count,
                events: events
            )
        } catch {
            try? exec(db, "ROLLBACK;")
            throw error
        }
    }

    func series(
        metric: SkillHistoryMetric,
        scopeKey: String,
        since: Date?
    ) throws -> [SkillHistoryPoint] {
        var db: OpaquePointer?
        try open(&db)
        defer { sqlite3_close(db) }
        try createSchema(db)
        var sql = """
        SELECT s.day, s.captured_at, s.origin, m.value
        FROM history_snapshots s
        JOIN history_metrics m ON m.snapshot_id = s.id
        WHERE m.metric = ? AND m.scope = ?
        """
        if since != nil {
            sql += " AND s.day >= ?"
        }
        sql += " ORDER BY s.day;"
        var statement: OpaquePointer?
        try prepare(db, sql, &statement)
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, metric.rawValue)
        bindText(statement, 2, scopeKey)
        if let since {
            bindText(statement, 3, historyDay(since))
        }
        var points: [SkillHistoryPoint] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let day = columnText(statement, 0) else { continue }
            let capturedAt = columnText(statement, 1)
                .flatMap(MetagentCore.parseSkillUsageTimestamp) ?? Date.distantPast
            let origin = columnText(statement, 2)
                .flatMap(SkillHistoryOrigin.init(rawValue:)) ?? .observed
            points.append(SkillHistoryPoint(
                day: day,
                capturedAt: capturedAt,
                origin: origin,
                value: sqlite3_column_double(statement, 3)
            ))
        }
        return points
    }

    /// Reads several metrics' series in one statement, grouped by metric.
    func series(
        metrics: [SkillHistoryMetric],
        scopeKey: String,
        since: Date?
    ) throws -> [SkillHistoryMetric: [SkillHistoryPoint]] {
        guard !metrics.isEmpty else { return [:] }
        var db: OpaquePointer?
        try open(&db)
        defer { sqlite3_close(db) }
        try createSchema(db)
        let placeholders = Array(repeating: "?", count: metrics.count).joined(separator: ", ")
        var sql = """
        SELECT m.metric, s.day, s.captured_at, s.origin, m.value
        FROM history_snapshots s
        JOIN history_metrics m ON m.snapshot_id = s.id
        WHERE m.scope = ? AND m.metric IN (\(placeholders))
        """
        if since != nil {
            sql += " AND s.day >= ?"
        }
        sql += " ORDER BY m.metric, s.day;"
        var statement: OpaquePointer?
        try prepare(db, sql, &statement)
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, scopeKey)
        for (offset, metric) in metrics.enumerated() {
            bindText(statement, Int32(2 + offset), metric.rawValue)
        }
        if let since {
            bindText(statement, Int32(2 + metrics.count), historyDay(since))
        }
        var grouped: [SkillHistoryMetric: [SkillHistoryPoint]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let metric = columnText(statement, 0).flatMap(SkillHistoryMetric.init(rawValue:)),
                  let day = columnText(statement, 1)
            else { continue }
            let capturedAt = columnText(statement, 2)
                .flatMap(MetagentCore.parseSkillUsageTimestamp) ?? Date.distantPast
            let origin = columnText(statement, 3)
                .flatMap(SkillHistoryOrigin.init(rawValue:)) ?? .observed
            grouped[metric, default: []].append(SkillHistoryPoint(
                day: day,
                capturedAt: capturedAt,
                origin: origin,
                value: sqlite3_column_double(statement, 4)
            ))
        }
        return grouped
    }

    /// Every recorded event for one skill, newest first.
    func events(forSubject subjectKey: String) throws -> [SkillHistoryEvent] {
        var db: OpaquePointer?
        try open(&db)
        defer { sqlite3_close(db) }
        try createSchema(db)
        var statement: OpaquePointer?
        try prepare(db, """
        SELECT event_id, occurred_at, kind, subject_key, subject_name, scope, origin, detail
        FROM history_events
        WHERE subject_key = ?
        ORDER BY occurred_at DESC, event_id DESC;
        """, &statement)
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, subjectKey)
        return readEvents(statement)
    }

    func events(since: Date?, scopeKey: String?, limit: Int) throws -> [SkillHistoryEvent] {
        var db: OpaquePointer?
        try open(&db)
        defer { sqlite3_close(db) }
        try createSchema(db)
        var sql = """
        SELECT event_id, occurred_at, kind, subject_key, subject_name, scope, origin, detail
        FROM history_events
        """
        var predicates: [String] = []
        if since != nil {
            predicates.append("occurred_at >= ?")
        }
        if scopeKey != nil {
            predicates.append("scope = ?")
        }
        if !predicates.isEmpty {
            sql += " WHERE \(predicates.joined(separator: " AND "))"
        }
        sql += " ORDER BY occurred_at DESC, event_id DESC LIMIT ?;"
        var statement: OpaquePointer?
        try prepare(db, sql, &statement)
        defer { sqlite3_finalize(statement) }
        var index: Int32 = 1
        if let since {
            bindText(statement, index, iso8601Formatter.string(from: since))
            index += 1
        }
        if let scopeKey {
            bindText(statement, index, scopeKey)
            index += 1
        }
        sqlite3_bind_int64(statement, index, Int64(max(1, limit)))
        return readEvents(statement)
    }

    /// Both event queries select the same columns in the same order, so they
    /// share one decoder rather than repeating the column indices.
    private func readEvents(_ statement: OpaquePointer?) -> [SkillHistoryEvent] {
        var events: [SkillHistoryEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = columnText(statement, 0),
                  let occurredAt = columnText(statement, 1)
                  .flatMap(MetagentCore.parseSkillUsageTimestamp),
                  let kind = columnText(statement, 2).flatMap(SkillHistoryEventKind.init(rawValue:))
            else { continue }
            let detail = columnText(statement, 7)
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
            events.append(SkillHistoryEvent(
                id: id,
                occurredAt: occurredAt,
                kind: kind,
                subjectKey: columnText(statement, 3) ?? "",
                subjectName: columnText(statement, 4) ?? "",
                scopeKey: columnText(statement, 5) ?? SkillHistoryScope.all.key,
                origin: columnText(statement, 6)
                    .flatMap(SkillHistoryOrigin.init(rawValue:)) ?? .observed,
                detail: detail
            ))
        }
        return events
    }

    func coverage() throws -> SkillHistoryCoverage {
        var db: OpaquePointer?
        try open(&db)
        defer { sqlite3_close(db) }
        try createSchema(db)
        var statement: OpaquePointer?
        try prepare(db, """
        SELECT
          MIN(CASE WHEN origin = 'observed' THEN day END),
          MAX(CASE WHEN origin = 'observed' THEN day END),
          MIN(CASE WHEN origin = 'inferred' THEN day END),
          SUM(CASE WHEN origin = 'observed' THEN 1 ELSE 0 END),
          SUM(CASE WHEN origin = 'inferred' THEN 1 ELSE 0 END)
        FROM history_snapshots;
        """, &statement)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return .empty }
        let eventCount = try scalarInt(db, "SELECT COUNT(*) FROM history_events;")
        return SkillHistoryCoverage(
            firstObservedDay: columnText(statement, 0),
            lastObservedDay: columnText(statement, 1),
            firstInferredDay: columnText(statement, 2),
            observedDayCount: Int(sqlite3_column_int64(statement, 3)),
            inferredDayCount: Int(sqlite3_column_int64(statement, 4)),
            eventCount: eventCount
        )
    }

    func metadata(_ key: String) throws -> String? {
        var db: OpaquePointer?
        try open(&db)
        defer { sqlite3_close(db) }
        try createSchema(db)
        var statement: OpaquePointer?
        try prepare(db, "SELECT value FROM history_metadata WHERE key = ?;", &statement)
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, key)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return columnText(statement, 0)
    }

    func setMetadata(_ key: String, _ value: String) throws {
        var db: OpaquePointer?
        try open(&db)
        defer { sqlite3_close(db) }
        try createSchema(db)
        var statement: OpaquePointer?
        try prepare(db, """
        INSERT INTO history_metadata (key, value) VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value;
        """, &statement)
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, key)
        bindText(statement, 2, value)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError(db, "write metadata")
        }
    }

    /// Inserts an event directly, used by the backfill for transitions that
    /// predate any recorded state.
    func insertEvents(_ events: [SkillHistoryEvent]) throws {
        guard !events.isEmpty else { return }
        var db: OpaquePointer?
        try open(&db)
        defer { sqlite3_close(db) }
        try createSchema(db)
        try exec(db, "BEGIN IMMEDIATE;")
        do {
            for event in events {
                try insertEvent(db, event)
            }
            try exec(db, "COMMIT;")
        } catch {
            try? exec(db, "ROLLBACK;")
            throw error
        }
    }

    /// Replaces one origin's event set as a transaction. A failed reconstruction
    /// therefore leaves the previous inferred timeline intact.
    func replaceEvents(origin: SkillHistoryOrigin, with events: [SkillHistoryEvent]) throws {
        var db: OpaquePointer?
        try open(&db)
        defer { sqlite3_close(db) }
        try createSchema(db)
        try exec(db, "BEGIN IMMEDIATE;")
        do {
            var statement: OpaquePointer?
            try prepare(db, "DELETE FROM history_events WHERE origin = ?;", &statement)
            bindText(statement, 1, origin.rawValue)
            let status = sqlite3_step(statement)
            sqlite3_finalize(statement)
            guard status == SQLITE_DONE else {
                throw databaseError(db, "delete \(origin.rawValue) events")
            }
            for event in events {
                try insertEvent(db, event)
            }
            try exec(db, "COMMIT;")
        } catch {
            try? exec(db, "ROLLBACK;")
            throw error
        }
    }

    // MARK: State folding

    private func applyStates(
        _ db: OpaquePointer?,
        states: [SkillHistoryState],
        at capturedAt: Date,
        origin: SkillHistoryOrigin
    ) throws -> [SkillHistoryEvent] {
        let timestamp = iso8601Formatter.string(from: capturedAt)
        let previous = try currentStates(db)
        let incoming = Dictionary(states.map { ($0.skillKey, $0) }, uniquingKeysWith: { _, last in last })

        // The first capture has nothing to diff against. Every installed skill
        // would otherwise read as added today, when in fact it predates capture
        // entirely and the backfill has already dated it from its creation time.
        if try scalarInt(db, "SELECT COUNT(*) FROM history_skill_states;") == 0 {
            for state in states {
                try insertState(db, state: state, validFrom: timestamp, origin: origin)
            }
            return []
        }

        var events: [SkillHistoryEvent] = []

        let removedKeys = Set(previous.keys).subtracting(incoming.keys)
        let addedKeys = Set(incoming.keys).subtracting(previous.keys)

        // A rename moves the canonical directory, so it arrives as one removal
        // and one addition. The moved directory keeps its inode, which pairs the
        // two exactly and keeps the skill's history continuous instead of
        // restarting it under a new key. Similar-looking content is not enough:
        // two unrelated skills of the same size would pair by mistake.
        var renamedFrom: [String: String] = [:]
        for addedKey in addedKeys.sorted() {
            guard let added = incoming[addedKey], !added.fileIdentity.isEmpty else { continue }
            let match = removedKeys.sorted().first { removedKey in
                guard !renamedFrom.values.contains(removedKey),
                      let removed = previous[removedKey]
                else { return false }
                return removed.fileIdentity == added.fileIdentity
            }
            if let match {
                renamedFrom[addedKey] = match
            }
        }

        for key in removedKeys.sorted() where !renamedFrom.values.contains(key) {
            guard let state = previous[key] else { continue }
            try closeState(db, skillKey: key, validTo: timestamp)
            events.append(makeEvent(
                kind: .removed,
                at: capturedAt,
                state: state,
                origin: origin
            ))
        }

        for key in addedKeys.sorted() {
            guard let state = incoming[key] else { continue }
            if let previousKey = renamedFrom[key], let old = previous[previousKey] {
                try closeState(db, skillKey: previousKey, validTo: timestamp)
                try insertState(db, state: state, validFrom: timestamp, origin: origin)
                events.append(makeEvent(
                    kind: .renamed,
                    at: capturedAt,
                    state: state,
                    origin: origin,
                    detail: ["from": old.name, "fromPath": previousKey, "to": state.name]
                ))
                continue
            }
            try insertState(db, state: state, validFrom: timestamp, origin: origin)
            events.append(makeEvent(kind: .added, at: capturedAt, state: state, origin: origin))
        }

        for key in Set(incoming.keys).intersection(previous.keys).sorted() {
            guard let old = previous[key], let new = incoming[key], old != new else { continue }
            try closeState(db, skillKey: key, validTo: timestamp)
            try insertState(db, state: new, validFrom: timestamp, origin: origin)
            if old.contentFingerprint != new.contentFingerprint || old.tokenEstimate != new.tokenEstimate {
                events.append(makeEvent(
                    kind: .contentChanged,
                    at: capturedAt,
                    state: new,
                    origin: origin,
                    detail: [
                        "tokensBefore": String(old.tokenEstimate),
                        "tokensAfter": String(new.tokenEstimate),
                    ]
                ))
            }
            if old.source != new.source || old.manager != new.manager {
                events.append(makeEvent(
                    kind: .sourceChanged,
                    at: capturedAt,
                    state: new,
                    origin: origin,
                    detail: ["from": old.source, "to": new.source]
                ))
            }
            if old.scope != new.scope || old.location != new.location {
                events.append(makeEvent(
                    kind: .scopeChanged,
                    at: capturedAt,
                    state: new,
                    origin: origin,
                    detail: ["from": old.scope, "to": new.scope]
                ))
            }
        }

        for event in events {
            try insertEvent(db, event)
        }
        return events
    }

    private func makeEvent(
        kind: SkillHistoryEventKind,
        at date: Date,
        state: SkillHistoryState,
        origin: SkillHistoryOrigin,
        detail: [String: String] = [:]
    ) -> SkillHistoryEvent {
        SkillHistoryEvent(
            id: "\(kind.rawValue):\(state.skillKey):\(iso8601Formatter.string(from: date))",
            occurredAt: date,
            kind: kind,
            subjectKey: state.skillKey,
            subjectName: state.name,
            scopeKey: state.scope == "project"
                ? SkillHistoryScope.project(root: projectRootForSkill(state.skillKey)).key
                : SkillHistoryScope.global.key,
            origin: origin,
            detail: detail
        )
    }

    private func currentStates(_ db: OpaquePointer?) throws -> [String: SkillHistoryState] {
        var statement: OpaquePointer?
        try prepare(db, """
        SELECT skill_key, name, scope, location, manager, source,
               content_fingerprint, file_identity, token_estimate, upstream_updated_at
        FROM history_skill_states
        WHERE valid_to IS NULL;
        """, &statement)
        defer { sqlite3_finalize(statement) }
        var states: [String: SkillHistoryState] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let key = columnText(statement, 0) else { continue }
            states[key] = SkillHistoryState(
                skillKey: key,
                name: columnText(statement, 1) ?? "",
                scope: columnText(statement, 2) ?? "",
                location: columnText(statement, 3) ?? "",
                manager: columnText(statement, 4) ?? "",
                source: columnText(statement, 5) ?? "",
                contentFingerprint: columnText(statement, 6) ?? "",
                fileIdentity: columnText(statement, 7) ?? "",
                tokenEstimate: Int(sqlite3_column_int64(statement, 8)),
                upstreamUpdatedAt: columnText(statement, 9) ?? ""
            )
        }
        return states
    }

    private func insertState(
        _ db: OpaquePointer?,
        state: SkillHistoryState,
        validFrom: String,
        origin: SkillHistoryOrigin
    ) throws {
        var statement: OpaquePointer?
        try prepare(db, """
        INSERT INTO history_skill_states (
          skill_key, valid_from, valid_to, name, scope, location, manager,
          source, content_fingerprint, file_identity, token_estimate,
          upstream_updated_at, origin
        ) VALUES (?, ?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """, &statement)
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, state.skillKey)
        bindText(statement, 2, validFrom)
        bindText(statement, 3, state.name)
        bindText(statement, 4, state.scope)
        bindText(statement, 5, state.location)
        bindText(statement, 6, state.manager)
        bindText(statement, 7, state.source)
        bindText(statement, 8, state.contentFingerprint)
        bindText(statement, 9, state.fileIdentity)
        sqlite3_bind_int64(statement, 10, Int64(state.tokenEstimate))
        bindText(statement, 11, state.upstreamUpdatedAt)
        bindText(statement, 12, origin.rawValue)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError(db, "insert skill state")
        }
    }

    private func closeState(_ db: OpaquePointer?, skillKey: String, validTo: String) throws {
        var statement: OpaquePointer?
        try prepare(db, """
        UPDATE history_skill_states SET valid_to = ?
        WHERE skill_key = ? AND valid_to IS NULL;
        """, &statement)
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, validTo)
        bindText(statement, 2, skillKey)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError(db, "close skill state")
        }
    }

    private func insertEvent(_ db: OpaquePointer?, _ event: SkillHistoryEvent) throws {
        let detail = (try? JSONEncoder().encode(event.detail))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        var statement: OpaquePointer?
        try prepare(db, """
        INSERT INTO history_events (
          event_id, occurred_at, kind, subject_key, subject_name, scope, origin, detail
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(event_id) DO NOTHING;
        """, &statement)
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, event.id)
        bindText(statement, 2, iso8601Formatter.string(from: event.occurredAt))
        bindText(statement, 3, event.kind.rawValue)
        bindText(statement, 4, event.subjectKey)
        bindText(statement, 5, event.subjectName)
        bindText(statement, 6, event.scopeKey)
        bindText(statement, 7, event.origin.rawValue)
        bindText(statement, 8, detail)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError(db, "insert event")
        }
    }

    // MARK: Snapshot rows

    private func snapshotID(_ db: OpaquePointer?, day: String) throws -> Int64? {
        var statement: OpaquePointer?
        try prepare(db, "SELECT id FROM history_snapshots WHERE day = ?;", &statement)
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, day)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    private func snapshotOrigin(_ db: OpaquePointer?, id: Int64) throws -> SkillHistoryOrigin? {
        var statement: OpaquePointer?
        try prepare(db, "SELECT origin FROM history_snapshots WHERE id = ?;", &statement)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return columnText(statement, 0).flatMap(SkillHistoryOrigin.init(rawValue:))
    }

    private func upsertSnapshot(
        _ db: OpaquePointer?,
        day: String,
        capturedAt: Date,
        trigger: SkillHistoryTrigger,
        origin: SkillHistoryOrigin,
        existing: Int64?
    ) throws -> Int64 {
        if let existing {
            var statement: OpaquePointer?
            try prepare(db, """
            UPDATE history_snapshots SET captured_at = ?, trigger = ?, origin = ? WHERE id = ?;
            """, &statement)
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, iso8601Formatter.string(from: capturedAt))
            bindText(statement, 2, trigger.rawValue)
            bindText(statement, 3, origin.rawValue)
            sqlite3_bind_int64(statement, 4, existing)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw databaseError(db, "update snapshot")
            }
            return existing
        }
        var statement: OpaquePointer?
        try prepare(db, """
        INSERT INTO history_snapshots (day, captured_at, trigger, origin) VALUES (?, ?, ?, ?);
        """, &statement)
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, day)
        bindText(statement, 2, iso8601Formatter.string(from: capturedAt))
        bindText(statement, 3, trigger.rawValue)
        bindText(statement, 4, origin.rawValue)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError(db, "insert snapshot")
        }
        return sqlite3_last_insert_rowid(db)
    }

    private func deleteMetrics(_ db: OpaquePointer?, snapshotID: Int64) throws {
        var statement: OpaquePointer?
        try prepare(db, "DELETE FROM history_metrics WHERE snapshot_id = ?;", &statement)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, snapshotID)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError(db, "clear metrics")
        }
    }

    private func insertMetric(
        _ db: OpaquePointer?,
        snapshotID: Int64,
        scopeKey: String,
        metric: SkillHistoryMetric,
        value: Double
    ) throws {
        var statement: OpaquePointer?
        try prepare(db, """
        INSERT INTO history_metrics (snapshot_id, scope, metric, value) VALUES (?, ?, ?, ?)
        ON CONFLICT(snapshot_id, scope, metric) DO UPDATE SET value = excluded.value;
        """, &statement)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, snapshotID)
        bindText(statement, 2, scopeKey)
        bindText(statement, 3, metric.rawValue)
        sqlite3_bind_double(statement, 4, value)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError(db, "insert metric")
        }
    }

    // MARK: SQLite plumbing

    private func open(_ db: inout OpaquePointer?) throws {
        guard sqlite3_open(path.path, &db) == SQLITE_OK else {
            let error = databaseError(db, "open \(path.path)")
            sqlite3_close(db)
            db = nil
            throw error
        }
        do {
            try exec(db, "PRAGMA journal_mode=WAL;")
            try exec(db, "PRAGMA synchronous=NORMAL;")
            try exec(db, "PRAGMA busy_timeout=2500;")
        } catch {
            sqlite3_close(db)
            db = nil
            throw error
        }
    }

    private func createSchema(_ db: OpaquePointer?) throws {
        try exec(db, """
        CREATE TABLE IF NOT EXISTS history_snapshots (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          day TEXT NOT NULL UNIQUE,
          captured_at TEXT NOT NULL,
          trigger TEXT NOT NULL,
          origin TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS history_metrics (
          snapshot_id INTEGER NOT NULL REFERENCES history_snapshots(id) ON DELETE CASCADE,
          scope TEXT NOT NULL,
          metric TEXT NOT NULL,
          value REAL NOT NULL,
          PRIMARY KEY (snapshot_id, scope, metric)
        );
        CREATE INDEX IF NOT EXISTS history_metrics_by_metric
          ON history_metrics(metric, scope);
        CREATE TABLE IF NOT EXISTS history_skill_states (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          skill_key TEXT NOT NULL,
          valid_from TEXT NOT NULL,
          valid_to TEXT,
          name TEXT NOT NULL,
          scope TEXT NOT NULL,
          location TEXT NOT NULL,
          manager TEXT NOT NULL,
          source TEXT NOT NULL,
          content_fingerprint TEXT NOT NULL,
          file_identity TEXT NOT NULL DEFAULT '',
          token_estimate INTEGER NOT NULL,
          upstream_updated_at TEXT NOT NULL,
          origin TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS history_states_current
          ON history_skill_states(skill_key, valid_to);
        CREATE TABLE IF NOT EXISTS history_events (
          event_id TEXT PRIMARY KEY,
          occurred_at TEXT NOT NULL,
          kind TEXT NOT NULL,
          subject_key TEXT NOT NULL,
          subject_name TEXT NOT NULL,
          scope TEXT NOT NULL,
          origin TEXT NOT NULL,
          detail TEXT NOT NULL DEFAULT '{}'
        );
        CREATE INDEX IF NOT EXISTS history_events_by_time
          ON history_events(occurred_at);
        CREATE TABLE IF NOT EXISTS history_metadata (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
        """)
    }

    private func prepare(
        _ db: OpaquePointer?,
        _ sql: String,
        _ statement: inout OpaquePointer?
    ) throws {
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError(db, "prepare")
        }
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw databaseError(db, "exec")
        }
    }

    private func scalarInt(_ db: OpaquePointer?, _ sql: String) throws -> Int {
        var statement: OpaquePointer?
        try prepare(db, sql, &statement)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        sqlite3_column_text(statement, index).map { String(cString: $0) }
    }

    private func databaseError(_ db: OpaquePointer?, _ action: String) -> NSError {
        let message = db.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:))
            ?? "unknown sqlite error"
        return NSError(domain: "MetagentHistory", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "\(action): \(message)",
        ])
    }
}

/// A project skill lives at `<root>/.agents/skills/<name>` or the Claude
/// equivalent, so the project root is the grandparent of the skills directory.
func projectRootForSkill(_ skillKey: String) -> String {
    var url = URL(fileURLWithPath: skillKey)
    for _ in 0 ..< 2 {
        url = url.deletingLastPathComponent()
    }
    // `.agents` / `.claude` sits directly under the project root.
    let container = url.lastPathComponent
    return [".agents", ".claude", ".codex"].contains(container)
        ? url.deletingLastPathComponent().path
        : url.path
}
