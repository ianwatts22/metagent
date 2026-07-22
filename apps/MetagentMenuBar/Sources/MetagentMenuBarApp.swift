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

    private static let applicationIcons: [String: NSImage] = {
        ["com.openai.codex", "com.anthropic.claudefordesktop"].reduce(into: [:]) { icons, bundleIdentifier in
            guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
                return
            }
            icons[bundleIdentifier] = NSWorkspace.shared.icon(forFile: applicationURL.path)
        }
    }()

    static func applicationIcon(bundleIdentifier: String) -> NSImage? {
        applicationIcons[bundleIdentifier]
    }
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
            .accessibilityLabel("More options")
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
            OverviewSection(model: model, isCompact: showsOpenWindowButton)
        case .skills:
            if showsOpenWindowButton {
                SkillsMenuSection(model: model) {
                    openWindow(id: "main")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
            } else {
                InventorySection(model: model)
            }
        case .mcps:
            if showsOpenWindowButton {
                MCPMenuSection(model: model) {
                    openWindow(id: "main")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
            } else {
                MCPInventorySection(model: model)
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
    case mcps

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .skills: "Skills"
        case .mcps: "MCPs"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge"
        case .skills: "sparkles"
        case .mcps: "server.rack"
        }
    }
}

private struct OverviewSection: View {
    @ObservedObject var model: MetagentModel
    let isCompact: Bool
    @State private var showsDoctorFindings = false
    @State private var showsRepair = false
    @State private var showsMCPDetails = false
    @State private var repairProjectRoot: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            mcpConnections
            if model.doctorActionCount > 0 {
                cleanupStatus
            }
            summary
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $showsDoctorFindings) {
            DoctorFindingsView(model: model) { projectRoot in
                repairProjectRoot = projectRoot
                model.previewRepair(projectRoot: projectRoot)
                showsRepair = true
            }
        }
        .sheet(isPresented: $showsRepair) {
            RepairSection(model: model, projectRoot: repairProjectRoot)
        }
        .alert(
            "Could not open Claude",
            isPresented: Binding(
                get: { model.lastOutputTitle == "Could not open Claude" },
                set: { isPresented in
                    if !isPresented {
                        model.clearLastOutput()
                    }
                }
            )
        ) {
            Button("OK") {
                model.clearLastOutput()
            }
        } message: {
            Text(model.lastOutputLines.first ?? "Open the project in Terminal and run Claude manually.")
        }
    }

    private var mcpConnections: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if model.mcpHealth.observedAt == .distantPast {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 28)
                } else {
                    Image(systemName: model.mcpHealth.attention.isEmpty
                        ? "checkmark.circle.fill"
                        : "exclamationmark.triangle.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(model.mcpHealth.attention.isEmpty ? Color.green : Color.orange)
                        .frame(width: 28)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("MCP Connections")
                        .font(.headline)
                    Text(mcpSummaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 16)

                HStack(spacing: 14) {
                    MCPClientCount(
                        client: .codex,
                        count: model.mcpHealth.count(for: .codex)
                    )
                    MCPClientCount(
                        client: .claude,
                        count: model.mcpHealth.count(for: .claude)
                    )
                }

                Button {
                    model.refreshMCPHealth()
                } label: {
                    if model.isMCPRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.plain)
                .frame(width: 24, height: 24)
                .disabled(model.isMCPRefreshing)
                .help("Refresh passive MCP configuration and sign-in evidence")
                .accessibilityLabel("Refresh MCP status")

                if !mcpDetailRows.isEmpty {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            showsMCPDetails.toggle()
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(showsMCPDetails ? 90 : 0))
                    }
                    .buttonStyle(.plain)
                    .help(showsMCPDetails ? "Hide MCP details" : "Show MCP details")
                    .accessibilityLabel(showsMCPDetails ? "Hide MCP details" : "Show MCP details")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            if !visibleMCPRows.isEmpty {
                Divider()
                    .padding(.leading, 56)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visibleMCPRows) { row in
                            MCPHealthRow(row: row) {
                                model.openMCPServer(row.server)
                            }

                            if row.id != visibleMCPRows.last?.id {
                                Divider()
                                    .padding(.leading, 40)
                            }
                        }
                    }
                }
                .frame(height: min(
                    CGFloat(visibleMCPRows.count) * 54,
                    isCompact ? 108 : 216
                ))
            }
        }
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.separator.opacity(0.55), lineWidth: 0.5)
        }
        .onChange(of: mcpDetailRows.isEmpty) { _, isEmpty in
            if isEmpty {
                showsMCPDetails = false
            }
        }
    }

    private var visibleMCPRows: [MCPHealthDisplayRow] {
        if showsMCPDetails {
            return mcpDetailRows
        }
        return groupedMCPRows(model.mcpHealth.attention)
    }

    private var mcpDetailRows: [MCPHealthDisplayRow] {
        groupedMCPRows(model.mcpHealth.servers.filter {
            $0.state.needsAttention || $0.state == .disabled
        })
    }

    private var mcpSummaryText: String {
        let configured = model.mcpHealth.configuredCount
        let attention = groupedMCPRows(model.mcpHealth.attention).count
        guard model.mcpHealth.observedAt != .distantPast else {
            return "Checking configuration…"
        }
        if attention == 0 {
            return "\(configured) configured · no known issues"
        }
        return "\(configured) configured · \(attention) \(attention == 1 ? "needs" : "need") attention"
    }

    private func groupedMCPRows(_ servers: [MCPServerHealth]) -> [MCPHealthDisplayRow] {
        let expandedServers = servers.flatMap { server in
            guard server.client == .claude,
                  server.state == .pendingApproval,
                  server.projectPaths.count > 1
            else { return [server] }
            return server.projectPaths.map { projectPath in
                MCPServerHealth(
                    client: server.client,
                    name: server.name,
                    state: .pendingApproval,
                    detail: "Needs approval in \(URL(fileURLWithPath: projectPath).lastPathComponent)",
                    projectStates: [.init(path: projectPath, state: .pendingApproval)]
                )
            }
        }
        var rows: [MCPHealthDisplayRow] = []
        var groupedIDs = Set<String>()
        let pendingGroups = Dictionary(grouping: expandedServers.filter {
            $0.client == .claude
                && $0.state == .pendingApproval
                && $0.projectPaths.count == 1
        }) { $0.projectPaths[0] }

        for server in expandedServers {
            if server.client == .claude,
               server.state == .pendingApproval,
               let projectPath = server.projectPaths.first,
               server.projectPaths.count == 1,
               let group = pendingGroups[projectPath]
            {
                let groupID = "claude-project:\(projectPath)"
                guard groupedIDs.insert(groupID).inserted else { continue }
                let projectName = projectDisplayName(projectPath)
                rows.append(MCPHealthDisplayRow(
                    id: groupID,
                    server: group[0],
                    title: "\(projectName) · Claude",
                    detail: "\(group.count) project \(group.count == 1 ? "server needs" : "servers need") approval"
                ))
            } else {
                rows.append(MCPHealthDisplayRow(
                    id: server.id,
                    server: server,
                    title: "\(server.name) · \(server.client.displayName)",
                    detail: server.detail
                ))
            }
        }
        return rows
    }

    private func projectDisplayName(_ projectPath: String) -> String {
        URL(fileURLWithPath: projectPath).lastPathComponent
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    private var cleanupStatus: some View {
        HStack(spacing: 12) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.orange)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text("Skill cleanup")
                    .font(.headline)
                Text(healthMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 16)

            HStack(spacing: 10) {
                if model.doctorActionCount > 0 {
                    if allDoctorFindingsRepairable {
                        Button {
                            repairProjectRoot = model.doctorFindings.first?.projectRoot
                            model.previewRepair(projectRoot: repairProjectRoot)
                            showsRepair = true
                        } label: {
                            Label("Resolve", systemImage: "wrench.and.screwdriver")
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(model.isRunning)
                    } else {
                        Button {
                            showsDoctorFindings = true
                        } label: {
                            Label("Review", systemImage: "stethoscope")
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(model.isRunning)
                    }
                }

                Button {
                    model.refreshStatus()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .frame(width: 24, height: 24)
                .help("Refresh Doctor")
                .disabled(model.isRunning)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.separator.opacity(0.55), lineWidth: 0.5)
        }
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
        }
        .frame(height: 76, alignment: .top)
        .padding(.vertical, 4)
    }

    private var recentInvocationCount: Int {
        model.usageSnapshot.summaries.reduce(0) { $0 + $1.invocations30d }
    }

    private var healthMessage: String {
        if model.doctorActionCount == 1,
           let issue = model.doctorFindings.first
        {
            return issue.summary ?? issue.message
        }
        return "Grouped by project and resolution."
    }

    private var allDoctorFindingsRepairable: Bool {
        model.doctorFindings.count == 1 && model.doctorFindings[0].repairAction != nil
    }

}

private struct MCPClientCount: View {
    let client: MCPClient
    let count: Int

    private var bundleIdentifier: String {
        switch client {
        case .codex: "com.openai.codex"
        case .claude: "com.anthropic.claudefordesktop"
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            if let icon = AppBrand.applicationIcon(bundleIdentifier: bundleIdentifier) {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            }
            Text("\(client.displayName) \(count)")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(client.displayName), \(count) configured")
    }
}

private struct MCPHealthDisplayRow: Identifiable {
    let id: String
    let server: MCPServerHealth
    let title: String
    let detail: String
}

private struct MCPHealthRow: View {
    let row: MCPHealthDisplayRow
    let openClient: () -> Void

    private var server: MCPServerHealth { row.server }

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: stateSymbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(stateTint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(row.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if server.state.needsAttention {
                Button(attentionActionLabel, action: openClient)
                    .buttonStyle(.glass)
            } else {
                Text(stateLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var attentionActionLabel: String {
        if server.client == .claude,
           server.state == .pendingApproval,
           server.projectPaths.count == 1
        {
            return "Resolve…"
        }
        return switch server.client {
        case .codex:
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") == nil
                ? "Show Codex config…"
                : "Open Codex…"
        case .claude: "Show Claude config…"
        }
    }

    private var stateLabel: String {
        switch server.state {
        case .configured: "Configured"
        case .disabled: "Disabled"
        case .pendingApproval: "Pending approval"
        case .needsSignIn: "Needs sign-in"
        case .unavailable: "Unavailable"
        }
    }

    private var stateSymbol: String {
        switch server.state {
        case .configured: "checkmark.circle"
        case .disabled: "pause.circle"
        case .pendingApproval: "questionmark.circle"
        case .needsSignIn: "person.crop.circle.badge.exclamationmark"
        case .unavailable: "exclamationmark.triangle.fill"
        }
    }

    private var stateTint: Color {
        switch server.state {
        case .configured: .green
        case .disabled: .secondary
        case .pendingApproval: .orange
        case .needsSignIn: .orange
        case .unavailable: .red
        }
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
    let onPreviewRepair: (String?) -> Void
    @Environment(\.dismiss) private var dismiss

    private var groups: [DoctorProjectGroup] {
        DoctorProjectGroup.groups(from: model.doctorFindings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Doctor")
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
                                        DoctorFindingRow(
                                            issue: issue,
                                            isDisabled: model.isRunning,
                                            onResolve: issue.repairAction == nil ? nil : {
                                                onPreviewRepair(issue.projectRoot)
                                                dismiss()
                                            },
                                            onOpenProject: issue.projectRoot.map { root in
                                                { model.openProjectRoot(root) }
                                            }
                                        )
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        } header: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(project.name)
                            }
                            .help(project.root ?? "General findings")
                        }
                    }
                }
                .listStyle(.inset)
            }

            HStack {
                Spacer()

                Button {
                    model.runDoctor()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .frame(width: 24, height: 24)
                .help("Run Doctor again")
                .accessibilityLabel("Run Doctor again")
                .disabled(model.isRunning)
            }
        }
        .padding(18)
        .frame(minWidth: 720, minHeight: 520)
    }

    private var summaryText: String {
        if model.doctorActionCount == 0 {
            return "No action needed."
        }
        return "\(model.doctorActionCount) \(model.doctorActionCount == 1 ? "cleanup" : "cleanups"), grouped by project."
    }
}

private struct DoctorFindingRow: View {
    let issue: DoctorIssue
    let isDisabled: Bool
    let onResolve: (() -> Void)?
    let onOpenProject: (() -> Void)?
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 9) {
                Image(systemName: issue.severity == .failure ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(issue.severity == .failure ? .red : .orange)

                Text(issue.summary ?? issue.message)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)

                Spacer()

                if let onResolve {
                    Button("Resolve…", action: onResolve)
                        .buttonStyle(.glass)
                        .disabled(isDisabled)
                } else if let onOpenProject {
                    Button("Open", action: onOpenProject)
                        .buttonStyle(.plain)
                }
            }
            .help(issue.guidance ?? issue.message)

            DisclosureGroup("Details", isExpanded: $showsDetails) {
                VStack(alignment: .leading, spacing: 6) {
                    if let guidance = issue.guidance {
                        Text(guidance)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(issue.message)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
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
        includes(status: row.status, totalInvocations: row.totalInvocations)
    }

    func includes(status: UsageSkillRow.Status, totalInvocations: Int) -> Bool {
        switch self {
        case .all: true
        case .observed: totalInvocations > 0
        case .neverObserved: status == .neverObserved
        case .dormant: status == .dormant
        case .insufficient: status == .insufficient
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

private enum SkillTableView: String, CaseIterable, Identifiable {
    case inventory
    case usage
    case review

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

private enum SkillSourceCategory: String, CaseIterable, Identifiable {
    case plugin
    case skillsCLI
    case dotagentsLocal
    case dotagentsManaged
    case git
    case codexSystem
    case codexInstalled
    case claude
    case local
    case notInstalled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plugin: "Codex plugins"
        case .skillsCLI: "Skills CLI"
        case .dotagentsLocal: "dotagents · path declaration"
        case .dotagentsManaged: "dotagents · package"
        case .git: "Git repository"
        case .codexSystem: "Codex system"
        case .codexInstalled: "Codex installed"
        case .claude: "Claude"
        case .local: "Local"
        case .notInstalled: "Not installed"
        }
    }

    var explanation: String {
        switch self {
        case .dotagentsLocal:
            "A local skill path is still declared in a legacy agents.toml or agents.lock file. dotagents did not download the skill."
        case .dotagentsManaged:
            "The skill is declared as a package managed by dotagents rather than as a local path."
        case .notInstalled:
            "Historical Codex usage matched this skill, but no current installed bundle matches its recorded path or identity."
        default:
            title
        }
    }

    var symbol: String {
        switch self {
        case .plugin: "powerplug.fill"
        case .skillsCLI: "globe"
        case .dotagentsLocal, .dotagentsManaged: "arrow.triangle.branch"
        case .git: "shippingbox"
        case .codexSystem, .codexInstalled: "sparkles"
        case .claude: "link"
        case .local: "person.crop.circle"
        case .notInstalled: "clock.arrow.circlepath"
        }
    }

    static func resolve(
        inventory: InventorySkillRow?,
        usage: UsageSkillRow,
        pluginInventoryAvailable: Bool
    ) -> SkillSourceCategory {
        guard let inventory else {
            return usage.scope == "plugin" ? .plugin : .notInstalled
        }
        switch inventory.skill.manager {
        case "codex-plugin": return .plugin
        case "skills-cli": return .skillsCLI
        case "dotagents":
            return inventory.skill.originKind == "dotagents-managed" ? .dotagentsManaged : .dotagentsLocal
        case "git": return .git
        case "codex":
            return inventory.skill.authority == "codex-system" ? .codexSystem : .codexInstalled
        case "claude": return .claude
        default: return .local
        }
    }
}

private enum SkillLocationKind: String, Identifiable {
    case agents
    case codex
    case claude
    case historical
    case other

    var id: String { rawValue }

    init(location: String) {
        switch location {
        case "agents": self = .agents
        case "codex", "plugin": self = .codex
        case "claude": self = .claude
        default: self = .other
        }
    }

    var title: String {
        switch self {
        case .agents: ".agents"
        case .codex: "Codex"
        case .claude: "Claude"
        case .historical: "Historical"
        case .other: "Other"
        }
    }

    var bundleIdentifier: String? {
        switch self {
        case .codex: "com.openai.codex"
        case .claude: "com.anthropic.claudefordesktop"
        default: nil
        }
    }

    var fallbackSymbol: String {
        switch self {
        case .agents: "globe"
        case .codex: "sparkles"
        case .claude: "link"
        case .historical: "clock.arrow.circlepath"
        case .other: "folder"
        }
    }
}

private struct SkillTableRow: Identifiable {
    let inventory: InventorySkillRow?
    let usage: UsageSkillRow
    let historicalProjectRoot: String?
    let pluginInventoryAvailable: Bool

    var id: String { inventory?.id ?? "historical:\(usage.id)" }
    var skillName: String { inventory?.skillName ?? usage.skillName }
    var projectName: String {
        inventory?.projectName
            ?? historicalProjectRoot.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? (usage.scope == "plugin" ? "Codex plugins" : "Not installed")
    }
    var projectRoot: String? { inventory?.projectRoot ?? historicalProjectRoot }
    var skillPath: String { inventory?.skillPath ?? usage.canonicalPath ?? "" }
    var canonicalPath: String? { inventory?.canonicalPath ?? usage.canonicalPath }
    var locationLabel: String { inventory?.locationLabel ?? "Historical" }
    var locationHelp: String {
        if let inventory { return inventory.locationHelp }
        if usage.scope == "plugin" {
            return pluginInventoryAvailable
                ? "Previously observed in Codex; no active plugin inventory match was found."
                : "Previously observed in Codex; plugin inventory is unavailable, so the current location cannot be confirmed."
        }
        return "Previously observed; no installed bundle matched this path."
    }
    var locationKinds: [SkillLocationKind] {
        guard let inventory else { return usage.scope == "plugin" ? [.codex] : [.historical] }
        return inventory.variants.map { SkillLocationKind(location: $0.location) }.uniqued()
    }
    var sourceCategory: SkillSourceCategory {
        SkillSourceCategory.resolve(
            inventory: inventory,
            usage: usage,
            pluginInventoryAvailable: pluginInventoryAvailable
        )
    }
    var sourceText: String { sourceCategory.title }
    var sourceHelp: String {
        let detail: String
        if inventory == nil, usage.scope == "plugin" {
            detail = pluginInventoryAvailable
                ? "No active plugin inventory match was found; the plugin may be disabled or removed."
                : "Codex plugin inventory is unavailable; current installation state is unknown."
        } else {
            detail = inventory?.originHelp ?? "Historical usage record\nScope: \(usage.scopeLabel)"
        }
        return "\(sourceCategory.explanation)\n\(detail)"
    }
    var sourceSymbol: String { sourceCategory.symbol }
    var scope: String { usage.scope }
    var scopeLabel: String { usage.scopeLabel }
    var scopeSymbol: String { usage.scopeSymbol }
    var metagentScoreSortValue: Int { inventory?.metagentScore.score ?? -1 }
    var metagentScoreText: String { inventory?.metagentScoreText ?? "—" }
    var metagentScoreTint: Color? { inventory?.metagentScoreTint }
    var metagentScoreHelp: String { inventory?.metagentScoreHelp ?? "Not available for an uninstalled skill." }
    var pluginEvalSortValue: Int { inventory?.pluginEvalSortValue ?? -1 }
    var pluginEvalText: String { inventory?.pluginEvalText ?? "—" }
    var pluginEvalTint: Color? { inventory?.pluginEvalTint }
    var pluginEvalHelp: String { inventory?.pluginEvalHelp ?? "Not available for an uninstalled skill." }
    var codexReviewSortValue: Int { inventory?.codexReviewSortValue ?? -1 }
    var codexReviewText: String { inventory?.codexReviewText ?? "—" }
    var codexReviewTint: Color? { inventory?.codexReviewTint }
    var codexReviewHelp: String { inventory?.codexReviewHelp ?? "Not available for an uninstalled skill." }
    var tokenEstimate: Int { inventory?.tokenEstimate ?? -1 }
    var totalInvocations: Int { usage.totalInvocations }
    var invocations7d: Int { usage.invocations7d }
    var invocations30d: Int { usage.invocations30d }
    var distinctThreads: Int { usage.distinctThreads }
    var repeatInvocations: Int { usage.repeatInvocations }
    var lastUsedDate: Date? { usage.lastUsedDate }
    var lastUsedSortValue: TimeInterval { usage.lastUsedSortValue }
    var lastUsedText: String {
        lastUsedDate?.formatted(.relative(presentation: .named, unitsStyle: .wide)) ?? "Never"
    }
    var lastUsedHelp: String {
        lastUsedDate?.formatted(date: .abbreviated, time: .shortened) ?? "No observed usage"
    }
    var usageStatus: UsageSkillRow.Status { usage.status }
    var isInstalled: Bool { inventory != nil }
    var installationText: String {
        if isInstalled { return "Installed" }
        if usage.scope == "plugin" { return "Unknown" }
        return "Not installed"
    }
    var installationHelp: String {
        switch installationText {
        case "Installed": "A matching skill bundle is currently installed."
        case "Unknown": pluginInventoryAvailable
            ? "No active plugin inventory match was found; the plugin may be disabled or removed."
            : "Codex plugin inventory is unavailable, so installation state cannot be confirmed."
        default: "Historical usage with no matching installed bundle."
        }
    }

    func matches(_ query: String) -> Bool {
        [skillName, projectName, locationLabel, sourceText, scopeLabel, metagentScoreText, pluginEvalText, codexReviewText]
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }

    static func rows(
        inventoryRows: [InventorySkillRow],
        usageRows: [UsageSkillRow],
        projectRoots: [String],
        pluginInventoryAvailable: Bool,
        isBackfillComplete: Bool
    ) -> [SkillTableRow] {
        let usageByPath = Dictionary(grouping: usageRows.compactMap { row -> (String, UsageSkillRow)? in
            guard let path = row.canonicalPath else { return nil }
            return (standardizedDirectoryPath(path), row)
        }, by: \.0).compactMapValues { $0.first?.1 }
        let usageByPlugin = Dictionary(grouping: usageRows.compactMap { row in
            pluginUsageMatchKey(id: row.id, canonicalPath: row.canonicalPath).map { ($0, row) }
        }, by: \.0).compactMapValues { $0.first?.1 }
        var matchedUsageIDs = Set<String>()

        var rows = inventoryRows.map { inventory -> SkillTableRow in
            let matched = usageByPath[standardizedDirectoryPath(inventory.canonicalPath)]
                ?? pluginUsageMatchKey(inventory.skill).flatMap { usageByPlugin[$0] }
            if let matched { matchedUsageIDs.insert(matched.id) }
            let usage = matched ?? UsageSkillRow(
                id: "inventory:\(inventory.id)",
                skillName: inventory.skillName,
                canonicalPath: inventory.canonicalPath,
                scope: inventory.skill.folderKind == "system"
                    ? "system"
                    : (inventory.projectRoot == NSHomeDirectory() ? "global" : "project"),
                totalInvocations: 0,
                invocations7d: 0,
                invocations30d: 0,
                distinctThreads: 0,
                repeatInvocations: 0,
                lastUsedDate: nil,
                lastUsedSortValue: -.infinity,
                status: isBackfillComplete ? .neverObserved : .insufficient
            )
            return SkillTableRow(
                inventory: inventory,
                usage: usage,
                historicalProjectRoot: nil,
                pluginInventoryAvailable: pluginInventoryAvailable
            )
        }

        rows.append(contentsOf: usageRows
            .filter { !matchedUsageIDs.contains($0.id) }
            .map { usage in
                SkillTableRow(
                    inventory: nil,
                    usage: usage,
                    historicalProjectRoot: inferredProjectRoot(for: usage.canonicalPath, roots: projectRoots),
                    pluginInventoryAvailable: pluginInventoryAvailable
                )
            })
        return rows
    }

    private static func inferredProjectRoot(for path: String?, roots: [String]) -> String? {
        guard let path else { return nil }
        let canonicalPath = standardizedDirectoryPath(path)
        return roots
            .map(standardizedDirectoryPath)
            .filter { canonicalPath == $0 || canonicalPath.hasPrefix($0 + "/") }
            .max { $0.count < $1.count }
    }
}

private struct InventorySection: View {
    @ObservedObject var model: MetagentModel
    @State private var selection = Set<SkillTableRow.ID>()
    @State private var sortOrder = [KeyPathComparator(\SkillTableRow.skillName)]
    @State private var selectedProjectRoot: String?
    @State private var query = ""
    @State private var usageFilter = UsageFilter.all
    @State private var pendingRemoval: InventoryRemovalConfirmation?
    @State private var pendingCodexReview: InventorySkillRow?
    @AppStorage("metagent.skills.view.v1") private var selectedViewRaw = SkillTableView.inventory.rawValue
    @AppStorage("metagent.skills.hidden-sources.v2")
    private var hiddenSourceRaw = "__unmigrated__"
    @SceneStorage("metagent.skills.inventory.columns.v1")
    private var inventoryColumnCustomization = TableColumnCustomization<SkillTableRow>()
    @SceneStorage("metagent.skills.usage.columns.v2")
    private var usageColumnCustomization = TableColumnCustomization<SkillTableRow>()
    @SceneStorage("metagent.skills.review.columns.v1")
    private var reviewColumnCustomization = TableColumnCustomization<SkillTableRow>()

    private var selectedView: SkillTableView {
        SkillTableView(rawValue: selectedViewRaw) ?? .inventory
    }

    private var selectedViewBinding: Binding<SkillTableView> {
        Binding(
            get: { selectedView },
            set: { selectedViewRaw = $0.rawValue }
        )
    }

    private var hiddenSources: Set<SkillSourceCategory> {
        let rawValue = hiddenSourceRaw == "__unmigrated__"
            ? SkillSourceCategory.notInstalled.rawValue
            : hiddenSourceRaw
        return Set(rawValue.split(separator: ",").compactMap { SkillSourceCategory(rawValue: String($0)) })
    }

    private var columnCustomization: Binding<TableColumnCustomization<SkillTableRow>> {
        switch selectedView {
        case .inventory:
            Binding(get: { inventoryColumnCustomization }, set: { inventoryColumnCustomization = $0 })
        case .usage:
            Binding(get: { usageColumnCustomization }, set: { usageColumnCustomization = $0 })
        case .review:
            Binding(get: { reviewColumnCustomization }, set: { reviewColumnCustomization = $0 })
        }
    }

    private var inventoryRows: [InventorySkillRow] {
        InventorySkillRow.rows(
            from: model.projects,
            usage: model.usageSnapshot,
            evaluations: model.skillEvaluations
        )
    }

    private var allRows: [SkillTableRow] {
        SkillTableRow.rows(
            inventoryRows: inventoryRows,
            usageRows: UsageSkillRow.rows(
                projects: model.projects,
                summaries: model.usageSnapshot.summaries,
                isBackfillComplete: model.usageSnapshot.isBackfillComplete
            ),
            projectRoots: model.projects.map(\.root),
            pluginInventoryAvailable: model.isPluginInventoryAvailable,
            isBackfillComplete: model.usageSnapshot.isBackfillComplete
        )
    }

    private var projectFilterProjects: [ProjectStatus] {
        model.projects.filter { project in
            let isPluginProject = !project.skills.isEmpty && project.skills.allSatisfy { $0.location == "plugin" }
            return !isPluginProject
        }
    }

    private var rows: [SkillTableRow] {
        let searchQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return allRows
        .filter { selectedView == .usage || $0.isInstalled }
        .filter { selectedProjectRoot == nil || $0.projectRoot == selectedProjectRoot }
        .filter { !hiddenSources.contains($0.sourceCategory) }
        .filter { usageFilter.includes(status: $0.usageStatus, totalInvocations: $0.totalInvocations) }
        .filter { searchQuery.isEmpty || $0.matches(searchQuery) }
    }

    private var sortedRows: [SkillTableRow] {
        rows.sorted(using: sortOrder)
    }

    private var selectedRow: InventorySkillRow? {
        guard selection.count == 1, let selectedID = selection.first else { return nil }
        return rows.first { $0.id == selectedID }?.inventory
    }

    private var selectedRows: [SkillTableRow] {
        rows.filter { selection.contains($0.id) }
    }

    private var selectedRemovalRows: [InventorySkillRow] {
        selectedRows.compactMap(\.inventory).filter { $0.removalRequest != nil }
    }

    private var visibleInventoryRows: [InventorySkillRow] {
        rows.compactMap(\.inventory)
    }

    private var hasActiveFilter: Bool {
        let effectiveHiddenSources = selectedView == .usage
            ? hiddenSources
            : hiddenSources.subtracting([.notInstalled])
        return selectedProjectRoot != nil
            || usageFilter != .all
            || !effectiveHiddenSources.isEmpty
            || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func rows(for contextSelection: Set<SkillTableRow.ID>) -> [SkillTableRow] {
        let ids = contextSelection.isEmpty ? selection : contextSelection
        return rows.filter { ids.contains($0.id) }
    }

    private func copyPaths(_ rows: [SkillTableRow]) {
        copyToPasteboard(rows.compactMap(\.canonicalPath).uniqued().joined(separator: "\n"))
    }

    private func copyToImprove(_ rows: [SkillTableRow]) {
        copyToPasteboard(improvementPrompt(paths: rows.compactMap(\.canonicalPath)))
    }

    private func setSource(_ source: SkillSourceCategory, visible: Bool) {
        var updated = hiddenSources
        if visible {
            updated.remove(source)
        } else {
            updated.insert(source)
        }
        hiddenSourceRaw = updated.map(\.rawValue).sorted().joined(separator: ",")
        selection.removeAll()
    }

    private func migrateSourceVisibilityIfNeeded() {
        guard hiddenSourceRaw == "__unmigrated__" else { return }
        if let legacyValue = UserDefaults.standard.string(forKey: "metagent.skills.hidden-sources.v1") {
            hiddenSourceRaw = legacyValue
        } else {
            hiddenSourceRaw = SkillSourceCategory.notInstalled.rawValue
        }
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

                Picker("View", selection: selectedViewBinding) {
                    ForEach(SkillTableView.allCases) { view in
                        Text(view.title).tag(view)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 250)

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
                        model.evaluateSkillsWithPluginEval(paths: visibleInventoryRows.map(\.canonicalPath))
                    }
                    .disabled(visibleInventoryRows.isEmpty)
                } label: {
                    Label("Evaluate", systemImage: "checkmark.seal")
                }
                .buttonStyle(.glass)
                .disabled(visibleInventoryRows.isEmpty || model.isSkillEvaluating)

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
                    model.refreshUsage()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.glass)
                .help("Refresh skills and usage")
                .disabled(model.isRunning)
            }

            HStack(spacing: 10) {
                TextField("Filter skills", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 190)

                Picker("Project", selection: $selectedProjectRoot) {
                    Text("All Projects").tag(String?.none)
                    ForEach(projectFilterProjects) { project in
                        Text(projectFilterLabel(project, projects: projectFilterProjects))
                            .help(project.root)
                            .tag(Optional(project.root))
                    }
                }
                .frame(minWidth: 150, idealWidth: 190)

                Menu {
                    Button("Show All Sources") {
                        hiddenSourceRaw = ""
                        selection.removeAll()
                    }
                    .disabled(hiddenSources.isEmpty)
                    Divider()
                    ForEach(SkillSourceCategory.allCases) { source in
                        Toggle(
                            source.title,
                            isOn: Binding(
                                get: { !hiddenSources.contains(source) },
                                set: { setSource(source, visible: $0) }
                            )
                        )
                    }
                } label: {
                    Label(
                        hiddenSources.isEmpty ? "Sources" : "Sources · \(hiddenSources.count) hidden",
                        systemImage: hiddenSources.isEmpty
                            ? "line.3.horizontal.decrease.circle"
                            : "line.3.horizontal.decrease.circle.fill"
                    )
                }
                .help("Choose which skill sources are visible")

                Picker("Usage", selection: $usageFilter) {
                    ForEach(UsageFilter.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .frame(width: 170)

                Spacer()

                if selectedView == .usage {
                    Text(model.usageStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
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
                    columnCustomization: columnCustomization
                ) {
                    TableColumnForEach(skillColumnSpecs) { column in
                        TableColumn(column.title, sortUsing: column.comparator) { row in
                            if column.id == "location" {
                                SkillLocationCell(kinds: row.locationKinds, help: row.locationHelp)
                            } else if column.id == "last-used" {
                                RelativeUsageDateCell(date: row.lastUsedDate)
                                    .foregroundStyle(row.totalInvocations == 0 ? .secondary : .primary)
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
                        .width(min: column.minWidth, ideal: column.idealWidth)
                        .customizationID(column.id)
                        .defaultVisibility(column.defaultVisibility(selectedView))
                    }
                }
                .id(selectedView)
                .tableStyle(.inset)
                .alternatingRowBackgrounds(.enabled)
                .contextMenu(forSelectionType: SkillTableRow.ID.self) { contextSelection in
                    let contextRows = rows(for: contextSelection)
                    let removableRows = contextRows.compactMap(\.inventory).filter { $0.removalRequest != nil }
                    let paths = contextRows.compactMap(\.canonicalPath)
                    let openableURLs = skillDirectoryURLs(for: contextRows)
                    let openWithApplications = applicationsForOpening(openableURLs)
                    Button("Open", systemImage: "folder") {
                        openSkillDirectories(openableURLs)
                    }
                    .disabled(openableURLs.isEmpty)
                    Menu("Open With", systemImage: "square.and.arrow.up") {
                        ForEach(openWithApplications) { application in
                            Button {
                                openSkillDirectories(openableURLs, with: application.url)
                            } label: {
                                Label {
                                    Text(application.name)
                                } icon: {
                                    Image(nsImage: application.icon)
                                }
                            }
                        }
                    }
                    .disabled(openableURLs.isEmpty || openWithApplications.isEmpty)
                    Divider()
                    Button("Copy Path", systemImage: "doc.on.doc") {
                        copyPaths(contextRows)
                    }
                    .disabled(paths.isEmpty)
                    Button("Copy to Improve", systemImage: "wand.and.sparkles") {
                        copyToImprove(contextRows)
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
        .onAppear {
            migrateSourceVisibilityIfNeeded()
            sortOrder = defaultSortOrder(for: selectedView)
        }
        .onChange(of: selectedViewRaw) { _, rawValue in
            let view = SkillTableView(rawValue: rawValue) ?? .inventory
            selection.formIntersection(Set(rows.map(\.id)))
            sortOrder = defaultSortOrder(for: view)
        }
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

    private func defaultSortOrder(for view: SkillTableView) -> [KeyPathComparator<SkillTableRow>] {
        switch view {
        case .inventory:
            [KeyPathComparator(\SkillTableRow.skillName)]
        case .usage:
            [KeyPathComparator(\SkillTableRow.totalInvocations, order: .reverse)]
        case .review:
            [KeyPathComparator(\SkillTableRow.metagentScoreSortValue)]
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

private enum MCPInventoryFilter: String, CaseIterable, Identifiable {
    case all
    case attention
    case configured
    case disabled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .attention: "Needs attention"
        case .configured: "Configured"
        case .disabled: "Disabled"
        }
    }

    func includes(_ row: MCPInventoryRow) -> Bool {
        switch self {
        case .all: true
        case .attention: row.state.needsAttention
        case .configured: row.state == .configured
        case .disabled: row.state == .disabled
        }
    }
}

private struct MCPInventoryRow: Identifiable {
    let entry: MCPInventoryEntry

    var id: String { entry.id }
    var name: String { entry.name }
    var clients: [MCPClient] { entry.clients }
    var state: MCPConnectionState { entry.state }
    var clientsSortValue: String { clients.map(\.displayName).joined(separator: ", ") }
    var statusSortValue: Int {
        switch state {
        case .unavailable: 0
        case .needsSignIn: 1
        case .pendingApproval: 2
        case .disabled: 3
        case .configured: 4
        }
    }
    var statusLabel: String {
        switch state {
        case .configured: "Configured"
        case .disabled: "Disabled"
        case .pendingApproval: "Pending approval"
        case .needsSignIn: "Needs sign-in"
        case .unavailable: "Unavailable"
        }
    }
    var scopeLabel: String {
        let global = !entry.globalClients.isEmpty
        let projects = entry.projectPaths.count
        return switch (global, projects) {
        case (true, 0): "Global"
        case (true, 1): "Global + 1 project"
        case (true, _): "Global + \(projects) projects"
        case (false, 1): "1 project"
        case (false, let count) where count > 1: "\(count) projects"
        default: "Client config"
        }
    }
    var scopeHelp: String {
        guard !entry.projectPaths.isEmpty else {
            return entry.globalClients.isEmpty
                ? "Discovered in client configuration."
                : "Available from global client configuration."
        }
        return entry.projectPaths.joined(separator: "\n")
    }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return ([name, clientsSortValue, statusLabel, scopeLabel] + entry.projectPaths)
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

private struct MCPInventorySection: View {
    @ObservedObject var model: MetagentModel
    @State private var searchText = ""
    @State private var filter = MCPInventoryFilter.all
    @State private var sortOrder = [KeyPathComparator(\MCPInventoryRow.name)]

    private var allRows: [MCPInventoryRow] {
        model.mcpHealth.inventory.map(MCPInventoryRow.init)
    }

    private var rows: [MCPInventoryRow] {
        allRows
            .filter { filter.includes($0) && $0.matches(searchText) }
            .sorted(using: sortOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MCPs")
                        .font(.title2.weight(.semibold))
                    Text("\(allRows.count) servers across Codex and Claude")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                TextField("Search MCPs", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)

                Picker("Status", selection: $filter) {
                    ForEach(MCPInventoryFilter.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .frame(width: 155)

                Button {
                    model.refreshMCPHealth()
                } label: {
                    if model.isMCPRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.glass)
                .disabled(model.isMCPRefreshing)
                .help("Refresh passive MCP inventory")
                .accessibilityLabel("Refresh MCP inventory")
            }

            if rows.isEmpty {
                EmptyStateView(
                    title: allRows.isEmpty ? "No MCP servers found" : "No matching MCPs",
                    message: allRows.isEmpty
                        ? "Refresh after configuring an MCP server in Codex or Claude."
                        : "Clear the search or choose a different status.",
                    symbol: "server.rack"
                )
            } else {
                Table(rows, sortOrder: $sortOrder) {
                    TableColumn("MCP", value: \.name) { row in
                        Text(row.name)
                            .font(.callout.weight(.medium))
                            .help(row.name)
                    }
                    .width(min: 220, ideal: 320)

                    TableColumn("Clients", value: \.clientsSortValue) { row in
                        MCPClientIcons(clients: row.clients)
                    }
                    .width(min: 90, ideal: 120)

                    TableColumn("Status", value: \.statusSortValue) { row in
                        MCPStateCell(state: row.state, label: row.statusLabel)
                    }
                    .width(min: 140, ideal: 170)

                    TableColumn("Scope", value: \.scopeLabel) { row in
                        Text(row.scopeLabel)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .help(row.scopeHelp)
                    }
                    .width(min: 150, ideal: 240)
                }
                .tableStyle(.inset)
                .alternatingRowBackgrounds(.enabled)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct MCPMenuSection: View {
    @ObservedObject var model: MetagentModel
    let openMainWindow: () -> Void

    private var rows: [MCPInventoryRow] {
        model.mcpHealth.inventory.map(MCPInventoryRow.init)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("MCPs")
                    .font(.headline)
                Spacer()
                Button(action: openMainWindow) {
                    Label("Window", systemImage: "macwindow")
                }
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                MetricView(title: "Servers", value: "\(rows.count)", symbol: "server.rack")
                MetricView(
                    title: "Attention",
                    value: "\(rows.filter { $0.state.needsAttention }.count)",
                    symbol: "exclamationmark.triangle"
                )
            }

            Button(action: openMainWindow) {
                Label("Open MCPs", systemImage: "arrow.up.right.square")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)

            Spacer()
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct MCPClientIcons: View {
    let clients: [MCPClient]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(clients, id: \.self) { client in
                if let icon = AppBrand.applicationIcon(bundleIdentifier: bundleIdentifier(for: client)) {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .help(client.displayName)
                } else {
                    Image(systemName: client == .codex ? "sparkles" : "link")
                        .frame(width: 18, height: 18)
                        .help(client.displayName)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(clients.map(\.displayName).joined(separator: ", "))
    }

    private func bundleIdentifier(for client: MCPClient) -> String {
        switch client {
        case .codex: "com.openai.codex"
        case .claude: "com.anthropic.claudefordesktop"
        }
    }
}

private struct MCPStateCell: View {
    let state: MCPConnectionState
    let label: String

    var body: some View {
        Label(label, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(tint)
    }

    private var symbol: String {
        switch state {
        case .configured: "checkmark.circle"
        case .disabled: "pause.circle"
        case .pendingApproval: "questionmark.circle"
        case .needsSignIn: "person.crop.circle.badge.exclamationmark"
        case .unavailable: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch state {
        case .configured: .green
        case .disabled: .secondary
        case .pendingApproval, .needsSignIn: .orange
        case .unavailable: .red
        }
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
            Dictionary(grouping: project.skills, by: canonicalSkillIdentity).values.map { variants in
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

    private static func canonicalSkillIdentity(_ skill: SkillStatus) -> String {
        if let pluginKey = pluginUsageMatchKey(skill) {
            return "plugin:\(pluginKey)"
        }
        if !skill.canonicalPath.isEmpty {
            return "path:\(standardizedDirectory(skill.canonicalPath))"
        }
        return "installed:\(skill.location):\(standardizedDirectory(skill.path))"
    }

    var id: String {
        "\(project.root):\(Self.canonicalSkillIdentity(skill))"
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
        if let standaloneVariant = variants.first(where: { variant in
            ["codex", "claude"].contains(variant.manager)
                && variant.representation == "canonical"
                && MetagentCore.canUninstallStandaloneSkill(
                    projectRoot: project.root,
                    skillPath: variant.path,
                    skillName: variant.name
                )
        })
        {
            return SkillRemovalRequest(
                id: "standalone:\(standaloneVariant.path)",
                displayName: standaloneVariant.name,
                kind: .standalone(
                    projectRoot: project.root,
                    skillPath: standaloneVariant.path,
                    skillName: standaloneVariant.name
                )
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

private struct SkillColumnSpec: Identifiable {
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

@MainActor private let skillColumnSpecs: [SkillColumnSpec] = [
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
        id: "project",
        title: "Project",
        comparator: KeyPathComparator(\SkillTableRow.projectName),
        minWidth: 120,
        idealWidth: 160,
        isNumeric: false,
        isMonospaced: false,
        isPrimary: false,
        defaultViews: [.inventory],
        value: \.projectName,
        help: { $0.projectRoot ?? "No installed project" }
    ),
    SkillColumnSpec(
        id: "location",
        title: "Location",
        comparator: KeyPathComparator(\SkillTableRow.locationLabel),
        minWidth: 64,
        idealWidth: 76,
        isNumeric: false,
        isMonospaced: false,
        isPrimary: false,
        defaultViews: [],
        value: \.locationLabel,
        help: \.locationHelp
    ),
    SkillColumnSpec(
        id: "origin",
        title: "Source",
        comparator: KeyPathComparator(\SkillTableRow.sourceText),
        minWidth: 120,
        idealWidth: 170,
        isNumeric: false,
        isMonospaced: false,
        isPrimary: false,
        defaultViews: [.inventory, .review],
        symbol: { $0.sourceSymbol },
        value: \.sourceText,
        help: \.sourceHelp
    ),
    SkillColumnSpec(
        id: "metagent-score",
        title: "Metagent",
        comparator: KeyPathComparator(\SkillTableRow.metagentScoreSortValue),
        minWidth: 82,
        idealWidth: 94,
        isNumeric: true,
        isMonospaced: false,
        isPrimary: false,
        defaultViews: [.inventory, .review],
        showsBadge: true,
        tint: { $0.metagentScoreTint },
        value: \.metagentScoreText,
        help: \.metagentScoreHelp
    ),
    SkillColumnSpec(
        id: "plugin-eval",
        title: "Plugin Eval",
        comparator: KeyPathComparator(\SkillTableRow.pluginEvalSortValue),
        minWidth: 90,
        idealWidth: 104,
        isNumeric: true,
        isMonospaced: false,
        isPrimary: false,
        defaultViews: [.inventory, .review],
        showsBadge: true,
        tint: \.pluginEvalTint,
        value: \.pluginEvalText,
        help: \.pluginEvalHelp
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
        defaultViews: [.inventory],
        value: { $0.tokenEstimate < 0 ? "—" : formatNumber($0.tokenEstimate) },
        help: { $0.tokenEstimate < 0 ? "Not available for an uninstalled skill." : formatNumber($0.tokenEstimate) }
    ),
    SkillColumnSpec(
        id: "scope",
        title: "Scope",
        comparator: KeyPathComparator(\SkillTableRow.scope),
        minWidth: 48,
        idealWidth: 56,
        isNumeric: false,
        isMonospaced: false,
        isPrimary: false,
        defaultViews: [.usage],
        symbol: { $0.scopeSymbol },
        value: { _ in "" },
        help: \.scopeLabel
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
        title: "30d",
        comparator: KeyPathComparator(\SkillTableRow.invocations30d),
        minWidth: 54,
        idealWidth: 64,
        isNumeric: true,
        isMonospaced: false,
        isPrimary: false,
        defaultViews: [.usage],
        value: { $0.invocations30d.formatted() },
        help: { "\($0.invocations30d.formatted()) reads in the last 30 days" }
    ),
    SkillColumnSpec(
        id: "all",
        title: "All",
        comparator: KeyPathComparator(\SkillTableRow.totalInvocations),
        minWidth: 54,
        idealWidth: 64,
        isNumeric: true,
        isMonospaced: false,
        isPrimary: false,
        defaultViews: [.usage],
        value: { $0.totalInvocations.formatted() },
        help: { "\($0.totalInvocations.formatted()) observed reads" }
    ),
    SkillColumnSpec(
        id: "tasks",
        title: "Tasks",
        comparator: KeyPathComparator(\SkillTableRow.distinctThreads),
        minWidth: 58,
        idealWidth: 68,
        isNumeric: true,
        isMonospaced: false,
        isPrimary: false,
        defaultViews: [],
        value: { $0.distinctThreads.formatted() },
        help: { "\($0.distinctThreads.formatted()) distinct Codex tasks" }
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

private struct SkillLocationCell: View {
    let kinds: [SkillLocationKind]
    let help: String

    var body: some View {
        HStack(spacing: 5) {
            ForEach(kinds) { kind in
                if let bundleIdentifier = kind.bundleIdentifier,
                   let icon = AppBrand.applicationIcon(bundleIdentifier: bundleIdentifier)
                {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 17, height: 17)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                } else {
                    Image(systemName: kind.fallbackSymbol)
                        .foregroundStyle(.secondary)
                        .frame(width: 17, height: 17)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kinds.map(\.title).joined(separator: ", "))
        .accessibilityHint(help)
    }
}

private struct RelativeUsageDateCell: View {
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

private func formatNumber(_ value: Int) -> String {
    value.formatted()
}

private func copyToPasteboard(_ text: String) {
    guard !text.isEmpty else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}

private struct SkillOpeningApplication: Identifiable {
    let url: URL
    let name: String
    let icon: NSImage

    var id: String { url.path }
}

private func skillDirectoryURLs(for rows: [SkillTableRow]) -> [URL] {
    rows.filter { $0.inventory != nil }.compactMap(\.canonicalPath).compactMap { path in
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return url
    }.uniqued()
}

@MainActor private func applicationsForOpening(_ urls: [URL]) -> [SkillOpeningApplication] {
    guard let firstURL = urls.first else { return [] }
    let candidateSets = urls.map { url in
        Set(NSWorkspace.shared.urlsForApplications(toOpen: url).map { $0.standardizedFileURL.path })
    }
    let commonPaths = candidateSets.dropFirst().reduce(candidateSets[0]) { $0.intersection($1) }
    return NSWorkspace.shared.urlsForApplications(toOpen: firstURL)
        .filter { commonPaths.contains($0.standardizedFileURL.path) }
        .map { applicationURL in
            let bundle = Bundle(url: applicationURL)
            let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? applicationURL.deletingPathExtension().lastPathComponent
            return SkillOpeningApplication(
                url: applicationURL,
                name: name,
                icon: NSWorkspace.shared.icon(forFile: applicationURL.path)
            )
        }
        .uniqued(by: \.id)
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

@MainActor private func openSkillDirectories(_ urls: [URL], with applicationURL: URL? = nil) {
    guard !urls.isEmpty else { return }
    guard let applicationURL else {
        urls.forEach { NSWorkspace.shared.open($0) }
        return
    }
    NSWorkspace.shared.open(
        urls,
        withApplicationAt: applicationURL,
        configuration: NSWorkspace.OpenConfiguration()
    ) { _, error in
        if error != nil { NSSound.beep() }
    }
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

private extension Sequence {
    func uniqued<Value: Hashable>(by keyPath: KeyPath<Element, Value>) -> [Element] {
        var seen = Set<Value>()
        return filter { seen.insert($0[keyPath: keyPath]).inserted }
    }
}

private struct RepairSection: View {
    @ObservedObject var model: MetagentModel
    let projectRoot: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Resolve cleanup")
                        .font(.title2.weight(.semibold))
                    Text("Review the exact changes before applying them.")
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
            } else if !model.lastOutputLines.isEmpty {
                CleanupFailureView(
                    lines: model.lastOutputLines,
                    onRetry: { model.previewRepair(projectRoot: projectRoot) },
                    onCopy: model.copyLastOutput
                )
            } else {
                Button {
                    model.previewRepair(projectRoot: projectRoot)
                } label: {
                    Label("Preview cleanup", systemImage: "doc.text.magnifyingglass")
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

private struct CleanupFailureView: View {
    let lines: [String]
    let onRetry: () -> Void
    let onCopy: () -> Void
    @State private var showsDetails = false

    private var changedAfterPreview: Bool {
        lines.contains { $0.localizedCaseInsensitiveContains("changed after preview") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(
                changedAfterPreview ? "Cleanup changed" : "Cleanup couldn’t be prepared",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.title3.weight(.semibold))
            .foregroundStyle(Color.orange)

            Text(changedAfterPreview
                ? "The files changed after Metagent prepared the preview. Preview them again before applying anything."
                : "Metagent couldn’t prepare a safe cleanup preview. Try again, then inspect the details if it still fails.")
                .foregroundStyle(.secondary)

            Button("Preview again", action: onRetry)
                .buttonStyle(.glassProminent)

            DisclosureGroup("Technical details", isExpanded: $showsDetails) {
                VStack(alignment: .trailing, spacing: 8) {
                    RawOutputBlock(title: nil, lines: Array(lines.prefix(18)))
                    Button("Copy details", systemImage: "doc.on.doc", action: onCopy)
                        .buttonStyle(.glass)
                }
                .padding(.top, 8)
            }
            .font(.caption.weight(.medium))

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                    Label("Apply cleanup", systemImage: "checkmark.circle")
                }
                .buttonStyle(.glassProminent)
                .disabled(!preview.canApply)
                .help(preview.canApply ? "Apply only the reviewed cleanup actions" : "No cleanup actions to apply")

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
