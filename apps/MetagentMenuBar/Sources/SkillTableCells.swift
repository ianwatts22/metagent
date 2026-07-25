import AppKit
import Foundation
import MetagentCore
import SwiftUI
import UniformTypeIdentifiers

struct SkillColumnSpec: Identifiable {
    let id: String
    let title: String
    let comparator: KeyPathComparator<SkillTableRow>
    let minWidth: CGFloat
    let idealWidth: CGFloat
    let isNumeric: Bool
    let isMonospaced: Bool
    let isPrimary: Bool
    let defaultViews: Set<SkillTableView>
    let showsBadge: Bool
    let symbol: ((SkillTableRow) -> String?)?
    let tint: ((SkillTableRow) -> Color?)?
    let value: (SkillTableRow) -> String
    let help: (SkillTableRow) -> String

    init(
        id: String,
        title: String,
        comparator: KeyPathComparator<SkillTableRow>,
        minWidth: CGFloat,
        idealWidth: CGFloat,
        isNumeric: Bool,
        isMonospaced: Bool,
        isPrimary: Bool,
        defaultViews: Set<SkillTableView>,
        showsBadge: Bool = false,
        symbol: ((SkillTableRow) -> String?)? = nil,
        tint: ((SkillTableRow) -> Color?)? = nil,
        value: @escaping (SkillTableRow) -> String,
        help: @escaping (SkillTableRow) -> String
    ) {
        self.id = id
        self.title = title
        self.comparator = comparator
        self.minWidth = minWidth
        self.idealWidth = idealWidth
        self.isNumeric = isNumeric
        self.isMonospaced = isMonospaced
        self.isPrimary = isPrimary
        self.defaultViews = defaultViews
        self.showsBadge = showsBadge
        self.symbol = symbol
        self.tint = tint
        self.value = value
        self.help = help
    }

    func defaultVisibility(_ view: SkillTableView) -> Visibility {
        defaultViews.contains(view) ? .visible : .hidden
    }
}

struct SkillTableColumnCell: View {
    let column: SkillColumnSpec
    let row: SkillTableRow

    @ViewBuilder
    var body: some View {
        if row.isGroup {
            if column.id == "skill" {
                SkillNameCell(row: row)
            } else {
                Color.clear
            }
        } else if column.id == "skill" {
            SkillNameCell(row: row)
        } else if column.id == "display-location" {
            SkillScopeLocationCell(row: row)
        } else if column.id == "origin" {
            SkillSourceIconCell(category: row.sourceCategory, help: row.sourceHelp)
        } else if column.id == "last-used" {
            RelativeUsageDateCell(date: row.lastUsedDate)
                .foregroundStyle(row.totalInvocations == 0 ? Color.secondary : Color.primary)
                .help(column.help(row))
        } else {
            InventoryTableCell(
                text: column.value(row),
                help: column.help(row),
                isNumeric: column.isNumeric,
                isMonospaced: column.isMonospaced,
                isPrimary: column.isPrimary,
                showsBadge: column.showsBadge,
                symbol: column.symbol?(row),
                tint: column.tint?(row)
            )
        }
    }
}

@MainActor let skillColumnSpecs: [SkillColumnSpec] = [
    SkillColumnSpec(
        id: "skill",
        title: "Skill",
        comparator: KeyPathComparator(\SkillTableRow.skillName),
        minWidth: 160,
        idealWidth: 220,
        isNumeric: false,
        isMonospaced: false,
        isPrimary: true,
        defaultViews: Set(SkillTableView.allCases),
        value: \.skillName,
        help: \.skillPath
    ),
    SkillColumnSpec(
        id: "display-location",
        title: "Location",
        comparator: KeyPathComparator(\SkillTableRow.displayLocationSortValue),
        minWidth: 92,
        idealWidth: 150,
        isNumeric: false,
        isMonospaced: false,
        isPrimary: false,
        defaultViews: [.summary, .duplicates, .inventory, .usage],
        value: \.displayLocationText,
        help: \.displayLocationHelp
    ),
    SkillColumnSpec(
        id: "origin",
        title: "Source",
        comparator: KeyPathComparator(\SkillTableRow.sourceText),
        minWidth: 48,
        idealWidth: 58,
        isNumeric: false,
        isMonospaced: false,
        isPrimary: false,
        defaultViews: [.summary, .duplicates, .inventory, .review],
        value: \.sourceText,
        help: \.sourceHelp
    ),
    SkillColumnSpec(
        id: "overlap",
        title: "Overlap",
        comparator: KeyPathComparator(\SkillTableRow.overlapSortValue),
        minWidth: 128,
        idealWidth: 160,
        isNumeric: false,
        isMonospaced: false,
        isPrimary: false,
        defaultViews: [.duplicates],
        value: \.overlapText,
        help: \.overlapHelp
    ),
    SkillColumnSpec(
        id: "description",
        title: "Description",
        comparator: KeyPathComparator(\SkillTableRow.descriptionText),
        minWidth: 180,
        idealWidth: 300,
        isNumeric: false,
        isMonospaced: false,
        isPrimary: false,
        defaultViews: [.inventory],
        value: \.descriptionText,
        help: \.descriptionHelp
    ),
    SkillColumnSpec(
        id: "upstream",
        title: "Upstream",
        comparator: KeyPathComparator(\SkillTableRow.upstreamText),
        minWidth: 92,
        idealWidth: 128,
        isNumeric: false,
        isMonospaced: false,
        isPrimary: false,
        defaultViews: [.summary, .duplicates, .inventory],
        value: \.upstreamText,
        help: \.upstreamHelp
    ),
    SkillColumnSpec(
        id: "version",
        title: "Version",
        comparator: KeyPathComparator(\SkillTableRow.versionText),
        minWidth: 72,
        idealWidth: 96,
        isNumeric: false,
        isMonospaced: true,
        isPrimary: false,
        defaultViews: [.inventory],
        value: \.versionText,
        help: \.versionHelp
    ),
    SkillColumnSpec(
        id: "updated",
        title: "Weeks old",
        comparator: KeyPathComparator(\SkillTableRow.updatedSortValue),
        minWidth: 74,
        idealWidth: 88,
        isNumeric: true,
        isMonospaced: false,
        isPrimary: false,
        defaultViews: [.summary, .inventory],
        value: \.updatedText,
        help: \.updatedHelp
    ),
    SkillColumnSpec(
        id: "references",
        title: "Refs",
        comparator: KeyPathComparator(\SkillTableRow.referenceFileCount),
        minWidth: 48,
        idealWidth: 58,
        isNumeric: true,
        isMonospaced: false,
        isPrimary: false,
        defaultViews: [.inventory],
        value: { $0.referenceFileCount < 0 ? "—" : $0.referenceFileCount.formatted() },
        help: { $0.referenceFileCount < 0 ? "Not available." : "\($0.referenceFileCount.formatted()) files under references/" }
    ),
    SkillColumnSpec(
        id: "scripts",
        title: "Scripts",
        comparator: KeyPathComparator(\SkillTableRow.scriptFileCount),
        minWidth: 56,
        idealWidth: 68,
        isNumeric: true,
        isMonospaced: false,
        isPrimary: false,
        defaultViews: [.inventory],
        value: { $0.scriptFileCount < 0 ? "—" : $0.scriptFileCount.formatted() },
        help: { $0.scriptFileCount < 0 ? "Not available." : "\($0.scriptFileCount.formatted()) files under scripts/" }
    ),
    SkillColumnSpec(
        id: "metagent-score",
        title: "Quality",
        comparator: KeyPathComparator(\SkillTableRow.metagentScoreSortValue),
        minWidth: 104,
        idealWidth: 116,
        isNumeric: true,
        isMonospaced: false,
        isPrimary: false,
        defaultViews: [.review],
        showsBadge: true,
        tint: { $0.metagentScoreTint },
        value: \.metagentScoreText,
        help: \.metagentScoreHelp
    ),
    SkillColumnSpec(
        id: "plugin-eval",
        title: "Plugin Eval",
        comparator: KeyPathComparator(\SkillTableRow.pluginEvalSortValue),
        minWidth: 112,
        idealWidth: 126,
        isNumeric: true,
        isMonospaced: false,
        isPrimary: false,
        defaultViews: [.review],
        showsBadge: true,
        tint: \.pluginEvalTint,
        value: \.pluginEvalText,
        help: \.pluginEvalHelp
    ),
    SkillColumnSpec(
        id: "portfolio-score",
        title: "Utility",
        comparator: KeyPathComparator(\SkillTableRow.portfolioScoreSortValue),
        minWidth: 82,
        idealWidth: 94,
        isNumeric: true,
        isMonospaced: false,
        isPrimary: false,
        defaultViews: [.summary, .review],
        showsBadge: true,
        tint: { $0.portfolioScoreTint },
        value: \.portfolioScoreText,
        help: \.portfolioScoreHelp
    ),
    SkillColumnSpec(
        id: "codex-review",
        title: "Codex",
        comparator: KeyPathComparator(\SkillTableRow.codexReviewSortValue),
        minWidth: 82,
        idealWidth: 94,
        isNumeric: true,
        isMonospaced: false,
        isPrimary: false,
        defaultViews: [.review],
        showsBadge: true,
        tint: \.codexReviewTint,
        value: \.codexReviewText,
        help: \.codexReviewHelp
    ),
    SkillColumnSpec(
        id: "tokens",
        title: "Tokens",
        comparator: KeyPathComparator(\SkillTableRow.tokenEstimate),
        minWidth: 76,
        idealWidth: 92,
        isNumeric: true,
        isMonospaced: false,
        isPrimary: false,
        defaultViews: [.summary, .inventory],
        value: { $0.tokenEstimate < 0 ? "—" : formatNumber($0.tokenEstimate) },
        help: { $0.tokenEstimate < 0 ? "Not available for an uninstalled skill." : formatNumber($0.tokenEstimate) }
    ),
    SkillColumnSpec(
        id: "installation",
        title: "State",
        comparator: KeyPathComparator(\SkillTableRow.installationText),
        minWidth: 88,
        idealWidth: 104,
        isNumeric: false,
        isMonospaced: false,
        isPrimary: false,
        defaultViews: [],
        value: \.installationText,
        help: \.installationHelp
    ),
    SkillColumnSpec(
        id: "7d",
        title: "7d",
        comparator: KeyPathComparator(\SkillTableRow.invocations7d),
        minWidth: 54,
        idealWidth: 64,
        isNumeric: true,
        isMonospaced: false,
        isPrimary: false,
        defaultViews: [.usage],
        value: { $0.invocations7d.formatted() },
        help: { "\($0.invocations7d.formatted()) reads in the last 7 days" }
    ),
    SkillColumnSpec(
        id: "30d",
        title: "30d Usage",
        comparator: KeyPathComparator(\SkillTableRow.invocations30d),
        minWidth: 82,
        idealWidth: 96,
        isNumeric: true,
        isMonospaced: false,
        isPrimary: false,
        defaultViews: [.summary, .duplicates, .usage],
        value: { $0.invocations30d.formatted() },
        help: { "\($0.invocations30d.formatted()) reads in the last 30 days" }
    ),
    SkillColumnSpec(
        id: "all",
        title: "All-time",
        comparator: KeyPathComparator(\SkillTableRow.totalInvocations),
        minWidth: 64,
        idealWidth: 76,
        isNumeric: true,
        isMonospaced: false,
        isPrimary: false,
        defaultViews: [.usage],
        value: { $0.totalInvocations.formatted() },
        help: { "\($0.totalInvocations.formatted()) observed reads" }
    ),
    SkillColumnSpec(
        id: "tasks",
        title: "Threads",
        comparator: KeyPathComparator(\SkillTableRow.distinctThreads),
        minWidth: 58,
        idealWidth: 68,
        isNumeric: true,
        isMonospaced: false,
        isPrimary: false,
        defaultViews: [],
        value: { $0.distinctThreads.formatted() },
        help: { "\($0.distinctThreads.formatted()) distinct Codex threads with an observed skill read" }
    ),
    SkillColumnSpec(
        id: "reads-per-thread",
        title: "Reads / thread",
        comparator: KeyPathComparator(\SkillTableRow.readsPerThread),
        minWidth: 92,
        idealWidth: 108,
        isNumeric: true,
        isMonospaced: false,
        isPrimary: false,
        defaultViews: [],
        value: \.readsPerThreadText,
        help: {
            guard $0.distinctThreads > 0 else { return "No observed threads." }
            return "\($0.totalInvocations.formatted()) all-time reads across \($0.distinctThreads.formatted()) threads. A lower value suggests broader one-off use; a higher value suggests repeated reliance within fewer threads."
        }
    ),
    SkillColumnSpec(
        id: "repeats",
        title: "Repeats",
        comparator: KeyPathComparator(\SkillTableRow.repeatInvocations),
        minWidth: 66,
        idealWidth: 76,
        isNumeric: true,
        isMonospaced: false,
        isPrimary: false,
        defaultViews: [],
        value: { $0.repeatInvocations.formatted() },
        help: { "\($0.repeatInvocations.formatted()) additional reads in the same turn" }
    ),
    SkillColumnSpec(
        id: "last-used",
        title: "Last used",
        comparator: KeyPathComparator(\SkillTableRow.lastUsedSortValue),
        minWidth: 100,
        idealWidth: 120,
        isNumeric: false,
        isMonospaced: false,
        isPrimary: false,
        defaultViews: [.usage, .review],
        value: \.lastUsedText,
        help: \.lastUsedHelp
    )
]

struct InventoryTableCell: View {
    let text: String
    let help: String
    let isNumeric: Bool
    let isMonospaced: Bool
    let isPrimary: Bool
    let showsBadge: Bool
    let symbol: String?
    let tint: Color?

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(cellFont)
                .lineLimit(1)
                .truncationMode(.middle)
                .monospacedDigit()
                .foregroundStyle(tint ?? .primary)
                .padding(.horizontal, showsBadge && text != "—" ? 7 : 0)
                .padding(.vertical, showsBadge && text != "—" ? 2 : 0)
                .background {
                    if showsBadge, text != "—", let tint {
                        Capsule().fill(tint.opacity(0.12))
                    }
                }
        }
        .frame(maxWidth: .infinity, alignment: isNumeric ? .trailing : .leading)
        .help(help.isEmpty ? text : help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text.isEmpty ? help : text)
    }

    private var cellFont: Font {
        if isPrimary {
            return .body.weight(.medium)
        }
        return isMonospaced ? .caption.monospaced() : .callout
    }
}

struct SkillNameCell: View {
    let row: SkillTableRow

    var body: some View {
        Group {
            if row.isGroup {
                HStack(spacing: 7) {
                    Text(row.skillName)
                        .font(.body.weight(.semibold))
                    Text((row.children?.count ?? 0).formatted())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("\(row.skillName), \(row.children?.count ?? 0) skills")
            } else {
                HStack(spacing: 7) {
                    Group {
                        if let icon = AppBrand.skillIcon(path: row.skillIconPath) {
                            Image(nsImage: icon)
                                .resizable()
                                .scaledToFit()
                        } else {
                            Image(systemName: "sparkles")
                                .resizable()
                                .scaledToFit()
                                .foregroundStyle(.tertiary)
                                .padding(2)
                        }
                    }
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .accessibilityHidden(true)

                    Text(row.skillName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(displayUserPath(row.skillPath))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.skillName)
                .accessibilityHint(displayUserPath(row.skillPath))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SkillScopeLocationCell: View {
    let row: SkillTableRow

    var body: some View {
        Group {
            if row.displaysGlobalLocation {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
            } else {
                Text(row.displayLocationText)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(row.displayLocationHelp)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.displaysGlobalLocation ? "Global" : row.displayLocationText)
        .accessibilityHint(row.displayLocationHelp)
    }
}

struct SkillSourceIconCell: View {
    let category: SkillSourceCategory
    let help: String

    var body: some View {
        sourceIcon
            .frame(width: 20, height: 20)
            .help(help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(category.title)
            .accessibilityHint(help)
    }

    @ViewBuilder
    private var sourceIcon: some View {
        switch category {
        case .plugin, .codexSystem, .codexInstalled:
            applicationIcon("com.openai.codex", fallback: "sparkles")
        case .claude:
            applicationIcon("com.anthropic.claudefordesktop", fallback: "link")
        case .dotagentsLocal, .dotagentsManaged:
            DotagentsSourceMark()
        case .skillsCLI:
            VercelSourceMark()
        case .externalCLI:
            Image(systemName: "terminal.fill")
                .foregroundStyle(.secondary)
        case .local:
            Image(systemName: "questionmark.folder")
                .foregroundStyle(.secondary)
        case .notInstalled:
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func applicationIcon(_ bundleIdentifier: String, fallback: String) -> some View {
        if let icon = AppBrand.applicationIcon(bundleIdentifier: bundleIdentifier) {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            Image(systemName: fallback)
                .foregroundStyle(.secondary)
        }
    }
}

struct DotagentsSourceMark: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: geometry.size.width * 0.23, style: .continuous)
                    .fill(Color(red: 0.72, green: 1, blue: 0))
                Circle()
                    .fill(.black)
                    .frame(width: geometry.size.width * 0.28)
                    .padding(.leading, geometry.size.width * 0.2)
                    .padding(.bottom, geometry.size.height * 0.2)
            }
        }
    }
}

struct VercelSourceMark: View {
    var body: some View {
        ZStack {
            Circle().fill(.black)
            Triangle()
                .fill(.white)
                .padding(4.5)
        }
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct RelativeUsageDateCell: View {
    let date: Date?

    var body: some View {
        if let date {
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                Text(date.formatted(.relative(presentation: .named, unitsStyle: .wide)))
                    .font(.callout)
            }
        } else {
            Text("Never")
                .font(.callout)
        }
    }
}
