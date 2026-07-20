import AppKit
import Foundation
import MetagentCore
import SwiftUI

@main
struct MetagentMenuBarApp: App {
    @StateObject private var model = MetagentModel()
    @State private var selectedSection = PanelSection.overview

    var body: some Scene {
        WindowGroup("Metagent", id: "main") {
            MetagentPanel(
                model: model,
                showsOpenWindowButton: false,
                selectedSection: $selectedSection
            )
                .frame(minWidth: 1040, idealWidth: 1180, minHeight: 680, idealHeight: 760)
        }
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra {
            MetagentPanel(
                model: model,
                showsOpenWindowButton: true,
                selectedSection: $selectedSection
            )
                .frame(width: 560, height: 640)
        } label: {
            MenuBarIcon()
                .frame(width: 18, height: 18)
                .accessibilityLabel("Metagent")
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarIcon: View {
    var body: some View {
        if let image = AppBrand.menuBarIcon {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "wrench.and.screwdriver")
        }
    }
}

private enum AppBrand {
    static let menuBarIcon: NSImage? = {
        for bundle in [Bundle.main, Bundle.module] {
            guard let url = bundle.url(forResource: "MenuBarIconTemplate", withExtension: "pdf"),
                  let image = NSImage(contentsOf: url)
            else {
                continue
            }
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        return nil
    }()
}

private struct MetagentPanel: View {
    @ObservedObject var model: MetagentModel
    let showsOpenWindowButton: Bool
    @Environment(\.openWindow) private var openWindow
    @Binding var selectedSection: PanelSection

    var body: some View {
        ZStack {
            PanelBackdrop()

            VStack(alignment: .leading, spacing: showsOpenWindowButton ? 14 : 18) {
                header
                navigation
                panelContent
                    .animation(.snappy(duration: 0.25), value: selectedSection)

                if showsOpenWindowButton {
                    compactFooter
                }
            }
            .padding(showsOpenWindowButton ? 16 : 22)
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Metagent")
                    .font(.title.weight(.semibold))
                Text(model.statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Label(healthLabel, systemImage: healthSymbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(healthTint)

                if let lastRun = model.lastRunText {
                    Text(lastRun)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var navigation: some View {
        HStack(spacing: 4) {
            ForEach(PanelSection.allCases) { section in
                SectionNavigationButton(
                    section: section,
                    isSelected: selectedSection == section
                ) {
                    withAnimation(.snappy(duration: 0.25)) {
                        selectedSection = section
                    }
                }
            }
        }
        .padding(4)
        .glassEffect(.clear, in: Capsule())
    }

    @ViewBuilder
    private var panelContent: some View {
        switch selectedSection {
        case .overview:
            OverviewSection(model: model)
        case .repos:
            ReposSection(model: model)
        case .usage:
            if showsOpenWindowButton {
                UsageMenuSection(model: model) {
                    openWindow(id: "main")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
            } else {
                UsageSection(model: model)
            }
        case .inventory:
            if showsOpenWindowButton {
                InventoryMenuSection(model: model) {
                    openWindow(id: "main")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
            } else {
                InventorySection(model: model)
            }
        case .repair:
            RepairSection(model: model)
        case .tools:
            ToolsSection(model: model)
        }
    }

    private var compactFooter: some View {
        HStack(spacing: 10) {
            if model.isRunning {
                ProgressView()
                    .controlSize(.small)
                Text("Working…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            } label: {
                Label("Open Window", systemImage: "macwindow")
            }
            .buttonStyle(.glassProminent)

            Button {
                model.refreshStatus()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.glass)
            .help("Refresh")
            .disabled(model.isRunning)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.glass)
            .help("Quit Metagent")
        }
    }

    private var healthLabel: String {
        if model.problemCount == 0 {
            return "Healthy"
        }
        return "\(model.problemCount) to review"
    }

    private var healthSymbol: String {
        model.problemCount == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var healthTint: Color {
        model.problemCount == 0 ? .green : .orange
    }
}

private struct PanelBackdrop: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(
                colors: [Color.accentColor.opacity(0.13), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 520
            )
            RadialGradient(
                colors: [Color.purple.opacity(0.07), .clear],
                center: .bottomTrailing,
                startRadius: 0,
                endRadius: 620
            )
        }
        .ignoresSafeArea()
    }
}

private struct SectionNavigationButton: View {
    let section: PanelSection
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        button
            .buttonStyle(.plain)
    }

    private var button: some View {
        Button(action: action) {
            Label(section.title, systemImage: section.symbol)
                .font(.callout.weight(isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    isSelected ? Color.accentColor : Color.clear,
                    in: Capsule()
                )
                .contentShape(Capsule())
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private enum PanelSection: String, CaseIterable, Identifiable {
    case overview
    case repos
    case usage
    case inventory
    case repair
    case tools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .repos: "Skills"
        case .usage: "Usage"
        case .inventory: "Inventory"
        case .repair: "Repair"
        case .tools: "Tools"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge"
        case .repos: "folder"
        case .usage: "chart.bar.xaxis"
        case .inventory: "tablecells"
        case .repair: "link.badge.plus"
        case .tools: "wrench.and.screwdriver"
        }
    }
}

private struct OverviewSection: View {
    @ObservedObject var model: MetagentModel
    @State private var showsDoctorFindings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            healthHero
            summary

            if let title = model.lastOutputTitle {
                LastOutputView(
                    title: title,
                    lines: model.lastOutputLines,
                    onCopy: model.copyLastOutput
                )
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $showsDoctorFindings) {
            DoctorFindingsView(model: model)
        }
    }

    private var healthHero: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(healthTint.opacity(0.14))
                Image(systemName: healthSymbol)
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(healthTint)
            }
            .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 4) {
                Text(healthTitle)
                    .font(.title2.weight(.semibold))
                Text(healthMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 16)

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        showsDoctorFindings = true
                        if model.problemCount == 0 {
                            model.runDoctor()
                        }
                    } label: {
                        Label(model.problemCount == 0 ? "Run Doctor" : "Review", systemImage: "stethoscope")
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(model.isRunning)

                    Button {
                        model.previewRepair()
                    } label: {
                        Label("Preview Repair", systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(.glass)
                    .disabled(model.isRunning)

                    Button {
                        model.refreshStatus()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.glass)
                    .help("Refresh")
                    .disabled(model.isRunning)
                }
                .controlSize(.large)
            }
        }
        .padding(20)
        .glassEffect(
            .regular.tint(healthTint.opacity(0.08)),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
    }

    private var summary: some View {
        HStack(spacing: 0) {
            SummaryMetric(
                title: "Skills",
                value: "\(model.skillCount)",
                detail: "across \(model.repoCount) locations",
                symbol: "sparkles"
            )
            Divider()
                .padding(.vertical, 4)
            SummaryMetric(
                title: "Doctor",
                value: model.problemText,
                detail: model.coreStatusText,
                symbol: "stethoscope"
            )
            Divider()
                .padding(.vertical, 4)
            SummaryMetric(
                title: "Configured roots",
                value: model.rootsText,
                detail: model.locationSummaryText,
                symbol: "point.3.connected.trianglepath.dotted"
            )
        }
        .frame(height: 76, alignment: .top)
        .padding(.vertical, 4)
    }

    private var healthTitle: String {
        if model.problemCount == 0 {
            return "Everything looks healthy"
        }
        return "\(model.problemCount) \(model.problemCount == 1 ? "item needs" : "items need") attention"
    }

    private var healthMessage: String {
        if model.problemCount == 0 {
            return "No action is needed. Metagent is ready when you are."
        }
        if model.doctorReviewCount == 0 {
            return "\(model.doctorRepairableCount) can be fixed by repairing the Claude skill links."
        }
        return "\(model.doctorRepairableCount) repairable · \(model.doctorReviewCount) need review"
    }

    private var healthSymbol: String {
        model.problemCount == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var healthTint: Color {
        model.problemCount == 0 ? .green : .orange
    }
}

private struct SummaryMetric: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.1), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
    }
}

private struct DoctorFindingsView: View {
    @ObservedObject var model: MetagentModel
    @Environment(\.dismiss) private var dismiss

    private var groups: [DoctorProjectGroup] {
        DoctorProjectGroup.groups(from: model.doctorFindings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Doctor Findings")
                        .font(.title2.weight(.semibold))
                    Text(summaryText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Close") {
                    dismiss()
                }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
            }

            if groups.isEmpty {
                EmptyStateView(
                    title: "Everything looks healthy",
                    message: "Doctor did not find any warnings or failures.",
                    symbol: "checkmark.circle"
                )
            } else {
                List {
                    ForEach(groups) { project in
                        Section {
                            ForEach(project.categories) { category in
                                VStack(alignment: .leading, spacing: 8) {
                                    Label(category.title, systemImage: category.symbol)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)

                                    ForEach(category.issues) { issue in
                                        DoctorFindingRow(issue: issue)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        } header: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(project.name)
                                if let root = project.root {
                                    Text(root)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .textCase(nil)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }

            HStack(spacing: 10) {
                if model.doctorRepairableCount > 0 {
                    Label(
                        "\(model.doctorRepairableCount) repairable",
                        systemImage: "link.badge.plus"
                    )
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.blue)
                }

                Spacer()

                Button {
                    model.runDoctor()
                } label: {
                    Label("Run Again", systemImage: "stethoscope")
                }
                .buttonStyle(.glass)
                .disabled(model.isRunning)

                if model.doctorRepairableCount > 0 {
                    Button {
                        model.previewRepair()
                        dismiss()
                    } label: {
                        Label("Preview Repair", systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(model.isRunning)
                }
            }
        }
        .padding(18)
        .frame(minWidth: 720, minHeight: 520)
    }

    private var summaryText: String {
        if model.problemCount == 0 {
            return "No action needed."
        }
        if model.doctorReviewCount == 0 {
            return "\(model.doctorRepairableCount) finding(s) can be fixed by repairing the Claude skill links."
        }
        return "\(model.doctorRepairableCount) repairable, \(model.doctorReviewCount) to review."
    }
}

private struct DoctorFindingRow: View {
    let issue: DoctorIssue
    @State private var showsTechnicalDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: issue.severity == .failure ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(issue.severity == .failure ? .red : .orange)

                Text(issue.summary ?? issue.message)
                    .font(.callout.weight(.medium))

                Spacer()

                if issue.repairAction == .repairProjection {
                    Text("Repairable")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.blue.opacity(0.1), in: Capsule())
                }
            }

            if let guidance = issue.guidance {
                Text(guidance)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 24)
            }

            DisclosureGroup("Technical detail", isExpanded: $showsTechnicalDetail) {
                Text(issue.message)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 3)
            }
            .font(.caption2)
            .padding(.leading, 24)
        }
    }
}

private struct DoctorProjectGroup: Identifiable {
    let root: String?
    let categories: [DoctorCategoryGroup]

    var id: String { root ?? "__general__" }
    var name: String { root.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "General" }

    static func groups(from issues: [DoctorIssue]) -> [DoctorProjectGroup] {
        Dictionary(grouping: issues, by: { $0.projectRoot }).map { root, projectIssues in
            let categories = Dictionary(grouping: projectIssues, by: { $0.category }).map { category, issues in
                DoctorCategoryGroup(category: category, issues: issues)
            }
            .sorted { $0.title < $1.title }
            return DoctorProjectGroup(root: root, categories: categories)
        }
        .sorted { left, right in
            switch (left.root, right.root) {
            case (nil, nil): return false
            case (nil, _): return true
            case (_, nil): return false
            case let (left?, right?): return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
            }
        }
    }
}

private struct DoctorCategoryGroup: Identifiable {
    let category: DoctorIssueCategory?
    let issues: [DoctorIssue]

    var id: String { category?.rawValue ?? "general" }
    var title: String {
        switch category {
        case .project: "Project"
        case .skills: "Skills"
        case .projection: "Claude Projection"
        case nil: "General"
        }
    }
    var symbol: String {
        switch category {
        case .project: "folder"
        case .skills: "sparkles"
        case .projection: "link"
        case nil: "exclamationmark.circle"
        }
    }
}

private struct ReposSection: View {
    @ObservedObject var model: MetagentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Skill locations")
                        .font(.title3.weight(.semibold))
                    Text("\(model.repoCount) discovered locations")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.refreshStatus()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.glass)
                .help("Refresh")
                .disabled(model.isRunning)
            }

            if model.projects.isEmpty {
                EmptyStateView(
                    title: "No skill locations found",
                    message: "Refresh status after configuring roots.",
                    symbol: "folder.badge.questionmark"
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.projects) { project in
                            ProjectRow(project: project)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct UsageSection: View {
    @ObservedObject var model: MetagentModel
    @State private var filter = UsageFilter.all
    @State private var query = ""
    @State private var sortOrder = [
        KeyPathComparator(\UsageSkillRow.totalInvocations, order: .reverse)
    ]

    private var rows: [UsageSkillRow] {
        UsageSkillRow.rows(
            projects: model.projects,
            summaries: model.usageSnapshot.summaries,
            isBackfillComplete: model.usageSnapshot.isBackfillComplete
        )
        .filter { filter.includes($0) }
        .filter { query.isEmpty || $0.skillName.localizedCaseInsensitiveContains(query) }
        .sorted(using: sortOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Skill Usage")
                        .font(.title3.weight(.semibold))
                    Text(model.usageStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                TextField("Filter skills", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)

                Picker("Status", selection: $filter) {
                    ForEach(UsageFilter.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .frame(width: 170)

                Button {
                    model.refreshUsage()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.glass)
                .help("Refresh usage history")
                .disabled(model.isUsageRefreshing)
            }

            HStack(spacing: 0) {
                SummaryMetric(
                    title: "Invocations",
                    value: model.usageSnapshot.totalInvocations.formatted(),
                    detail: "every observed SKILL.md read",
                    symbol: "sparkles"
                )
                Divider().padding(.vertical, 4)
                SummaryMetric(
                    title: "Observed skills",
                    value: model.usageSnapshot.summaries.count.formatted(),
                    detail: model.usageCoverageText,
                    symbol: "list.bullet.rectangle"
                )
                Divider().padding(.vertical, 4)
                SummaryMetric(
                    title: "Backfill",
                    value: model.usageSnapshot.isBackfillComplete
                        ? "Current"
                        : model.usageProgress.formatted(.percent.precision(.fractionLength(1))),
                    detail: model.usageProgressText,
                    symbol: "clock.arrow.trianglehead.counterclockwise.rotate.90"
                )
            }
            .frame(height: 92)

            if model.isUsageRefreshing {
                ProgressView(value: model.usageProgress)
                    .progressViewStyle(.linear)
            }

            if rows.isEmpty {
                EmptyStateView(
                    title: filter.emptyTitle,
                    message: filter.emptyMessage(backfillComplete: model.usageSnapshot.isBackfillComplete),
                    symbol: "chart.bar.xaxis"
                )
            } else {
                Table(rows, sortOrder: $sortOrder) {
                    TableColumn(
                        "Skill",
                        sortUsing: KeyPathComparator(\UsageSkillRow.skillName)
                    ) { row in
                        Text(row.skillName)
                        .help(row.canonicalPath ?? row.skillName)
                    }
                    .width(min: 180, ideal: 240)

                    TableColumn(
                        "Scope",
                        sortUsing: KeyPathComparator(\UsageSkillRow.scope)
                    ) { row in
                        Image(systemName: row.scopeSymbol)
                            .foregroundStyle(.secondary)
                            .help(row.scopeLabel)
                            .accessibilityLabel(row.scopeLabel)
                    }
                    .width(min: 54, ideal: 60)

                    TableColumn(
                        "7d",
                        sortUsing: KeyPathComparator(\UsageSkillRow.invocations7d)
                    ) { row in numericCell(row.invocations7d) }
                        .width(min: 54, ideal: 64)
                    TableColumn(
                        "30d",
                        sortUsing: KeyPathComparator(\UsageSkillRow.invocations30d)
                    ) { row in numericCell(row.invocations30d) }
                        .width(min: 54, ideal: 64)
                    TableColumn(
                        "All",
                        sortUsing: KeyPathComparator(\UsageSkillRow.totalInvocations)
                    ) { row in numericCell(row.totalInvocations) }
                        .width(min: 54, ideal: 64)
                    TableColumn(
                        "Tasks",
                        sortUsing: KeyPathComparator(\UsageSkillRow.distinctThreads)
                    ) { row in
                        numericCell(row.distinctThreads)
                            .help("Distinct Codex tasks where this skill was observed")
                    }
                    .width(min: 58, ideal: 68)
                    TableColumn(
                        "Repeats",
                        sortUsing: KeyPathComparator(\UsageSkillRow.repeatInvocations)
                    ) { row in
                        numericCell(row.repeatInvocations)
                            .help("Additional reads after the first read in the same turn")
                    }
                        .width(min: 66, ideal: 76)
                    TableColumn(
                        "Last used",
                        sortUsing: KeyPathComparator(\UsageSkillRow.lastUsedSortValue)
                    ) { row in
                        RelativeUsageDateCell(date: row.lastUsedDate)
                            .foregroundStyle(row.totalInvocations == 0 ? .secondary : .primary)
                    }
                    .width(min: 100, ideal: 120)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func numericCell(_ value: Int) -> some View {
        Text(value.formatted())
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct RelativeUsageDateCell: View {
    let date: Date?

    var body: some View {
        if let date {
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                Text(date.formatted(.relative(presentation: .named, unitsStyle: .wide)))
            }
        } else {
            Text("Never")
        }
    }
}

private struct UsageMenuSection: View {
    @ObservedObject var model: MetagentModel
    let openMainWindow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Skill Usage")
                    .font(.headline)
                Spacer()
                if model.isUsageRefreshing {
                    ProgressView().controlSize(.small)
                }
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                MetricView(
                    title: "Invocations",
                    value: model.usageSnapshot.totalInvocations.formatted(),
                    symbol: "sparkles"
                )
                MetricView(
                    title: "Observed skills",
                    value: model.usageSnapshot.summaries.count.formatted(),
                    symbol: "chart.bar.xaxis"
                )
            }

            InfoRow(title: "History", value: model.usageStatusText, symbol: "clock.arrow.circlepath")
            InfoRow(title: "Coverage", value: model.usageCoverageText, symbol: "calendar")

            if model.isUsageRefreshing {
                ProgressView(value: model.usageProgress)
                Text(model.usageProgressText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button(action: openMainWindow) {
                Label("Open Usage Table", systemImage: "arrow.up.right.square")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)

            Spacer()
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private enum UsageFilter: String, CaseIterable, Identifiable {
    case all
    case observed
    case neverObserved
    case dormant
    case insufficient

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All skills"
        case .observed: "Observed"
        case .neverObserved: "Never observed"
        case .dormant: "Dormant (90d)"
        case .insufficient: "Insufficient data"
        }
    }
    var emptyTitle: String { self == .all ? "No skill usage yet" : "No matching skills" }
    func emptyMessage(backfillComplete: Bool) -> String {
        if !backfillComplete {
            return "The low-priority backfill is still building coverage."
        }
        return "No skills currently match this usage filter."
    }
    func includes(_ row: UsageSkillRow) -> Bool {
        switch self {
        case .all: true
        case .observed: row.totalInvocations > 0
        case .neverObserved: row.status == .neverObserved
        case .dormant: row.status == .dormant
        case .insufficient: row.status == .insufficient
        }
    }
}

private struct UsageSkillRow: Identifiable {
    enum Status { case active, dormant, neverObserved, insufficient }

    let id: String
    let skillName: String
    let canonicalPath: String?
    let scope: String
    let totalInvocations: Int
    let invocations7d: Int
    let invocations30d: Int
    let distinctThreads: Int
    let repeatInvocations: Int
    let lastUsedDate: Date?
    let lastUsedSortValue: TimeInterval
    let status: Status

    var scopeLabel: String {
        switch scope {
        case "project": "Project"
        case "global": "Global"
        case "plugin": "Plugin"
        case "system": "System"
        default: "Unknown"
        }
    }

    var scopeSymbol: String {
        switch scope {
        case "project": "folder"
        case "global": "globe"
        case "plugin": "puzzlepiece.extension"
        case "system": "gearshape"
        default: "questionmark.circle"
        }
    }

    static func rows(
        projects: [ProjectStatus],
        summaries: [SkillUsageSummary],
        isBackfillComplete: Bool
    ) -> [UsageSkillRow] {
        var rows = summaries.map { summary in
            from(summary: summary, isBackfillComplete: isBackfillComplete)
        }
        let summaryPaths = Set(summaries.compactMap(\.canonicalPath).map(standardizedDirectory))

        var inventoryPaths = Set<String>()
        for (project, skill) in projects.flatMap({ project in
            project.skills.map { (project, $0) }
        }) {
            let directory = standardizedDirectory(
                URL(fileURLWithPath: skill.path).deletingLastPathComponent().path
            )
            guard !summaryPaths.contains(directory), inventoryPaths.insert(directory).inserted else {
                continue
            }
            rows.append(UsageSkillRow(
                id: "inventory:\(project.root):\(skill.path)",
                skillName: skill.name,
                canonicalPath: directory,
                scope: skill.folderKind == "system"
                    ? "system"
                    : (project.root == NSHomeDirectory() ? "global" : "project"),
                totalInvocations: 0,
                invocations7d: 0,
                invocations30d: 0,
                distinctThreads: 0,
                repeatInvocations: 0,
                lastUsedDate: nil,
                lastUsedSortValue: -.infinity,
                status: isBackfillComplete ? .neverObserved : .insufficient
            ))
        }
        return rows
    }

    private static func from(
        summary: SkillUsageSummary,
        isBackfillComplete: Bool
    ) -> UsageSkillRow {
        let lastDate = MetagentCore.parseSkillUsageTimestamp(summary.lastUsedAt)
        let isDormant = lastDate.map { $0 < Date().addingTimeInterval(-90 * 24 * 60 * 60) } ?? false
        return UsageSkillRow(
            id: summary.id,
            skillName: summary.skillName,
            canonicalPath: summary.canonicalPath,
            scope: summary.scope,
            totalInvocations: summary.totalInvocations,
            invocations7d: summary.invocations7d,
            invocations30d: summary.invocations30d,
            distinctThreads: summary.distinctThreads,
            repeatInvocations: summary.repeatInvocations,
            lastUsedDate: lastDate,
            lastUsedSortValue: lastDate?.timeIntervalSinceReferenceDate ?? -.infinity,
            status: isDormant ? .dormant : .active
        )
    }

    private static func standardizedDirectory(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            return url.resolvingSymlinksInPath().standardizedFileURL.path
        }
        return url.path
    }
}

private struct InventorySection: View {
    @ObservedObject var model: MetagentModel
    @State private var selection = Set<InventorySkillRow.ID>()
    @State private var sortOrder = [KeyPathComparator(\InventorySkillRow.skillName)]
    @State private var selectedProjectRoot: String?
    @State private var pendingRemoval: InventorySkillRow?
    @SceneStorage("metagent.inventory.columns")
    private var columnCustomization = TableColumnCustomization<InventorySkillRow>()

    private var rows: [InventorySkillRow] {
        InventorySkillRow.rows(
            from: model.projects.filter { project in
                selectedProjectRoot == nil || project.root == selectedProjectRoot
            }
        )
    }

    private var sortedRows: [InventorySkillRow] {
        rows.sorted(using: sortOrder)
    }

    private var selectedRow: InventorySkillRow? {
        guard selection.count == 1, let selectedID = selection.first else { return nil }
        return rows.first { $0.id == selectedID }
    }

    private func removalButton(for row: InventorySkillRow) -> Alert.Button {
        let action = {
            selection.removeAll()
            model.uninstallSkill(projectRoot: row.projectRoot, skillName: row.skillName)
        }
        if row.isManaged {
            return .default(Text("Show Command"), action: action)
        }
        return .destructive(Text("Uninstall"), action: action)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Skill Inventory")
                        .font(.headline)
                    Text("\(rows.count) entries - \(model.locationSummaryText) - \(model.refreshPolicyText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Picker("Project", selection: $selectedProjectRoot) {
                    Text("All Projects").tag(String?.none)
                    ForEach(model.projects) { project in
                        Text(projectFilterLabel(project, projects: model.projects))
                            .help(project.root)
                            .tag(Optional(project.root))
                    }
                }
                .frame(minWidth: 150, idealWidth: 190)

                Button(role: selectedRow?.isManaged == true ? nil : .destructive) {
                    pendingRemoval = selectedRow
                } label: {
                    Label(
                        selectedRow?.isManaged == true ? "Show Command" : "Uninstall",
                        systemImage: selectedRow?.isManaged == true ? "terminal" : "trash"
                    )
                }
                .buttonStyle(.glass)
                .disabled(selectedRow?.canUninstall != true || model.isRunning)

                Button {
                    model.refreshStatus()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.glass)
                .help("Refresh")
                .disabled(model.isRunning)
            }

            if rows.isEmpty {
                EmptyStateView(
                    title: "No skills found",
                    message: "Refresh after configuring roots or adding skills.",
                    symbol: "tablecells"
                )
            } else {
                Table(
                    sortedRows,
                    selection: $selection,
                    sortOrder: $sortOrder,
                    columnCustomization: $columnCustomization
                ) {
                    TableColumnForEach(inventoryColumnSpecs) { column in
                        TableColumn(column.title, sortUsing: column.comparator) { row in
                            InventoryTableCell(
                                text: column.value(row),
                                help: column.help(row),
                                isNumeric: column.isNumeric,
                                isMonospaced: column.isMonospaced
                            )
                        }
                        .width(min: column.minWidth, ideal: column.idealWidth)
                        .customizationID(column.id)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .alert(item: $pendingRemoval) { row in
            Alert(
                title: Text("Uninstall \(row.skillName)?"),
                message: Text(row.removalMessage),
                primaryButton: removalButton(for: row),
                secondaryButton: .cancel()
            )
        }
    }
}

private struct InventoryMenuSection: View {
    @ObservedObject var model: MetagentModel
    let openMainWindow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Skill Inventory")
                    .font(.headline)
                Spacer()
                Button(action: openMainWindow) {
                    Label("Window", systemImage: "macwindow")
                }
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                MetricView(title: "Skills", value: "\(model.logicalSkillCount)", symbol: "tablecells")
                StatusPathView(title: "Locations", value: model.locationSummaryText, symbol: "folder.badge.gearshape")
            }

            InfoRow(title: "Refresh", value: model.refreshPolicyText, symbol: "arrow.clockwise")

            Button(action: openMainWindow) {
                Label("Open Inventory Table", systemImage: "arrow.up.right.square")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)

            Spacer()
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct InventorySkillRow: Identifiable {
    let project: ProjectStatus
    let skill: SkillStatus
    let variants: [SkillStatus]

    static func rows(from projects: [ProjectStatus]) -> [InventorySkillRow] {
        projects.flatMap { project in
            Dictionary(grouping: project.skills, by: \.name).values.map { variants in
                let sortedVariants = variants.sorted(by: canonicalSkillOrder)
                return InventorySkillRow(
                    project: project,
                    skill: sortedVariants[0],
                    variants: sortedVariants
                )
            }
        }
    }

    private static func canonicalSkillOrder(_ left: SkillStatus, _ right: SkillStatus) -> Bool {
        let priority = ["agents": 0, "claude": 1, "codex": 2]
        let leftPriority = priority[left.location, default: 3]
        let rightPriority = priority[right.location, default: 3]
        if leftPriority != rightPriority {
            return leftPriority < rightPriority
        }
        return left.path < right.path
    }

    var id: String {
        "\(project.root):\(skill.name)"
    }

    var skillName: String { skill.name }
    var projectName: String { project.name }
    var projectRoot: String { project.root }
    var skillPath: String { skill.path }
    var locationLabel: String {
        variants
            .map(\.locationLabel)
            .uniqued()
            .joined(separator: " + ")
    }
    var locationHelp: String {
        variants.map { "\($0.locationLabel): \($0.path)" }.joined(separator: "\n")
    }
    var originText: String { skill.tableOriginText }
    var originHelp: String { skill.sourceURL ?? skill.tableOriginText }
    var tokenEstimate: Int { skill.tokenEstimate }
    var scriptFileCount: Int { skill.scriptFileCount }
    var assetFileCount: Int { skill.assetFileCount }
    var otherFileCount: Int { skill.otherFileCount }
    var otherFolderCount: Int { skill.otherFolderCount }
    var metadataText: String { skill.hasOpenAIYaml ? "yes" : "no" }
    var iconText: String { skill.hasIconSmall || skill.hasIconLarge ? "yes" : "no" }
    var iconHelp: String {
        [skill.iconSmallPath, skill.iconLargePath]
            .compactMap { $0 }
            .joined(separator: "\n")
    }
    var canUninstall: Bool {
        variants.contains { $0.location == "agents" }
    }
    var isManaged: Bool { skill.originKind == "npx-skills" }
    var removalMessage: String {
        let ownership = isManaged
            ? "npx skills owns this package. Metagent will show the exact removal command without changing files."
            : "Metagent will move the canonical .agents bundle and its per-skill projection links into Removed Skills recovery."
        let retained = variants.contains { $0.location != "agents" && !$0.symlinkedContainer }
            ? " Independent same-name legacy locations will be retained for separate review."
            : ""
        return "Project: \(project.root)\n\n\(ownership)\(retained)"
    }
}

private struct InventoryColumnSpec: Identifiable {
    let id: String
    let title: String
    let comparator: KeyPathComparator<InventorySkillRow>
    let minWidth: CGFloat
    let idealWidth: CGFloat
    let isNumeric: Bool
    let isMonospaced: Bool
    let value: (InventorySkillRow) -> String
    let help: (InventorySkillRow) -> String
}

@MainActor private let inventoryColumnSpecs: [InventoryColumnSpec] = [
    InventoryColumnSpec(
        id: "skill",
        title: "Skill",
        comparator: KeyPathComparator(\InventorySkillRow.skillName),
        minWidth: 160,
        idealWidth: 220,
        isNumeric: false,
        isMonospaced: false,
        value: \.skillName,
        help: \.skillPath
    ),
    InventoryColumnSpec(
        id: "project",
        title: "Project",
        comparator: KeyPathComparator(\InventorySkillRow.projectName),
        minWidth: 120,
        idealWidth: 160,
        isNumeric: false,
        isMonospaced: false,
        value: \.projectName,
        help: \.projectRoot
    ),
    InventoryColumnSpec(
        id: "location",
        title: "Location",
        comparator: KeyPathComparator(\InventorySkillRow.locationLabel),
        minWidth: 80,
        idealWidth: 96,
        isNumeric: false,
        isMonospaced: false,
        value: \.locationLabel,
        help: \.locationHelp
    ),
    InventoryColumnSpec(
        id: "origin",
        title: "Origin",
        comparator: KeyPathComparator(\InventorySkillRow.originText),
        minWidth: 120,
        idealWidth: 170,
        isNumeric: false,
        isMonospaced: false,
        value: \.originText,
        help: \.originHelp
    ),
    InventoryColumnSpec(
        id: "tokens",
        title: "Tokens",
        comparator: KeyPathComparator(\InventorySkillRow.tokenEstimate),
        minWidth: 76,
        idealWidth: 92,
        isNumeric: true,
        isMonospaced: false,
        value: { formatNumber($0.tokenEstimate) },
        help: { formatNumber($0.tokenEstimate) }
    ),
    InventoryColumnSpec(
        id: "scripts",
        title: "Scripts",
        comparator: KeyPathComparator(\InventorySkillRow.scriptFileCount),
        minWidth: 62,
        idealWidth: 74,
        isNumeric: true,
        isMonospaced: false,
        value: { formatNumber($0.scriptFileCount) },
        help: { formatNumber($0.scriptFileCount) }
    ),
    InventoryColumnSpec(
        id: "assets",
        title: "Assets",
        comparator: KeyPathComparator(\InventorySkillRow.assetFileCount),
        minWidth: 60,
        idealWidth: 72,
        isNumeric: true,
        isMonospaced: false,
        value: { formatNumber($0.assetFileCount) },
        help: { formatNumber($0.assetFileCount) }
    ),
    InventoryColumnSpec(
        id: "other-files",
        title: "Other files",
        comparator: KeyPathComparator(\InventorySkillRow.otherFileCount),
        minWidth: 72,
        idealWidth: 88,
        isNumeric: true,
        isMonospaced: false,
        value: { formatNumber($0.otherFileCount) },
        help: { formatNumber($0.otherFileCount) }
    ),
    InventoryColumnSpec(
        id: "other-folders",
        title: "Other folders",
        comparator: KeyPathComparator(\InventorySkillRow.otherFolderCount),
        minWidth: 86,
        idealWidth: 104,
        isNumeric: true,
        isMonospaced: false,
        value: { formatNumber($0.otherFolderCount) },
        help: { formatNumber($0.otherFolderCount) }
    ),
    InventoryColumnSpec(
        id: "metadata",
        title: "Metadata",
        comparator: KeyPathComparator(\InventorySkillRow.metadataText),
        minWidth: 72,
        idealWidth: 82,
        isNumeric: false,
        isMonospaced: false,
        value: \.metadataText,
        help: { $0.skill.hasOpenAIYaml ? "agents/openai.yaml configured" : "No agents/openai.yaml" }
    ),
    InventoryColumnSpec(
        id: "icon",
        title: "Icon",
        comparator: KeyPathComparator(\InventorySkillRow.iconText),
        minWidth: 52,
        idealWidth: 62,
        isNumeric: false,
        isMonospaced: false,
        value: \.iconText,
        help: \.iconHelp
    ),
    InventoryColumnSpec(
        id: "path",
        title: "Path",
        comparator: KeyPathComparator(\InventorySkillRow.skillPath),
        minWidth: 260,
        idealWidth: 420,
        isNumeric: false,
        isMonospaced: true,
        value: \.skillPath,
        help: \.skillPath
    )
]

private struct InventoryTableCell: View {
    let text: String
    let help: String
    let isNumeric: Bool
    let isMonospaced: Bool

    var body: some View {
        Text(text)
            .font(isMonospaced ? .caption.monospaced() : .body)
            .lineLimit(1)
            .truncationMode(.middle)
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: isNumeric ? .trailing : .leading)
            .help(help.isEmpty ? text : help)
    }
}

private func formatNumber(_ value: Int) -> String {
    value.formatted()
}

private func projectFilterLabel(_ project: ProjectStatus, projects: [ProjectStatus]) -> String {
    guard projects.filter({ $0.name == project.name }).count > 1 else {
        return project.name
    }
    let parent = URL(fileURLWithPath: project.root).deletingLastPathComponent().lastPathComponent
    return "\(project.name) — \(parent)"
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

private struct RepairSection: View {
    @ObservedObject var model: MetagentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Repair skill links")
                        .font(.title3.weight(.semibold))
                    Text("Keep .agents/skills canonical and point each project's .claude/skills at it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        Button {
                            model.previewRepair()
                        } label: {
                            Label("Preview", systemImage: "doc.text.magnifyingglass")
                        }
                        .buttonStyle(.glass)

                        Button {
                            model.repairNow()
                        } label: {
                            Label("Apply Repair", systemImage: "checkmark.circle")
                        }
                        .buttonStyle(.glassProminent)
                    }
                    .controlSize(.large)
                    .disabled(model.isRunning)
                }
            }

            Label(
                "Preview is read-only. Apply only creates or replaces project .claude/skills symlinks; real directories are left for review.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if let repairPreview = model.repairPreview {
                RepairPreviewView(
                    preview: repairPreview,
                    showsRawOutput: model.showsRawOutput,
                    rawLines: model.lastOutputLines,
                    onApply: model.repairNow,
                    onCopySummary: model.copyRepairSummary,
                    onCopyRawOutput: model.copyLastOutput,
                    onToggleRawOutput: model.toggleRawOutput,
                    onOpenProject: model.openProject
                )
            } else if let title = model.lastOutputTitle {
                LastOutputView(
                    title: title,
                    lines: model.lastOutputLines,
                    onCopy: model.copyLastOutput
                )
            } else {
                QuietPrompt(
                    title: "Start with Preview",
                    message: "You’ll see every planned project change here before anything is written.",
                    symbol: "doc.text.magnifyingglass"
                )
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct ToolsSection: View {
    @ObservedObject var model: MetagentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Tools")
                    .font(.title3.weight(.semibold))
                Text("Diagnostics and lower-frequency maintenance live here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                ToolButton(title: "Doctor", symbol: "stethoscope", action: model.runDoctor)
                ToolButton(title: "Morph Status", symbol: "waveform.path.ecg", action: model.runMorphStatus)
                ToolButton(title: "Refresh", symbol: "arrow.clockwise", action: model.refreshStatus)
            }
            .disabled(model.isRunning)

            HStack(spacing: 8) {
                Button {
                    model.openConfig()
                } label: {
                    Label("Config", systemImage: "gearshape")
                }
                .buttonStyle(.glass)

                Button {
                    model.openLogs()
                } label: {
                    Label("Logs", systemImage: "doc.text")
                }
                .buttonStyle(.glass)

                Button {
                    model.restartMenuBar()
                } label: {
                    Label("Restart App", systemImage: "arrow.clockwise.circle")
                }
                .buttonStyle(.glass)
                .disabled(model.isRunning)
            }

            if let title = model.lastOutputTitle {
                LastOutputView(
                    title: title,
                    lines: model.lastOutputLines,
                    onCopy: model.copyLastOutput
                )
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct ProjectRow: View {
    let project: ProjectStatus
    @State private var showsSkills = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.callout.weight(.semibold))
                    Text(project.root)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Badge(text: "\(project.skillCount)", symbol: "sparkles", tint: .blue)

            }

            HStack(spacing: 6) {
                if project.agentsSkillCount > 0 {
                    Badge(text: ".agents \(project.agentsSkillCount)", symbol: "sparkles", tint: .blue)
                }
                if project.codexSkillCount > 0 {
                    Badge(text: ".codex \(project.codexSkillCount)", symbol: "chevron.left.forwardslash.chevron.right", tint: .purple)
                }
                if project.claudeSkillCount > 0 {
                    Badge(text: ".claude \(project.claudeSkillCount)", symbol: "link", tint: .orange)
                }
            }

            if !project.skills.isEmpty {
                DisclosureGroup(isExpanded: $showsSkills) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(project.skills) { skill in
                            SkillRow(skill: skill)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text(showsSkills ? "Hide skills" : "Show skills")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.055), lineWidth: 1)
        }
    }
}

private struct SkillRow: View {
    let skill: SkillStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(skill.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)

                Spacer(minLength: 8)

                Badge(text: skill.locationLabel, symbol: skill.locationSymbol, tint: locationTint)

                if let originText = skill.originText {
                    Badge(text: originText, symbol: originSymbol, tint: originTint)
                }

                if skill.symlinkedContainer {
                    Badge(text: "symlink", symbol: "link", tint: .secondary)
                }
            }

            Text(skill.path)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(10)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var locationTint: Color {
        switch skill.location {
        case "agents": .blue
        case "codex": .purple
        case "claude": .orange
        default: .secondary
        }
    }

    private var originTint: Color {
        skill.originKind == "npx-skills" ? .green : .secondary
    }

    private var originSymbol: String {
        skill.originKind == "npx-skills" ? "arrow.down.circle" : "hammer"
    }
}

private struct ToolButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.1), in: Circle())
                Text(title)
                    .font(.callout.weight(.medium))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
        }
        .buttonStyle(.glass)
    }
}

private struct QuietPrompt: View {
    let title: String
    let message: String
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 4)
    }
}

private struct InfoRow: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(Color.accentColor)
                .frame(width: 16)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct EmptyStateView: View {
    let title: String
    let message: String
    let symbol: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.callout.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}

private struct RepairPreviewView: View {
    let preview: RepairPreview
    let showsRawOutput: Bool
    let rawLines: [String]
    let onApply: () -> Void
    let onCopySummary: () -> Void
    let onCopyRawOutput: () -> Void
    let onToggleRawOutput: () -> Void
    let onOpenProject: (RepairProjectPreview) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preview.title)
                        .font(.headline)
                    Text(preview.summaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                if preview.summary.warningCount == 0 {
                    Badge(text: "Ready", symbol: "checkmark.circle", tint: .green)
                } else {
                    Badge(text: "\(preview.summary.warningCount) warn", symbol: "exclamationmark.triangle", tint: .orange)
                }
            }

            HStack(spacing: 8) {
                MetricView(title: "Projects", value: "\(preview.summary.projectCount)", symbol: "folder")
                MetricView(title: "Actions", value: "\(preview.summary.actionCount)", symbol: "list.bullet.rectangle")
                MetricView(title: "Skills", value: "\(preview.summary.validSkillCount)", symbol: "sparkles")
            }

            HStack(spacing: 8) {
                Button {
                    onApply()
                } label: {
                    Label("Apply Repair", systemImage: "checkmark.circle")
                }
                .buttonStyle(.glassProminent)

                Button {
                    onCopySummary()
                } label: {
                    Label("Copy Summary", systemImage: "doc.on.doc")
                }
                .buttonStyle(.glass)

                Button {
                    onToggleRawOutput()
                } label: {
                    Label(showsRawOutput ? "Hide Raw" : "Show Raw", systemImage: "terminal")
                }
                .buttonStyle(.glass)

                if showsRawOutput {
                    Button {
                        onCopyRawOutput()
                    } label: {
                        Label("Copy Raw", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.glass)
                }
            }
            .font(.callout)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(preview.projects) { project in
                        RepairProjectView(project: project) {
                            onOpenProject(project)
                        }
                    }

                    if showsRawOutput {
                        RawOutputBlock(title: "Raw Output", lines: rawLines)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct RepairProjectView: View {
    let project: RepairProjectPreview
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.displayName)
                        .font(.callout.weight(.semibold))
                    Text(project.root)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Button {
                    onOpen()
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.glass)
                .help("Open Project")
            }

            HStack(spacing: 6) {
                Badge(text: "\(project.validSkillCount) skills", symbol: "sparkles", tint: .blue)
                if project.actionCount > 0 {
                    Badge(text: "\(project.actionCount) actions", symbol: "list.bullet", tint: .green)
                }
                if project.warningCount > 0 {
                    Badge(text: "\(project.warningCount) warn", symbol: "exclamationmark.triangle", tint: .orange)
                }
                if project.skippedCount > 0 {
                    Badge(text: "\(project.skippedCount) skipped", symbol: "minus.circle", tint: .secondary)
                }
            }

            LineGroup(lines: project.warnings, tint: .orange)
            LineGroup(lines: project.actions, tint: .green)
            LineGroup(lines: project.skipped, tint: .secondary)
            LineGroup(lines: project.info, tint: .secondary)
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.055), lineWidth: 1)
        }
    }
}

private struct LineGroup: View {
    let lines: [RepairLinePreview]
    let tint: Color

    var body: some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle()
                            .fill(tint)
                            .frame(width: 5, height: 5)
                        Text(line.text)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                    }
                }
            }
        }
    }
}

private struct LastOutputView: View {
    let title: String
    let lines: [String]
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Button {
                    onCopy()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.glass)
            }

            RawOutputBlock(title: nil, lines: Array(lines.prefix(18)))
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct RawOutputBlock: View {
    let title: String?
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

private struct MetricView: View {
    let title: String
    let value: String
    let symbol: String
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct StatusPathView: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .foregroundStyle(Color.accentColor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct Badge: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(text)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(tint.opacity(0.12), in: Capsule())
    }
}
