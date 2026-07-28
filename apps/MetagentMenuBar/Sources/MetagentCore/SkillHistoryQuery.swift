import Foundation

/// One metric's recorded series over a window, with the comparison a card needs.
public struct SkillHistoryTrend: Sendable, Equatable {
    public let metric: SkillHistoryMetric
    public let points: [SkillHistoryPoint]
    /// The most recent recorded value, or `nil` when nothing was recorded.
    public let latest: Double?
    /// The value closest to the start of the comparison window, used as the
    /// baseline for `change`. Absent when the window predates all recording.
    public let baseline: Double?
    /// The day the baseline was recorded, so a card can say what it compared
    /// against rather than implying an exact window it may not have.
    public let baselineDay: String?

    public init(
        metric: SkillHistoryMetric,
        points: [SkillHistoryPoint],
        latest: Double?,
        baseline: Double?,
        baselineDay: String?
    ) {
        self.metric = metric
        self.points = points
        self.latest = latest
        self.baseline = baseline
        self.baselineDay = baselineDay
    }

    public static func empty(_ metric: SkillHistoryMetric) -> SkillHistoryTrend {
        SkillHistoryTrend(metric: metric, points: [], latest: nil, baseline: nil, baselineDay: nil)
    }

    /// The signed change against the baseline, or `nil` when there is nothing
    /// honest to compare. A single recorded day has no trend, only a value.
    public var change: Double? {
        guard let latest, let baseline, points.count > 1 else { return nil }
        return latest - baseline
    }

    /// True when any point in the window was reconstructed rather than observed,
    /// so the view can mark the series as partly inferred.
    public var includesInferred: Bool {
        points.contains { $0.origin == .inferred }
    }

    /// Whether the series has enough recorded days to draw a line at all.
    public var isPlottable: Bool {
        points.count > 1
    }
}

/// Every trend a surface needs, read in one pass.
public struct SkillHistoryTrends: Sendable, Equatable {
    public let scope: SkillHistoryScope
    public let windowDays: Int
    public let trends: [SkillHistoryMetric: SkillHistoryTrend]
    public let coverage: SkillHistoryCoverage

    public init(
        scope: SkillHistoryScope,
        windowDays: Int,
        trends: [SkillHistoryMetric: SkillHistoryTrend],
        coverage: SkillHistoryCoverage
    ) {
        self.scope = scope
        self.windowDays = windowDays
        self.trends = trends
        self.coverage = coverage
    }

    public static let empty = SkillHistoryTrends(
        scope: .all,
        windowDays: 0,
        trends: [:],
        coverage: .empty
    )

    public subscript(metric: SkillHistoryMetric) -> SkillHistoryTrend {
        trends[metric] ?? .empty(metric)
    }

    /// True once there is more than one recorded day anywhere, which is the
    /// point at which a history surface has something to show.
    public var hasTrend: Bool {
        trends.values.contains { $0.isPlottable }
    }
}

public extension MetagentCore {
    /// Reads several metrics' series for one scope in a single database pass.
    ///
    /// The Overview draws six cards at once; issuing six queries per refresh
    /// would reopen and rescan the same table six times for no benefit.
    static func skillHistoryTrends(
        metrics: [SkillHistoryMetric] = SkillHistoryMetric.allCases,
        scope: SkillHistoryScope = .all,
        windowDays: Int = 30,
        now: Date = Date(),
        calendar: Calendar = .current,
        databasePath: String? = nil
    ) throws -> SkillHistoryTrends {
        let store = try SkillHistoryStore(path: databasePath)
        let effectiveWindowDays = max(1, windowDays)
        let since = calendar.date(byAdding: .day, value: -effectiveWindowDays, to: now)
        let series = try store.series(
            metrics: metrics,
            scopeKey: scope.key,
            since: since
        )
        var trends: [SkillHistoryMetric: SkillHistoryTrend] = [:]
        for metric in metrics {
            let points = series[metric] ?? []
            trends[metric] = SkillHistoryTrend(
                metric: metric,
                points: points,
                latest: points.last?.value,
                baseline: points.first?.value,
                baselineDay: points.first?.day
            )
        }
        return SkillHistoryTrends(
            scope: scope,
            windowDays: effectiveWindowDays,
            trends: trends,
            coverage: try store.coverage()
        )
    }

    /// One skill's recorded lifetime, newest first. Callers pass the canonical
    /// path; the identity mapping keeps a plugin skill's timeline continuous
    /// across the versioned cache directories it has lived in.
    static func skillHistoryTimeline(
        skillKey: String,
        databasePath: String? = nil
    ) throws -> [SkillHistoryEvent] {
        try SkillHistoryStore(path: databasePath)
            .events(forSubject: historySkillIdentity(skillKey).key)
    }
}
