import Darwin
import Foundation
import SQLite3

public struct SkillUsageRefreshOptions: Sendable, Equatable {
    public var sessionRoots: [String]
    public var databasePath: String?
    public var maxBytes: Int64
    public var maxFiles: Int
    /// Maximum size of one JSONL record. This is intentionally independent
    /// from `maxBytes`, which is the cooperative per-refresh slice budget.
    public var maxRecordBytes: Int64
    public var throttleEveryBytes: Int64
    public var throttleDelayMilliseconds: Int
    /// Zero means an explicit foreground refresh. A positive value makes this
    /// a cooperative background refresh: only one app process may claim the
    /// shared database during the interval.
    public var minimumMaintenanceIntervalSeconds: TimeInterval

    public init(
        sessionRoots: [String] = [],
        databasePath: String? = nil,
        maxBytes: Int64 = 8 * 1_024 * 1_024,
        maxFiles: Int = 12,
        maxRecordBytes: Int64 = 8 * 1_024 * 1_024,
        throttleEveryBytes: Int64 = 0,
        throttleDelayMilliseconds: Int = 0,
        minimumMaintenanceIntervalSeconds: TimeInterval = 0
    ) {
        self.sessionRoots = sessionRoots
        self.databasePath = databasePath
        self.maxBytes = max(1, maxBytes)
        self.maxFiles = max(1, maxFiles)
        self.maxRecordBytes = max(1, maxRecordBytes)
        self.throttleEveryBytes = max(0, throttleEveryBytes)
        self.throttleDelayMilliseconds = max(0, throttleDelayMilliseconds)
        self.minimumMaintenanceIntervalSeconds = max(0, minimumMaintenanceIntervalSeconds)
    }
}

public struct SkillUsageSummary: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let skillName: String
    public let canonicalPath: String?
    public let scope: String
    public let totalInvocations: Int
    public let invocations7d: Int
    public let invocations30d: Int
    public let activeTurns: Int
    public let distinctThreads: Int
    public let repeatInvocations: Int
    public let directInvocations: Int
    public let inferredInvocations: Int
    public let firstUsedAt: String
    public let lastUsedAt: String
}

public struct SkillUsageSnapshot: Codable, Sendable, Equatable {
    public let summaries: [SkillUsageSummary]
    public let totalInvocations: Int
    public let totalFiles: Int
    public let completedFiles: Int
    public let totalBytes: Int64
    public let processedBytes: Int64
    public let isBackfillComplete: Bool
    public let isParserUpgradeBackfill: Bool
    public let displayParserVersion: Int?
    public let targetParserVersion: Int
    public let coverageStartedAt: String?
    public let lastUpdatedAt: String?

    public static let empty = SkillUsageSnapshot(
        summaries: [],
        totalInvocations: 0,
        totalFiles: 0,
        completedFiles: 0,
        totalBytes: 0,
        processedBytes: 0,
        isBackfillComplete: false,
        isParserUpgradeBackfill: false,
        displayParserVersion: nil,
        targetParserVersion: 0,
        coverageStartedAt: nil,
        lastUpdatedAt: nil
    )
}

/// One skill's observed reads on one calendar day.
public struct SkillUsageDayCount: Codable, Sendable, Equatable {
    public let canonicalPath: String?
    public let skillID: String
    public let day: String
    public let count: Int

    public init(canonicalPath: String?, skillID: String, day: String, count: Int) {
        self.canonicalPath = canonicalPath
        self.skillID = skillID
        self.day = day
        self.count = count
    }
}

public struct SkillUsageRefreshReport: Codable, Sendable, Equatable {
    public let snapshot: SkillUsageSnapshot
    public let filesRead: Int
    public let bytesRead: Int64
    public let processedBytesAdvanced: Int64
    public let invocationsAdded: Int
    public let hasMore: Bool
    public let wasDeferred: Bool
    public let warnings: [String]
}

public struct AgentRunDurationStats: Codable, Sendable, Equatable {
    public let windowDays: Int
    public let runCount: Int
    public let medianMilliseconds: Int64
    public let averageMilliseconds: Int64
    public let p90Milliseconds: Int64
    public let totalMilliseconds: Int64
    public let isBackfillComplete: Bool

    public static let empty = AgentRunDurationStats(
        windowDays: 30,
        runCount: 0,
        medianMilliseconds: 0,
        averageMilliseconds: 0,
        p90Milliseconds: 0,
        totalMilliseconds: 0,
        isBackfillComplete: false
    )
}

public extension MetagentCore {
    static func loadSkillUsageSnapshot(databasePath: String? = nil) -> SkillUsageSnapshot? {
        try? SkillUsageStore(path: databasePath).snapshot()
    }

    static func refreshSkillUsage(
        options: SkillUsageRefreshOptions = SkillUsageRefreshOptions()
    ) throws -> SkillUsageRefreshReport {
        try SkillUsageStore(path: options.databasePath).refresh(options: options)
    }

    /// Per-day observed reads for every skill identity in the event log, used to
    /// reconstruct adoption history for dates that predate history capture.
    static func skillUsageDailyCounts(
        databasePath: String? = nil,
        calendar: Calendar = .current
    ) throws -> [SkillUsageDayCount] {
        try SkillUsageStore(path: databasePath).dailyCounts(calendar: calendar)
    }

    static func agentRunDurationStats(
        databasePath: String? = nil,
        windowDays: Int = 30,
        projectRoot: String? = nil,
        now: Date = Date()
    ) throws -> AgentRunDurationStats {
        try SkillUsageStore(path: databasePath).agentRunDurationStats(
            windowDays: windowDays,
            projectRoot: projectRoot,
            now: now
        )
    }

    static func parseSkillUsageTimestamp(_ value: String) -> Date? {
        if let date = iso8601FractionalFormatter.date(from: value) {
            return date
        }
        return iso8601Formatter.date(from: value)
    }

    static func normalizedPluginMarketplace(_ marketplace: String) -> String {
        ["openai-curated", "openai-curated-remote"].contains(marketplace)
            ? "openai-curated"
            : marketplace
    }
}

private let skillUsageParserVersion = 17
private let skillUsageEventsTable = "skill_usage_events"
private let skillUsageSourcesTable = "skill_usage_sources"
private let agentRunsTable = "agent_runs"

private struct SkillUsageDayKey: Hashable {
    let canonicalPath: String
    let skillID: String
    let day: String
}

private let skillUsageMetadataTable = "skill_usage_metadata"
private let previousSkillUsageEventsTable = "skill_usage_events_previous"
private let previousSkillUsageSourcesTable = "skill_usage_sources_previous"
private let previousSkillUsageMetadataTable = "skill_usage_metadata_previous"
private let previousAgentRunsTable = "agent_runs_previous"

private func skillUsageCodexHomeURL() -> URL {
    if let configured = ProcessInfo.processInfo.environment["CODEX_HOME"], !configured.isEmpty {
        return URL(fileURLWithPath: configured).standardizedFileURL
    }
    return homeURL().standardizedFileURL.appendingPathComponent(".codex").standardizedFileURL
}

private struct UsageSource: Sendable {
    let path: String
    let size: Int64
    let modifiedAt: Double
    let fileIdentity: String
    let prefixFingerprint: String
}

private struct UsageSourceMetadata {
    let size: Int64
    let modifiedAt: Double
    let fileIdentity: String
}

private struct UsageSourceState: Sendable {
    var offset: Int64 = 0
    var fileSize: Int64 = 0
    var modifiedAt: Double = 0
    var fileIdentity = ""
    var prefixFingerprint = ""
    var sessionID = ""
    var cwd = ""
    var turnID = ""
    var coverageStartedAt = ""
    var pendingEvents: [String: [ParsedUsageEvent]] = [:]
    var runSessionID = ""
    var runSessionStartedAt = ""
    var runKind = "unknown"
}

private struct ParsedSkillIdentity: Codable, Sendable {
    let id: String
    let name: String
    let confirmationName: String
    let canonicalPath: String
    let scope: String
}

private struct ParsedUsageEvent: Codable, Sendable {
    let id: String
    let skill: ParsedSkillIdentity
    let occurredAt: String
    let sessionID: String
    let turnID: String
    let cwd: String
    let sourcePath: String
    let callID: String
}

private struct ParsedAgentRun: Sendable {
    let id: String
    let sessionID: String
    let turnID: String
    let cwd: String
    let startedAt: String
    let completedAt: String
    let durationMilliseconds: Int64
    let kind: String
    let sourcePath: String
}

private struct FileParseResult: Sendable {
    let state: UsageSourceState
    let events: [ParsedUsageEvent]
    let runs: [ParsedAgentRun]
    let bytesRead: Int64
    let reachedEnd: Bool
    let warning: String?
}

private struct ExecutedCommand: Sendable {
    let text: String
    let workdir: String?
}

private final class SkillUsageStore {
    private let path: URL
    private let fileManager = FileManager.default

    init(path: String?) throws {
        if let path {
            self.path = URL(fileURLWithPath: path)
        } else {
            self.path = homeURL().standardizedFileURL
                .appendingPathComponent("Library/Application Support/Metagent/usage.sqlite")
        }
        try fileManager.createDirectory(
            at: self.path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    func refresh(options: SkillUsageRefreshOptions) throws -> SkillUsageRefreshReport {
        try prepareParserVersion()
        var maintenanceLeaseID: String?
        if options.minimumMaintenanceIntervalSeconds > 0 {
            guard let claimedLeaseID = try claimMaintenanceLease(
                minimumIntervalSeconds: options.minimumMaintenanceIntervalSeconds
            ) else {
                let current = try snapshot()
                return SkillUsageRefreshReport(
                    snapshot: current,
                    filesRead: 0,
                    bytesRead: 0,
                    processedBytesAdvanced: 0,
                    invocationsAdded: 0,
                    hasMore: !current.isBackfillComplete,
                    wasDeferred: true,
                    warnings: []
                )
            }
            maintenanceLeaseID = claimedLeaseID
        }
        defer {
            if let maintenanceLeaseID {
                try? finishMaintenanceLease(id: maintenanceLeaseID)
            }
        }
        var states = try loadSourceStates()
        let sources = discoverSources(roots: options.sessionRoots, states: states)
        let sourcePaths = Set(sources.map(\.path))
        var migrations: [(oldPath: String, newPath: String)] = []
        let orphanedByIdentity = Dictionary(grouping: states.filter {
            !sourcePaths.contains($0.key) && !$0.value.fileIdentity.isEmpty
        }, by: { $0.value.fileIdentity })
        for source in sources where states[source.path] == nil && !source.fileIdentity.isEmpty {
            guard let matches = orphanedByIdentity[source.fileIdentity], matches.count == 1 else { continue }
            migrations.append((matches[0].key, source.path))
        }
        if !migrations.isEmpty {
            for migration in migrations {
                guard var state = states.removeValue(forKey: migration.oldPath) else { continue }
                state.pendingEvents = state.pendingEvents.mapValues { pending in
                    pending.map { event in
                        ParsedUsageEvent(
                            id: event.id,
                            skill: event.skill,
                            occurredAt: event.occurredAt,
                            sessionID: event.sessionID,
                            turnID: event.turnID,
                            cwd: event.cwd,
                            sourcePath: migration.newPath,
                            callID: event.callID
                        )
                    }
                }
                try migrateSource(from: migration.oldPath, to: migration.newPath, state: state)
                states[migration.newPath] = state
            }
        }
        let resetPaths = sources.compactMap { source -> String? in
            guard let state = states[source.path] else { return nil }
            let shrank = state.offset > source.size || state.fileSize > source.size
            let identityChanged = !state.fileIdentity.isEmpty
                && !source.fileIdentity.isEmpty
                && state.fileIdentity != source.fileIdentity
            let prefixChanged = !state.prefixFingerprint.isEmpty
                && !source.prefixFingerprint.isEmpty
                && state.prefixFingerprint != source.prefixFingerprint
            guard shrank || identityChanged || prefixChanged else { return nil }
            return source.path
        }
        if !resetPaths.isEmpty {
            try resetSources(resetPaths)
            for path in resetPaths {
                states.removeValue(forKey: path)
            }
        }
        let startingProgress = progress(for: sources, states: states)
        var candidates = sources.filter { source in
            (states[source.path]?.offset ?? 0) < source.size
        }
        candidates.sort { left, right in
            if left.modifiedAt != right.modifiedAt {
                return left.modifiedAt > right.modifiedAt
            }
            return left.path > right.path
        }

        var filesRead = 0
        var bytesRead: Int64 = 0
        var invocationsAdded = 0
        var warnings: [String] = []
        var identityCache: [String: ParsedSkillIdentity] = [:]

        for source in candidates {
            guard filesRead < options.maxFiles, bytesRead < options.maxBytes else { break }
            let state = states[source.path] ?? UsageSourceState()
            let remainingBudget = max(1, options.maxBytes - bytesRead)
            let result = parse(
                source: source,
                state: state,
                maxBytes: remainingBudget,
                maxRecordBytes: options.maxRecordBytes,
                throttleEveryBytes: options.throttleEveryBytes,
                throttleDelayMilliseconds: options.throttleDelayMilliseconds,
                throttleOffset: bytesRead,
                identityCache: &identityCache
            )
            let added = try save(result: result, source: source)
            states[source.path] = result.state
            filesRead += 1
            bytesRead += result.bytesRead
            invocationsAdded += added
            if let warning = result.warning {
                warnings.append(warning)
            }
        }

        let progress = progress(for: sources, states: states)
        try saveProgress(progress)
        let snapshot = try snapshot()
        return SkillUsageRefreshReport(
            snapshot: snapshot,
            filesRead: filesRead,
            bytesRead: bytesRead,
            processedBytesAdvanced: max(0, progress.processedBytes - startingProgress.processedBytes),
            invocationsAdded: invocationsAdded,
            hasMore: !sources.isEmpty && !progress.isComplete,
            wasDeferred: false,
            warnings: warnings
        )
    }

    private func claimMaintenanceLease(minimumIntervalSeconds: TimeInterval) throws -> String? {
        var db: OpaquePointer?
        try open(&db)
        defer { sqlite3_close(db) }
        try createSchema(db)
        let now = Date()
        try exec(db, "BEGIN IMMEDIATE;")
        do {
            let lastFinished = try scalarText(
                db,
                "SELECT value FROM \(skillUsageMetadataTable) WHERE key = 'maintenance_finished_at';"
            ).flatMap(MetagentCore.parseSkillUsageTimestamp)
            let leaseExpires = try scalarText(
                db,
                "SELECT value FROM \(skillUsageMetadataTable) WHERE key = 'maintenance_lease_expires_at';"
            ).flatMap(MetagentCore.parseSkillUsageTimestamp)
            if lastFinished.map({ now.timeIntervalSince($0) < minimumIntervalSeconds }) == true
                || leaseExpires.map({ $0 > now }) == true
            {
                try exec(db, "COMMIT;")
                return nil
            }
            let leaseID = UUID().uuidString.lowercased()
            try upsertMetadata(
                db,
                key: "maintenance_lease_expires_at",
                value: iso8601Formatter.string(from: now.addingTimeInterval(5 * 60))
            )
            try upsertMetadata(db, key: "maintenance_lease_id", value: leaseID)
            try exec(db, "COMMIT;")
            return leaseID
        } catch {
            try? exec(db, "ROLLBACK;")
            throw error
        }
    }

    private func finishMaintenanceLease(id: String) throws {
        var db: OpaquePointer?
        try open(&db)
        defer { sqlite3_close(db) }
        try createSchema(db)
        try exec(db, "BEGIN IMMEDIATE;")
        do {
            let currentLeaseID = try scalarText(
                db,
                "SELECT value FROM \(skillUsageMetadataTable) WHERE key = 'maintenance_lease_id';"
            )
            guard currentLeaseID == id else {
                try exec(db, "COMMIT;")
                return
            }
            try upsertMetadata(
                db,
                key: "maintenance_finished_at",
                value: iso8601Formatter.string(from: Date())
            )
            try exec(
                db,
                "DELETE FROM \(skillUsageMetadataTable) "
                    + "WHERE key IN ('maintenance_lease_expires_at', 'maintenance_lease_id');"
            )
            try exec(db, "COMMIT;")
        } catch {
            try? exec(db, "ROLLBACK;")
            throw error
        }
    }

    func snapshot() throws -> SkillUsageSnapshot {
        var db: OpaquePointer?
        try open(&db)
        defer { sqlite3_close(db) }
        try createSchema(db)
        try exec(db, "BEGIN;")
        do {
            let snapshot = try snapshot(db)
            try exec(db, "COMMIT;")
            return snapshot
        } catch {
            try? exec(db, "ROLLBACK;")
            throw error
        }
    }

    /// Per-day read counts for every observed skill identity, grouped with the
    /// same local calendar the history store uses for its snapshots.
    ///
    /// The event log is the only store that already carries a timestamp on every
    /// row, so it is the one source history can reconstruct backwards rather
    /// than only accumulate forwards.
    func dailyCounts(calendar: Calendar) throws -> [SkillUsageDayCount] {
        var db: OpaquePointer?
        try open(&db)
        defer { sqlite3_close(db) }
        try createSchema(db)
        let table = try previousGenerationExists(db)
            ? previousSkillUsageEventsTable
            : skillUsageEventsTable
        let sql = """
        SELECT
          CASE WHEN canonical_path != '' THEN canonical_path ELSE '' END,
          skill_id,
          occurred_at
        FROM \(table)
        WHERE trim(occurred_at) != ''
          AND julianday(occurred_at) IS NOT NULL
        ORDER BY occurred_at;
        """
        var statement: OpaquePointer?
        try prepare(db, sql, &statement)
        defer { sqlite3_finalize(statement) }
        var grouped: [SkillUsageDayKey: Int] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let canonicalPath = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
            let skillID = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            guard let occurredAt = sqlite3_column_text(statement, 2).map({ String(cString: $0) }),
                  let date = MetagentCore.parseSkillUsageTimestamp(occurredAt)
            else { continue }
            let key = SkillUsageDayKey(
                canonicalPath: canonicalPath,
                skillID: skillID,
                day: historyDay(date, calendar: calendar)
            )
            grouped[key, default: 0] += 1
        }
        return grouped
            .map { key, count in
                SkillUsageDayCount(
                    canonicalPath: key.canonicalPath.isEmpty ? nil : key.canonicalPath,
                    skillID: key.skillID,
                    day: key.day,
                    count: count
                )
            }
            .sorted {
                ($0.day, $0.canonicalPath ?? "", $0.skillID)
                    < ($1.day, $1.canonicalPath ?? "", $1.skillID)
            }
    }

    func agentRunDurationStats(
        windowDays: Int,
        projectRoot: String?,
        now: Date
    ) throws -> AgentRunDurationStats {
        var db: OpaquePointer?
        try open(&db)
        defer { sqlite3_close(db) }
        try createSchema(db)

        let hasPrevious = try previousGenerationExists(db)
        let previousRunsAreUsable = try tableExists(db, previousAgentRunsTable)
            && columnExists(db, table: previousAgentRunsTable, column: "run_kind")
        let previousCount = previousRunsAreUsable
            ? try scalarInt(db, "SELECT COUNT(*) FROM \(previousAgentRunsTable);")
            : 0
        let table = previousCount > 0 ? previousAgentRunsTable : agentRunsTable
        let normalizedRoot = projectRoot.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }
        let cutoff = iso8601Formatter.string(
            from: now.addingTimeInterval(-Double(max(1, windowDays)) * 86_400)
        )

        var statement: OpaquePointer?
        try prepare(db, """
        SELECT duration_ms, cwd
        FROM \(table)
        WHERE completed_at >= ?
          AND duration_ms >= 0
          AND run_kind = 'user'
        ORDER BY duration_ms;
        """, &statement)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, cutoff)

        var durations: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let cwd = text(statement, 1)
            if let root = normalizedRoot {
                guard cwd == root || cwd.hasPrefix(root + "/") else { continue }
            }
            durations.append(sqlite3_column_int64(statement, 0))
        }

        let metadata = try loadMetadata(db, table: skillUsageMetadataTable)
        let isComplete = previousCount > 0
            || (
                metadata["parser_version"] == String(skillUsageParserVersion)
                    && metadata["is_complete"] == "1"
                    && !hasPrevious
            )
        guard !durations.isEmpty else {
            return AgentRunDurationStats(
                windowDays: max(1, windowDays),
                runCount: 0,
                medianMilliseconds: 0,
                averageMilliseconds: 0,
                p90Milliseconds: 0,
                totalMilliseconds: 0,
                isBackfillComplete: isComplete
            )
        }
        let total = durations.reduce(Int64(0), +)
        let middle = durations.count / 2
        let median = durations.count.isMultiple(of: 2)
            ? (durations[middle - 1] + durations[middle]) / 2
            : durations[middle]
        let p90Index = max(0, Int(ceil(Double(durations.count) * 0.9)) - 1)
        return AgentRunDurationStats(
            windowDays: max(1, windowDays),
            runCount: durations.count,
            medianMilliseconds: median,
            averageMilliseconds: total / Int64(durations.count),
            p90Milliseconds: durations[p90Index],
            totalMilliseconds: total,
            isBackfillComplete: isComplete
        )
    }

    private func snapshot(_ db: OpaquePointer?) throws -> SkillUsageSnapshot {
        let metadata = try loadMetadata(db, table: skillUsageMetadataTable)
        let hasPreviousGeneration = try previousGenerationExists(db)
        let storedParserVersion = Int(metadata["parser_version"] ?? "")
        let isParserUpgradeBackfill = hasPreviousGeneration
            || (storedParserVersion != nil && storedParserVersion != skillUsageParserVersion)
        let summariesTable = hasPreviousGeneration
            ? previousSkillUsageEventsTable
            : skillUsageEventsTable
        let coverageTable = hasPreviousGeneration
            ? previousSkillUsageSourcesTable
            : skillUsageSourcesTable
        let displayMetadata = hasPreviousGeneration
            ? try loadMetadata(db, table: previousSkillUsageMetadataTable)
            : metadata

        let sql = """
        WITH normalized AS (
          SELECT
            *,
            rowid AS event_rowid,
            CASE
              WHEN skill_id LIKE 'plugin:%' THEN 'id:' || skill_id
              WHEN canonical_path != '' THEN 'path:' || canonical_path
              ELSE 'id:' || skill_id
            END AS aggregate_id
          FROM \(summariesTable)
        ), ranked AS (
          SELECT
            *,
            ROW_NUMBER() OVER (
              PARTITION BY aggregate_id
              ORDER BY occurred_at DESC, event_rowid DESC
            ) AS identity_rank
          FROM normalized
        ), identity_counts AS (
          SELECT skill_id, COUNT(DISTINCT aggregate_id) AS aggregate_count
          FROM normalized
          GROUP BY skill_id
        )
        SELECT
          CASE
            WHEN MAX(identity_counts.aggregate_count) > 1 THEN ranked.aggregate_id
            ELSE MAX(CASE WHEN identity_rank = 1 THEN ranked.skill_id END)
          END,
          MAX(CASE WHEN identity_rank = 1 THEN skill_name END),
          MAX(CASE WHEN identity_rank = 1 THEN NULLIF(canonical_path, '') END),
          MAX(CASE WHEN identity_rank = 1 THEN scope END),
          COUNT(*),
          SUM(CASE WHEN julianday(occurred_at) >= julianday('now', '-7 days') THEN 1 ELSE 0 END),
          SUM(CASE WHEN julianday(occurred_at) >= julianday('now', '-30 days') THEN 1 ELSE 0 END),
          COUNT(DISTINCT session_id || char(0) || turn_id),
          COUNT(DISTINCT session_id),
          COUNT(*) - COUNT(DISTINCT session_id || char(0) || turn_id),
          SUM(CASE WHEN evidence = 'otel' THEN 1 ELSE 0 END),
          SUM(CASE WHEN evidence != 'otel' THEN 1 ELSE 0 END),
          MIN(occurred_at),
          MAX(occurred_at)
        FROM ranked
        JOIN identity_counts USING (skill_id)
        GROUP BY aggregate_id
        ORDER BY COUNT(*) DESC, lower(MAX(CASE WHEN identity_rank = 1 THEN skill_name END)), aggregate_id;
        """
        var statement: OpaquePointer?
        try prepare(db, sql, &statement)
        defer { sqlite3_finalize(statement) }

        var summaries: [SkillUsageSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            summaries.append(SkillUsageSummary(
                id: text(statement, 0),
                skillName: text(statement, 1),
                canonicalPath: optionalText(statement, 2),
                scope: text(statement, 3),
                totalInvocations: Int(sqlite3_column_int64(statement, 4)),
                invocations7d: Int(sqlite3_column_int64(statement, 5)),
                invocations30d: Int(sqlite3_column_int64(statement, 6)),
                activeTurns: Int(sqlite3_column_int64(statement, 7)),
                distinctThreads: Int(sqlite3_column_int64(statement, 8)),
                repeatInvocations: Int(sqlite3_column_int64(statement, 9)),
                directInvocations: Int(sqlite3_column_int64(statement, 10)),
                inferredInvocations: Int(sqlite3_column_int64(statement, 11)),
                firstUsedAt: text(statement, 12),
                lastUsedAt: text(statement, 13)
            ))
        }

        return SkillUsageSnapshot(
            summaries: summaries,
            totalInvocations: summaries.reduce(0) { $0 + $1.totalInvocations },
            totalFiles: Int(metadata["total_files"] ?? "0") ?? 0,
            completedFiles: Int(metadata["completed_files"] ?? "0") ?? 0,
            totalBytes: Int64(metadata["total_bytes"] ?? "0") ?? 0,
            processedBytes: Int64(metadata["processed_bytes"] ?? "0") ?? 0,
            isBackfillComplete: metadata["is_complete"] == "1" && !isParserUpgradeBackfill,
            isParserUpgradeBackfill: isParserUpgradeBackfill,
            displayParserVersion: Int(displayMetadata["parser_version"] ?? ""),
            targetParserVersion: skillUsageParserVersion,
            coverageStartedAt: try scalarText(
                db,
                "SELECT MIN(NULLIF(coverage_started_at, '')) FROM \(coverageTable);"
            ),
            lastUpdatedAt: metadata["last_updated_at"]
        )
    }

    /// Reads the regular-file check, size, modification time, and stable
    /// identity from one metadata snapshot. Source discovery used to ask
    /// Foundation for size/time and then call `lstat` again for identity,
    /// doubling metadata syscalls for every retained session on every slice.
    private func sourceMetadata(path: String) -> UsageSourceMetadata? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        if (info.st_mode & S_IFMT) == S_IFLNK {
            // Preserve the existing behavior for the unusual case of a
            // symlinked JSONL file: enumerate the target as a regular file,
            // but identify the directory entry so replacing the link resets
            // its cursor. Normal session files stay on the one-syscall path.
            let url = URL(fileURLWithPath: path)
            let keys: Set<URLResourceKey> = [
                .isRegularFileKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ]
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true
            else { return nil }
            return UsageSourceMetadata(
                size: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
                fileIdentity: fileIdentity(info)
            )
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return UsageSourceMetadata(
            size: Int64(info.st_size),
            modifiedAt: TimeInterval(info.st_mtimespec.tv_sec)
                + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000,
            fileIdentity: fileIdentity(info)
        )
    }

    private func fileIdentity(_ info: stat) -> String {
        "\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)"
    }

    private func prefixFingerprint(path: String, maxBytes: Int = 8_192) -> String {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return ""
        }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: max(0, maxBytes))) ?? Data()
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "\(data.count):\(String(hash, radix: 16))"
    }

    private func fingerprintByteCount(_ fingerprint: String) -> Int? {
        guard let separator = fingerprint.firstIndex(of: ":") else { return nil }
        return Int(fingerprint[..<separator])
    }

    private func discoverSources(
        roots: [String],
        states: [String: UsageSourceState]
    ) -> [UsageSource] {
        let resolvedRoots: [URL]
        if roots.isEmpty {
            let codex = skillUsageCodexHomeURL()
            resolvedRoots = [
                codex.appendingPathComponent("sessions"),
                codex.appendingPathComponent("archived_sessions")
            ]
        } else {
            resolvedRoots = roots.map { URL(fileURLWithPath: $0).standardizedFileURL }
        }

        var seen = Set<String>()
        var sources: [UsageSource] = []
        for root in resolvedRoots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
                let path = fileURL.standardizedFileURL.path
                guard seen.insert(path).inserted,
                      let metadata = sourceMetadata(path: path)
                else { continue }
                let size = metadata.size
                let modifiedAt = metadata.modifiedAt
                let existing = states[path]
                let shouldCheckPrefix = existing.map {
                    $0.modifiedAt != modifiedAt
                        || $0.fileSize != size
                        || (!$0.fileIdentity.isEmpty && $0.fileIdentity != metadata.fileIdentity)
                } ?? false
                sources.append(UsageSource(
                    path: path,
                    size: size,
                    modifiedAt: modifiedAt,
                    fileIdentity: metadata.fileIdentity,
                    prefixFingerprint: shouldCheckPrefix
                        ? prefixFingerprint(
                            path: path,
                            maxBytes: fingerprintByteCount(existing?.prefixFingerprint ?? "") ?? 8_192
                        )
                        : (existing?.prefixFingerprint ?? "")
                ))
            }
        }
        return sources
    }

    private func parse(
        source: UsageSource,
        state initialState: UsageSourceState,
        maxBytes: Int64,
        maxRecordBytes: Int64,
        throttleEveryBytes: Int64,
        throttleDelayMilliseconds: Int,
        throttleOffset: Int64,
        identityCache: inout [String: ParsedSkillIdentity]
    ) -> FileParseResult {
        guard let file = fopen(source.path, "r") else {
            return FileParseResult(
                state: initialState,
                events: [],
                runs: [],
                bytesRead: 0,
                reachedEnd: false,
                warning: "Could not read \(source.path)"
            )
        }
        defer { fclose(file) }
        guard fseeko(file, off_t(initialState.offset), SEEK_SET) == 0 else {
            return FileParseResult(
                state: initialState,
                events: [],
                runs: [],
                bytesRead: 0,
                reachedEnd: false,
                warning: "Could not seek \(source.path)"
            )
        }

        var state = initialState
        state.fileSize = source.size
        state.modifiedAt = source.modifiedAt
        state.fileIdentity = source.fileIdentity
        // Discovery already fingerprints changed sources so reset detection
        // and the saved cursor can usually reuse the same view of the file.
        // A file that grew beyond its old fingerprint still needs one read to
        // extend coverage to the normal 8 KiB prefix.
        let desiredFingerprintBytes = Int(min(Int64(8_192), max(0, source.size)))
        state.prefixFingerprint = fingerprintByteCount(source.prefixFingerprint)
            == desiredFingerprintBytes
            ? source.prefixFingerprint
            : prefixFingerprint(path: source.path)
        var events: [ParsedUsageEvent] = []
        var runs: [ParsedAgentRun] = []
        var warning: String?
        var bytesRead: Int64 = 0
        var nextThrottleAt = throttleEveryBytes > 0
            ? ((throttleOffset / throttleEveryBytes) + 1) * throttleEveryBytes
            : 0
        while true {
            let lineStart = Int64(ftello(file))
            let remainingLineBudget = maxBytes - bytesRead
            guard remainingLineBudget > 0 else { break }
            // The refresh byte limit is a soft scheduling boundary, not a
            // record-size limit. If a record does not fit at the end of this
            // slice, rewind it so the next slice can parse it whole. A record
            // at the start of a slice may exceed the slice to ensure progress.
            let lineReadLimit = bytesRead == 0
                ? maxRecordBytes
                : min(remainingLineBudget, maxRecordBytes)
            let read = readBoundedLine(file, maxBytes: lineReadLimit)
            guard let read else { break }
            if read.exceededLimit {
                if bytesRead > 0, remainingLineBudget < maxRecordBytes {
                    fseeko(file, off_t(lineStart), SEEK_SET)
                    state.offset = lineStart
                    break
                }
                if !read.isTerminated {
                    discardRemainderOfLine(file)
                }
                state.offset = Int64(ftello(file))
                bytesRead += max(0, state.offset - lineStart)
                warning = "Skipped oversized JSONL record in \(source.path) at byte \(lineStart)"
                break
            }
            let lineBytes = Int64(read.data.count)
            bytesRead += lineBytes
            if !read.isTerminated {
                fseeko(file, off_t(lineStart), SEEK_SET)
                state.offset = lineStart
                break
            }
            state.offset = Int64(ftello(file))
            parseLine(
                read.data,
                lineOffset: lineStart,
                sourcePath: source.path,
                state: &state,
                identityCache: &identityCache,
                events: &events,
                runs: &runs
            )
            if throttleEveryBytes > 0,
               throttleDelayMilliseconds > 0,
               throttleOffset + bytesRead >= nextThrottleAt
            {
                let crossedIntervals = ((throttleOffset + bytesRead - nextThrottleAt) / throttleEveryBytes) + 1
                Thread.sleep(
                    forTimeInterval: Double(throttleDelayMilliseconds) * Double(crossedIntervals) / 1_000
                )
                nextThrottleAt += throttleEveryBytes * crossedIntervals
            }
            if bytesRead >= maxBytes { break }
        }

        return FileParseResult(
            state: state,
            events: events,
            runs: runs,
            bytesRead: bytesRead,
            reachedEnd: state.offset >= source.size,
            warning: warning
        )
    }

    private func discardRemainderOfLine(_ file: UnsafeMutablePointer<FILE>) {
        var buffer = [CChar](repeating: 0, count: 64 * 1_024)
        while fgets(&buffer, Int32(buffer.count), file) != nil {
            let count = Int(strlen(buffer))
            if count > 0, buffer[count - 1] == 10 { break }
        }
    }

    private func readBoundedLine(
        _ file: UnsafeMutablePointer<FILE>,
        maxBytes: Int64
    ) -> (data: Data, isTerminated: Bool, exceededLimit: Bool)? {
        let bufferSize = 64 * 1_024
        var buffer = [CChar](repeating: 0, count: bufferSize)
        var data = Data()
        while true {
            guard fgets(&buffer, Int32(buffer.count), file) != nil else {
                return data.isEmpty ? nil : (data, false, false)
            }
            let count = Int(strlen(buffer))
            guard Int64(data.count + count) <= maxBytes else {
                return (Data(), count > 0 && buffer[count - 1] == 10, true)
            }
            data.append(buffer.withUnsafeBytes { Data($0.prefix(count)) })
            if count > 0, buffer[count - 1] == 10 {
                return (data, true, false)
            }
        }
    }

    private func parseLine(
        _ data: Data,
        lineOffset: Int64,
        sourcePath: String,
        state: inout UsageSourceState,
        identityCache: inout [String: ParsedSkillIdentity],
        events: inout [ParsedUsageEvent],
        runs: inout [ParsedAgentRun]
    ) {
        guard Self.containsUsageMarker(in: data) else { return }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String,
              let payload = object["payload"] as? [String: Any]
        else { return }

        if type == "session_meta" {
            let sessionID = string(payload["id"] ?? payload["session_id"])
            state.sessionID = sessionID
            state.cwd = string(payload["cwd"])
            let timestamp = string(object["timestamp"] ?? payload["timestamp"])
            if !timestamp.isEmpty,
               state.coverageStartedAt.isEmpty || timestamp < state.coverageStartedAt
            {
                state.coverageStartedAt = timestamp
            }
            let sourceSessionID = rolloutSessionID(sourcePath)
            if state.runSessionID.isEmpty,
               sourceSessionID == nil || sourceSessionID == sessionID
            {
                state.runSessionID = sessionID
                state.runSessionStartedAt = timestamp
                state.runKind = agentRunKind(payload)
            }
            return
        }
        if type == "turn_context" {
            state.turnID = string(payload["turn_id"])
            let cwd = string(payload["cwd"])
            if !cwd.isEmpty { state.cwd = cwd }
            return
        }
        if type == "event_msg" {
            let eventType = string(payload["type"])
            guard eventType == "task_complete" else { return }
            let turnID = string(payload["turn_id"])
            guard !turnID.isEmpty,
                  !state.runSessionID.isEmpty,
                  let startedDate = unixTimestampDate(payload["started_at"]),
                  let completedDate = unixTimestampDate(payload["completed_at"]),
                  completedDate >= startedDate
            else { return }

            // Forked and subagent rollouts contain copied parent history whose
            // JSONL wrapper timestamps are rewritten to the fork time. The
            // payload timestamps retain the real task time. Only events that
            // began in this source session belong to this file; the originals
            // are retained in their own rollout and deduplicate by turn there.
            if let sessionStarted = MetagentCore.parseSkillUsageTimestamp(state.runSessionStartedAt) {
                // Payload epochs are often whole seconds while the session
                // timestamp includes fractions. Keep starts from the same
                // second, but reject everything from an earlier second.
                let sessionStartSecond = Date(
                    timeIntervalSince1970: floor(sessionStarted.timeIntervalSince1970)
                )
                if startedDate < sessionStartSecond { return }
            }

            let recordedDuration = int64(payload["duration_ms"])
            let derivedDuration = Int64((completedDate.timeIntervalSince(startedDate) * 1_000).rounded())
            let duration = recordedDuration ?? derivedDuration
            guard duration >= 0 else { return }
            runs.append(ParsedAgentRun(
                id: "\(state.runSessionID)\u{1F}\(turnID)",
                sessionID: state.runSessionID,
                turnID: turnID,
                cwd: state.cwd,
                startedAt: iso8601Formatter.string(from: startedDate),
                completedAt: iso8601Formatter.string(from: completedDate),
                durationMilliseconds: duration,
                kind: state.runKind,
                sourcePath: sourcePath
            ))
            return
        }
        guard type == "response_item", let itemType = payload["type"] as? String else { return }
        if ["custom_tool_call_output", "function_call_output", "local_shell_call_output"].contains(itemType) {
            let callID = string(payload["call_id"] ?? payload["id"])
            guard !callID.isEmpty, let pending = state.pendingEvents.removeValue(forKey: callID) else {
                return
            }
            let output = collectStrings(payload["output"] ?? payload["result"]).joined(separator: "\n")
            events.append(contentsOf: pending.filter { outputConfirmsRead($0, output: output) })
            return
        }
        guard ["custom_tool_call", "function_call", "local_shell_call"].contains(itemType) else {
            return
        }

        let toolName = string(payload["name"])
        guard isSupportedReadTool(name: toolName, itemType: itemType) else { return }

        let callID = string(payload["call_id"] ?? payload["id"])
        guard !callID.isEmpty else { return }
        if let metadata = payload["internal_chat_message_metadata_passthrough"] as? [String: Any] {
            let turnID = string(metadata["turn_id"])
            if !turnID.isEmpty { state.turnID = turnID }
        }
        var pending: [ParsedUsageEvent] = []
        for (commandIndex, command) in executedCommands(payload: payload, itemType: itemType).enumerated() {
            let executionCWD = commandExecutionCWD(command, sessionCWD: state.cwd)
            for (readIndex, rawPath) in extractExecutedSkillPaths(command.text).enumerated() {
                let resolvedPath = resolve(path: rawPath, cwd: executionCWD)
                let skill = identityCache[resolvedPath] ?? identify(path: resolvedPath)
                identityCache[resolvedPath] = skill
                let sessionID = state.sessionID.isEmpty ? sourcePath : state.sessionID
                let turnID = state.turnID.isEmpty ? "unknown" : state.turnID
                pending.append(ParsedUsageEvent(
                    id: "\(sessionID)\u{1F}\(callID)\u{1F}\(commandIndex)\u{1F}\(readIndex)\u{1F}\(skill.id)",
                    skill: skill,
                    occurredAt: string(object["timestamp"]),
                    sessionID: sessionID,
                    turnID: turnID,
                    cwd: executionCWD,
                    sourcePath: sourcePath,
                    callID: callID
                ))
            }
        }
        if !pending.isEmpty {
            state.pendingEvents[callID] = pending
        }
    }

    /// Most session records cannot affect usage or run timing. Inspect their
    /// UTF-8 bytes before allocating a Swift String or decoding JSON. Large
    /// retained histories contain millions of token and message records, so
    /// this cheap gate is the difference between an incremental index and a
    /// sustained CPU workload.
    private static func containsUsageMarker(in data: Data) -> Bool {
        usageMarkers.contains { data.range(of: $0) != nil }
    }

    private static let usageMarkers = [
        Data("session_meta".utf8),
        Data("turn_context".utf8),
        Data("task_complete".utf8),
        Data("tool_call_output".utf8),
        Data("function_call_output".utf8),
        Data("shell_call_output".utf8),
        Data("SKILL.md".utf8),
    ]

    private func outputConfirmsRead(_ event: ParsedUsageEvent, output: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: event.skill.confirmationName)
        let pattern = #"(?im)^.*\bname:\s*[\"']?"# + escaped + #"[\"']?\s*$"#
        if output.range(of: pattern, options: .regularExpression) != nil { return true }
        if output.range(of: #"(?im)^.*\bname:\s*[\"']?[^\r\n]+$"#, options: .regularExpression) != nil {
            return false
        }
        let substantiveLines = output.components(separatedBy: .newlines).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "Output:" { return false }
            if trimmed.localizedCaseInsensitiveContains("Script completed") { return false }
            if trimmed.localizedCaseInsensitiveContains("Wall time") { return false }
            return true
        }
        guard let first = substantiveLines.first?.trimmingCharacters(in: .whitespaces) else {
            return false
        }
        let leadingFailure = #"(?i)^(?:Script failed|Rejected\(|Process exited with code\s+(?:-[0-9]+|[1-9][0-9]*)\b|(?:cat|sed|head|tail|bat|zsh|bash|sh):.*(?:No such file or directory|Permission denied|Operation not permitted|command not found|cannot open|can't open))"#
        return first.range(of: leadingFailure, options: .regularExpression) == nil
    }

    private func collectStrings(_ value: Any?) -> [String] {
        if let value = value as? String {
            if let data = value.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                let content = ["text", "output", "result", "content", "message"].flatMap {
                    collectStrings(object[$0])
                }
                if let failure = structuredFailureLine(object) { return [failure] + content }
                if !content.isEmpty { return content }
            }
            return [value]
        }
        if let values = value as? [Any] { return values.flatMap(collectStrings) }
        if let values = value as? [String: Any] {
            let content = ["text", "output", "result", "content", "message"].flatMap {
                collectStrings(values[$0])
            }
            if let failure = structuredFailureLine(values) { return [failure] + content }
            return content.isEmpty ? values.values.flatMap(collectStrings) : content
        }
        return []
    }

    private func structuredFailureLine(_ object: [String: Any]) -> String? {
        if let exitCode = (object["exit_code"] as? Int) ?? (object["exitCode"] as? Int),
           exitCode != 0
        {
            return "Process exited with code \(exitCode)"
        }
        if object["success"] as? Bool == false { return "Script failed" }
        guard let status = object["status"] as? String else { return nil }
        switch status.lowercased() {
        case "failed", "failure", "error", "rejected": return "Script failed"
        default: return nil
        }
    }

    private func isSupportedReadTool(name: String, itemType: String) -> Bool {
        if itemType == "local_shell_call" { return true }
        let normalized = name.lowercased()
        return normalized == "exec"
            || normalized.hasSuffix(".exec")
            || normalized == "exec_command"
            || normalized.hasSuffix(".exec_command")
            || normalized == "shell"
            || normalized == "shell_command"
            || normalized.hasSuffix(".shell_command")
    }

    private func executedCommands(payload: [String: Any], itemType: String) -> [ExecutedCommand] {
        if itemType == "local_shell_call" {
            let workdir = string(payload["workdir"] ?? payload["cwd"])
            return commandStrings(payload["command"] ?? payload["cmd"]).map {
                ExecutedCommand(text: $0, workdir: workdir.isEmpty ? nil : workdir)
            }
        }

        if let arguments = payload["arguments"] as? String,
           let data = arguments.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            return executedCommands(from: object)
        }
        if let arguments = payload["arguments"] as? [String: Any] {
            return executedCommands(from: arguments)
        }

        guard let input = payload["input"] as? String else { return [] }
        return extractJavaScriptExecCommands(input)
    }

    private func executedCommands(from object: [String: Any]) -> [ExecutedCommand] {
        let workdir = string(object["workdir"] ?? object["cwd"])
        return commandStrings(object["cmd"] ?? object["command"]).map {
            ExecutedCommand(text: $0, workdir: workdir.isEmpty ? nil : workdir)
        }
    }

    private func commandStrings(_ value: Any?) -> [String] {
        if let value = value as? String { return [value] }
        if let values = value as? [String] { return values }
        if let values = value as? [Any] {
            return values.compactMap { $0 as? String }
        }
        return []
    }

    private func extractJavaScriptValues(_ source: String, property: String) -> [String] {
        let characters = Array(source)
        var commands: [String] = []
        var index = 0
        while index < characters.count {
            if let next = skipJavaScriptNonCode(characters, from: index) {
                index = next
                continue
            }
            guard isIdentifierStart(characters[index]) else {
                index += 1
                continue
            }
            let start = index
            index += 1
            while index < characters.count, isIdentifierPart(characters[index]) { index += 1 }
            guard String(characters[start..<index]) == property else { continue }
            var cursor = index
            while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
            guard cursor < characters.count, characters[cursor] == ":" else { continue }
            cursor += 1
            while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
            guard cursor < characters.count,
                  characters[cursor] == "\"" || characters[cursor] == "'" || characters[cursor] == "`",
                  let parsed = parseJavaScriptString(characters, from: cursor)
            else { continue }
            if !parsed.value.contains("${") {
                commands.append(parsed.value)
            }
            index = parsed.nextIndex
        }
        return commands
    }

    private func extractJavaScriptExecCommands(_ source: String) -> [ExecutedCommand] {
        let characters = Array(source)
        let marker = Array("tools.exec_command")
        var results: [ExecutedCommand] = []
        var index = 0
        while index < characters.count {
            if let next = skipJavaScriptNonCode(characters, from: index) {
                index = next
                continue
            }
            let markerEnd = index + marker.count
            guard markerEnd <= characters.count,
                  Array(characters[index..<markerEnd]) == marker,
                  index == 0 || !isIdentifierPart(characters[index - 1])
            else {
                index += 1
                continue
            }
            var cursor = markerEnd
            while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
            guard cursor < characters.count, characters[cursor] == "(" else {
                index = markerEnd
                continue
            }
            let bodyStart = cursor + 1
            cursor = bodyStart
            var depth = 1
            while cursor < characters.count, depth > 0 {
                if characters[cursor] == "\"" || characters[cursor] == "'" || characters[cursor] == "`" {
                    cursor = skipJavaScriptString(characters, from: cursor)
                    continue
                }
                if characters[cursor] == "(" { depth += 1 }
                if characters[cursor] == ")" { depth -= 1 }
                cursor += 1
            }
            guard depth == 0 else { break }
            let body = String(characters[bodyStart..<(cursor - 1)])
            let workdir = extractJavaScriptValues(body, property: "workdir").first
            for command in extractJavaScriptValues(body, property: "cmd") {
                results.append(ExecutedCommand(text: command, workdir: workdir))
            }
            index = cursor
        }
        return results
    }

    private func commandExecutionCWD(_ command: ExecutedCommand, sessionCWD: String) -> String {
        if let workdir = command.workdir, !workdir.isEmpty {
            return resolve(path: workdir, cwd: sessionCWD)
        }
        let pattern = #"^\s*cd\s+(?:--\s+)?(\"[^\"]+\"|'[^']+'|[^;&|\s]+)\s*&&"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: command.text,
                range: NSRange(command.text.startIndex..<command.text.endIndex, in: command.text)
              ),
              let directoryRange = Range(match.range(at: 1), in: command.text)
        else { return sessionCWD }
        let directory = String(command.text[directoryRange])
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .replacingOccurrences(of: #"\ "#, with: " ")
        return resolve(path: directory, cwd: sessionCWD)
    }

    /// Returns the index just past a comment or string literal starting at
    /// `index`, or nil when that position is ordinary code. Both JavaScript
    /// scanners use this to stay out of quoted and commented text.
    private func skipJavaScriptNonCode(_ characters: [Character], from index: Int) -> Int? {
        if characters[index] == "/", index + 1 < characters.count {
            if characters[index + 1] == "/" {
                var cursor = index + 2
                while cursor < characters.count, characters[cursor] != "\n" { cursor += 1 }
                return cursor
            }
            if characters[index + 1] == "*" {
                var cursor = index + 2
                while cursor + 1 < characters.count,
                      !(characters[cursor] == "*" && characters[cursor + 1] == "/")
                { cursor += 1 }
                return min(characters.count, cursor + 2)
            }
        }
        if characters[index] == "\"" || characters[index] == "'" || characters[index] == "`" {
            return skipJavaScriptString(characters, from: index)
        }
        return nil
    }

    private func skipJavaScriptString(_ characters: [Character], from start: Int) -> Int {
        parseJavaScriptString(characters, from: start)?.nextIndex ?? characters.count
    }

    private func parseJavaScriptString(
        _ characters: [Character],
        from start: Int
    ) -> (value: String, nextIndex: Int)? {
        guard start < characters.count else { return nil }
        let quote = characters[start]
        var index = start + 1
        var value = ""
        while index < characters.count {
            let character = characters[index]
            if character == quote {
                return (value, index + 1)
            }
            if character == "\\" {
                index += 1
                guard index < characters.count else { return nil }
                let escaped = characters[index]
                switch escaped {
                case "n": value.append("\n")
                case "r": value.append("\r")
                case "t": value.append("\t")
                case "\n": break
                default: value.append(escaped)
                }
                index += 1
                continue
            }
            value.append(character)
            index += 1
        }
        return nil
    }

    private func isIdentifierStart(_ character: Character) -> Bool {
        character == "_" || character == "$" || character.isLetter
    }

    private func isIdentifierPart(_ character: Character) -> Bool {
        isIdentifierStart(character) || character.isNumber
    }

    private func extractExecutedSkillPaths(_ command: String) -> [String] {
        let withoutHeredocs = removingHeredocBodies(command)
        guard !containsAmbiguousControlFlow(withoutHeredocs) else { return [] }
        return shellSegments(withoutHeredocs).flatMap { segment in
            guard isSupportedReadSegment(segment) else { return [String]() }
            return extractSkillPaths(removingOutputRedirections(segment))
        }
    }

    private func removingOutputRedirections(_ segment: String) -> String {
        segment.replacingOccurrences(
            of: #"(?:\d+|&)?>>?\s*(?:'[^']*'|\"[^\"]*\"|[^\s;&|]+)"#,
            with: " ",
            options: .regularExpression
        )
    }

    private func containsAmbiguousControlFlow(_ command: String) -> Bool {
        var unquoted = ""
        var quote: Character?
        var escaped = false
        var index = command.startIndex
        while index < command.endIndex {
            let character = command[index]
            let nextIndex = command.index(after: index)
            let next = nextIndex < command.endIndex ? command[nextIndex] : nil
            if escaped {
                unquoted.append(" ")
                escaped = false
            } else if character == "\\", quote != "'" {
                unquoted.append(" ")
                escaped = true
            } else if let activeQuote = quote {
                unquoted.append(character == "\n" ? "\n" : " ")
                if character == activeQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
                unquoted.append(" ")
            } else if character == "|", next == "|" {
                return true
            } else {
                unquoted.append(character)
            }
            index = nextIndex
        }
        let pattern = #"(?i)(?:^|[^A-Za-z0-9_])(?:if|then|elif|else|fi|case|esac|for|while|until|select)\b"#
        return unquoted.range(of: pattern, options: .regularExpression) != nil
    }

    private func isSupportedReadSegment(_ segment: String) -> Bool {
        var value = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        let controlPrefix = #"^(?:(?:then|do|else)\s+)+"#
        value = value.replacingOccurrences(
            of: controlPrefix,
            with: "",
            options: .regularExpression
        )
        let pattern = #"^(?:(?:[A-Za-z_][A-Za-z0-9_]*=(?:'[^']*'|\"[^\"]*\"|[^\s]+))\s+)*(?:(?:command|builtin)\s+)?(?:/usr/bin/|/bin/)?(?:cat|sed|head|tail|bat)\b"#
        return value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func shellSegments(_ command: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var index = command.startIndex

        func finishSegment() {
            let value = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { segments.append(value) }
            current = ""
        }

        while index < command.endIndex {
            let character = command[index]
            let nextIndex = command.index(after: index)
            let next = nextIndex < command.endIndex ? command[nextIndex] : nil
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\", quote != "'" {
                current.append(character)
                escaped = true
            } else if let activeQuote = quote {
                current.append(character)
                if character == activeQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
                current.append(character)
            } else if character == "#", current.isEmpty || current.last?.isWhitespace == true {
                while index < command.endIndex, command[index] != "\n" {
                    index = command.index(after: index)
                }
                finishSegment()
                continue
            } else if character == "\n" || character == ";" || character == "|" || character == "&" {
                finishSegment()
                if (character == "|" || character == "&"), next == character {
                    index = nextIndex
                }
            } else {
                current.append(character)
            }
            index = command.index(after: index)
        }
        finishSegment()
        return segments
    }

    private func removingHeredocBodies(_ command: String) -> String {
        let lines = command.components(separatedBy: .newlines)
        var output: [String] = []
        var delimiters: [(value: String, stripsTabs: Bool)] = []
        for line in lines {
            if let delimiter = delimiters.first {
                let candidate = delimiter.stripsTabs
                    ? String(line.drop(while: { $0 == "\t" }))
                    : line
                if candidate == delimiter.value {
                    delimiters.removeFirst()
                }
                continue
            }
            output.append(line)
            delimiters.append(contentsOf: heredocDelimiters(in: line))
        }
        return output.joined(separator: "\n")
    }

    private func heredocDelimiters(in line: String) -> [(value: String, stripsTabs: Bool)] {
        let pattern = #"<<(-)?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return expression.matches(in: line, range: range).compactMap { match in
            guard let valueRange = Range(match.range(at: 3), in: line) else { return nil }
            return (String(line[valueRange]), match.range(at: 1).location != NSNotFound)
        }
    }

    private func extractSkillPaths(_ text: String) -> [String] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let patterns = [
            #"[\"']((?:file://)?(?:~|/|\.\.?/)[^\"'\r\n]*?/SKILL\.md)[\"']"#,
            #"((?:file://)?(?:~|/|\.\.?/)?(?:[A-Za-z0-9_@.+~:-]|\\ )+(?:/(?:[A-Za-z0-9_@.+~:-]|\\ )+)+/SKILL\.md)(?=$|[\s;&|<>()])"#
        ]
        var matches: [(location: Int, length: Int, path: String)] = []
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in expression.matches(in: text, range: range) {
                guard match.numberOfRanges > 1,
                      let matchRange = Range(match.range(at: 1), in: text)
                else { continue }
                matches.append((
                    location: match.range(at: 1).location,
                    length: match.range(at: 1).length,
                    path: String(text[matchRange])
                        .replacingOccurrences(of: "file://", with: "")
                        .replacingOccurrences(of: #"\ "#, with: " ")
                ))
            }
        }
        matches.sort {
            $0.location == $1.location ? $0.length > $1.length : $0.location < $1.location
        }
        var seenRanges = Set<String>()
        return matches.compactMap { match in
            guard seenRanges.insert("\(match.location):\(match.length)").inserted else { return nil }
            return match.path
        }
    }

    private func resolve(path: String, cwd: String) -> String {
        let expanded: String
        if path.hasPrefix("~/") {
            expanded = homeURL().standardizedFileURL
                .appendingPathComponent(String(path.dropFirst(2))).path
        } else if path.hasPrefix("/") {
            expanded = path
        } else if !cwd.isEmpty {
            expanded = URL(fileURLWithPath: cwd).appendingPathComponent(path).path
        } else {
            expanded = path
        }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        if fileManager.fileExists(atPath: url.path) {
            return url.resolvingSymlinksInPath().standardizedFileURL.path
        }
        return url.path
    }

    private func identify(path: String) -> ParsedSkillIdentity {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        let components = directory.pathComponents
        let folderName = directory.lastPathComponent
        let frontmatterName = readSkillName(url) ?? folderName

        if components.contains(".system") {
            return ParsedSkillIdentity(
                id: "system:\(frontmatterName)",
                name: frontmatterName,
                confirmationName: frontmatterName,
                canonicalPath: directory.path,
                scope: "system"
            )
        }

        if let skillsIndex = components.lastIndex(of: "skills"),
           components.prefix(skillsIndex).contains("plugins"),
           components.prefix(skillsIndex).contains("cache")
        {
            let marketplace = skillsIndex >= 3 ? components[skillsIndex - 3] : "unknown"
            let pluginName = skillsIndex >= 2 ? components[skillsIndex - 2] : "plugin"
            let pluginOwner = "\(MetagentCore.normalizedPluginMarketplace(marketplace))/\(pluginName)"
            return ParsedSkillIdentity(
                id: "plugin:\(pluginOwner):\(folderName)",
                name: "\(pluginName):\(frontmatterName)",
                confirmationName: frontmatterName,
                canonicalPath: directory.path,
                scope: "plugin"
            )
        }

        let codexSkills = skillUsageCodexHomeURL().appendingPathComponent("skills").standardizedFileURL
        if directory.deletingLastPathComponent().standardizedFileURL.path == codexSkills.path {
            return ParsedSkillIdentity(
                id: "global:codex:\(frontmatterName)",
                name: frontmatterName,
                confirmationName: frontmatterName,
                canonicalPath: directory.path,
                scope: "global"
            )
        }

        if let containerIndex = components.lastIndex(where: {
            agentDirectoryNames.contains($0)
        }),
           containerIndex + 1 < components.count,
           components[containerIndex + 1] == "skills"
        {
            let root = NSString.path(withComponents: Array(components[..<containerIndex]))
            let container = components[containerIndex]
            let identityName = container == ".agents"
                ? frontmatterName
                : "\(container.dropFirst()):\(frontmatterName)"
            if URL(fileURLWithPath: root).standardizedFileURL.path
                == homeURL().standardizedFileURL.path
            {
                return ParsedSkillIdentity(
                    id: "global:\(identityName)",
                    name: frontmatterName,
                    confirmationName: frontmatterName,
                    canonicalPath: directory.path,
                    scope: "global"
                )
            }
            return ParsedSkillIdentity(
                id: "project:\(root):\(identityName)",
                name: frontmatterName,
                confirmationName: frontmatterName,
                canonicalPath: directory.path,
                scope: "project"
            )
        }

        return ParsedSkillIdentity(
            id: "path:\(directory.path)",
            name: frontmatterName,
            confirmationName: frontmatterName,
            canonicalPath: directory.path,
            scope: "unknown"
        )
    }

    private func readSkillName(_ file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 8_192)) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(40) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("name:") else { continue }
            return String(trimmed.dropFirst(5))
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
        }
        return nil
    }

    private func save(result: FileParseResult, source: UsageSource) throws -> Int {
        var db: OpaquePointer?
        try open(&db)
        defer { sqlite3_close(db) }
        try createSchema(db)
        try exec(db, "BEGIN IMMEDIATE;")
        do {
            var added = 0
            for event in result.events {
                var statement: OpaquePointer?
                try prepare(db, """
                INSERT OR IGNORE INTO skill_usage_events (
                  event_id, skill_id, skill_name, canonical_path, scope,
                  occurred_at, session_id, turn_id, cwd, evidence,
                  invocation_kind, confidence, source_path, call_id
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'session_backfill', 'skill_file_read', 'observed', ?, ?);
                """, &statement)
                defer { sqlite3_finalize(statement) }
                bind(statement, 1, event.id)
                bind(statement, 2, event.skill.id)
                bind(statement, 3, event.skill.name)
                bind(statement, 4, event.skill.canonicalPath)
                bind(statement, 5, event.skill.scope)
                bind(statement, 6, event.occurredAt)
                bind(statement, 7, event.sessionID)
                bind(statement, 8, event.turnID)
                bind(statement, 9, event.cwd)
                bind(statement, 10, event.sourcePath)
                bind(statement, 11, event.callID)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw databaseError(db, "insert usage event")
                }
                if sqlite3_changes(db) > 0 { added += 1 }
            }

            for run in result.runs {
                var statement: OpaquePointer?
                try prepare(db, """
                INSERT OR IGNORE INTO agent_runs (
                  run_id, session_id, turn_id, cwd, started_at, completed_at,
                  duration_ms, run_kind, source_path
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                """, &statement)
                defer { sqlite3_finalize(statement) }
                bind(statement, 1, run.id)
                bind(statement, 2, run.sessionID)
                bind(statement, 3, run.turnID)
                bind(statement, 4, run.cwd)
                bind(statement, 5, run.startedAt)
                bind(statement, 6, run.completedAt)
                sqlite3_bind_int64(statement, 7, run.durationMilliseconds)
                bind(statement, 8, run.kind)
                bind(statement, 9, run.sourcePath)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw databaseError(db, "insert agent run")
                }
            }

            var sourceStatement: OpaquePointer?
            try prepare(db, """
            INSERT INTO skill_usage_sources (
              path, byte_offset, file_size, modified_at, file_identity, prefix_fingerprint,
              session_id, cwd, turn_id, coverage_started_at, pending_events_json,
              run_session_id, run_session_started_at, run_kind, parser_version, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))
            ON CONFLICT(path) DO UPDATE SET
              byte_offset = excluded.byte_offset,
              file_size = excluded.file_size,
              modified_at = excluded.modified_at,
              file_identity = excluded.file_identity,
              prefix_fingerprint = excluded.prefix_fingerprint,
              session_id = excluded.session_id,
              cwd = excluded.cwd,
              turn_id = excluded.turn_id,
              coverage_started_at = excluded.coverage_started_at,
              pending_events_json = excluded.pending_events_json,
              run_session_id = excluded.run_session_id,
              run_session_started_at = excluded.run_session_started_at,
              run_kind = excluded.run_kind,
              parser_version = excluded.parser_version,
              updated_at = excluded.updated_at;
            """, &sourceStatement)
            defer { sqlite3_finalize(sourceStatement) }
            bind(sourceStatement, 1, source.path)
            sqlite3_bind_int64(sourceStatement, 2, result.state.offset)
            sqlite3_bind_int64(sourceStatement, 3, source.size)
            sqlite3_bind_double(sourceStatement, 4, source.modifiedAt)
            bind(sourceStatement, 5, result.state.fileIdentity)
            bind(sourceStatement, 6, result.state.prefixFingerprint)
            bind(sourceStatement, 7, result.state.sessionID)
            bind(sourceStatement, 8, result.state.cwd)
            bind(sourceStatement, 9, result.state.turnID)
            bind(sourceStatement, 10, result.state.coverageStartedAt)
            let pendingData = try JSONEncoder().encode(result.state.pendingEvents)
            bind(sourceStatement, 11, String(decoding: pendingData, as: UTF8.self))
            bind(sourceStatement, 12, result.state.runSessionID)
            bind(sourceStatement, 13, result.state.runSessionStartedAt)
            bind(sourceStatement, 14, result.state.runKind)
            sqlite3_bind_int(sourceStatement, 15, Int32(skillUsageParserVersion))
            guard sqlite3_step(sourceStatement) == SQLITE_DONE else {
                throw databaseError(db, "save usage cursor")
            }
            try exec(db, "COMMIT;")
            return added
        } catch {
            try? exec(db, "ROLLBACK;")
            throw error
        }
    }

    private func loadSourceStates() throws -> [String: UsageSourceState] {
        var db: OpaquePointer?
        try open(&db)
        defer { sqlite3_close(db) }
        try createSchema(db)
        var statement: OpaquePointer?
        try prepare(db, """
        SELECT path, byte_offset, file_size, modified_at, file_identity, prefix_fingerprint,
               session_id, cwd, turn_id, coverage_started_at, pending_events_json,
               run_session_id, run_session_started_at, run_kind
        FROM skill_usage_sources
        WHERE parser_version = ?;
        """, &statement)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(skillUsageParserVersion))
        var states: [String: UsageSourceState] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let pendingJSON = text(statement, 10)
            let pendingEvents = pendingJSON.data(using: .utf8).flatMap {
                try? JSONDecoder().decode([String: [ParsedUsageEvent]].self, from: $0)
            } ?? [:]
            states[text(statement, 0)] = UsageSourceState(
                offset: sqlite3_column_int64(statement, 1),
                fileSize: sqlite3_column_int64(statement, 2),
                modifiedAt: sqlite3_column_double(statement, 3),
                fileIdentity: text(statement, 4),
                prefixFingerprint: text(statement, 5),
                sessionID: text(statement, 6),
                cwd: text(statement, 7),
                turnID: text(statement, 8),
                coverageStartedAt: text(statement, 9),
                pendingEvents: pendingEvents,
                runSessionID: text(statement, 11),
                runSessionStartedAt: text(statement, 12),
                runKind: text(statement, 13)
            )
        }
        return states
    }

    private func migrateSource(
        from oldPath: String,
        to newPath: String,
        state: UsageSourceState
    ) throws {
        var db: OpaquePointer?
        try open(&db)
        defer { sqlite3_close(db) }
        try createSchema(db)
        try exec(db, "BEGIN IMMEDIATE;")
        do {
            var eventStatement: OpaquePointer?
            try prepare(db, "UPDATE skill_usage_events SET source_path = ? WHERE source_path = ?;", &eventStatement)
            defer { sqlite3_finalize(eventStatement) }
            bind(eventStatement, 1, newPath)
            bind(eventStatement, 2, oldPath)
            guard sqlite3_step(eventStatement) == SQLITE_DONE else {
                throw databaseError(db, "migrate usage events")
            }

            var runStatement: OpaquePointer?
            try prepare(db, "UPDATE agent_runs SET source_path = ? WHERE source_path = ?;", &runStatement)
            defer { sqlite3_finalize(runStatement) }
            bind(runStatement, 1, newPath)
            bind(runStatement, 2, oldPath)
            guard sqlite3_step(runStatement) == SQLITE_DONE else {
                throw databaseError(db, "migrate agent runs")
            }

            let pendingData = try JSONEncoder().encode(state.pendingEvents)
            var sourceStatement: OpaquePointer?
            try prepare(db, """
            UPDATE skill_usage_sources
            SET path = ?, pending_events_json = ?, updated_at = datetime('now')
            WHERE path = ?;
            """, &sourceStatement)
            defer { sqlite3_finalize(sourceStatement) }
            bind(sourceStatement, 1, newPath)
            bind(sourceStatement, 2, String(decoding: pendingData, as: UTF8.self))
            bind(sourceStatement, 3, oldPath)
            guard sqlite3_step(sourceStatement) == SQLITE_DONE else {
                throw databaseError(db, "migrate usage cursor")
            }
            try exec(db, "COMMIT;")
        } catch {
            try? exec(db, "ROLLBACK;")
            throw error
        }
    }

    private func resetSources(_ paths: [String]) throws {
        var db: OpaquePointer?
        try open(&db)
        defer { sqlite3_close(db) }
        try createSchema(db)
        try exec(db, "BEGIN IMMEDIATE;")
        do {
            var eventStatement: OpaquePointer?
            try prepare(db, "DELETE FROM skill_usage_events WHERE source_path = ?;", &eventStatement)
            defer { sqlite3_finalize(eventStatement) }
            var sourceStatement: OpaquePointer?
            try prepare(db, "DELETE FROM skill_usage_sources WHERE path = ?;", &sourceStatement)
            defer { sqlite3_finalize(sourceStatement) }
            var runStatement: OpaquePointer?
            try prepare(db, "DELETE FROM agent_runs WHERE source_path = ?;", &runStatement)
            defer { sqlite3_finalize(runStatement) }

            for path in paths {
                sqlite3_reset(eventStatement)
                sqlite3_clear_bindings(eventStatement)
                bind(eventStatement, 1, path)
                guard sqlite3_step(eventStatement) == SQLITE_DONE else {
                    throw databaseError(db, "reset usage events")
                }

                sqlite3_reset(sourceStatement)
                sqlite3_clear_bindings(sourceStatement)
                bind(sourceStatement, 1, path)
                guard sqlite3_step(sourceStatement) == SQLITE_DONE else {
                    throw databaseError(db, "reset usage cursor")
                }

                sqlite3_reset(runStatement)
                sqlite3_clear_bindings(runStatement)
                bind(runStatement, 1, path)
                guard sqlite3_step(runStatement) == SQLITE_DONE else {
                    throw databaseError(db, "reset agent runs")
                }
            }
            try exec(db, "COMMIT;")
        } catch {
            try? exec(db, "ROLLBACK;")
            throw error
        }
    }

    private func progress(
        for sources: [UsageSource],
        states: [String: UsageSourceState]
    ) -> (totalFiles: Int, completedFiles: Int, totalBytes: Int64, processedBytes: Int64, isComplete: Bool) {
        let totalBytes = sources.reduce(Int64(0)) { $0 + $1.size }
        let processedBytes = sources.reduce(Int64(0)) { total, source in
            total + min(states[source.path]?.offset ?? 0, source.size)
        }
        let completedFiles = sources.reduce(0) { count, source in
            count + ((states[source.path]?.offset ?? 0) >= source.size ? 1 : 0)
        }
        return (
            totalFiles: sources.count,
            completedFiles: completedFiles,
            totalBytes: totalBytes,
            processedBytes: processedBytes,
            isComplete: !sources.isEmpty
                && sources.allSatisfy { (states[$0.path]?.offset ?? 0) >= $0.size }
        )
    }

    private func saveProgress(
        _ progress: (totalFiles: Int, completedFiles: Int, totalBytes: Int64, processedBytes: Int64, isComplete: Bool)
    ) throws {
        var db: OpaquePointer?
        try open(&db)
        defer { sqlite3_close(db) }
        try createSchema(db)
        let values = [
            "total_files": String(progress.totalFiles),
            "completed_files": String(progress.completedFiles),
            "total_bytes": String(progress.totalBytes),
            "processed_bytes": String(progress.processedBytes),
            "is_complete": progress.isComplete ? "1" : "0",
            "last_updated_at": iso8601Formatter.string(from: Date())
        ]
        try exec(db, "BEGIN IMMEDIATE;")
        do {
            for (key, value) in values {
                var statement: OpaquePointer?
                try prepare(db, """
                INSERT INTO skill_usage_metadata (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value;
                """, &statement)
                defer { sqlite3_finalize(statement) }
                bind(statement, 1, key)
                bind(statement, 2, value)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw databaseError(db, "save usage metadata")
                }
            }
            if progress.isComplete {
                try dropPreviousGeneration(db)
            }
            try exec(db, "COMMIT;")
        } catch {
            try? exec(db, "ROLLBACK;")
            throw error
        }
    }

    private func prepareParserVersion() throws {
        var db: OpaquePointer?
        try open(&db)
        defer { sqlite3_close(db) }
        try createSchema(db)
        let current = try scalarText(
            db,
            "SELECT value FROM skill_usage_metadata WHERE key = 'parser_version';"
        )
        guard current != String(skillUsageParserVersion) else { return }
        try exec(db, "BEGIN IMMEDIATE;")
        do {
            if try previousGenerationExists(db) {
                try dropCurrentGeneration(db)
            } else if try currentGenerationHasHistory(db) {
                try preserveCurrentGeneration(db)
            } else {
                try dropCurrentGeneration(db)
            }
            try createSchema(db)
            var statement: OpaquePointer?
            try prepare(db, """
            INSERT INTO skill_usage_metadata (key, value) VALUES ('parser_version', ?);
            """, &statement)
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, String(skillUsageParserVersion))
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw databaseError(db, "save parser version")
            }
            try exec(db, "COMMIT;")
        } catch {
            try? exec(db, "ROLLBACK;")
            throw error
        }
    }

    private func currentGenerationHasHistory(_ db: OpaquePointer?) throws -> Bool {
        let events = try scalarInt(db, "SELECT COUNT(*) FROM \(skillUsageEventsTable);")
        let sources = try scalarInt(db, "SELECT COUNT(*) FROM \(skillUsageSourcesTable);")
        return events > 0 || sources > 0
    }

    private func previousGenerationExists(_ db: OpaquePointer?) throws -> Bool {
        try tableExists(db, previousSkillUsageEventsTable)
            && tableExists(db, previousSkillUsageSourcesTable)
            && tableExists(db, previousSkillUsageMetadataTable)
    }

    private func preserveCurrentGeneration(_ db: OpaquePointer?) throws {
        try exec(db, "DROP INDEX IF EXISTS skill_usage_by_skill_time;")
        try exec(db, "DROP INDEX IF EXISTS skill_usage_by_session_turn;")
        try exec(db, "DROP INDEX IF EXISTS agent_runs_by_completed_at;")
        // Agent runs were added after the three core usage tables. A failed
        // development migration can therefore leave an orphan with this name
        // even though no complete previous generation exists.
        try exec(db, "DROP TABLE IF EXISTS \(previousAgentRunsTable);")
        try exec(db, "ALTER TABLE \(skillUsageEventsTable) RENAME TO \(previousSkillUsageEventsTable);")
        try exec(db, "ALTER TABLE \(skillUsageSourcesTable) RENAME TO \(previousSkillUsageSourcesTable);")
        try exec(db, "ALTER TABLE \(skillUsageMetadataTable) RENAME TO \(previousSkillUsageMetadataTable);")
        try exec(db, "ALTER TABLE \(agentRunsTable) RENAME TO \(previousAgentRunsTable);")
        try exec(db, """
        CREATE INDEX IF NOT EXISTS skill_usage_previous_by_skill_time
          ON \(previousSkillUsageEventsTable)(skill_id, occurred_at);
        CREATE INDEX IF NOT EXISTS skill_usage_previous_by_session_turn
          ON \(previousSkillUsageEventsTable)(session_id, turn_id);
        CREATE INDEX IF NOT EXISTS agent_runs_previous_by_completed_at
          ON \(previousAgentRunsTable)(completed_at);
        """)
    }

    private func dropCurrentGeneration(_ db: OpaquePointer?) throws {
        try exec(db, "DROP TABLE IF EXISTS \(skillUsageEventsTable);")
        try exec(db, "DROP TABLE IF EXISTS \(skillUsageSourcesTable);")
        try exec(db, "DROP TABLE IF EXISTS \(skillUsageMetadataTable);")
        try exec(db, "DROP TABLE IF EXISTS \(agentRunsTable);")
    }

    private func dropPreviousGeneration(_ db: OpaquePointer?) throws {
        try exec(db, "DROP TABLE IF EXISTS \(previousSkillUsageEventsTable);")
        try exec(db, "DROP TABLE IF EXISTS \(previousSkillUsageSourcesTable);")
        try exec(db, "DROP TABLE IF EXISTS \(previousSkillUsageMetadataTable);")
        try exec(db, "DROP TABLE IF EXISTS \(previousAgentRunsTable);")
    }

    private func open(_ db: inout OpaquePointer?) throws {
        guard sqlite3_open(path.path, &db) == SQLITE_OK else {
            throw databaseError(db, "open \(path.path)")
        }
        try exec(db, "PRAGMA journal_mode=WAL;")
        try exec(db, "PRAGMA synchronous=NORMAL;")
        try exec(db, "PRAGMA busy_timeout=2500;")
    }

    private func createSchema(_ db: OpaquePointer?) throws {
        try exec(db, """
        CREATE TABLE IF NOT EXISTS skill_usage_events (
          event_id TEXT PRIMARY KEY,
          skill_id TEXT NOT NULL,
          skill_name TEXT NOT NULL,
          canonical_path TEXT NOT NULL,
          scope TEXT NOT NULL,
          occurred_at TEXT NOT NULL,
          session_id TEXT NOT NULL,
          turn_id TEXT NOT NULL,
          cwd TEXT NOT NULL,
          evidence TEXT NOT NULL,
          invocation_kind TEXT NOT NULL,
          confidence TEXT NOT NULL,
          source_path TEXT NOT NULL,
          call_id TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS skill_usage_by_skill_time
          ON skill_usage_events(skill_id, occurred_at);
        CREATE INDEX IF NOT EXISTS skill_usage_by_session_turn
          ON skill_usage_events(session_id, turn_id);
        CREATE TABLE IF NOT EXISTS agent_runs (
          run_id TEXT PRIMARY KEY,
          session_id TEXT NOT NULL,
          turn_id TEXT NOT NULL,
          cwd TEXT NOT NULL,
          started_at TEXT NOT NULL,
          completed_at TEXT NOT NULL,
          duration_ms INTEGER NOT NULL,
          run_kind TEXT NOT NULL,
          source_path TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS agent_runs_by_completed_at
          ON agent_runs(completed_at);
        CREATE TABLE IF NOT EXISTS skill_usage_sources (
          path TEXT PRIMARY KEY,
          byte_offset INTEGER NOT NULL,
          file_size INTEGER NOT NULL,
          modified_at REAL NOT NULL,
          file_identity TEXT NOT NULL DEFAULT '',
          prefix_fingerprint TEXT NOT NULL DEFAULT '',
          session_id TEXT NOT NULL,
          cwd TEXT NOT NULL,
          turn_id TEXT NOT NULL,
          coverage_started_at TEXT NOT NULL DEFAULT '',
          pending_events_json TEXT NOT NULL DEFAULT '{}',
          run_session_id TEXT NOT NULL DEFAULT '',
          run_session_started_at TEXT NOT NULL DEFAULT '',
          run_kind TEXT NOT NULL DEFAULT 'unknown',
          parser_version INTEGER NOT NULL,
          updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS skill_usage_metadata (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
        """)
        try? exec(db, "ALTER TABLE skill_usage_sources ADD COLUMN file_identity TEXT NOT NULL DEFAULT '';" )
        try? exec(db, "ALTER TABLE skill_usage_sources ADD COLUMN prefix_fingerprint TEXT NOT NULL DEFAULT '';" )
        try? exec(db, "ALTER TABLE skill_usage_sources ADD COLUMN pending_events_json TEXT NOT NULL DEFAULT '{}';" )
        try? exec(db, "ALTER TABLE skill_usage_sources ADD COLUMN run_session_id TEXT NOT NULL DEFAULT '';" )
        try? exec(db, "ALTER TABLE skill_usage_sources ADD COLUMN run_session_started_at TEXT NOT NULL DEFAULT '';" )
        try? exec(db, "ALTER TABLE skill_usage_sources ADD COLUMN run_kind TEXT NOT NULL DEFAULT 'unknown';" )
        try? exec(db, "ALTER TABLE skill_usage_sources ADD COLUMN coverage_started_at TEXT NOT NULL DEFAULT '';" )
    }

    private func loadMetadata(
        _ db: OpaquePointer?,
        table: String
    ) throws -> [String: String] {
        var statement: OpaquePointer?
        try prepare(db, "SELECT key, value FROM \(table);", &statement)
        defer { sqlite3_finalize(statement) }
        var values: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            values[text(statement, 0)] = text(statement, 1)
        }
        return values
    }

    private func upsertMetadata(
        _ db: OpaquePointer?,
        key: String,
        value: String
    ) throws {
        var statement: OpaquePointer?
        try prepare(db, """
        INSERT INTO \(skillUsageMetadataTable) (key, value) VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value;
        """, &statement)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, key)
        bind(statement, 2, value)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError(db, "save usage metadata")
        }
    }

    private func scalarText(_ db: OpaquePointer?, _ sql: String) throws -> String? {
        var statement: OpaquePointer?
        try prepare(db, sql, &statement)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return optionalText(statement, 0)
    }

    private func scalarInt(_ db: OpaquePointer?, _ sql: String) throws -> Int64 {
        var statement: OpaquePointer?
        try prepare(db, sql, &statement)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(statement, 0)
    }

    private func tableExists(_ db: OpaquePointer?, _ table: String) throws -> Bool {
        var statement: OpaquePointer?
        try prepare(
            db,
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;",
            &statement
        )
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, table)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func columnExists(
        _ db: OpaquePointer?,
        table: String,
        column: String
    ) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if text(statement, 1) == column { return true }
        }
        return false
    }

    private func prepare(_ db: OpaquePointer?, _ sql: String, _ statement: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError(db, "prepare statement")
        }
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw databaseError(db, "execute statement")
        }
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private func text(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private func optionalText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        let value = text(statement, index)
        return value.isEmpty ? nil : value
    }

    private func string(_ value: Any?) -> String {
        value as? String ?? ""
    }

    private func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber {
            return number.int64Value
        }
        if let value = value as? String {
            return Int64(value)
        }
        return nil
    }

    private func unixTimestampDate(_ value: Any?) -> Date? {
        let seconds: Double?
        if let number = value as? NSNumber {
            seconds = number.doubleValue
        } else if let value = value as? String {
            seconds = Double(value)
        } else {
            seconds = nil
        }
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1_000 : seconds)
    }

    private func rolloutSessionID(_ sourcePath: String) -> String? {
        let filename = URL(fileURLWithPath: sourcePath)
            .deletingPathExtension()
            .lastPathComponent
        guard filename.count >= 36 else { return nil }
        let candidate = String(filename.suffix(36))
        return UUID(uuidString: candidate) == nil ? nil : candidate
    }

    private func agentRunKind(_ session: [String: Any]) -> String {
        func hasJSONValue(_ value: Any?) -> Bool {
            value != nil && !(value is NSNull)
        }

        switch string(session["thread_source"]) {
        case "user":
            return "user"
        case "automation":
            return "automation"
        case "guardian_review":
            return "guardian"
        case "subagent":
            return "subagent"
        default:
            if hasJSONValue(session["agent_path"])
                || hasJSONValue(session["parent_thread_id"])
                || hasJSONValue(session["forked_from_id"])
                || hasJSONValue((session["source"] as? [String: Any])?["subagent"])
            {
                return "subagent"
            }
            return "unknown"
        }
    }

    private func databaseError(_ db: OpaquePointer?, _ operation: String) -> Error {
        let detail = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
        return NSError(domain: "MetagentSkillUsage", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "\(operation): \(detail)"
        ])
    }
}
