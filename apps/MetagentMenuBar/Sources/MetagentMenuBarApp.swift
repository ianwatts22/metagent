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
        .buttonBorderShape(.capsule)
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

            HStack(spacing: 10) {
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

                Menu {
                    Button("Open Config", systemImage: "gearshape") {
                        model.openConfig()
                    }
                    Button("Open Logs", systemImage: "doc.text") {
                        model.openLogs()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .buttonStyle(.glass)
                .help("More")
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
        case .skills:
            if showsOpenWindowButton {
                SkillsMenuSection(model: model) {
                    openWindow(id: "main")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
            } else {
                InventorySection(model: model)
            }
        case .usage:
            if showsOpenWindowButton {
                UsageMenuSection(model: model) {
                    openWindow(id: "main")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
            } else {
                UsageSection(model: model)
            }
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
        Color(nsColor: .windowBackgroundColor)
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
    case skills
    case usage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .skills: "Skills"
        case .usage: "Usage"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge"
        case .skills: "sparkles"
        case .usage: "chart.bar.xaxis"
        }
    }
}

private struct OverviewSection: View {
    @ObservedObject var model: MetagentModel
    @State private var showsDoctorFindings = false
    @State private var showsRepair = false

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
            DoctorFindingsView(model: model) {
                model.previewRepair()
                showsRepair = true
            }
        }
        .sheet(isPresented: $showsRepair) {
            RepairSection(model: model)
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
                    if model.problemCount > 0 {
                        Button {
                            showsDoctorFindings = true
                        } label: {
                            Label("Review", systemImage: "stethoscope")
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(model.isRunning)
                    }

                    if model.doctorRepairableCount > 0 {
                        Button {
                            model.previewRepair()
                            showsRepair = true
                        } label: {
                            Label("Preview fixes", systemImage: "doc.text.magnifyingglass")
                        }
                        .buttonStyle(.glass)
                        .disabled(model.isRunning)
                    }

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
                detail: "across \(model.repoCount) projects",
                symbol: "sparkles"
            )
            Divider()
                .padding(.vertical, 4)
            SummaryMetric(
                title: "30-day reads",
                value: "\(recentInvocationCount)",
                detail: "in the last 30 days",
                symbol: "clock.arrow.circlepath"
            )
            Divider()
                .padding(.vertical, 4)
            SummaryMetric(
                title: "Health",
                value: model.problemCount == 0 ? "No issues" : model.problemText,
                detail: model.problemCount == 0 ? "No action needed" : "Review findings",
                symbol: "stethoscope"
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

    private var recentInvocationCount: Int {
        model.usageSnapshot.summaries.reduce(0) { $0 + $1.invocations30d }
    }

    private var healthMessage: String {
        if model.problemCount == 0 {
            return "No action is needed. Metagent is ready when you are."
        }
        if model.doctorReviewCount == 0 {
            return "\(model.doctorRepairableCount) can be fixed automatically."
        }
        return "\(model.doctorRepairableCount) fixable · \(model.doctorReviewCount) need review"
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
    let onPreviewRepair: () -> Void
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
                        "\(model.doctorRepairableCount) fixable",
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
                        onPreviewRepair()
                        dismiss()
                    } label: {
                        Label("Preview fixes", systemImage: "doc.text.magnifyingglass")
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
            return "\(model.doctorRepairableCount) finding(s) can be fixed automatically."
        }
        return "\(model.doctorRepairableCount) fixable, \(model.doctorReviewCount) to review."
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
                    Text("Fixable")
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

private struct UsageSection: View {
    @ObservedObject var model: MetagentModel
    @State private var selection = Set<UsageSkillRow.ID>()
    @State private var pendingRemoval: InventoryRemovalConfirmation?
    @State private var filter = UsageFilter.all
    @State private var query = ""
    @State private var sortOrder = [
        KeyPathComparator(\UsageSkillRow.totalInvocations, order: .reverse)
    ]
    @SceneStorage("metagent.usage.columns.v1")
    private var columnCustomization = TableColumnCustomization<UsageSkillRow>()

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

    private var inventoryRows: [InventorySkillRow] {
        InventorySkillRow.rows(
            from: model.projects,
            usage: model.usageSnapshot,
            evaluations: model.skillEvaluations
        )
    }

    private func rows(for contextSelection: Set<UsageSkillRow.ID>) -> [UsageSkillRow] {
        let ids = contextSelection.isEmpty ? selection : contextSelection
        return rows.filter { ids.contains($0.id) }
    }

    private func inventoryRows(for usageRows: [UsageSkillRow]) -> [InventorySkillRow] {
        let paths = Set(usageRows.compactMap(\.canonicalPath).map(standardizedDirectoryPath))
        let pluginKeys = Set(usageRows.compactMap {
            pluginUsageMatchKey(id: $0.id, canonicalPath: $0.canonicalPath)
        })
        return inventoryRows.filter { row in
            paths.contains(standardizedDirectoryPath(row.canonicalPath))
                || pluginUsageMatchKey(row.skill).map(pluginKeys.contains) == true
        }
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
                Table(
                    rows,
                    selection: $selection,
                    sortOrder: $sortOrder,
                    columnCustomization: $columnCustomization
                ) {
                    TableColumn(
                        "Skill",
                        sortUsing: KeyPathComparator(\UsageSkillRow.skillName)
                    ) { row in
                        Text(row.skillName)
                            .fontWeight(.medium)
                            .help(row.canonicalPath ?? row.skillName)
                    }
                    .width(min: 180, ideal: 240)
                    .customizationID("skill")
                    .defaultVisibility(.visible)

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
                    .customizationID("scope")
                    .defaultVisibility(.visible)

                    TableColumn(
                        "7d",
                        sortUsing: KeyPathComparator(\UsageSkillRow.invocations7d)
                    ) { row in numericCell(row.invocations7d) }
                        .width(min: 54, ideal: 64)
                        .customizationID("7d")
                        .defaultVisibility(.visible)
                    TableColumn(
                        "30d",
                        sortUsing: KeyPathComparator(\UsageSkillRow.invocations30d)
                    ) { row in numericCell(row.invocations30d) }
                        .width(min: 54, ideal: 64)
                        .customizationID("30d")
                        .defaultVisibility(.visible)
                    TableColumn(
                        "All",
                        sortUsing: KeyPathComparator(\UsageSkillRow.totalInvocations)
                    ) { row in numericCell(row.totalInvocations) }
                        .width(min: 54, ideal: 64)
                        .customizationID("all")
                        .defaultVisibility(.visible)
                    TableColumn(
                        "Tasks",
                        sortUsing: KeyPathComparator(\UsageSkillRow.distinctThreads)
                    ) { row in
                        numericCell(row.distinctThreads)
                            .help("Distinct Codex tasks where this skill was observed")
                    }
                    .width(min: 58, ideal: 68)
                    .customizationID("tasks")
                    .defaultVisibility(.hidden)
                    TableColumn(
                        "Repeats",
                        sortUsing: KeyPathComparator(\UsageSkillRow.repeatInvocations)
                    ) { row in
                        numericCell(row.repeatInvocations)
                            .help("Additional reads after the first read in the same turn")
                    }
                        .width(min: 66, ideal: 76)
                        .customizationID("repeats")
                        .defaultVisibility(.hidden)
                    TableColumn(
                        "Last used",
                        sortUsing: KeyPathComparator(\UsageSkillRow.lastUsedSortValue)
                    ) { row in
                        RelativeUsageDateCell(date: row.lastUsedDate)
                            .foregroundStyle(row.totalInvocations == 0 ? .secondary : .primary)
                    }
                    .width(min: 100, ideal: 120)
                    .customizationID("last-used")
                    .defaultVisibility(.visible)
                }
                .tableStyle(.inset)
                .alternatingRowBackgrounds(.enabled)
                .contextMenu(forSelectionType: UsageSkillRow.ID.self) { contextSelection in
                    let usageRows = rows(for: contextSelection)
                    let paths = usageRows.compactMap(\.canonicalPath)
                    let removableRows = inventoryRows(for: usageRows).filter { $0.removalRequest != nil }
                    Button("Copy Path", systemImage: "doc.on.doc") {
                        copyToPasteboard(paths.uniqued().joined(separator: "\n"))
                    }
                    .disabled(paths.isEmpty)
                    Button("Copy to Improve", systemImage: "wand.and.sparkles") {
                        copyToPasteboard(improvementPrompt(paths: paths))
                    }
                    .disabled(paths.isEmpty)
                    Divider()
                    Button(
                        removableRows.count > 1 ? "Remove \(removableRows.count) Items…" : "Remove…",
                        systemImage: "trash",
                        role: .destructive
                    ) {
                        pendingRemoval = InventoryRemovalConfirmation(rows: removableRows)
                    }
                    .disabled(removableRows.isEmpty || model.isRunning)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .alert(item: $pendingRemoval) { confirmation in
            let requests = confirmation.rows.compactMap(\.removalRequest)
            let names = confirmation.rows.prefix(6).map(\.skillName).joined(separator: ", ")
            let suffix = confirmation.rows.count > 6 ? ", …" : ""
            return Alert(
                title: Text(requests.count == 1 ? "Remove selected skill?" : "Remove \(requests.count) selected items?"),
                message: Text("\(names)\(suffix)\n\n\(skillRemovalMessage(for: confirmation.rows))"),
                primaryButton: .destructive(Text(requests.count == 1 ? "Approve Removal" : "Approve \(requests.count) Removals")) {
                    selection.removeAll()
                    model.uninstallSkills(requests)
                },
                secondaryButton: .cancel()
            )
        }
    }

    @ViewBuilder
    private func numericCell(_ value: Int) -> some View {
        Text(value.formatted())
            .font(.callout)
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
        let summaryPluginKeys = Set(summaries.compactMap {
            pluginUsageMatchKey(id: $0.id, canonicalPath: $0.canonicalPath)
        })

        var inventoryPaths = Set<String>()
        for (project, skill) in projects.flatMap({ project in
            project.skills.map { (project, $0) }
        }) {
            let directory = standardizedDirectory(skill.path)
            let pluginAlreadyRepresented = pluginUsageMatchKey(skill).map(summaryPluginKeys.contains) ?? false
            guard !summaryPaths.contains(directory),
                  !pluginAlreadyRepresented,
                  inventoryPaths.insert(directory).inserted
            else {
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

private struct InventoryRemovalConfirmation: Identifiable {
    let id = UUID()
    let rows: [InventorySkillRow]
}

private struct InventorySection: View {
    @ObservedObject var model: MetagentModel
    @State private var selection = Set<InventorySkillRow.ID>()
    @State private var sortOrder = [KeyPathComparator(\InventorySkillRow.skillName)]
    @State private var selectedProjectRoot: String?
    @State private var query = ""
    @State private var pendingRemoval: InventoryRemovalConfirmation?
    @State private var pendingCodexReview: InventorySkillRow?
    @SceneStorage("metagent.inventory.columns.v3")
    private var columnCustomization = TableColumnCustomization<InventorySkillRow>()

    private var rows: [InventorySkillRow] {
        let searchQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return InventorySkillRow.rows(
            from: model.projects,
            usage: model.usageSnapshot,
            evaluations: model.skillEvaluations
        )
        .filter { selectedProjectRoot == nil || $0.projectRoot == selectedProjectRoot }
        .filter { searchQuery.isEmpty || $0.matches(searchQuery) }
    }

    private var sortedRows: [InventorySkillRow] {
        rows.sorted(using: sortOrder)
    }

    private var selectedRow: InventorySkillRow? {
        guard selection.count == 1, let selectedID = selection.first else { return nil }
        return rows.first { $0.id == selectedID }
    }

    private var selectedRows: [InventorySkillRow] {
        rows.filter { selection.contains($0.id) }
    }

    private var selectedRemovalRows: [InventorySkillRow] {
        selectedRows.filter { $0.removalRequest != nil }
    }

    private var hasActiveFilter: Bool {
        selectedProjectRoot != nil || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func rows(for contextSelection: Set<InventorySkillRow.ID>) -> [InventorySkillRow] {
        let ids = contextSelection.isEmpty ? selection : contextSelection
        return rows.filter { ids.contains($0.id) }
    }

    private func copyPaths(_ rows: [InventorySkillRow]) {
        copyToPasteboard(rows.map(\.canonicalPath).uniqued().joined(separator: "\n"))
    }

    private func copyToImprove(_ rows: [InventorySkillRow]) {
        copyToPasteboard(improvementPrompt(paths: rows.map(\.canonicalPath)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Skills")
                        .font(.headline)
                    Text(selectedRows.isEmpty
                        ? "\(rows.count) visible skills"
                        : "\(selectedRows.count) selected · \(rows.count) visible")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                TextField("Filter skills", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)

                Picker("Project", selection: $selectedProjectRoot) {
                    Text("All Projects").tag(String?.none)
                    ForEach(model.projects) { project in
                        Text(projectFilterLabel(project, projects: model.projects))
                            .help(project.root)
                            .tag(Optional(project.root))
                    }
                }
                .frame(minWidth: 150, idealWidth: 190)

                Menu {
                    Button("Run Plugin Eval") {
                        if let selectedRow {
                            model.evaluateSkillWithPluginEval(path: selectedRow.canonicalPath)
                        }
                    }
                    .disabled(selectedRow == nil)
                    Button("Review with Codex") {
                        if let selectedRow {
                            pendingCodexReview = selectedRow
                        }
                    }
                    .disabled(selectedRow == nil)
                    Divider()
                    Button("Run Plugin Eval for Visible Skills") {
                        model.evaluateSkillsWithPluginEval(paths: rows.map(\.canonicalPath))
                    }
                } label: {
                    Label("Evaluate", systemImage: "checkmark.seal")
                }
                .buttonStyle(.glass)
                .disabled(rows.isEmpty || model.isSkillEvaluating)

                Button(role: .destructive) {
                    pendingRemoval = InventoryRemovalConfirmation(rows: selectedRemovalRows)
                } label: {
                    Label(
                        selectedRemovalRows.count > 1 ? "Remove \(selectedRemovalRows.count)" : "Remove",
                        systemImage: "trash"
                    )
                }
                .buttonStyle(.glass)
                .disabled(selectedRemovalRows.isEmpty || model.isRunning)

                Button {
                    model.refreshStatus()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.glass)
                .help("Refresh")
                .disabled(model.isRunning)
            }

            if let evaluationStatus = model.skillEvaluationStatusText {
                HStack(spacing: 6) {
                    if model.isSkillEvaluating {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(evaluationStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if rows.isEmpty {
                EmptyStateView(
                    title: hasActiveFilter ? "No matching skills" : "No skills found",
                    message: hasActiveFilter
                        ? "Clear the search or choose All Projects."
                        : "Refresh after configuring roots or adding skills.",
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
                                isMonospaced: column.isMonospaced,
                                isPrimary: column.isPrimary,
                                showsBadge: column.showsBadge,
                                symbol: column.symbol?(row),
                                tint: column.tint?(row)
                            )
                        }
                        .width(min: column.minWidth, ideal: column.idealWidth)
                        .customizationID(column.id)
                        .defaultVisibility(column.defaultVisibility)
                    }
                }
                .tableStyle(.inset)
                .alternatingRowBackgrounds(.enabled)
                .contextMenu(forSelectionType: InventorySkillRow.ID.self) { contextSelection in
                    let contextRows = rows(for: contextSelection)
                    let removableRows = contextRows.filter { $0.removalRequest != nil }
                    Button("Copy Path", systemImage: "doc.on.doc") {
                        copyPaths(contextRows)
                    }
                    .disabled(contextRows.isEmpty)
                    Button("Copy to Improve", systemImage: "wand.and.sparkles") {
                        copyToImprove(contextRows)
                    }
                    .disabled(contextRows.isEmpty)
                    Divider()
                    Button(
                        removableRows.count > 1 ? "Remove \(removableRows.count) Items…" : "Remove…",
                        systemImage: "trash",
                        role: .destructive
                    ) {
                        pendingRemoval = InventoryRemovalConfirmation(rows: removableRows)
                    }
                    .disabled(removableRows.isEmpty || model.isRunning)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .alert(item: $pendingRemoval) { confirmation in
            let requests = confirmation.rows.compactMap(\.removalRequest)
            let names = confirmation.rows.prefix(6).map(\.skillName).joined(separator: ", ")
            let suffix = confirmation.rows.count > 6 ? ", …" : ""
            return Alert(
                title: Text(requests.count == 1 ? "Remove selected skill?" : "Remove \(requests.count) selected items?"),
                message: Text("\(names)\(suffix)\n\n\(skillRemovalMessage(for: confirmation.rows))"),
                primaryButton: .destructive(Text(requests.count == 1 ? "Approve Removal" : "Approve \(requests.count) Removals")) {
                    selection.removeAll()
                    model.uninstallSkills(requests)
                },
                secondaryButton: .cancel()
            )
        }
        .alert(item: $pendingCodexReview) { row in
            Alert(
                title: Text("Review \(row.skillName) with Codex?"),
                message: Text("Metagent will copy this skill into an isolated temporary directory, disable Codex tools and user configuration, and send the copied contents to OpenAI for an ephemeral review. The skill and other local files cannot be edited or read by the review."),
                primaryButton: .default(Text("Run Review")) {
                    model.reviewSkillWithCodex(path: row.canonicalPath)
                },
                secondaryButton: .cancel()
            )
        }
    }
}

private struct SkillsMenuSection: View {
    @ObservedObject var model: MetagentModel
    let openMainWindow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Skills")
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

            Button(action: openMainWindow) {
                Label("Open Skills", systemImage: "arrow.up.right.square")
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
    let metagentScore: MetagentSkillScore
    let pluginEval: PluginEvalSkillAssessment?
    let codexReview: CodexSkillReview?

    static func rows(
        from projects: [ProjectStatus],
        usage: SkillUsageSnapshot,
        evaluations: SkillEvaluationSnapshot
    ) -> [InventorySkillRow] {
        let usageByPath = Dictionary(grouping: usage.summaries.compactMap { summary -> (String, SkillUsageSummary)? in
            guard let canonicalPath = summary.canonicalPath else { return nil }
            return (standardizedDirectory(canonicalPath), summary)
        }, by: \.0).compactMapValues { values in
            values.map(\.1).max { $0.totalInvocations < $1.totalInvocations }
        }
        let usageByIdentity = Dictionary(grouping: usage.summaries, by: {
            "\($0.skillName):\($0.scope)"
        }).compactMapValues { values in
            values.max { $0.totalInvocations < $1.totalInvocations }
        }
        let pluginUsageByKey = Dictionary(grouping: usage.summaries.compactMap { summary in
            pluginUsageMatchKey(id: summary.id, canonicalPath: summary.canonicalPath).map { ($0, summary) }
        }, by: \.0).compactMapValues { values in
            values.map(\.1).max { $0.totalInvocations < $1.totalInvocations }
        }
        let evaluationsByPath = Dictionary(evaluations.records.values.map {
            (standardizedDirectory($0.canonicalPath), $0)
        }, uniquingKeysWith: { first, _ in first })
        let portfolioVariantsByName = Dictionary(grouping: projects.flatMap(\.skills), by: \.name)
        return projects.flatMap { project in
            Dictionary(grouping: project.skills, by: \.name).values.map { variants in
                let sortedVariants = variants.sorted(by: canonicalSkillOrder)
                let skill = sortedVariants[0]
                let canonicalPath = standardizedDirectory(skill.canonicalPath)
                let matchedUsage = usageByPath[canonicalPath]
                    ?? pluginUsageMatchKey(skill).flatMap { pluginUsageByKey[$0] }
                    ?? (skill.canonicalPath.isEmpty ? usageByIdentity["\(skill.name):\(skill.scope)"] : nil)
                return InventorySkillRow(
                    project: project,
                    skill: skill,
                    variants: sortedVariants,
                    metagentScore: MetagentCore.scoreSkill(
                        skill.coreSkill,
                        variants: (portfolioVariantsByName[skill.name] ?? sortedVariants).map(\.coreSkill),
                        usage: matchedUsage,
                        usageCoverageComplete: usage.isBackfillComplete
                    ),
                    pluginEval: evaluationsByPath[canonicalPath]?.pluginEval,
                    codexReview: evaluationsByPath[canonicalPath]?.codexReview
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
    var canonicalPath: String { skill.canonicalPath }
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
    var originHelp: String {
        [
            skill.tableOriginText,
            "Manager: \(skill.manager)",
            "Authority: \(skill.authority)",
            skill.source.map { "Source: \($0)" },
            skill.sourceType.map { "Evidence: \($0)" },
            skill.sourceURL
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
    }
    var sourceSymbol: String {
        switch skill.manager {
        case "codex-plugin": "powerplug.fill"
        case "skills-cli": "globe"
        case "codex": "sparkles"
        case "claude": "link"
        case "dotagents": "arrow.triangle.branch"
        case "git": "shippingbox"
        default: "person.crop.circle"
        }
    }
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
    var metagentScoreText: String { "\(metagentScore.score) \(metagentScore.grade.rawValue)" }
    var metagentScoreTint: Color { scoreTint(metagentScore.grade) }
    var metagentScoreHelp: String {
        let breakdown = metagentScore.components.map {
            "\($0.label): \($0.score)/\($0.maximum) — \($0.explanation)"
        }.joined(separator: "\n")
        return "Metagent Score v\(metagentScore.version) · \(metagentScore.confidence.rawValue) confidence\nAbsolute grades: A 90+, B 80+, C 70+, D 60+, F below 60.\n\(breakdown)"
    }
    var pluginEvalText: String {
        guard let pluginEval else { return "—" }
        return "\(pluginEval.score) \(pluginEval.grade)"
    }
    var pluginEvalSortValue: Int { pluginEval?.score ?? -1 }
    var pluginEvalTint: Color? {
        pluginEval.flatMap { SkillGrade(rawValue: $0.grade.uppercased()) }.map(scoreTint)
    }
    var pluginEvalHelp: String {
        guard let pluginEval else { return "Not evaluated. Use Evaluate → Run Plugin Eval." }
        return "Plugin Eval \(pluginEval.toolVersion) · \(pluginEval.riskLevel) risk\nThe letter is emitted by Plugin Eval using its stricter absolute bands: A 93+, B 85+, C 70+, D 55+. It is not relative.\n\(pluginEval.riskReasons.joined(separator: "\n"))"
    }
    var codexReviewText: String {
        guard let codexReview else { return "—" }
        return "\(codexReview.score) \(codexReview.grade.rawValue)"
    }
    var codexReviewSortValue: Int { codexReview?.score ?? -1 }
    var codexReviewTint: Color? { codexReview.map { scoreTint($0.grade) } }
    var codexReviewHelp: String {
        guard let codexReview else { return "Not reviewed. Use Evaluate → Review with Codex." }
        return "Absolute grades: A 90+, B 80+, C 70+, D 60+, F below 60.\n\(codexReview.summary)\nNext: \(codexReview.recommendation)"
    }
    var agentsVariant: SkillStatus? {
        variants.first { $0.location == "agents" }
    }
    var removalRequest: SkillRemovalRequest? {
        if let agentsVariant,
           agentsVariant.representation == "canonical",
           ["local", "git", "dotagents", "skills-cli"].contains(agentsVariant.manager)
        {
            return SkillRemovalRequest(
                id: "canonical:\(project.root):\(agentsVariant.name)",
                displayName: agentsVariant.name,
                kind: .canonical(projectRoot: project.root, skillName: agentsVariant.name)
            )
        }
        if skill.manager == "codex-plugin", skill.authority.contains("@") {
            return SkillRemovalRequest(
                id: "plugin:\(skill.authority)",
                displayName: "\(skill.authority) plugin",
                kind: .plugin(pluginID: skill.authority)
            )
        }
        if ["codex", "claude"].contains(skill.manager),
           skill.representation == "canonical",
           MetagentCore.canUninstallStandaloneSkill(
               projectRoot: project.root,
               skillPath: skill.path,
               skillName: skill.name
           )
        {
            return SkillRemovalRequest(
                id: "standalone:\(skill.path)",
                displayName: skill.name,
                kind: .standalone(projectRoot: project.root, skillPath: skill.path, skillName: skill.name)
            )
        }
        return nil
    }
    func matches(_ query: String) -> Bool {
        [skillName, projectName, locationLabel, originText, metagentScoreText, pluginEvalText, codexReviewText]
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }
    private static func standardizedDirectory(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            return url.resolvingSymlinksInPath().standardizedFileURL.path
        }
        return url.path
    }

}

private func pluginUsageMatchKey(id: String, canonicalPath: String?) -> String? {
    let components = id.split(separator: ":", maxSplits: 2).map(String.init)
    guard components.count == 3,
          components[0] == "plugin",
          let canonicalPath,
          let identity = pluginCacheIdentity(canonicalPath),
          identity.plugin == components[1]
    else { return nil }
    return identity.key
}

private func pluginUsageMatchKey(_ skill: SkillStatus) -> String? {
    guard skill.location == "plugin",
          let identity = pluginCacheIdentity(skill.canonicalPath)
    else { return nil }
    return identity.key
}

private func pluginCacheIdentity(_ canonicalPath: String) -> (marketplace: String, plugin: String, skill: String, key: String)? {
    let url = URL(fileURLWithPath: canonicalPath)
    let components = url.pathComponents
    guard let skillsIndex = components.lastIndex(of: "skills"),
          skillsIndex >= 4,
          components[skillsIndex - 4] == "cache"
    else { return nil }
    let marketplace = components[skillsIndex - 3]
    let plugin = components[skillsIndex - 2]
    let skill = url.lastPathComponent
    return (marketplace, plugin, skill, "\(marketplace):\(plugin):\(skill)")
}

private func skillRemovalMessage(for rows: [InventorySkillRow]) -> String {
    let requests = rows.compactMap(\.removalRequest)
    let pluginCount = requests.filter { request in
        if case .plugin = request.kind { return true }
        return false
    }.count
    let managedCount = rows.filter { ["skills-cli", "dotagents"].contains($0.skill.manager) }.count
    var parts = ["This action is manager-aware and will verify every removal before refreshing inventory."]
    if pluginCount > 0 {
        parts.append("Removing a plugin skill uninstalls its entire Codex plugin, including its other skills; duplicate selections from one plugin are collapsed into one action.")
    }
    if managedCount > 0 {
        parts.append("Managed skills are removed through their owning CLI after recovery state is saved.")
    }
    if requests.count > 1 {
        parts.append("Items are removed sequentially; processing stops and reports details if one fails.")
    }
    return parts.joined(separator: " ")
}

private struct InventoryColumnSpec: Identifiable {
    let id: String
    let title: String
    let comparator: KeyPathComparator<InventorySkillRow>
    let minWidth: CGFloat
    let idealWidth: CGFloat
    let isNumeric: Bool
    let isMonospaced: Bool
    let isPrimary: Bool
    let defaultVisibility: Visibility
    let showsBadge: Bool
    let symbol: ((InventorySkillRow) -> String?)?
    let tint: ((InventorySkillRow) -> Color?)?
    let value: (InventorySkillRow) -> String
    let help: (InventorySkillRow) -> String

    init(
        id: String,
        title: String,
        comparator: KeyPathComparator<InventorySkillRow>,
        minWidth: CGFloat,
        idealWidth: CGFloat,
        isNumeric: Bool,
        isMonospaced: Bool,
        isPrimary: Bool,
        defaultVisibility: Visibility,
        showsBadge: Bool = false,
        symbol: ((InventorySkillRow) -> String?)? = nil,
        tint: ((InventorySkillRow) -> Color?)? = nil,
        value: @escaping (InventorySkillRow) -> String,
        help: @escaping (InventorySkillRow) -> String
    ) {
        self.id = id
        self.title = title
        self.comparator = comparator
        self.minWidth = minWidth
        self.idealWidth = idealWidth
        self.isNumeric = isNumeric
        self.isMonospaced = isMonospaced
        self.isPrimary = isPrimary
        self.defaultVisibility = defaultVisibility
        self.showsBadge = showsBadge
        self.symbol = symbol
        self.tint = tint
        self.value = value
        self.help = help
    }
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
        isPrimary: true,
        defaultVisibility: .visible,
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
        isPrimary: false,
        defaultVisibility: .visible,
        value: \.projectName,
        help: \.projectRoot
    ),
    InventoryColumnSpec(
        id: "location",
        title: "Location",
        comparator: KeyPathComparator(\InventorySkillRow.locationLabel),
        minWidth: 130,
        idealWidth: 160,
        isNumeric: false,
        isMonospaced: false,
        isPrimary: false,
        defaultVisibility: .hidden,
        value: \.locationLabel,
        help: \.locationHelp
    ),
    InventoryColumnSpec(
        id: "origin",
        title: "Source",
        comparator: KeyPathComparator(\InventorySkillRow.originText),
        minWidth: 120,
        idealWidth: 170,
        isNumeric: false,
        isMonospaced: false,
        isPrimary: false,
        defaultVisibility: .visible,
        symbol: { $0.sourceSymbol },
        value: \.originText,
        help: \.originHelp
    ),
    InventoryColumnSpec(
        id: "metagent-score",
        title: "Metagent",
        comparator: KeyPathComparator(\InventorySkillRow.metagentScore.score),
        minWidth: 82,
        idealWidth: 94,
        isNumeric: true,
        isMonospaced: false,
        isPrimary: false,
        defaultVisibility: .visible,
        showsBadge: true,
        tint: { $0.metagentScoreTint },
        value: \.metagentScoreText,
        help: \.metagentScoreHelp
    ),
    InventoryColumnSpec(
        id: "plugin-eval",
        title: "Plugin Eval",
        comparator: KeyPathComparator(\InventorySkillRow.pluginEvalSortValue),
        minWidth: 90,
        idealWidth: 104,
        isNumeric: true,
        isMonospaced: false,
        isPrimary: false,
        defaultVisibility: .visible,
        showsBadge: true,
        tint: \.pluginEvalTint,
        value: \.pluginEvalText,
        help: \.pluginEvalHelp
    ),
    InventoryColumnSpec(
        id: "codex-review",
        title: "Codex",
        comparator: KeyPathComparator(\InventorySkillRow.codexReviewSortValue),
        minWidth: 82,
        idealWidth: 94,
        isNumeric: true,
        isMonospaced: false,
        isPrimary: false,
        defaultVisibility: .hidden,
        showsBadge: true,
        tint: \.codexReviewTint,
        value: \.codexReviewText,
        help: \.codexReviewHelp
    ),
    InventoryColumnSpec(
        id: "tokens",
        title: "Tokens",
        comparator: KeyPathComparator(\InventorySkillRow.tokenEstimate),
        minWidth: 76,
        idealWidth: 92,
        isNumeric: true,
        isMonospaced: false,
        isPrimary: false,
        defaultVisibility: .visible,
        value: { formatNumber($0.tokenEstimate) },
        help: { formatNumber($0.tokenEstimate) }
    )
]

private struct InventoryTableCell: View {
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
    }

    private var cellFont: Font {
        if isPrimary {
            return .body.weight(.medium)
        }
        return isMonospaced ? .caption.monospaced() : .callout
    }
}

private func formatNumber(_ value: Int) -> String {
    value.formatted()
}

private func copyToPasteboard(_ text: String) {
    guard !text.isEmpty else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}

private func standardizedDirectoryPath(_ path: String) -> String {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    if FileManager.default.fileExists(atPath: url.path) {
        return url.resolvingSymlinksInPath().standardizedFileURL.path
    }
    return url.path
}

private func improvementPrompt(paths: [String]) -> String {
    let pathList = paths.uniqued().map { "- \($0)" }.joined(separator: "\n")
    return """
    Please review and improve the following skill(s):
    \(pathList)

    Use the applicable skill-authoring guidance. Improve trigger precision, clarity, progressive disclosure, and safety while preserving each skill's intended scope and manager ownership. Validate the edited canonical source.
    """
}

private func scoreTint(_ grade: SkillGrade) -> Color {
    switch grade {
    case .a: .green
    case .b: .blue
    case .c: .orange
    case .d: .pink
    case .f: .red
    }
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fix skill links")
                        .font(.title2.weight(.semibold))
                    Text("Review every change before applying it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Close") {
                    dismiss()
                }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
            }

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
            } else if model.isRunning {
                ProgressView("Preparing preview…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let title = model.lastOutputTitle {
                LastOutputView(
                    title: title,
                    lines: model.lastOutputLines,
                    onCopy: model.copyLastOutput
                )
            } else {
                Button {
                    model.previewRepair()
                } label: {
                    Label("Preview fixes", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
        }
        .padding(20)
        .frame(minWidth: 820, minHeight: 580)
        .frame(maxHeight: .infinity, alignment: .top)
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
                    Label("Apply fixes", systemImage: "checkmark.circle")
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
