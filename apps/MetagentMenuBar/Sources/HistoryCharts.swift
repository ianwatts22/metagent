import Charts
import MetagentCore
import SwiftUI

/// One recorded point, prepared for charting.
///
/// `SkillHistoryPoint` carries a day string because that is the storage key.
/// Charts need a `Date`, and the conversion should happen once at the boundary
/// rather than inside every chart body.
struct HistoryPlotPoint: Identifiable, Equatable {
    let id: String
    let date: Date
    let value: Double
    let origin: SkillHistoryOrigin
    /// The number of days since the previous recorded point, used to break the
    /// line across gaps.
    let daysSincePrevious: Int
}

enum HistoryPlot {
    /// Converts recorded points to plottable ones, marking where the record has
    /// holes.
    ///
    /// A gap means the app was not open, which is not the same as the value
    /// having been zero or having moved smoothly across the missing days. The
    /// line is broken rather than drawn through, so the chart never invents a
    /// measurement that was never taken.
    static func points(
        _ recorded: [SkillHistoryPoint],
        calendar: Calendar = .current
    ) -> [HistoryPlotPoint] {
        var previousDate: Date?
        return recorded.compactMap { point in
            guard let date = date(fromHistoryDay: point.day, calendar: calendar) else { return nil }
            defer { previousDate = date }
            let gap = previousDate.map {
                calendar.dateComponents([.day], from: $0, to: date).day ?? 1
            } ?? 1
            return HistoryPlotPoint(
                id: point.day,
                date: date,
                value: point.value,
                origin: point.origin,
                daysSincePrevious: gap
            )
        }
    }

    /// Splits points into runs of consecutive days, so each run draws as its own
    /// unbroken line and missing days show as empty space.
    static func segments(
        _ points: [HistoryPlotPoint],
        maximumGapDays: Int = 1
    ) -> [[HistoryPlotPoint]] {
        var segments: [[HistoryPlotPoint]] = []
        var current: [HistoryPlotPoint] = []
        for point in points {
            if !current.isEmpty, point.daysSincePrevious > maximumGapDays {
                segments.append(current)
                current = []
            }
            current.append(point)
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    /// Parses a stored day key using the same calendar the samples were bucketed
    /// with.
    static func date(fromHistoryDay day: String, calendar: Calendar) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return calendar.date(from: components)
    }
}

/// A compact trend line for a metric card.
///
/// Deliberately axis-free and label-free: the card's number is the fact, and the
/// line only says which way it has been moving. Reconstructed stretches are
/// drawn dashed and dimmer so inferred evidence never reads as observed.
struct HistorySparkline: View {
    let points: [HistoryPlotPoint]
    var tint: Color = .secondary
    var height: CGFloat = 22

    /// Flattened the same way the full charts are, so a gap breaks the line and
    /// the type checker never has to reason about nested chart builders.
    private var marks: [HistoryChartMark] {
        HistoryPlot.segments(points).enumerated().flatMap { index, segment in
            segment.map { point in
                HistoryChartMark(
                    id: point.id,
                    seriesKey: "spark-\(index)",
                    tint: tint,
                    isInferred: point.origin == .inferred,
                    date: point.date,
                    value: point.value
                )
            }
        }
    }

    var body: some View {
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
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartPlotStyle { plot in
            plot.background(.clear)
        }
        .frame(height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The signed movement of a metric over the recorded window.
///
/// Direction alone is not judgment: fewer skills is not automatically better and
/// more reads is not automatically worse. The caller says whether a rise is good,
/// and a metric with no honest direction passes `nil` and gets neutral styling.
struct HistoryDelta: View {
    let change: Double
    let baselineDay: String?
    var risingIsGood: Bool?
    var formatter: (Double) -> String = { $0.formatted(.number.precision(.fractionLength(0))) }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.caption2.weight(.bold))
            Text(formatter(abs(change)))
                .font(.caption.weight(.medium))
                .monospacedDigit()
        }
        .foregroundStyle(tint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var isFlat: Bool {
        change == 0
    }

    private var symbol: String {
        if isFlat { return "equal" }
        return change > 0 ? "arrow.up" : "arrow.down"
    }

    private var tint: Color {
        guard let risingIsGood, !isFlat else { return .secondary }
        return (change > 0) == risingIsGood ? .green : .orange
    }

    private var accessibilityText: String {
        guard !isFlat else { return "unchanged since \(baselineDay ?? "the first recorded day")" }
        let direction = change > 0 ? "up" : "down"
        let since = baselineDay.map { " since \($0)" } ?? ""
        return "\(direction) \(formatter(abs(change)))\(since)"
    }
}

/// What a card shows in place of a sparkline before there is a trend to draw.
///
/// One recorded day is a value, not a trend. Saying so is better than drawing a
/// flat line that implies stability nobody measured.
struct HistoryTrendPlaceholder: View {
    let coverage: SkillHistoryCoverage
    var height: CGFloat = 22

    var body: some View {
        Text(message)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(height: height, alignment: .center)
    }

    private var message: String {
        coverage.observedDayCount == 0 && coverage.inferredDayCount == 0
            ? "History starts recording today"
            : "Not enough recorded days yet"
    }
}
