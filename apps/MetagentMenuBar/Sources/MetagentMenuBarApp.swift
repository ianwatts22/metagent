import AppKit
import Foundation
import SwiftUI

@main
struct MetagentMenuBarApp: App {
    @StateObject private var model = MetagentModel()

    var body: some Scene {
        WindowGroup("Metagent", id: "main") {
            MetagentPanel(model: model, showsOpenWindowButton: false)
                .frame(minWidth: 1040, idealWidth: 1180, minHeight: 680, idealHeight: 760)
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MetagentPanel(model: model, showsOpenWindowButton: true)
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
    @State private var selectedSection = PanelSection.overview

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Picker("Section", selection: $selectedSection) {
                ForEach(PanelSection.allCases) { section in
                    Label(section.title, systemImage: section.symbol)
                        .tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            panelContent

            footer
        }
        .padding(16)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Metagent")
                    .font(.title3.weight(.semibold))
                Text(model.statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let lastRun = model.lastRunText {
                Text(lastRun)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var panelContent: some View {
        switch selectedSection {
        case .overview:
            OverviewSection(model: model)
        case .repos:
            ReposSection(model: model)
        case .inventory:
            if showsOpenWindowButton {
                InventoryMenuSection(model: model) {
                    openWindow(id: "main")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
            } else {
                InventorySection(model: model)
            }
        case .sync:
            SyncSection(model: model)
        case .tools:
            ToolsSection(model: model)
        }
    }

    private var statusGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                MetricView(title: "Locations", value: "\(model.repoCount)", symbol: "folder")
                MetricView(title: "Skills", value: "\(model.skillCount)", symbol: "sparkles")
                MetricView(
                    title: "Doctor",
                    value: model.problemText,
                    symbol: model.problemCount == 0 ? "checkmark.circle" : "exclamationmark.triangle",
                    tint: model.problemCount == 0 ? .green : .orange
                )
            }
            GridRow {
                MetricView(title: "Background", value: model.backgroundStatus, symbol: "timer")
                StatusPathView(title: "Locations", value: model.locationSummaryText, symbol: "folder.badge.gearshape")
                StatusPathView(title: "Roots", value: model.rootsText, symbol: "point.3.connected.trianglepath.dotted")
            }
        }
    }

    private var primaryActions: some View {
        HStack(spacing: 8) {
            ActionButton(
                title: "Refresh",
                symbol: "arrow.clockwise",
                action: model.refreshStatus
            )
            .disabled(model.isRunning)

            ActionButton(
                title: "Doctor",
                symbol: "stethoscope",
                action: model.runDoctor
            )
            .disabled(model.isRunning)

            ActionButton(
                title: "Dry Run",
                symbol: "doc.text.magnifyingglass",
                action: model.dryRunSkillsSync
            )
            .disabled(model.isRunning)

            ActionButton(
                title: "Sync",
                symbol: "arrow.triangle.2.circlepath",
                action: model.syncNow
            )
            .disabled(model.isRunning)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if showsOpenWindowButton {
                Button {
                    openWindow(id: "main")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                } label: {
                    Label("Window", systemImage: "macwindow")
                }
            }

            Button {
                model.openConfig()
            } label: {
                Label("Config", systemImage: "gearshape")
            }

            Button {
                model.openLogs()
            } label: {
                Label("Logs", systemImage: "doc.text")
            }

            Button {
                model.installBackgroundSync()
            } label: {
                Label("Install Sync", systemImage: "timer")
            }
            .disabled(model.isRunning)

            Spacer()

            Button {
                model.restartMenuBar()
            } label: {
                Image(systemName: "arrow.clockwise.circle")
            }
            .help("Restart App")
            .disabled(model.isRunning)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .help("Quit")
        }
        .font(.callout)
    }
}

private enum PanelSection: String, CaseIterable, Identifiable {
    case overview
    case repos
    case inventory
    case sync
    case tools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .repos: "Skills"
        case .inventory: "Inventory"
        case .sync: "Sync"
        case .tools: "Tools"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge"
        case .repos: "folder"
        case .inventory: "tablecells"
        case .sync: "arrow.triangle.2.circlepath"
        case .tools: "wrench.and.screwdriver"
        }
    }
}

private struct OverviewSection: View {
    @ObservedObject var model: MetagentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusGrid
            primaryActions

            InfoRow(title: "CLI", value: model.cliPathText, symbol: "terminal")
            InfoRow(title: "Refresh", value: model.refreshPolicyText, symbol: "arrow.clockwise")

            if let title = model.lastOutputTitle {
                LastOutputView(
                    title: title,
                    lines: model.lastOutputLines,
                    onCopy: model.copyLastOutput
                )
            } else {
                EmptyStateView(
                    title: "Ready",
                    message: "Run a command or open another section.",
                    symbol: "checkmark.circle"
                )
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var statusGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                MetricView(title: "Locations", value: "\(model.repoCount)", symbol: "folder")
                MetricView(title: "Skills", value: "\(model.skillCount)", symbol: "sparkles")
                MetricView(
                    title: "Doctor",
                    value: model.problemText,
                    symbol: model.problemCount == 0 ? "checkmark.circle" : "exclamationmark.triangle",
                    tint: model.problemCount == 0 ? .green : .orange
                )
            }
            GridRow {
                MetricView(title: "Background", value: model.backgroundStatus, symbol: "timer")
                StatusPathView(title: "Locations", value: model.locationSummaryText, symbol: "folder.badge.gearshape")
                StatusPathView(title: "Roots", value: model.rootsText, symbol: "point.3.connected.trianglepath.dotted")
            }
        }
    }

    private var primaryActions: some View {
        HStack(spacing: 8) {
            ActionButton(
                title: "Refresh",
                symbol: "arrow.clockwise",
                action: model.refreshStatus
            )
            .disabled(model.isRunning)

            ActionButton(
                title: "Doctor",
                symbol: "stethoscope",
                action: model.runDoctor
            )
            .disabled(model.isRunning)

            ActionButton(
                title: "Dry Run",
                symbol: "doc.text.magnifyingglass",
                action: model.dryRunSkillsSync
            )
            .disabled(model.isRunning)

            ActionButton(
                title: "Sync",
                symbol: "arrow.triangle.2.circlepath",
                action: model.syncNow
            )
            .disabled(model.isRunning)
        }
    }
}

private struct ReposSection: View {
    @ObservedObject var model: MetagentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Skill Locations")
                    .font(.headline)
                Spacer()
                Button {
                    model.refreshStatus()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
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
                    VStack(alignment: .leading, spacing: 8) {
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

private struct InventorySection: View {
    @ObservedObject var model: MetagentModel
    @State private var selection = Set<InventorySkillRow.ID>()
    @State private var sortOrder = [KeyPathComparator(\InventorySkillRow.skillName)]
    @SceneStorage("metagent.inventory.columns")
    private var columnCustomization = TableColumnCustomization<InventorySkillRow>()

    private var rows: [InventorySkillRow] {
        InventorySkillRow.rows(from: model.projects)
    }

    private var sortedRows: [InventorySkillRow] {
        rows.sorted(using: sortOrder)
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

                Button {
                    model.refreshStatus()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
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
                MetricView(title: "Entries", value: "\(model.skillInventory.count)", symbol: "tablecells")
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

    static func rows(from projects: [ProjectStatus]) -> [InventorySkillRow] {
        projects.flatMap { project in
            project.skills.map { skill in
                InventorySkillRow(project: project, skill: skill)
            }
        }
    }

    var id: String {
        "\(project.root):\(skill.id)"
    }

    var skillName: String { skill.name }
    var projectName: String { project.name }
    var projectRoot: String { project.root }
    var skillPath: String { skill.path }
    var locationLabel: String { skill.locationLabel }
    var originText: String { skill.tableOriginText }
    var originHelp: String { skill.sourceURL ?? skill.tableOriginText }
    var folderKind: String { skill.folderKindLabel }
    var characterCount: Int { skill.characterCount }
    var wordCount: Int { skill.wordCount }
    var tokenEstimate: Int { skill.tokenEstimate }
    var skillFileTokenEstimate: Int { skill.skillFileTokenEstimate }
    var textFileCount: Int { skill.textFileCount }
    var referenceFileCount: Int { skill.referenceFileCount }
    var scriptFileCount: Int { skill.scriptFileCount }
    var assetFileCount: Int { skill.assetFileCount }
    var otherFileCount: Int { skill.otherFileCount }
    var otherFolderCount: Int { skill.otherFolderCount }
    var iconLogoText: String { skill.iconLogoText }
    var iconHelp: String {
        [skill.iconSmallPath, skill.iconLargePath]
            .compactMap { $0 }
            .joined(separator: "\n")
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
        help: \.locationLabel
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
        id: "folder",
        title: "Folder",
        comparator: KeyPathComparator(\InventorySkillRow.folderKind),
        minWidth: 110,
        idealWidth: 130,
        isNumeric: false,
        isMonospaced: false,
        value: \.folderKind,
        help: \.folderKind
    ),
    InventoryColumnSpec(
        id: "chars",
        title: "Chars",
        comparator: KeyPathComparator(\InventorySkillRow.characterCount),
        minWidth: 72,
        idealWidth: 86,
        isNumeric: true,
        isMonospaced: false,
        value: { formatNumber($0.characterCount) },
        help: { formatNumber($0.characterCount) }
    ),
    InventoryColumnSpec(
        id: "words",
        title: "Words",
        comparator: KeyPathComparator(\InventorySkillRow.wordCount),
        minWidth: 72,
        idealWidth: 86,
        isNumeric: true,
        isMonospaced: false,
        value: { formatNumber($0.wordCount) },
        help: { formatNumber($0.wordCount) }
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
        id: "skill-md",
        title: "SKILL.md",
        comparator: KeyPathComparator(\InventorySkillRow.skillFileTokenEstimate),
        minWidth: 78,
        idealWidth: 94,
        isNumeric: true,
        isMonospaced: false,
        value: { formatNumber($0.skillFileTokenEstimate) },
        help: { formatNumber($0.skillFileTokenEstimate) }
    ),
    InventoryColumnSpec(
        id: "text-files",
        title: "Text",
        comparator: KeyPathComparator(\InventorySkillRow.textFileCount),
        minWidth: 54,
        idealWidth: 66,
        isNumeric: true,
        isMonospaced: false,
        value: { formatNumber($0.textFileCount) },
        help: { formatNumber($0.textFileCount) }
    ),
    InventoryColumnSpec(
        id: "references",
        title: "Refs",
        comparator: KeyPathComparator(\InventorySkillRow.referenceFileCount),
        minWidth: 54,
        idealWidth: 66,
        isNumeric: true,
        isMonospaced: false,
        value: { formatNumber($0.referenceFileCount) },
        help: { formatNumber($0.referenceFileCount) }
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
        id: "icon-logo",
        title: "Icon/logo",
        comparator: KeyPathComparator(\InventorySkillRow.iconLogoText),
        minWidth: 92,
        idealWidth: 120,
        isNumeric: false,
        isMonospaced: false,
        value: \.iconLogoText,
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

private struct SyncSection: View {
    @ObservedObject var model: MetagentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ActionButton(
                    title: "Dry Run",
                    symbol: "doc.text.magnifyingglass",
                    action: model.dryRunSkillsSync
                )
                .disabled(model.isRunning)

                ActionButton(
                    title: "Apply",
                    symbol: "checkmark.circle",
                    action: model.syncNow
                )
                .disabled(model.isRunning)
            }

            if let syncPreview = model.syncPreview {
                SyncPreviewView(
                    preview: syncPreview,
                    showsRawOutput: model.showsRawOutput,
                    rawLines: model.lastOutputLines,
                    onApply: model.syncNow,
                    onCopySummary: model.copySyncSummary,
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
                EmptyStateView(
                    title: "No sync preview",
                    message: "Run a dry run to inspect planned changes before applying.",
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Maintenance")
                .font(.headline)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ToolButton(title: "Doctor", symbol: "stethoscope", action: model.runDoctor)
                ToolButton(title: "Morph Status", symbol: "waveform.path.ecg", action: model.runMorphStatus)
                ToolButton(title: "Install Sync", symbol: "timer", action: model.installBackgroundSync)
                ToolButton(title: "Refresh", symbol: "arrow.clockwise", action: model.refreshStatus)
            }
            .disabled(model.isRunning)

            if let title = model.lastOutputTitle {
                LastOutputView(
                    title: title,
                    lines: model.lastOutputLines,
                    onCopy: model.copyLastOutput
                )
            } else {
                EmptyStateView(
                    title: "No command output",
                    message: "Run a maintenance command to inspect results here.",
                    symbol: "terminal"
                )
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
                if project.npxInstalledAgentsSkillCount > 0 {
                    Badge(text: "\(project.npxInstalledAgentsSkillCount) npx", symbol: "arrow.down.circle", tint: .green)
                }
                if project.nativeAgentsSkillCount > 0 {
                    Badge(text: "\(project.nativeAgentsSkillCount) native", symbol: "hammer", tint: .secondary)
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
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
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
        .padding(8)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
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
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .frame(width: 18)
                Text(title)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
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
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
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

private struct SyncPreviewView: View {
    let preview: SyncPreview
    let showsRawOutput: Bool
    let rawLines: [String]
    let onApply: () -> Void
    let onCopySummary: () -> Void
    let onCopyRawOutput: () -> Void
    let onToggleRawOutput: () -> Void
    let onOpenProject: (SyncProjectPreview) -> Void

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
                MetricView(title: "Dotagents", value: "\(preview.summary.dotagentsCount)", symbol: "arrow.triangle.2.circlepath")
            }

            HStack(spacing: 8) {
                Button {
                    onApply()
                } label: {
                    Label("Apply Sync", systemImage: "checkmark.circle")
                }

                Button {
                    onCopySummary()
                } label: {
                    Label("Copy Summary", systemImage: "doc.on.doc")
                }

                Button {
                    onToggleRawOutput()
                } label: {
                    Label(showsRawOutput ? "Hide Raw" : "Show Raw", systemImage: "terminal")
                }

                if showsRawOutput {
                    Button {
                        onCopyRawOutput()
                    } label: {
                        Label("Copy Raw", systemImage: "doc.on.clipboard")
                    }
                }
            }
            .font(.callout)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(preview.projects) { project in
                        SyncProjectView(project: project) {
                            onOpenProject(project)
                        }
                    }

                    if showsRawOutput {
                        RawOutputBlock(title: "Raw CLI Output", lines: rawLines)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct SyncProjectView: View {
    let project: SyncProjectPreview
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
                .buttonStyle(.borderless)
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
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct LineGroup: View {
    let lines: [SyncLinePreview]
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
            .background(.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
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
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
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
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ActionButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity)
        }
        .controlSize(.regular)
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
