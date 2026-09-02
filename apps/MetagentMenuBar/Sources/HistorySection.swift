import Charts
import MetagentCore
import SwiftUI

/// How far back a history chart looks.
///
/// This is the window of the *chart*, not of any metric. "Unused, last 30 days"
/// counts skills unread in a trailing 30-day window on every day it is measured;
/// changing this range changes how many of those daily measurements are drawn,
/// never what any of them mean.
enum HistoryRange: String, CaseIterable, Identifiable {
    case week
    case month
    case quarter
    case year
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: "7d"
        case .month: "30d"
        case .quarter: "90d"
        case .year: "1y"
        case .all: "All"
        }
    }

    /// How the window reads in a sentence, for labels and help text.
    var phrase: String {
        switch self {
        case .week: "the last 7 days"
        case .month: "the last 30 days"
        case .quarter: "the last 90 days"
        case .year: "the last year"
        case .all: "all recorded history"
        }
    }

    var days: Int {
        switch self {
        case .week: 7
        case .month: 30
        case .quarter: 90
        case .year: 365
        case .all: 3_650
        }
    }

    /// The ranges the Overview offers. The full-page view adds a year; six small
    /// sparklines gain nothing from a fifth choice.
    static let overviewCases: [HistoryRange] = [.week, .month, .quarter, .all]
}

/// One charted metric on the History page.
private struct HistoryChartModel: Identifiable {
    let id: String
    let title: String
    let help: String
    let metrics: [SkillHistoryMetric]
    let labels: [SkillHistoryMetric: String]
    let tints: [SkillHistoryMetric: Color]
    /// Formats a value for the axis and the readout.
    let format: (Double) -> String
}

struct HistorySection: View {
    @ObservedObject var model: MetagentModel
    let isCompact: Bool
    let selectedProjectRoot: String?

    @AppStorage("metagent.history.range.v1") private var storedRange = HistoryRange.quarter.rawValue
    @State private var trends = SkillHistoryTrends.empty
    @State private var events: [SkillHistoryEvent] = []
    @State private var isLoading = true
    @State private var loadedRefreshID: String?

    private var range: HistoryRange {
        HistoryRange(rawValue: storedRange) ?? .quarter
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: isCompact ? 8 : 12) {
                header
                if isStale {
                    loadingState
                } else if !trends.hasTrend {
                    emptyState
                } else {
                    charts
                    eventFeed
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollIndicators(.hidden)
        .task(id: refreshID) {
            await refresh()
        }
    }

    private var refreshID: String {
        "\(model.skillTableRevision):\(selectedProjectRoot ?? "all"):\(range.rawValue)"
    }

    private var isStale: Bool {
        isLoading || loadedRefreshID != refreshID
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                Text("History")
                    .font((isCompact ? Font.title3 : .title).weight(.semibold))

                Text("PREVIEW")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())

                if !isStale, !coverageChips.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(coverageChips, id: \.self) { chip in
                            Text(chip)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(.quaternary.opacity(0.6), in: Capsule())
                        }
                    }
                    .help(coverageHelp)
                }

                if !isStale, trends.coverage.inferredDayCount > 0 {
                    HStack(spacing: 7) {
                        HistoryLineSample(isEstimated: true)
                        Text("Dashed lines are estimates from older local evidence, not measurements Metagent observed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .help(coverageHelp)
                }
            }

            Spacer(minLength: 12)

            Picker("Range", selection: $storedRange) {
                ForEach(HistoryRange.allCases) { range in
                    Text(range.title).tag(range.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: isCompact ? 200 : 240)
            .help("How far back these charts look, currently \(range.phrase). This changes the charts only; each metric still counts exactly what its title says.")
        }
        .padding(.horizontal, isCompact ? 12 : 14)
        .padding(.top, isCompact ? 10 : 12)
    }

    /// Coverage is stated up front because every chart below inherits it: how
    /// many days were actually observed, and how many were estimated.
    private var coverageChips: [String] {
        var chips: [String] = []
        let coverage = trends.coverage
        if coverage.observedDayCount > 0 {
            chips.append("\(coverage.observedDayCount) recorded")
        }
        if coverage.inferredDayCount > 0 {
            chips.append("\(coverage.inferredDayCount) estimated")
        }
        if coverage.eventCount > 0 {
            chips.append("\(coverage.eventCount) changes")
        }
        return chips
    }

    private var coverageHelp: String {
        let coverage = trends.coverage
        var parts: [String] = []
        if let first = coverage.firstObservedDay {
            parts.append("Recorded days come from scans since \(first).")
        }
        if coverage.inferredDayCount > 0 {
            parts.append(
                "Estimated days are inferred from git history, folder creation dates, the removal archive, and session history, and are drawn dashed."
            )
        }
        parts.append("Days with no sample are left as gaps rather than joined through.")
        return parts.joined(separator: " ")
    }

    private var loadingState: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Reading recorded history…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
        .cardBackground()
    }

    private var emptyState: some View {
        EmptyStateView(
            title: "No history yet",
            message: "History records one sample per day. Come back tomorrow, or run `metagent history backfill` to estimate earlier days from local evidence.",
            symbol: "chart.xyaxis.line"
        )
        .frame(maxWidth: .infinity, minHeight: 200)
        .cardBackground()
    }

    private var charts: some View {
        VStack(alignment: .leading, spacing: isCompact ? 8 : 12) {
            ForEach(chartModels) { chart in
                HistoryChartCard(
                    title: chart.title,
                    help: chart.help,
                    series: chart.metrics.compactMap { metric in
                        let trend = trends[metric]
                        guard trend.isPlottable else { return nil }
                        return HistoryChartSeries(
                            id: metric.rawValue,
                            label: chart.labels[metric] ?? metric.rawValue,
                            tint: chart.tints[metric] ?? .accentColor,
                            points: HistoryPlot.points(trend.points)
                        )
                    },
                    format: chart.format,
                    isCompact: isCompact
                )
            }
        }
    }

    private var chartModels: [HistoryChartModel] {
        [
            HistoryChartModel(
                id: "portfolio",
                title: "Skills installed",
                help: "How many skills existed in this scope on each recorded day. Estimated days count every skill whose lifetime covers that day, from git history where available and folder creation dates otherwise.",
                metrics: [.portfolioSkills],
                labels: [.portfolioSkills: "Installed"],
                tints: [.portfolioSkills: .accentColor],
                format: { $0.formatted(.number.precision(.fractionLength(0))) }
            ),
            HistoryChartModel(
                id: "adoption",
                title: "Skills not being read",
                help: "Skills with no observed read in the last 30 days, and skills never read at all. Both are counts rather than rates so they share an axis with the installed line above. Estimated days rate every skill alive that day, while recorded days exclude dormant directories, so the two are not directly comparable across the seam.",
                metrics: [.adoptionUnused30d, .adoptionNeverObserved],
                labels: [.adoptionUnused30d: "Unused 30d", .adoptionNeverObserved: "Never read"],
                tints: [.adoptionUnused30d: .orange, .adoptionNeverObserved: .red],
                format: { $0.formatted(.number.precision(.fractionLength(0))) }
            ),
            HistoryChartModel(
                id: "tokens",
                title: "Instruction and catalog size",
                help: "Estimated tokens across installed SKILL.md bodies, and across skill names and descriptions. These are recorded only, never backfilled: git covers some skills and not others, and a partial total would draw a decline that never happened.",
                metrics: [.tokensSkillBody, .tokensCatalog],
                labels: [.tokensSkillBody: "SKILL.md", .tokensCatalog: "Catalog"],
                tints: [.tokensSkillBody: .purple, .tokensCatalog: .teal],
                format: { formatNumber(Int($0)) }
            ),
        ]
    }

    private var eventFeed: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Changes")
                    .font(.headline)
                Spacer(minLength: 12)
                if !events.isEmpty {
                    Text("\(events.count) in range")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            if events.isEmpty {
                Text("No recorded changes in this range.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                Divider().padding(.leading, 16)
                LazyVStack(spacing: 0) {
                    ForEach(Array(groupedEvents.enumerated()), id: \.element.day) { index, group in
                        if index > 0 {
                            Divider().padding(.leading, 16)
                        }
                        HistoryEventDayRow(group: group)
                    }
                }
            }
        }
        .cardBackground()
    }

    /// The feed groups by day: fifty individual "added" rows from one install
    /// session is noise, while "Jul 16 · added 6" is the fact.
    private var groupedEvents: [HistoryEventDay] {
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: events) { event in
            historyDayKey(event.occurredAt, calendar: calendar)
        }
        return byDay.map { day, events in
            HistoryEventDay(day: day, events: events)
        }
        .sorted { $0.day > $1.day }
    }

    private var historyScope: SkillHistoryScope {
        guard let selectedProjectRoot else { return .all }
        return isGlobalRoot(selectedProjectRoot) ? .global : .project(root: selectedProjectRoot)
    }

    @MainActor
    private func refresh() async {
        let refreshID = self.refreshID
        isLoading = true
        let scope = historyScope
        let days = range.days
        let loaded = await Task.detached(priority: .utility) {
            let trends = (try? MetagentCore.skillHistoryTrends(
                metrics: [
                    .portfolioSkills,
                    .adoptionUnused30d,
                    .adoptionNeverObserved,
                    .tokensSkillBody,
                    .tokensCatalog,
                ],
                scope: scope,
                windowDays: days
            )) ?? .empty
            let since = Calendar.current.date(byAdding: .day, value: -days, to: Date())
            let events = (try? MetagentCore.skillHistoryEvents(
                since: since,
                scope: scope == .all ? nil : scope,
                limit: 400
            )) ?? []
            return (trends, events)
        }.value
        guard !Task.isCancelled, refreshID == self.refreshID else { return }
        trends = loaded.0
        events = loaded.1
        loadedRefreshID = refreshID
        isLoading = false
    }
}

private func historyDayKey(_ date: Date, calendar: Calendar) -> String {
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    return String(
        format: "%04d-%02d-%02d",
        components.year ?? 0,
        components.month ?? 0,
        components.day ?? 0
    )
}

struct HistoryEventDay: Identifiable {
    let day: String
    let events: [SkillHistoryEvent]

    var id: String { day }

    var countsByKind: [(kind: SkillHistoryEventKind, count: Int)] {
        SkillHistoryEventKind.allCases.compactMap { kind in
            let count = events.count { $0.kind == kind }
            return count > 0 ? (kind, count) : nil
        }
    }

    /// A day is reconstructed when nothing in it was actually observed.
    var isEntirelyInferred: Bool {
        events.allSatisfy { $0.origin == .inferred }
    }
}

struct HistoryEventDayRow: View {
    let group: HistoryEventDay
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)

                    Text(group.day)
                        .font(.callout.weight(.medium))
                        .monospacedDigit()
                        .frame(width: 92, alignment: .leading)

                    HStack(spacing: 6) {
                        ForEach(group.countsByKind, id: \.kind) { entry in
                            HistoryEventBadge(kind: entry.kind, count: entry.count)
                        }
                    }

                    Spacer(minLength: 8)

                    if group.isEntirelyInferred {
                        Text("estimated")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)

            if isExpanded {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(group.events) { event in
                        HStack(spacing: 8) {
                            Text(event.kind.displayLabel)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(event.kind.tint)
                                .frame(width: 74, alignment: .leading)
                            Text(event.subjectName)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            if let evidence = event.detail["evidence"] {
                                Text(evidence)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.leading, 24)
                .padding(.bottom, 10)
            }
        }
    }
}

private struct HistoryLineSample: View {
    let isEstimated: Bool

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 3))
            path.addLine(to: CGPoint(x: 30, y: 3))
        }
        .stroke(
            Color.secondary,
            style: StrokeStyle(lineWidth: 1.5, dash: isEstimated ? [4, 3] : [])
        )
        .frame(width: 30, height: 6)
        .accessibilityHidden(true)
    }
}

struct HistoryEventBadge: View {
    let kind: SkillHistoryEventKind
    let count: Int

    var body: some View {
        Text("\(kind.displayLabel) \(count)")
            .font(.caption.weight(.medium))
            .foregroundStyle(kind.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(kind.tint.opacity(0.12), in: Capsule())
    }
}

extension SkillHistoryEventKind {
    var displayLabel: String {
        switch self {
        case .added: "added"
        case .removed: "removed"
        case .archived: "archived"
        case .restored: "restored"
        case .renamed: "renamed"
        case .updated: "updated"
        case .contentChanged: "edited"
        case .sourceChanged: "resourced"
        case .scopeChanged: "rescoped"
        }
    }

    var tint: Color {
        switch self {
        case .added: .green
        case .removed: .orange
        case .archived: .brown
        case .restored: .mint
        case .renamed: .blue
        case .updated: .cyan
        case .contentChanged: .purple
        case .sourceChanged: .teal
        case .scopeChanged: .indigo
        }
    }
}

struct HistoryChartSeries: Identifiable {
    let id: String
    let label: String
    let tint: Color
    let points: [HistoryPlotPoint]
}

/// One point ready to draw, carrying the line it belongs to and how it should
/// be stroked. Reconstructed points are dashed and dimmed so inferred evidence
/// never reads as something the app watched happen.
struct HistoryChartMark: Identifiable {
    let id: String
    let seriesKey: String
    let tint: Color
    let isInferred: Bool
    let date: Date
    let value: Double

    var strokeStyle: StrokeStyle {
        StrokeStyle(lineWidth: 1.8, lineCap: .round, dash: isInferred ? [3, 3] : [])
    }

    var strokeColor: Color {
        tint.opacity(isInferred ? 0.5 : 1)
    }
}

/// A full-width chart with a legend, axes, and honest gaps.
struct HistoryChartCard: View {
    let title: String
    let help: String
    let series: [HistoryChartSeries]
    let format: (Double) -> String
    let isCompact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title)
                    .font(.headline)
                Spacer(minLength: 12)
                HStack(spacing: 10) {
                    ForEach(series) { entry in
                        HStack(spacing: 5) {
                            Circle()
                                .fill(entry.tint)
                                .frame(width: 7, height: 7)
                            Text(entry.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if series.isEmpty {
                Text("Nothing recorded for this range yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            } else {
                chart
            }
        }
        .padding(isCompact ? 12 : 14)
        .cardBackground()
        .help(help)
    }

    /// Every point flattened into one list, each tagged with the line it belongs
    /// to. Splitting series and gap segments inside the chart body pushed the
    /// type checker past its limit, and this reads more plainly anyway.
    private var marks: [HistoryChartMark] {
        series.flatMap { entry in
            HistoryPlot.segments(entry.points).enumerated().flatMap { index, segment in
                segment.map { point in
                    HistoryChartMark(
                        id: "\(entry.id)-\(point.id)",
                        seriesKey: "\(entry.id)-\(index)",
                        tint: entry.tint,
                        isInferred: point.origin == .inferred,
                        date: point.date,
                        value: point.value
                    )
                }
            }
        }
    }

    private var chart: some View {
        // Each run of consecutive days is its own series key, so days with no
        // sample stay visibly empty instead of being joined through.
        Chart(marks) { mark in
            LineMark(
                x: .value("Day", mark.date),
                y: .value("Value", mark.value),
                series: .value("Series", mark.seriesKey)
            )
            .interpolationMethod(.monotone)
            .lineStyle(mark.strokeStyle)
            .foregroundStyle(mark.strokeColor)
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(format(number))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: isCompact ? 3 : 6)) { value in
                AxisGridLine().foregroundStyle(.quaternary.opacity(0.5))
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .chartLegend(.hidden)
        .frame(height: isCompact ? 120 : 168)
    }
}
