import AppKit
import Foundation
import MetagentCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct MetagentMenuBarApp: App {
    @StateObject private var model = MetagentModel()
    @State private var selectedSection = PanelSection.overview
    @State private var selectedProjectRoot: String?

    var body: some Scene {
        WindowGroup("Metagent", id: "main") {
            MetagentPanel(
                model: model,
                showsOpenWindowButton: false,
                selectedSection: $selectedSection,
                selectedProjectRoot: $selectedProjectRoot
            )
                .frame(minWidth: 1040, idealWidth: 1180, minHeight: 680, idealHeight: 760)
        }
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra {
            MetagentPanel(
                model: model,
                showsOpenWindowButton: true,
                selectedSection: $selectedSection,
                selectedProjectRoot: $selectedProjectRoot
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

@MainActor private enum AppBrand {
    static let menuBarIcon: NSImage? = {
        loadMenuBarIcon(in: .main) ?? loadMenuBarIcon(in: .module)
    }()

    private static let applicationIcons: [String: NSImage] = {
        ["com.openai.codex", "com.anthropic.claudefordesktop"].reduce(into: [:]) { icons, bundleIdentifier in
            guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
                return
            }
            icons[bundleIdentifier] = NSWorkspace.shared.icon(forFile: applicationURL.path)
        }
    }()

    private static let skillIcons = NSCache<NSString, NSImage>()

    static func applicationIcon(bundleIdentifier: String) -> NSImage? {
        applicationIcons[bundleIdentifier]
    }

    static func skillIcon(path: String?) -> NSImage? {
        guard let path, !path.isEmpty else { return nil }
        let key = path as NSString
        if let cached = skillIcons.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        skillIcons.setObject(image, forKey: key)
        return image
    }

    static func clearSkillIconCache() {
        skillIcons.removeAllObjects()
    }

    private static func loadMenuBarIcon(in bundle: Bundle) -> NSImage? {
        guard let url = bundle.url(forResource: "MenuBarIconTemplate", withExtension: "pdf"),
              let image = NSImage(contentsOf: url)
        else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }
}

private struct MetagentPanel: View {
    @ObservedObject var model: MetagentModel
    let showsOpenWindowButton: Bool
    @Environment(\.openWindow) private var openWindow
    @Binding var selectedSection: PanelSection
    @Binding var selectedProjectRoot: String?

    private var directoryOptions: [DirectoryFilterOption] {
        directoryFilterOptions(
            projects: model.projects,
            mcpHealth: model.mcpHealth,
            doctorIssues: model.doctorIssues
        )
    }

    var body: some View {
        ZStack {
            PanelBackdrop()

            VStack(alignment: .leading, spacing: showsOpenWindowButton ? 12 : 14) {
                topBar
                panelContent
                    .animation(.snappy(duration: 0.25), value: selectedSection)

                if showsOpenWindowButton {
                    compactFooter
                }
            }
            .padding(.horizontal, showsOpenWindowButton ? 16 : 18)
            .padding(.top, showsOpenWindowButton ? 16 : 10)
            .padding(.bottom, showsOpenWindowButton ? 16 : 18)
        }
        .buttonBorderShape(.capsule)
        .onChange(of: directoryOptions.map(\.root)) { _, roots in
            if let selectedProjectRoot, !roots.contains(selectedProjectRoot) {
                self.selectedProjectRoot = nil
            }
        }
    }

    @ViewBuilder
    private var topBar: some View {
        if showsOpenWindowButton {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    brandMark
                    directoryScopeControl
                    Spacer(minLength: 0)
                    statusFailureControl
                    settingsControl
                }
                navigation
            }
        } else {
            HStack(spacing: 10) {
                brandMark
                directoryScopeControl
                navigation
                statusFailureControl
                settingsControl
            }
        }
    }

    private var brandMark: some View {
        MenuBarIcon()
            .frame(width: 36, height: 36)
            .padding(3)
            .help("Metagent")
            .accessibilityLabel("Metagent")
    }

    @ViewBuilder
    private var statusFailureControl: some View {
        if !model.isRunning,
           model.statusText.localizedCaseInsensitiveContains("failed")
        {
            Button {
                model.openLogs()
            } label: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .frame(width: 20)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .frame(width: 46, height: 42)
            .help("\(model.statusText). Open logs.")
            .accessibilityLabel("\(model.statusText). Open logs.")
        }
    }

    private var directoryScopeControl: some View {
        Menu {
            Button {
                selectedProjectRoot = nil
            } label: {
                if selectedProjectRoot == nil {
                    Label("All directories", systemImage: "checkmark")
                } else {
                    Text("All directories")
                }
            }
            Divider()
            ForEach(directoryOptions) { directory in
                Button {
                    selectedProjectRoot = directory.root
                } label: {
                    if selectedProjectRoot == directory.root {
                        Label(
                            directoryFilterLabel(directory, options: directoryOptions),
                            systemImage: "checkmark"
                        )
                    } else {
                        Text(directoryFilterLabel(directory, options: directoryOptions))
                    }
                }
            }
        } label: {
            Label(selectedDirectoryLabel, systemImage: "scope")
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .frame(
                    minWidth: showsOpenWindowButton ? 180 : 205,
                    idealWidth: showsOpenWindowButton ? 205 : 240,
                    maxWidth: showsOpenWindowButton ? 240 : 285,
                    alignment: .leading
                )
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .frame(height: 42)
        .help(selectedProjectRoot.map(displayUserPath) ?? "Show all directories")
        .accessibilityLabel("Directory")
    }

    private var settingsControl: some View {
        Menu {
            Button("Open Configuration", systemImage: "slider.horizontal.3") {
                model.openConfig()
            }
            Button("Open Logs", systemImage: "doc.text") {
                model.openLogs()
            }
        } label: {
            Image(systemName: "gearshape")
                .frame(width: 20)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .frame(width: 46, height: 42)
        .help("Settings and diagnostics")
        .accessibilityLabel("Settings and diagnostics")
    }

    private var selectedDirectoryLabel: String {
        guard let selectedProjectRoot,
              let directory = directoryOptions.first(where: { $0.root == selectedProjectRoot })
        else {
            return "All directories"
        }
        return directoryFilterLabel(directory, options: directoryOptions)
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
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var panelContent: some View {
        switch selectedSection {
        case .overview:
            OverviewSection(model: model, isCompact: showsOpenWindowButton, selectedProjectRoot: selectedProjectRoot)
        case .skills:
            if showsOpenWindowButton {
                SkillsMenuSection(model: model, selectedProjectRoot: selectedProjectRoot) {
                    openWindow(id: "main")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
            } else {
                InventorySection(model: model, selectedProjectRoot: selectedProjectRoot)
            }
        case .mcps:
            if showsOpenWindowButton {
                MCPMenuSection(model: model, selectedProjectRoot: selectedProjectRoot) {
                    openWindow(id: "main")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
            } else {
                MCPInventorySection(model: model, selectedProjectRoot: selectedProjectRoot)
            }
        case .projects:
            if showsOpenWindowButton {
                ProjectsMenuSection(model: model, selectedProjectRoot: selectedProjectRoot) {
                    openWindow(id: "main")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
            } else {
                ProjectsSection(model: model, selectedProjectRoot: selectedProjectRoot)
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
        if isSelected {
            button
                .buttonStyle(.glassProminent)
        } else {
            button
                .buttonStyle(.glass)
        }
    }

    private var button: some View {
        Button(action: action) {
            Label(section.title, systemImage: section.symbol)
                .font(.callout.weight(isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .contentShape(Capsule())
        }
        .controlSize(.large)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct GlassSearchField: View {
    let placeholder: String
    @Binding var text: String
    let width: CGFloat

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 11)
        .frame(width: width, height: 34)
        .glassEffect(.regular, in: Capsule())
    }
}

private enum PanelSection: String, CaseIterable, Identifiable {
    case overview
    case skills
    case mcps
    case projects

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .skills: "Skills"
        case .mcps: "MCPs"
        case .projects: "Projects"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge"
        case .skills: "sparkles"
        case .mcps: "server.rack"
        case .projects: "folder"
        }
    }
}

private struct OverviewSection: View {
    @ObservedObject var model: MetagentModel
    let isCompact: Bool
    let selectedProjectRoot: String?
    @State private var showsDoctorFindings = false
    @State private var showsRepair = false
    @State private var showsMCPDetails = false
    @State private var repairProjectRoot: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            mcpConnections
            if doctorActionCount > 0 {
                cleanupStatus
            }
            summary
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $showsDoctorFindings) {
            DoctorFindingsView(model: model, findings: doctorFindings) { projectRoot in
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
                if scopedMCPHealth.observedAt == .distantPast {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 28)
                } else {
                    Image(systemName: scopedMCPHealth.attention.isEmpty
                        ? "checkmark.circle.fill"
                        : "exclamationmark.triangle.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(scopedMCPHealth.attention.isEmpty ? Color.green : Color.orange)
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
                        count: scopedMCPHealth.count(for: .codex)
                    )
                    MCPClientCount(
                        client: .claude,
                        count: scopedMCPHealth.count(for: .claude)
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
        return groupedMCPRows(scopedMCPHealth.attention)
    }

    private var mcpDetailRows: [MCPHealthDisplayRow] {
        groupedMCPRows(scopedMCPHealth.servers.filter {
            $0.state.needsAttention || $0.state == .disabled
        })
    }

    private var mcpSummaryText: String {
        let configured = scopedMCPHealth.configuredCount
        let attention = groupedMCPRows(scopedMCPHealth.attention).count
        guard scopedMCPHealth.observedAt != .distantPast else {
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
                if doctorActionCount > 0 {
                    if allDoctorFindingsRepairable {
                        Button {
                            repairProjectRoot = doctorFindings.first?.projectRoot
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
                value: "\(scopedSkillCount)",
                detail: selectedProjectRoot == nil ? "across \(model.repoCount) projects" : "in this directory",
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
        model.usageSnapshot.summaries
            .filter { summary in
                guard let selectedProjectRoot else { return true }
                guard summary.scope == "project" else { return false }
                guard let path = summary.canonicalPath else { return false }
                return path == selectedProjectRoot
                    || path.hasPrefix(selectedProjectRoot + "/")
            }
            .reduce(0) { $0 + $1.invocations30d }
    }

    private var healthMessage: String {
        if doctorActionCount == 1,
           let issue = doctorFindings.first
        {
            return issue.summary ?? issue.message
        }
        return "Grouped by project and resolution."
    }

    private var allDoctorFindingsRepairable: Bool {
        doctorFindings.count == 1 && doctorFindings[0].repairAction != nil
    }

    private var scopedMCPHealth: MCPHealthSnapshot {
        projectFilteredMCPHealth(model.mcpHealth, selectedProjectRoot: selectedProjectRoot)
    }

    private var doctorFindings: [DoctorIssue] {
        guard let selectedProjectRoot else { return model.doctorFindings }
        return model.doctorFindings.filter {
            $0.projectRoot.map(standardizedDirectoryPath) == selectedProjectRoot
        }
    }

    private var doctorActionCount: Int {
        groupedDoctorActionCount(doctorFindings)
    }

    private var scopedSkillCount: Int {
        guard let selectedProjectRoot else { return model.skillCount }
        return logicalSkillCount(projects: model.projects, selectedProjectRoot: selectedProjectRoot)
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
    let findings: [DoctorIssue]
    let onPreviewRepair: (String?) -> Void
    @Environment(\.dismiss) private var dismiss

    private var groups: [DoctorProjectGroup] {
        DoctorProjectGroup.groups(from: findings)
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
                            .help(project.root.map(displayUserPath) ?? "General findings")
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
        let actionCount = groupedDoctorActionCount(findings)
        if actionCount == 0 {
            return "No action needed."
        }
        return "\(actionCount) \(actionCount == 1 ? "cleanup" : "cleanups"), grouped by project."
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

private enum SkillScopeFilter: String, CaseIterable, Identifiable {
    case all
    case global
    case project

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All locations"
        case .global: "Global"
        case .project: "Project"
        }
    }

    func includes(_ row: SkillTableRow) -> Bool {
        switch self {
        case .all: true
        case .global: row.scope != "project"
        case .project: row.scope == "project"
        }
    }
}

private enum SkillGrouping: String, CaseIterable, Identifiable {
    case none
    case source
    case location
    case upstream

    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "No grouping"
        case .source: "Source"
        case .location: "Location"
        case .upstream: "Upstream"
        }
    }

    func title(for row: SkillTableRow) -> String {
        switch self {
        case .none: ""
        case .source: row.sourceText
        case .location: row.displaysGlobalLocation ? "Global" : row.projectName
        case .upstream: row.upstreamText == "—" ? "No upstream recorded" : row.upstreamText
        }
    }

    func key(for row: SkillTableRow) -> String {
        switch self {
        case .none: ""
        case .source: row.sourceCategory.rawValue
        case .location:
            row.displaysGlobalLocation
                ? "global"
                : "project:\(row.projectRoot ?? row.displayLocationSortValue)"
        case .upstream: row.upstreamText
        }
    }
}

private struct UsageSkillRow: Identifiable, Sendable {
    enum Status: Sendable { case active, dormant, neverObserved, insufficient }

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

private enum InventoryConfirmation: Identifiable {
    case removal([InventorySkillRow])
    case codexReview(InventorySkillRow)

    var id: String {
        switch self {
        case let .removal(rows):
            "removal:" + rows.map(\.id).sorted().joined(separator: ",")
        case let .codexReview(row):
            "codex-review:\(row.id)"
        }
    }
}

private enum SkillTableView: String, CaseIterable, Identifiable {
    case summary
    case review
    case duplicates
    case inventory
    case usage

    var id: String { rawValue }
    var title: String {
        switch self {
        case .duplicates: "Duplicates"
        default: rawValue.capitalized
        }
    }
}

private struct SkillViewSelector: View {
    @Binding var selection: SkillTableView

    var body: some View {
        Picker("View", selection: $selection) {
            ForEach(SkillTableView.allCases) { view in
                Text(view.title).tag(view)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityLabel("Skills view")
    }
}

private enum SkillSourceCategory: String, CaseIterable, Identifiable {
    case plugin
    case skillsCLI
    case dotagentsLocal
    case dotagentsManaged
    case externalCLI
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
        case .dotagentsLocal: "dotagents · external path"
        case .dotagentsManaged: "dotagents · package"
        case .externalCLI: "External CLI"
        case .codexSystem: "Codex system"
        case .codexInstalled: "Codex installed"
        case .claude: "Claude installed"
        case .local: "Local or unknown"
        case .notInstalled: "Not installed"
        }
    }

    var explanation: String {
        switch self {
        case .dotagentsLocal:
            "dotagents manages this installation from a distinct local source path. Self-referential orphan-adoption records are classified as local instead."
        case .dotagentsManaged:
            "The skill is declared as a package managed by dotagents rather than as a local path."
        case .skillsCLI:
            "Skills CLI owns this installation because its lockfile records the skill and upstream package."
        case .externalCLI:
            "A known third-party CLI owns this versioned bundle. Metagent matched a specific bundle signature rather than inferring ownership from Git or folder location."
        case .local:
            "No installer, lockfile, or independent upstream source is recorded. The skill may be locally authored or imported; ordinary Git tracking does not establish provenance."
        case .notInstalled:
            "Historical Codex usage matched this skill, but no current installed bundle matches its recorded path or identity."
        case .codexInstalled:
            "The canonical skill bundle is installed in Codex. It may also be projected into another agent."
        case .claude:
            "The canonical skill bundle is installed in Claude. It may also be projected into another agent."
        default:
            title
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
        case "external-cli": return .externalCLI
        case "codex":
            return inventory.skill.authority == "codex-system" ? .codexSystem : .codexInstalled
        case "claude": return .claude
        default: return .local
        }
    }
}

private struct SkillOverlapMembership: Sendable {
    let groupID: String
    let kind: SkillOverlapKind
    let similarity: Double
    let suggestedRemoval: Bool

    var title: String {
        switch kind {
        case .pluginReplacement: suggestedRemoval ? "Plugin replaces this" : "Plugin replacement"
        case .exactDuplicate: "Exact duplicate"
        case .globalProject: "Global + project"
        case .sameName: "Same name"
        }
    }

    var sortValue: Int {
        switch kind {
        case .pluginReplacement: 0
        case .exactDuplicate: 1
        case .globalProject: 2
        case .sameName: 3
        }
    }

    var help: String {
        let percent = (similarity * 100).rounded().formatted(.number.precision(.fractionLength(0)))
        switch kind {
        case .pluginReplacement:
            return suggestedRemoval
                ? "This global standalone bundle closely overlaps an installed plugin skill (\(percent)% content similarity). Removing the standalone copy is recommended; the plugin remains available."
                : "An installed plugin and standalone bundle closely overlap (\(percent)% content similarity). Compare the copies before removing anything."
        case .exactDuplicate:
            return "These are byte-equivalent after normalizing provider paths. Keep the copy whose scope and lifecycle owner you actually need."
        case .globalProject:
            return "The same skill name exists globally and in a project. This may be intentional so collaborators receive the project copy."
        case .sameName:
            return "Distinct installed bundles share this skill name, but their contents are not similar enough for Metagent to call one a replacement."
        }
    }
}

private struct SkillTableRow: Identifiable, Sendable {
    let inventory: InventorySkillRow?
    let usage: UsageSkillRow
    let historicalProjectRoot: String?
    let pluginInventoryAvailable: Bool
    var overlap: SkillOverlapMembership? = nil
    var groupTitle: String? = nil
    var children: [SkillTableRow]? = nil

    var id: String { groupTitle == nil ? (inventory?.id ?? "historical:\(usage.id)") : usage.id }
    var isGroup: Bool { children != nil }
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
    var scope: String { inventory?.skill.scope ?? usage.scope }
    var scopeLabel: String {
        switch scope {
        case "project": "Project"
        case "global": "Global"
        case "plugin": "Plugin"
        case "system": "System"
        default: "Unknown"
        }
    }
    var displayLocationText: String {
        scope == "project" ? projectName : ""
    }
    var displayLocationSortValue: String {
        scope == "project" ? projectName : "Global"
    }
    var displayLocationHelp: String {
        scope == "project"
            ? (projectRoot ?? projectName)
            : "Available globally · \(scopeLabel)"
    }
    var displaysGlobalLocation: Bool { scope != "project" }
    var metagentScoreSortValue: Int { inventory?.metagentStaticScore ?? -1 }
    var metagentScoreText: String { inventory?.metagentScoreText ?? "—" }
    var metagentScoreTint: Color? { inventory?.metagentScoreTint }
    var metagentScoreHelp: String { inventory?.metagentScoreHelp ?? "Not available for an uninstalled skill." }
    var portfolioScoreSortValue: Int { inventory?.utilityScore ?? -1 }
    var portfolioScoreText: String { inventory?.portfolioScoreText ?? "—" }
    var portfolioScoreTint: Color? { inventory?.portfolioScoreTint }
    var portfolioScoreHelp: String { inventory?.portfolioScoreHelp ?? "Not available for an uninstalled skill." }
    var pluginEvalSortValue: Int { inventory?.pluginEvalSortValue ?? -1 }
    var pluginEvalText: String { inventory?.pluginEvalText ?? "—" }
    var pluginEvalTint: Color? { inventory?.pluginEvalTint }
    var pluginEvalHelp: String { inventory?.pluginEvalHelp ?? "Not available for an uninstalled skill." }
    var codexReviewSortValue: Int { inventory?.codexReviewSortValue ?? -1 }
    var codexReviewText: String { inventory?.codexReviewText ?? "—" }
    var codexReviewTint: Color? { inventory?.codexReviewTint }
    var codexReviewHelp: String { inventory?.codexReviewHelp ?? "Not available for an uninstalled skill." }
    var tokenEstimate: Int { inventory?.tokenEstimate ?? -1 }
    var descriptionText: String { inventory?.descriptionText ?? "—" }
    var descriptionHelp: String { inventory?.descriptionHelp ?? "Not available for an uninstalled skill." }
    var upstreamText: String { inventory?.upstreamText ?? "—" }
    var upstreamHelp: String { inventory?.upstreamHelp ?? "No installed source metadata is available." }
    var versionText: String { inventory?.versionText ?? "—" }
    var versionHelp: String { inventory?.versionHelp ?? "No installed version metadata is available." }
    var updatedDate: Date? { inventory?.updatedDate }
    var updatedSortValue: Int { inventory?.weeksOld ?? Int.max }
    var updatedText: String { inventory?.updatedText ?? "—" }
    var updatedHelp: String { inventory?.updatedHelp ?? "No installed update metadata is available." }
    var referenceFileCount: Int { inventory?.referenceFileCount ?? -1 }
    var scriptFileCount: Int { inventory?.scriptFileCount ?? -1 }
    var skillIconPath: String? { inventory?.skillIconPath }
    var totalInvocations: Int { usage.totalInvocations }
    var invocations7d: Int { usage.invocations7d }
    var invocations30d: Int { usage.invocations30d }
    var distinctThreads: Int { usage.distinctThreads }
    var readsPerThread: Double {
        guard distinctThreads > 0 else { return 0 }
        return Double(totalInvocations) / Double(distinctThreads)
    }
    var readsPerThreadText: String {
        guard distinctThreads > 0 else { return "—" }
        return readsPerThread.formatted(.number.precision(.fractionLength(1)))
    }
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
    var overlapSortValue: Int { overlap?.sortValue ?? Int.max }
    var overlapText: String { overlap?.title ?? "—" }
    var overlapHelp: String { overlap?.help ?? "No duplicate or overlapping installation detected." }

    func matches(_ query: String) -> Bool {
        [
            skillName,
            projectName,
            locationLabel,
            sourceText,
            scopeLabel,
            descriptionText,
            upstreamText,
            versionText,
            metagentScoreText,
            pluginEvalText,
            codexReviewText,
        ]
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }

    static func rows(
        inventoryRows: [InventorySkillRow],
        usageRows: [UsageSkillRow],
        projectRoots: [String],
        pluginInventoryAvailable: Bool,
        isBackfillComplete: Bool,
        overlaps: [SkillOverlapGroup]
    ) -> [SkillTableRow] {
        let usageByPath = Dictionary(grouping: usageRows.compactMap { row -> (String, UsageSkillRow)? in
            guard let path = row.canonicalPath else { return nil }
            return (standardizedDirectoryPath(path), row)
        }, by: \.0).compactMapValues { $0.first?.1 }
        let usageByPlugin = Dictionary(grouping: usageRows.compactMap { row in
            pluginUsageMatchKey(id: row.id, canonicalPath: row.canonicalPath).map { ($0, row) }
        }, by: \.0).compactMapValues { $0.first?.1 }
        var matchedUsageIDs = Set<String>()
        let overlapsByPath = Dictionary(
            overlaps.flatMap { group in
                group.members.map { member in
                    (
                        standardizedDirectoryPath(member.canonicalPath),
                        SkillOverlapMembership(
                            groupID: group.id,
                            kind: group.kind,
                            similarity: group.similarity,
                            suggestedRemoval: member.suggestedRemoval
                        )
                    )
                }
            },
            uniquingKeysWith: { first, _ in first }
        )

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
                pluginInventoryAvailable: pluginInventoryAvailable,
                overlap: inventory.skill.representation == "projection"
                    ? nil
                    : overlapsByPath[standardizedDirectoryPath(inventory.canonicalPath)]
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

    static func group(id: String, title: String, children: [SkillTableRow]) -> SkillTableRow {
        SkillTableRow(
            inventory: nil,
            usage: UsageSkillRow(
                id: "group:\(id)",
                skillName: title,
                canonicalPath: nil,
                scope: "group",
                totalInvocations: 0,
                invocations7d: 0,
                invocations30d: 0,
                distinctThreads: 0,
                repeatInvocations: 0,
                lastUsedDate: nil,
                lastUsedSortValue: -.infinity,
                status: .insufficient
            ),
            historicalProjectRoot: nil,
            pluginInventoryAvailable: true,
            groupTitle: title,
            children: children
        )
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

private struct DuplicateReviewGroup: Identifiable {
    let id: String
    let kind: SkillOverlapKind
    let similarity: Double
    let rows: [SkillTableRow]

    var skillName: String { rows.first?.skillName ?? "Unnamed skill" }
    var suggestedRemovalRows: [SkillTableRow] {
        rows.filter { $0.overlap?.suggestedRemoval == true && $0.inventory?.removalRequest != nil }
    }
    var similarityText: String {
        similarity.formatted(.percent.precision(.fractionLength(0)))
    }
    var recommendationTitle: String {
        switch kind {
        case .pluginReplacement:
            suggestedRemovalRows.isEmpty
                ? "Compare the plugin and standalone copies"
                : "Keep the plugin; remove the standalone copy"
        case .exactDuplicate:
            "Choose one canonical copy"
        case .globalProject:
            "Keeping both may be intentional"
        case .sameName:
            "Compare before removing anything"
        }
    }
    var recommendationDetail: String {
        switch kind {
        case .pluginReplacement:
            suggestedRemovalRows.isEmpty
                ? "The contents overlap, but Metagent cannot safely choose a removable standalone copy."
                : "The plugin owns updates and remains available. The selected standalone bundle is redundant."
        case .exactDuplicate:
            "The contents match. Keep the copy whose location and lifecycle owner you want."
        case .globalProject:
            "A project copy can be useful for collaborators even when you also keep the skill globally."
        case .sameName:
            "These bundles share a name but differ enough that one is not a safe replacement for the other."
        }
    }
    var symbol: String {
        switch kind {
        case .pluginReplacement: "powerplug.fill"
        case .exactDuplicate: "square.on.square"
        case .globalProject: "folder.badge.plus"
        case .sameName: "questionmark.diamond"
        }
    }
}

private struct InventorySection: View {
    @ObservedObject var model: MetagentModel
    let selectedProjectRoot: String?
    @State private var selection = Set<SkillTableRow.ID>()
    @State private var sortOrder = [KeyPathComparator(\SkillTableRow.skillName)]
    @State private var cachedRows: [SkillTableRow] = []
    @State private var query = ""
    @State private var usageFilter = UsageFilter.all
    @State private var scopeFilter = SkillScopeFilter.all
    @State private var pendingConfirmation: InventoryConfirmation?
    @State private var inspectedSkill: InventorySkillRow?
    @State private var viewedSkill: InventorySkillRow?
    @State private var iconTarget: InventorySkillRow?
    @State private var showsScoreExplanation = false
    @State private var selectedDuplicateGroupID: String?
    @State private var duplicateRemovalIDs = Set<SkillTableRow.ID>()
    @State private var reviewedDuplicateGroupIDs = Set<String>()
    @AppStorage("metagent.skills.view.v2") private var selectedViewRaw = SkillTableView.summary.rawValue
    @AppStorage("metagent.skills.grouping.v1") private var groupingRaw = SkillGrouping.none.rawValue
    @AppStorage("metagent.skills.hidden-sources.v2")
    private var hiddenSourceRaw = "__unmigrated__"
    @SceneStorage("metagent.skills.inventory.columns.v3")
    private var inventoryColumnCustomization = TableColumnCustomization<SkillTableRow>()
    @SceneStorage("metagent.skills.summary.columns.v4")
    private var summaryColumnCustomization = TableColumnCustomization<SkillTableRow>()
    @SceneStorage("metagent.skills.usage.columns.v3")
    private var usageColumnCustomization = TableColumnCustomization<SkillTableRow>()
    @SceneStorage("metagent.skills.review.columns.v2")
    private var reviewColumnCustomization = TableColumnCustomization<SkillTableRow>()
    @SceneStorage("metagent.skills.duplicates.columns.v1")
    private var duplicateColumnCustomization = TableColumnCustomization<SkillTableRow>()

    private var selectedView: SkillTableView {
        SkillTableView(rawValue: selectedViewRaw) ?? .summary
    }

    private var selectedViewBinding: Binding<SkillTableView> {
        Binding(
            get: { selectedView },
            set: { selectedViewRaw = $0.rawValue }
        )
    }

    private var grouping: SkillGrouping {
        SkillGrouping(rawValue: groupingRaw) ?? .none
    }

    private var groupingBinding: Binding<SkillGrouping> {
        Binding(
            get: { grouping },
            set: {
                groupingRaw = $0.rawValue
                selection.removeAll()
            }
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
        case .summary:
            Binding(get: { summaryColumnCustomization }, set: { summaryColumnCustomization = $0 })
        case .review:
            Binding(get: { reviewColumnCustomization }, set: { reviewColumnCustomization = $0 })
        case .duplicates:
            Binding(get: { duplicateColumnCustomization }, set: { duplicateColumnCustomization = $0 })
        case .inventory:
            Binding(get: { inventoryColumnCustomization }, set: { inventoryColumnCustomization = $0 })
        case .usage:
            Binding(get: { usageColumnCustomization }, set: { usageColumnCustomization = $0 })
        }
    }

    private var allRows: [SkillTableRow] {
        cachedRows
    }

    private var rows: [SkillTableRow] {
        let searchQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return allRows
        .filter {
            guard let removalID = $0.inventory?.removalRequest?.id else { return true }
            return !model.pendingSkillRemovalIDs.contains(removalID)
        }
        .filter { selectedView == .usage || $0.isInstalled }
        .filter { selectedView != .duplicates || $0.overlap != nil }
        .filter {
            guard let selectedProjectRoot else { return true }
            return $0.scope == "project" && $0.projectRoot == selectedProjectRoot
        }
        .filter { !hiddenSources.contains($0.sourceCategory) }
        .filter { scopeFilter.includes($0) }
        .filter { usageFilter.includes(status: $0.usageStatus, totalInvocations: $0.totalInvocations) }
        .filter { searchQuery.isEmpty || $0.matches(searchQuery) }
    }

    private var sortedRows: [SkillTableRow] {
        rows.sorted(using: sortOrder)
    }

    private var displayRows: [SkillTableRow] {
        guard grouping != .none else { return sortedRows }
        let groupedRows = Dictionary(grouping: rows, by: grouping.key(for:))
            .map { key, children in
                SkillTableRow.group(
                    id: "\(grouping.rawValue):\(key)",
                    title: children.first.map(grouping.title(for:)) ?? key,
                    children: children.sorted(using: sortOrder)
                )
            }
        return groupedRows.sorted { left, right in
            guard let leftChild = left.children?.first, let rightChild = right.children?.first else {
                return left.skillName.localizedCaseInsensitiveCompare(right.skillName) == .orderedAscending
            }
            for comparator in sortOrder {
                switch comparator.compare(leftChild, rightChild) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: continue
                }
            }
            return left.skillName.localizedCaseInsensitiveCompare(right.skillName) == .orderedAscending
        }
    }

    private var selectedRow: InventorySkillRow? {
        let resolved = resolvedRows(for: selection)
        guard resolved.count == 1 else { return nil }
        return resolved.first?.inventory
    }

    private var selectedRows: [SkillTableRow] {
        resolvedRows(for: selection)
    }

    private var selectedRemovalRows: [InventorySkillRow] {
        selectedRows.compactMap(\.inventory).filter { $0.removalRequest != nil }
    }

    private var visibleInventoryRows: [InventorySkillRow] {
        rows.compactMap(\.inventory)
    }

    private var completeVisibleDuplicateGroups: [DuplicateReviewGroup] {
        let visibleRowIDs = Set(rows.map(\.id))
        return Dictionary(grouping: allRows.compactMap { row -> SkillTableRow? in
            row.overlap == nil ? nil : row
        }, by: { $0.overlap?.groupID ?? "" })
            .compactMap { id, groupRows -> DuplicateReviewGroup? in
                guard !id.isEmpty,
                      groupRows.count > 1,
                      groupRows.allSatisfy({ visibleRowIDs.contains($0.id) }),
                      let overlap = groupRows.compactMap(\.overlap).first
                else { return nil }
                return DuplicateReviewGroup(
                    id: id,
                    kind: overlap.kind,
                    similarity: overlap.similarity,
                    rows: groupRows.sorted {
                        if $0.overlap?.suggestedRemoval != $1.overlap?.suggestedRemoval {
                            return $1.overlap?.suggestedRemoval == true
                        }
                        return $0.sourceText.localizedCaseInsensitiveCompare($1.sourceText) == .orderedAscending
                    }
                )
            }
            .sorted {
                let leftPriority = $0.rows.first?.overlap?.sortValue ?? Int.max
                let rightPriority = $1.rows.first?.overlap?.sortValue ?? Int.max
                if leftPriority != rightPriority { return leftPriority < rightPriority }
                return $0.skillName.localizedCaseInsensitiveCompare($1.skillName) == .orderedAscending
            }
    }

    private var duplicateReviewGroups: [DuplicateReviewGroup] {
        completeVisibleDuplicateGroups.filter { !reviewedDuplicateGroupIDs.contains($0.id) }
    }

    private var visibleOverlapGroupCount: Int {
        completeVisibleDuplicateGroups.count
    }

    private var hasDetectedOverlapGroups: Bool {
        allRows.contains { $0.overlap != nil }
    }

    private var hasActiveFilter: Bool {
        let effectiveHiddenSources = selectedView == .usage
            ? hiddenSources
            : hiddenSources.subtracting([.notInstalled])
        return usageFilter != .all
            || scopeFilter != .all
            || !effectiveHiddenSources.isEmpty
            || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func rows(for contextSelection: Set<SkillTableRow.ID>) -> [SkillTableRow] {
        let ids = contextSelection.isEmpty ? selection : contextSelection
        return resolvedRows(for: ids)
    }

    private func resolvedRows(for ids: Set<SkillTableRow.ID>) -> [SkillTableRow] {
        displayRows.flatMap { row -> [SkillTableRow] in
            if ids.contains(row.id) {
                return row.children ?? [row]
            }
            return row.children?.filter { ids.contains($0.id) } ?? []
        }
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
                        ? (selectedView == .duplicates
                            ? "\(visibleOverlapGroupCount) groups · \(rows.count) installed copies"
                            : "\(rows.count) visible skills")
                        : "\(selectedRows.count) selected · \(rows.count) visible")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                SkillViewSelector(selection: selectedViewBinding)
                .frame(width: 430)

                Button {
                    showsScoreExplanation = true
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.glass)
                .help("Quality = Plugin Eval 60% + management confidence 20% + optional Codex review 20%; available inputs are normalized. Utility = Quality 70% + observed adoption 30%. Click for full details.")
                .accessibilityLabel("How scores work")

                if selectedView != .duplicates {
                    Menu {
                        Button("Run Plugin Eval") {
                            if let selectedRow {
                                model.evaluateSkillWithPluginEval(path: selectedRow.canonicalPath)
                            }
                        }
                        .disabled(selectedRow == nil)
                        Button("Review with Codex") {
                            if let selectedRow {
                                pendingConfirmation = .codexReview(selectedRow)
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
                        pendingConfirmation = .removal(selectedRemovalRows)
                    } label: {
                        Label(
                            selectedRemovalRows.count > 1 ? "Remove \(selectedRemovalRows.count)" : "Remove",
                            systemImage: "trash"
                        )
                    }
                    .buttonStyle(.glass)
                    .disabled(selectedRemovalRows.isEmpty)
                }

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
                GlassSearchField(placeholder: "Filter skills", text: $query, width: 190)

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
                .buttonStyle(.glass)

                Picker("Usage", selection: $usageFilter) {
                    ForEach(UsageFilter.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .frame(width: 170)
                .buttonStyle(.glass)

                Picker("Location", selection: $scopeFilter) {
                    ForEach(SkillScopeFilter.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .frame(width: 145)
                .buttonStyle(.glass)

                if selectedView != .duplicates {
                    Picker("Group by", selection: groupingBinding) {
                        ForEach(SkillGrouping.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .frame(width: 145)
                    .buttonStyle(.glass)
                    .help("Group the current Skills view. Groups can be expanded or collapsed and apply across every view.")
                }

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
                    title: selectedView == .duplicates
                        ? (hasActiveFilter ? "No matching duplicates" : "No duplicate installations")
                        : (hasActiveFilter ? "No matching skills" : "No skills found"),
                    message: hasActiveFilter
                        ? "Clear the search or choose All Projects."
                        : (selectedView == .duplicates
                            ? "Metagent found no same-name or overlapping canonical skill bundles."
                            : "Refresh after configuring roots or adding skills."),
                    symbol: selectedView == .duplicates ? "checkmark.circle" : "tablecells"
                )
            } else if selectedView == .duplicates {
                DuplicateReviewExperience(
                    groups: duplicateReviewGroups,
                    hasVisibleGroups: !completeVisibleDuplicateGroups.isEmpty,
                    hasDetectedGroups: hasDetectedOverlapGroups,
                    selectedGroupID: $selectedDuplicateGroupID,
                    removalIDs: $duplicateRemovalIDs,
                    isRunning: model.isRunning && !model.isRemovingSkills,
                    onView: { row in viewedSkill = row.inventory },
                    onInfo: { row in inspectedSkill = row.inventory },
                    onReviewRemoval: { candidateRows in
                        let removableRows = candidateRows.compactMap(\.inventory)
                            .filter { $0.removalRequest != nil }
                        guard !removableRows.isEmpty else { return }
                        pendingConfirmation = .removal(removableRows)
                    },
                    onKeepAll: { group in
                        reviewedDuplicateGroupIDs.insert(group.id)
                        duplicateRemovalIDs.subtract(group.rows.map(\.id))
                        selectedDuplicateGroupID = duplicateReviewGroups.first {
                            $0.id != group.id
                        }?.id
                    },
                    onReviewAgain: {
                        reviewedDuplicateGroupIDs.removeAll()
                        selectedDuplicateGroupID = nil
                        duplicateRemovalIDs.removeAll()
                    }
                )
            } else {
                skillsTable
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            Button("") {
                if let selectedRow { inspectedSkill = selectedRow }
            }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(selectedRow == nil)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .onAppear {
            migrateSourceVisibilityIfNeeded()
            sortOrder = defaultSortOrder(for: selectedView)
        }
        .task(id: model.skillTableRevision) {
            await rebuildRows()
        }
        .onChange(of: selectedViewRaw) { _, rawValue in
            let view = SkillTableView(rawValue: rawValue) ?? .summary
            selection.formIntersection(Set(rows.map(\.id)))
            duplicateRemovalIDs.removeAll()
            sortOrder = defaultSortOrder(for: view)
        }
        .alert(item: $pendingConfirmation) { confirmation in
            switch confirmation {
            case let .removal(rows):
                let requests = rows.compactMap(\.removalRequest)
                let names = rows.prefix(6).map(\.skillName).joined(separator: ", ")
                let suffix = rows.count > 6 ? ", …" : ""
                return Alert(
                    title: Text(requests.count == 1 ? "Remove selected skill?" : "Remove \(requests.count) selected items?"),
                    message: Text("\(names)\(suffix)\n\n\(skillRemovalMessage(for: rows))"),
                    primaryButton: .destructive(Text(requests.count == 1 ? "Approve Removal" : "Approve \(requests.count) Removals")) {
                        if model.uninstallSkills(requests) {
                            duplicateRemovalIDs.removeAll()
                            selection.removeAll()
                        }
                    },
                    secondaryButton: .cancel()
                )
            case let .codexReview(row):
                return Alert(
                    title: Text("Review \(row.skillName) with Codex?"),
                    message: Text("Metagent will copy this skill into an isolated temporary directory, disable Codex tools and user configuration, and send the copied contents to OpenAI for an ephemeral review. The skill and other local files cannot be edited or read by the review."),
                    primaryButton: .default(Text("Run Review")) {
                        model.reviewSkillWithCodex(path: row.canonicalPath)
                    },
                    secondaryButton: .cancel()
                )
            }
        }
        .sheet(item: $inspectedSkill) { row in
            SkillInfoView(model: model, row: row)
        }
        .sheet(item: $viewedSkill) { row in
            SkillReaderView(model: model, row: row)
        }
        .sheet(item: $iconTarget) { row in
            SkillIconEditorView(model: model, row: row)
        }
        .sheet(isPresented: $showsScoreExplanation) {
            ScoreExplanationView()
        }
    }

    private var skillsTable: some View {
        Table(
            displayRows,
            children: \.children,
            selection: $selection,
            sortOrder: $sortOrder,
            columnCustomization: columnCustomization
        ) {
            TableColumnForEach(skillColumnSpecs) { column in
                TableColumn(column.title, sortUsing: column.comparator) { row in
                    SkillTableColumnCell(column: column, row: row)
                }
                .width(min: column.minWidth, ideal: column.idealWidth)
                .customizationID(column.id)
                .defaultVisibility(column.defaultVisibility(selectedView))
            }
        }
        .id("\(selectedView.rawValue):\(grouping.rawValue)")
        .tableStyle(.inset)
        .alternatingRowBackgrounds(.enabled)
        .contextMenu(forSelectionType: SkillTableRow.ID.self) { contextSelection in
            skillContextMenu(for: contextSelection)
        }
    }

    @ViewBuilder
    private func skillContextMenu(for contextSelection: Set<SkillTableRow.ID>) -> some View {
        let contextRows = rows(for: contextSelection)
        let removableRows = contextRows.compactMap(\.inventory).filter { $0.removalRequest != nil }
        let paths = contextRows.compactMap(\.canonicalPath)
        let openableURLs = skillDirectoryURLs(for: contextRows)
        let skillFiles = skillFileURLs(for: contextRows)
        let openWithApplications = applicationsForOpening(openableURLs)
        if contextRows.count == 1, let inventory = contextRows.first?.inventory {
            Button("View Skill", systemImage: "doc.text.magnifyingglass") {
                viewedSkill = inventory
            }
            Button("Get Info", systemImage: "info.circle") {
                inspectedSkill = inventory
            }
            Button(
                inventory.skillIconPath == nil ? "Add Icon…" : "Change Icon…",
                systemImage: "photo.badge.plus"
            ) {
                iconTarget = inventory
            }
            .disabled(!inventory.canEditIcon)
            Divider()
        }
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
        Button("Open SKILL.md", systemImage: "doc.text") {
            openSkillFiles(skillFiles)
        }
        .disabled(skillFiles.isEmpty)
        Button("Open in Editor", systemImage: "chevron.left.forwardslash.chevron.right") {
            openSkillDirectoriesInEditor(openableURLs, skillFiles: skillFiles)
        }
        .disabled(openableURLs.isEmpty)
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
            pendingConfirmation = .removal(removableRows)
        }
        .disabled(removableRows.isEmpty)
    }

    private func defaultSortOrder(for view: SkillTableView) -> [KeyPathComparator<SkillTableRow>] {
        switch view {
        case .summary:
            [KeyPathComparator(\SkillTableRow.invocations30d, order: .reverse)]
        case .review:
            [KeyPathComparator(\SkillTableRow.metagentScoreSortValue)]
        case .duplicates:
            [
                KeyPathComparator(\SkillTableRow.overlapSortValue),
                KeyPathComparator(\SkillTableRow.skillName),
            ]
        case .inventory:
            [KeyPathComparator(\SkillTableRow.skillName)]
        case .usage:
            [KeyPathComparator(\SkillTableRow.totalInvocations, order: .reverse)]
        }
    }

    private func rebuildRows() async {
        AppBrand.clearSkillIconCache()
        let projects = model.projects
        let usage = model.usageSnapshot
        let evaluations = model.skillEvaluations
        let pluginInventoryAvailable = model.isPluginInventoryAvailable
        let rows = await Task.detached(priority: .utility) {
            let inventoryRows = InventorySkillRow.rows(
                from: projects,
                usage: usage,
                evaluations: evaluations
            )
            let overlaps = MetagentCore.detectSkillOverlaps(inventoryRows.map { $0.skill.coreSkill })
            return SkillTableRow.rows(
                inventoryRows: inventoryRows,
                usageRows: UsageSkillRow.rows(
                    projects: projects,
                    summaries: usage.summaries,
                    isBackfillComplete: usage.isBackfillComplete
                ),
                projectRoots: projects.map(\.root),
                pluginInventoryAvailable: pluginInventoryAvailable,
                isBackfillComplete: usage.isBackfillComplete,
                overlaps: overlaps
            )
        }.value
        guard !Task.isCancelled else { return }
        cachedRows = rows
        selection.formIntersection(Set(cachedRows.map(\.id)))
    }
}

private struct DuplicateReviewExperience: View {
    let groups: [DuplicateReviewGroup]
    let hasVisibleGroups: Bool
    let hasDetectedGroups: Bool
    @Binding var selectedGroupID: String?
    @Binding var removalIDs: Set<SkillTableRow.ID>
    let isRunning: Bool
    let onView: (SkillTableRow) -> Void
    let onInfo: (SkillTableRow) -> Void
    let onReviewRemoval: ([SkillTableRow]) -> Void
    let onKeepAll: (DuplicateReviewGroup) -> Void
    let onReviewAgain: () -> Void

    private var selectedGroup: DuplicateReviewGroup? {
        groups.first { $0.id == selectedGroupID } ?? groups.first
    }

    var body: some View {
        if groups.isEmpty {
            if hasVisibleGroups {
                ContentUnavailableView {
                    Label("Duplicate review complete", systemImage: "checkmark.circle")
                } description: {
                    Text("You kept the remaining groups for this session.")
                } actions: {
                    Button("Review again", action: onReviewAgain)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label(
                        hasDetectedGroups ? "No complete groups match" : "No duplicate skills found",
                        systemImage: hasDetectedGroups ? "line.3.horizontal.decrease.circle" : "checkmark.circle"
                    )
                } description: {
                    Text(hasDetectedGroups
                        ? "A directory, source, scope, usage, or search filter is hiding part of each group. Adjust the filters to compare every copy safely."
                        : "Metagent found no same-name or overlapping canonical skill bundles.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            HStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        Text(groups.count == 1 ? "1 group to review" : "\(groups.count) groups to review")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.top, 4)
                            .padding(.bottom, 2)
                        ForEach(groups) { group in
                            Button {
                                select(group)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: group.symbol)
                                        .foregroundStyle(
                                            group.id == selectedGroup?.id ? Color.accentColor : .secondary
                                        )
                                        .frame(width: 18)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(group.skillName)
                                            .font(.callout.weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text("\(group.rows.count) copies · \(group.similarityText)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if group.id == selectedGroup?.id {
                                        Image(systemName: "chevron.right")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 9)
                                .background {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(group.id == selectedGroup?.id
                                            ? Color.accentColor.opacity(0.12)
                                            : Color.clear)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                }
                .frame(width: 220)

                Divider()

                if let selectedGroup {
                    DuplicateReviewDetail(
                        group: selectedGroup,
                        removalIDs: $removalIDs,
                        isRunning: isRunning,
                        onView: onView,
                        onInfo: onInfo,
                        onUseRecommendation: {
                            removalIDs.subtract(selectedGroup.rows.map(\.id))
                            removalIDs.formUnion(selectedGroup.suggestedRemovalRows.map(\.id))
                        },
                        onReviewRemoval: {
                            onReviewRemoval(selectedGroup.rows.filter { removalIDs.contains($0.id) })
                        },
                        onKeepAll: {
                            onKeepAll(selectedGroup)
                        }
                    )
                    .id(selectedGroup.id)
                }
            }
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.quaternary.opacity(0.18))
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.quaternary, lineWidth: 1)
            }
            .onAppear {
                if selectedGroupID == nil {
                    selectedGroupID = groups.first?.id
                }
            }
            .onChange(of: groups.map(\.id)) { _, ids in
                guard !ids.contains(selectedGroupID ?? "") else { return }
                selectedGroupID = ids.first
                removalIDs.removeAll()
            }
        }
    }

    private func select(_ group: DuplicateReviewGroup) {
        guard selectedGroupID != group.id else { return }
        selectedGroupID = group.id
        removalIDs.removeAll()
    }
}

private struct DuplicateReviewDetail: View {
    let group: DuplicateReviewGroup
    @Binding var removalIDs: Set<SkillTableRow.ID>
    let isRunning: Bool
    let onView: (SkillTableRow) -> Void
    let onInfo: (SkillTableRow) -> Void
    let onUseRecommendation: () -> Void
    let onReviewRemoval: () -> Void
    let onKeepAll: () -> Void

    private var selectedRemovalCount: Int {
        group.rows.filter { removalIDs.contains($0.id) }.count
    }

    private var candidateColumns: [GridItem] {
        if group.rows.count <= 2 {
            return Array(
                repeating: GridItem(.flexible(minimum: 280), spacing: 10, alignment: .top),
                count: max(group.rows.count, 1)
            )
        }
        return [GridItem(.adaptive(minimum: 280), spacing: 10, alignment: .top)]
    }

    private var recommendationTint: Color {
        group.kind == .pluginReplacement ? .orange : .secondary
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.skillName)
                            .font(.title3.weight(.semibold))
                        Text(group.rows.count == 1
                            ? "1 installed copy"
                            : "\(group.rows.count) installed copies")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label("\(group.similarityText) similar", systemImage: "equal.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.accentColor.opacity(0.10), in: Capsule())
                }

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: group.kind == .pluginReplacement
                        ? "lightbulb.max.fill"
                        : "lightbulb")
                        .foregroundStyle(recommendationTint)
                        .font(.callout)
                        .frame(width: 26, height: 26)
                        .background(recommendationTint.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.recommendationTitle)
                            .font(.callout.weight(.semibold))
                        Text(group.recommendationDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if !group.suggestedRemovalRows.isEmpty {
                        Button("Use recommendation", action: onUseRecommendation)
                            .buttonStyle(.glass)
                            .help("Select Metagent’s recommended copies for removal. Nothing is removed until you approve the final review.")
                    }
                }
                .padding(10)
                .background(recommendationTint.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(recommendationTint.opacity(0.18), lineWidth: 1)
                }

                LazyVGrid(
                    columns: candidateColumns,
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(group.rows) { row in
                        DuplicateCandidateCard(
                            row: row,
                            isMarkedForRemoval: Binding(
                                get: { removalIDs.contains(row.id) },
                                set: { shouldRemove in
                                    if shouldRemove {
                                        removalIDs.insert(row.id)
                                    } else {
                                        removalIDs.remove(row.id)
                                    }
                                }
                            ),
                            onView: { onView(row) },
                            onInfo: { onInfo(row) }
                        )
                    }
                }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 10) {
                Button("Keep all", action: onKeepAll)
                    .buttonStyle(.glass)
                    .disabled(isRunning)
                    .help("Keep every copy in this group and mark it reviewed for this session.")
                Spacer()
                if selectedRemovalCount > 0 {
                    Text(selectedRemovalCount == 1
                        ? "1 copy marked for removal"
                        : "\(selectedRemovalCount) copies marked for removal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(
                    selectedRemovalCount > 1 ? "Review \(selectedRemovalCount) removals…" : "Review removal…",
                    role: .destructive,
                    action: onReviewRemoval
                )
                .buttonStyle(.glassProminent)
                .disabled(selectedRemovalCount == 0 || isRunning)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }
}

private struct DuplicateCandidateCard: View {
    let row: SkillTableRow
    @Binding var isMarkedForRemoval: Bool
    let onView: () -> Void
    let onInfo: () -> Void

    private var canRemove: Bool { row.inventory?.removalRequest != nil }
    private var removalLabel: String {
        guard let request = row.inventory?.removalRequest else { return "Keep" }
        if case .plugin = request.kind { return "Remove plugin" }
        return "Remove"
    }

    private var isProjectSkill: Bool { row.scope == "project" }
    private var locationLabel: String {
        isProjectSkill ? row.projectName : "Global"
    }
    private var locationHelp: String {
        guard isProjectSkill else { return "Global skill available across directories" }
        guard let projectRoot = row.projectRoot else {
            return "Project skill available in \(row.projectName)"
        }
        return "Project skill available from \(displayUserPath(projectRoot))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                SkillSourceIconCell(category: row.sourceCategory, help: row.sourceHelp)
                Text(row.sourceText)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if row.overlap?.suggestedRemoval == true {
                    Text("Suggested removal")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.orange.opacity(0.12), in: Capsule())
                }
            }

            Label(locationLabel, systemImage: isProjectSkill ? "folder.fill" : "globe")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isProjectSkill ? Color.accentColor : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    (isProjectSkill ? Color.accentColor : Color.secondary).opacity(0.10),
                    in: Capsule()
                )
                .help(locationHelp)

            if row.descriptionText != "—" {
                Text(row.descriptionText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            HStack(spacing: 12) {
                candidateStat("Last 30 days", row.invocations30d.formatted())
                Divider().frame(height: 24)
                candidateStat("All time", row.totalInvocations.formatted())
                Divider().frame(height: 24)
                candidateStat("Updated", row.updatedText)
                Spacer(minLength: 0)
            }

            Text(displayUserPath(row.canonicalPath ?? row.skillPath))
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .truncationMode(.middle)
                .help(displayUserPath(row.canonicalPath ?? row.skillPath))

            Divider()

            HStack {
                Button("View", action: onView)
                    .buttonStyle(.glass)
                Button(action: onInfo) {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.glass)
                .help("Get Info")
                Spacer()
                if canRemove {
                    Picker("Decision", selection: $isMarkedForRemoval) {
                        Text("Keep").tag(false)
                        Text(removalLabel).tag(true)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .glassEffect(.regular.interactive(), in: Capsule())
                    .tint(isMarkedForRemoval ? .red : .accentColor)
                    .frame(width: removalLabel == "Remove plugin" ? 190 : 155)
                    .accessibilityLabel("Duplicate decision")
                    .help(removalLabel == "Remove plugin"
                        ? "Removing this copy uninstalls its entire plugin."
                        : "The final removal still requires approval.")
                } else {
                    Label("Keep", systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Metagent does not have a safe removal action for this managed copy.")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            isMarkedForRemoval ? AnyShapeStyle(Color.red.opacity(0.07)) : AnyShapeStyle(.background),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isMarkedForRemoval ? AnyShapeStyle(Color.red.opacity(0.4)) : AnyShapeStyle(.quaternary), lineWidth: 1)
        }
    }

    private func candidateStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SkillsMenuSection: View {
    @ObservedObject var model: MetagentModel
    let selectedProjectRoot: String?
    let openMainWindow: () -> Void

    private var scopedProjects: [ProjectStatus] {
        guard let selectedProjectRoot else { return model.projects }
        return model.projects.filter { $0.root == selectedProjectRoot }
    }

    private var scopedSkillCount: Int {
        guard let selectedProjectRoot else { return model.logicalSkillCount }
        return logicalSkillCount(projects: model.projects, selectedProjectRoot: selectedProjectRoot)
    }

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
                MetricView(title: "Skills", value: "\(scopedSkillCount)", symbol: "tablecells")
                StatusPathView(
                    title: "Locations",
                    value: selectedProjectRoot == nil ? model.locationSummaryText : (scopedProjects.first?.name ?? "No match"),
                    symbol: "folder.badge.gearshape"
                )
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
        if !entry.globalClients.isEmpty, !entry.projectPaths.isEmpty {
            return "Configured globally and also for:\n\(entry.projectPaths.map(displayUserPath).joined(separator: "\n"))"
        }
        if !entry.globalClients.isEmpty {
            return "Configured globally in at least one client. Check Status for availability."
        }
        if !entry.projectPaths.isEmpty {
            return "Configured only for:\n\(entry.projectPaths.map(displayUserPath).joined(separator: "\n"))"
        }
        return "Discovered in client configuration."
    }
    var displaysGlobalLocation: Bool { !entry.globalClients.isEmpty }
    var projectLocationText: String {
        let names = entry.projectPaths.map { URL(fileURLWithPath: $0).lastPathComponent }.uniqued()
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default: return "\(names.count) projects"
        }
    }
    var locationSortValue: String {
        [displaysGlobalLocation ? "Global" : nil, projectLocationText.isEmpty ? nil : projectLocationText]
            .compactMap { $0 }
            .joined(separator: " + ")
    }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return ([name, clientsSortValue, statusLabel, scopeLabel] + entry.projectPaths)
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

private struct MCPInventorySection: View {
    @ObservedObject var model: MetagentModel
    let selectedProjectRoot: String?
    @State private var searchText = ""
    @State private var filter = MCPInventoryFilter.all
    @State private var sortOrder = [KeyPathComparator(\MCPInventoryRow.name)]

    private var allRows: [MCPInventoryRow] {
        projectFilteredMCPHealth(model.mcpHealth, selectedProjectRoot: selectedProjectRoot)
            .inventory
            .map(MCPInventoryRow.init)
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

                GlassSearchField(placeholder: "Search MCPs", text: $searchText, width: 220)

                Picker("Status", selection: $filter) {
                    ForEach(MCPInventoryFilter.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .frame(width: 155)
                .buttonStyle(.glass)

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

                    TableColumn("Location", value: \.locationSortValue) { row in
                        MCPLocationCell(row: row)
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
    let selectedProjectRoot: String?
    let openMainWindow: () -> Void

    private var rows: [MCPInventoryRow] {
        projectFilteredMCPHealth(model.mcpHealth, selectedProjectRoot: selectedProjectRoot)
            .inventory
            .map(MCPInventoryRow.init)
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

private struct ProjectDirectoryRow: Identifiable {
    enum LinkState: String, Comparable {
        case healthy = "Connected"
        case notApplicable = "Independent"
        case missing = "Not connected"
        case separate = "Separate folder"
        case wrong = "Wrong link"

        static func < (lhs: LinkState, rhs: LinkState) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    let root: String
    let name: String
    let skillCount: Int
    let mcpCount: Int
    let claudeState: LinkState
    let codexOnlyCount: Int
    let claudeOnlyCount: Int
    let issueCount: Int

    var id: String { root }
    var claudeText: String { claudeState.rawValue }

    init(
        directory: DirectoryFilterOption,
        projects: [ProjectStatus],
        mcpHealth: MCPHealthSnapshot,
        doctorIssues: [DoctorIssue]
    ) {
        root = directory.root
        name = directory.root == NSHomeDirectory() ? "Global" : directory.name
        let matchingProjects = projects.filter {
            standardizedDirectoryPath($0.root) == standardizedDirectoryPath(directory.root)
        }
        skillCount = Set(matchingProjects.flatMap { project in
            project.skills.map { skill in
                skill.canonicalPath.isEmpty ? "\(skill.name):\(skill.location)" : standardizedDirectoryPath(skill.canonicalPath)
            }
        }).count
        mcpCount = mcpHealth.projectOnly(at: directory.root).inventory.count
        claudeState = Self.claudeLinkState(
            root: directory.root,
            isGlobal: standardizedDirectoryPath(directory.root) == standardizedDirectoryPath(NSHomeDirectory())
        )
        let agentsPaths = Set(matchingProjects.flatMap { project in
            project.skills
                .filter { $0.location == "agents" && $0.representation == "canonical" }
                .map { standardizedDirectoryPath($0.canonicalPath.isEmpty ? $0.path : $0.canonicalPath) }
        })
        let codexPaths = Set(matchingProjects.flatMap { project in
            project.skills
                .filter {
                    $0.location == "codex"
                        && $0.representation == "canonical"
                        && $0.authority != "codex-system"
                }
                .map { standardizedDirectoryPath($0.canonicalPath.isEmpty ? $0.path : $0.canonicalPath) }
        })
        let claudePaths = Set(matchingProjects.flatMap { project in
            project.skills
                .filter { $0.location == "claude" && $0.representation == "canonical" }
                .map { standardizedDirectoryPath($0.canonicalPath.isEmpty ? $0.path : $0.canonicalPath) }
        })
        codexOnlyCount = codexPaths.subtracting(agentsPaths).subtracting(claudePaths).count
        claudeOnlyCount = claudePaths.subtracting(agentsPaths).subtracting(codexPaths).count
        issueCount = groupedDoctorActionCount(doctorIssues.filter {
            $0.severity != .ok
                && $0.projectRoot.map(standardizedDirectoryPath) == standardizedDirectoryPath(directory.root)
        })
    }

    private static func claudeLinkState(root: String, isGlobal: Bool) -> LinkState {
        let project = URL(fileURLWithPath: root)
        let link = project.appendingPathComponent(".claude/skills")
        let expected = project.appendingPathComponent(".agents/skills")
        if isSymbolicLink(link) {
            let isConnected = link.resolvingSymlinksInPath().standardizedFileURL.path
                == expected.resolvingSymlinksInPath().standardizedFileURL.path
            return isConnected ? .healthy : (isGlobal ? .notApplicable : .wrong)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: link.path, isDirectory: &isDirectory) else {
            return isGlobal ? .notApplicable : .missing
        }
        return isDirectory.boolValue ? (isGlobal ? .notApplicable : .separate) : .wrong
    }
}

private struct ProjectsSection: View {
    @ObservedObject var model: MetagentModel
    let selectedProjectRoot: String?
    @State private var searchText = ""
    @State private var sortOrder = [KeyPathComparator(\ProjectDirectoryRow.name)]

    private var allRows: [ProjectDirectoryRow] {
        directoryFilterOptions(
            projects: model.projects,
            mcpHealth: model.mcpHealth,
            doctorIssues: model.doctorIssues
        )
        .filter { directory in
            guard let selectedProjectRoot else { return true }
            return standardizedDirectoryPath(directory.root) == standardizedDirectoryPath(selectedProjectRoot)
        }
        .map {
            ProjectDirectoryRow(
                directory: $0,
                projects: model.projects,
                mcpHealth: model.mcpHealth,
                doctorIssues: model.doctorIssues
            )
        }
    }

    private func filteredRows(from allRows: [ProjectDirectoryRow]) -> [ProjectDirectoryRow] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return allRows
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.root.localizedCaseInsensitiveContains(query) }
            .sorted(using: sortOrder)
    }

    var body: some View {
        let allRows = allRows
        let rows = filteredRows(from: allRows)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Projects")
                        .font(.title2.weight(.semibold))
                    Text("\(allRows.count) directories · shared skill and MCP setup")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                GlassSearchField(placeholder: "Search projects", text: $searchText, width: 220)
                Button {
                    model.refreshStatus()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.glass)
                .help("Refresh projects")
                .disabled(model.isRunning)
            }

            if rows.isEmpty {
                EmptyStateView(
                    title: allRows.isEmpty ? "No projects found" : "No matching projects",
                    message: allRows.isEmpty ? "Add a configured skill or MCP directory, then refresh." : "Clear the search.",
                    symbol: "folder"
                )
            } else {
                Table(rows, sortOrder: $sortOrder) {
                    TableColumn("Project", value: \.name) { row in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.name).font(.callout.weight(.medium))
                            Text(displayUserPath(row.root)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        .help(displayUserPath(row.root))
                    }
                    .width(min: 260, ideal: 360)
                    TableColumn("Skills", value: \.skillCount) { row in
                        Text(row.skillCount.formatted()).monospacedDigit()
                    }
                    .width(min: 64, ideal: 76)
                    TableColumn("MCPs", value: \.mcpCount) { row in
                        Text(row.mcpCount.formatted()).monospacedDigit()
                    }
                    .width(min: 60, ideal: 72)
                    TableColumn("Claude skills", value: \.claudeText) { row in
                        ProjectLinkStateCell(state: row.claudeState)
                    }
                    .width(min: 132, ideal: 154)
                    TableColumn("Codex-only", value: \.codexOnlyCount) { row in
                        Text(row.codexOnlyCount == 0 ? "—" : row.codexOnlyCount.formatted())
                            .monospacedDigit()
                            .font(.callout)
                            .help("Skills stored only in .codex/skills. Skills shared through .agents/skills are not counted because Codex discovers those automatically.")
                    }
                    .width(min: 86, ideal: 104)
                    TableColumn("Claude-only", value: \.claudeOnlyCount) { row in
                        Text(row.claudeOnlyCount == 0 ? "—" : row.claudeOnlyCount.formatted())
                            .monospacedDigit()
                            .font(.callout)
                            .help("Skills stored only in .claude/skills. Skills shared through .agents/skills are not counted.")
                    }
                    .width(min: 90, ideal: 108)
                    TableColumn("Issues", value: \.issueCount) { row in
                        let value = row.issueCount == 0 ? "—" : row.issueCount.formatted()
                        let tint: Color = row.issueCount == 0 ? .secondary : .orange
                        Text(value)
                            .monospacedDigit()
                            .foregroundStyle(tint)
                    }
                    .width(min: 54, ideal: 66)
                }
                .tableStyle(.inset)
                .alternatingRowBackgrounds(.enabled)
                .contextMenu(forSelectionType: ProjectDirectoryRow.ID.self) { selection in
                    if let root = selection.first {
                        Button("Open", systemImage: "folder") {
                            model.openProjectRoot(root)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct ProjectsMenuSection: View {
    @ObservedObject var model: MetagentModel
    let selectedProjectRoot: String?
    let openMainWindow: () -> Void

    private var rows: [ProjectDirectoryRow] {
        directoryFilterOptions(projects: model.projects, mcpHealth: model.mcpHealth, doctorIssues: model.doctorIssues)
            .filter { directory in
                guard let selectedProjectRoot else { return true }
                return standardizedDirectoryPath(directory.root) == standardizedDirectoryPath(selectedProjectRoot)
            }
            .map { ProjectDirectoryRow(directory: $0, projects: model.projects, mcpHealth: model.mcpHealth, doctorIssues: model.doctorIssues) }
    }

    var body: some View {
        let rows = rows
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Projects").font(.headline)
                Spacer()
                Button(action: openMainWindow) { Label("Window", systemImage: "macwindow") }
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                MetricView(title: "Directories", value: rows.count.formatted(), symbol: "folder")
                MetricView(
                    title: "Link issues",
                    value: rows.filter {
                        $0.skillCount > 0 && [.missing, .separate, .wrong].contains($0.claudeState)
                    }.count.formatted(),
                    symbol: "link"
                )
            }
            Button(action: openMainWindow) {
                Label("Open Projects", systemImage: "arrow.up.right.square").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            Spacer()
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct ProjectLinkStateCell: View {
    let state: ProjectDirectoryRow.LinkState

    var body: some View {
        Label(state.rawValue, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(tint)
            .help(help)
    }

    private var symbol: String {
        switch state {
        case .healthy: "checkmark.circle"
        case .notApplicable: "info.circle"
        case .missing: "minus.circle"
        case .separate: "folder.badge.questionmark"
        case .wrong: "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch state {
        case .healthy: .green
        case .notApplicable, .missing: .secondary
        case .separate, .wrong: .orange
        }
    }

    private var help: String {
        switch state {
        case .healthy: ".claude/skills points to .agents/skills."
        case .notApplicable: "Global Claude skills are stored independently from .agents/skills. This is allowed, but the two locations do not share one canonical collection."
        case .missing: "Claude does not currently see this project's .agents skills."
        case .separate: ".claude/skills is an independent directory, not a shared link."
        case .wrong: ".claude/skills is linked somewhere other than .agents/skills."
        }
    }
}

private func isSymbolicLink(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
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

private struct MCPLocationCell: View {
    let row: MCPInventoryRow

    var body: some View {
        HStack(spacing: 7) {
            if row.displaysGlobalLocation {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            if row.displaysGlobalLocation, !row.projectLocationText.isEmpty {
                Text("+")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            if !row.projectLocationText.isEmpty {
                Text(row.projectLocationText)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .help(row.scopeHelp)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.locationSortValue)
        .accessibilityHint(row.scopeHelp)
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

private struct InventorySkillRow: Identifiable, Sendable {
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
        let leftRepresentationPriority = left.representation == "canonical" ? 0 : 1
        let rightRepresentationPriority = right.representation == "canonical" ? 0 : 1
        if leftRepresentationPriority != rightRepresentationPriority {
            return leftRepresentationPriority < rightRepresentationPriority
        }
        let priority = ["agents": 0, "codex": 1, "claude": 2]
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
        variants.map { "\($0.locationLabel): \(displayUserPath($0.path))" }.joined(separator: "\n")
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
    var descriptionText: String { skill.description ?? "—" }
    var descriptionHelp: String { skill.description ?? "No description in SKILL.md frontmatter." }
    var upstreamText: String {
        githubRepositoryName(url: skill.sourceURL)
            ?? githubRepositoryName(source: skill.source)
            ?? (skill.manager == "codex-plugin" ? skill.authority : nil)
            ?? "—"
    }
    var upstreamHelp: String {
        [
            upstreamText == "—" ? "No upstream repository is recorded." : "Upstream: \(upstreamText)",
            skill.sourceURL,
            skill.source.map { "Recorded source: \($0)" },
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
    }
    var versionText: String { skill.ref ?? "—" }
    var versionHelp: String {
        skill.ref.map { "Recorded version or Git ref: \($0)" }
            ?? "No version or Git ref is recorded for this source."
    }
    var updatedDate: Date? { skill.updatedAt.flatMap(parseISO8601Date) }
    var weeksOld: Int? {
        updatedDate.map { max(0, Calendar.current.dateComponents([.day], from: $0, to: Date()).day ?? 0) / 7 }
    }
    var updatedText: String {
        weeksOld?.formatted() ?? "—"
    }
    var updatedHelp: String {
        guard let updatedDate else { return "No update timestamp is available." }
        return "Recorded update or latest local content change: \(updatedDate.formatted(date: .abbreviated, time: .shortened)). Calendar age alone does not lower Quality."
    }
    var tokenEstimate: Int { skill.tokenEstimate }
    var referenceFileCount: Int { skill.referenceFileCount }
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
    var skillIconPath: String? { skill.iconSmallPath ?? skill.iconLargePath }
    var canEditIcon: Bool {
        skill.representation == "canonical"
            && skill.mutability == "editable"
            && skill.manager != "codex-plugin"
    }
    var canEditDocument: Bool { canEditIcon }
    var metagentStaticScore: Int {
        metagentScore.qualityScore(
            pluginEvalScore: pluginEval?.score,
            codexReviewScore: codexReview?.score
        )
    }
    var metagentStaticGrade: SkillGrade { .forScore(metagentStaticScore) }
    var utilityScore: Int { metagentScore.utilityScore(qualityScore: metagentStaticScore) }
    var utilityGrade: SkillGrade { .forScore(utilityScore) }
    var metagentScoreText: String { "\(metagentStaticScore) \(metagentStaticGrade.rawValue)" }
    var metagentScoreTint: Color { scoreTint(metagentStaticGrade) }
    var metagentScoreHelp: String {
        let breakdown = metagentScore.components.filter { $0.id != "adoption" }.map {
            "\($0.label): \($0.score)/\($0.maximum) — \($0.explanation)"
        }.joined(separator: "\n")
        let pluginLine = pluginEval.map { "Plugin Eval: \($0.score)/100 · 60% weight" }
            ?? "Plugin Eval: not run · excluded"
        let codexLine = codexReview.map { "Codex review: \($0.score)/100 · 20% weight" }
            ?? "Codex review: not run · excluded"
        return "Quality excludes usage and update age. Available inputs are normalized.\nPlugin Eval (skill correctness and efficiency): 60%\nManagement confidence (known source, owner, manager, and canonical identity): 20%\nCodex review (optional judgment): 20%\n\nManagement confidence: \(metagentScore.structuralScore)/100\n\(pluginLine)\n\(codexLine)\nAbsolute grades: A 90+, B 80+, C 70+, D 60+, F below 60.\n\(breakdown)"
    }
    var portfolioScoreText: String { "\(utilityScore) \(utilityGrade.rawValue)" }
    var portfolioScoreTint: Color { scoreTint(utilityGrade) }
    var portfolioScoreHelp: String {
        let adoption = metagentScore.components.first { $0.id == "adoption" }
        let adoptionText = adoption.map {
            "Observed adoption: \($0.score)/\($0.maximum) — \($0.explanation)"
        } ?? "Observed adoption: unavailable"
        return "Utility combines Quality at 70% with observed adoption at 30%.\nQuality: \(metagentStaticScore)/100\n\(adoptionText)"
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
        return "Plugin Eval \(pluginEval.toolVersion) · \(pluginEval.riskLevel) risk\nA separate static evaluator that starts at 100 and deducts for concrete findings such as invalid frontmatter, weak trigger descriptions, broken links, excessive token budgets, and missing progressive disclosure. Its number supplies 60% of Quality when present; 60% is not its internal formula.\nThe letter uses Plugin Eval's stricter absolute bands: A 93+, B 85+, C 70+, D 55+. It is not relative.\n\(pluginEval.riskReasons.joined(separator: "\n"))"
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
           ["local", "dotagents", "skills-cli"].contains(agentsVariant.manager)
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
        [
            skillName,
            projectName,
            locationLabel,
            originText,
            descriptionText,
            upstreamText,
            versionText,
            metagentScoreText,
            pluginEvalText,
            codexReviewText,
        ]
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
          [identity.owner, identity.plugin].contains(components[1]),
          identity.skill == components[2]
    else { return nil }
    return identity.key
}

private func pluginUsageMatchKey(_ skill: SkillStatus) -> String? {
    guard skill.location == "plugin",
          let identity = pluginCacheIdentity(skill.canonicalPath)
    else { return nil }
    return identity.key
}

private func pluginCacheIdentity(
    _ canonicalPath: String
) -> (marketplace: String, plugin: String, skill: String, owner: String, key: String)? {
    let url = URL(fileURLWithPath: canonicalPath)
    let components = url.pathComponents
    guard let skillsIndex = components.lastIndex(of: "skills"),
          skillsIndex >= 4,
          components[skillsIndex - 4] == "cache"
    else { return nil }
    let marketplace = components[skillsIndex - 3]
    let plugin = components[skillsIndex - 2]
    let skill = url.lastPathComponent
    // OpenAI renamed this marketplace directory without changing plugin
    // identity. Preserve every other marketplace so unrelated installations
    // with matching folder names do not share usage.
    let stableMarketplace = MetagentCore.normalizedPluginMarketplace(marketplace)
    let owner = "\(stableMarketplace)/\(plugin)"
    return (marketplace, plugin, skill, owner, "\(owner):\(skill)")
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
        parts.append("Managed skills are removed through their owning CLI after recovery state is saved; skills sharing one project are sent in a single batch.")
    }
    if requests.count > 1 {
        parts.append("Independent projects can finish in parallel. A failed item returns to the table with details while successful removals stay removed.")
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

private struct SkillTableColumnCell: View {
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

private struct SkillNameCell: View {
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

private struct SkillScopeLocationCell: View {
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

private struct SkillSourceIconCell: View {
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

private struct DotagentsSourceMark: View {
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

private struct VercelSourceMark: View {
    var body: some View {
        ZStack {
            Circle().fill(.black)
            Triangle()
                .fill(.white)
                .padding(4.5)
        }
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
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

private struct SkillInfoView: View {
    @ObservedObject var model: MetagentModel
    let row: InventorySkillRow
    @Environment(\.dismiss) private var dismiss
    @State private var showsIconEditor = false
    @State private var showsScoreExplanation = false
    @State private var showsReader = false
    @State private var updatedSkillName: String?
    @State private var updatedSkillPath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Group {
                    if let icon = AppBrand.skillIcon(path: row.skillIconPath) {
                        Image(nsImage: icon)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image(systemName: "sparkles")
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(.secondary)
                            .padding(6)
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(updatedSkillName ?? row.skillName)
                        .font(.title2.weight(.semibold))
                    Text(displayUserPath(currentSkillPath))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }

            if row.descriptionText != "—" {
                Text(row.descriptionText)
                    .font(.body)
                    .textSelection(.enabled)
            }

            Form {
                Section("Source") {
                    LabeledContent("Manager", value: row.skill.tableOriginText)
                    LabeledContent("Upstream", value: row.upstreamText)
                    LabeledContent("Version", value: row.versionText)
                    LabeledContent("Updated", value: row.updatedText)
                    LabeledContent("Path") {
                        Text(displayUserPath(currentSkillPath))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }

                Section("Contents") {
                    LabeledContent("Tokens", value: row.tokenEstimate.formatted())
                    LabeledContent("References", value: row.referenceFileCount.formatted())
                    LabeledContent("Scripts", value: row.scriptFileCount.formatted())
                    LabeledContent("Assets", value: row.assetFileCount.formatted())
                    LabeledContent("Other files", value: row.otherFileCount.formatted())
                }

                Section("Scores") {
                    LabeledContent("Quality", value: row.metagentScoreText)
                    LabeledContent("Plugin Eval", value: row.pluginEvalText)
                    LabeledContent("Utility", value: row.portfolioScoreText)
                    LabeledContent("Codex", value: row.codexReviewText)
                    Button("How scores work…") {
                        showsScoreExplanation = true
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Open Skill") {
                    showsReader = true
                }
                .buttonStyle(.glassProminent)
                Menu("Actions") {
                    Button("Open Folder") {
                        openSkillDirectories([URL(fileURLWithPath: currentSkillPath)])
                    }
                    Button("Open SKILL.md") {
                        openSkillFiles([URL(fileURLWithPath: currentSkillPath).appendingPathComponent("SKILL.md")])
                    }
                    Button("Open in Editor") {
                        let directory = URL(fileURLWithPath: currentSkillPath)
                        openSkillDirectoriesInEditor(
                            [directory],
                            skillFiles: [directory.appendingPathComponent("SKILL.md")]
                        )
                    }
                    Divider()
                    Button("Copy Path") {
                        copyToPasteboard(currentSkillPath)
                    }
                    Button(row.skillIconPath == nil ? "Add Icon…" : "Change Icon…") {
                        showsIconEditor = true
                    }
                    .disabled(!row.canEditIcon)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 620, height: 600)
        .sheet(isPresented: $showsIconEditor) {
            SkillIconEditorView(
                model: model,
                row: row,
                skillPath: currentSkillPath,
                skillName: updatedSkillName ?? row.skillName
            )
        }
        .sheet(isPresented: $showsScoreExplanation) {
            ScoreExplanationView()
        }
        .sheet(isPresented: $showsReader) {
            SkillReaderView(
                model: model,
                row: row,
                initialSkillPath: currentSkillPath
            ) { updated in
                updatedSkillName = updated.name
                updatedSkillPath = updated.directoryPath
            }
        }
    }

    private var currentSkillPath: String {
        updatedSkillPath ?? row.canonicalPath
    }
}

private struct SkillReaderView: View {
    @ObservedObject var model: MetagentModel
    let row: InventorySkillRow
    var initialSkillPath: String? = nil
    var onDocumentChange: ((SkillDocument) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var document: SkillDocument?
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var isEditing = false
    @State private var isSaving = false
    @State private var draftName = ""
    @State private var draftDescription = ""
    @State private var draftBody = ""
    @State private var renamedSkillPath: String?
    @State private var portablePathScan: SkillPortablePathScan?
    @State private var showsPortablePathConfirmation = false
    @State private var actionMessage: String?
    @State private var isCheckingPortablePaths = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Group {
                    if let icon = AppBrand.skillIcon(path: row.skillIconPath) {
                        Image(nsImage: icon)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image(systemName: "doc.text")
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(.secondary)
                            .padding(6)
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(document?.name ?? row.skillName)
                        .font(.title2.weight(.semibold))
                    Text(displayUserPath(currentSkillPath))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer()
                if document != nil {
                    Button(isEditing ? "Reading" : "Edit") {
                        if isEditing {
                            cancelEditing()
                        } else {
                            beginEditing()
                        }
                    }
                    .disabled(!row.canEditDocument || isSaving || isCheckingPortablePaths)
                    .help(row.canEditDocument
                        ? (isEditing ? "Discard unsaved edits and return to the reader." : "Edit this local SKILL.md.")
                        : "This skill is managed by \(row.skill.tableOriginText) and is read-only here.")
                }
            }

            if let document {
                if isEditing {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Name")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            TextField("Skill name", text: $draftName)
                                .textFieldStyle(.roundedBorder)
                        }

                        VStack(alignment: .leading, spacing: 5) {
                            Text("Description")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            TextEditor(text: $draftDescription)
                                .font(.body)
                                .scrollContentBackground(.hidden)
                                .padding(7)
                                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                                .frame(minHeight: 72, maxHeight: 110)
                        }

                        VStack(alignment: .leading, spacing: 5) {
                            Text("Instructions")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            TextEditor(text: $draftBody)
                                .font(.system(.body, design: .monospaced))
                                .scrollContentBackground(.hidden)
                                .padding(8)
                                .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
                                .frame(maxHeight: .infinity)
                        }

                        if let saveError {
                            Label(saveError, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    if let description = document.description {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Description")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(description)
                                .font(.body)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                    }

                    if !document.metadata.isEmpty {
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                            ForEach(document.metadata) { item in
                                GridRow {
                                    Text(item.key)
                                        .foregroundStyle(.secondary)
                                    Text(item.value)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .font(.callout)
                    }

                    Divider()

                    ScrollView {
                        SkillMarkdownDocumentView(
                            blocks: MetagentCore.skillMarkdownBlocks(document.bodyMarkdown)
                        )
                        .padding(.trailing, 10)
                    }
                }
            } else if let loadError {
                ContentUnavailableView(
                    "Couldn’t read this skill",
                    systemImage: "doc.badge.ellipsis",
                    description: Text(loadError)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("Loading skill…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let actionMessage {
                Text(actionMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack {
                if isEditing {
                    Button("Cancel", action: cancelEditing)
                        .disabled(isSaving)
                    Spacer()
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button("Save changes", action: saveChanges)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSave)
                } else {
                    Menu("Actions") {
                        Button("Open SKILL.md") {
                            openSkillFiles([skillFileURL])
                        }
                        Button("Open in Editor") {
                            openSkillDirectoriesInEditor([skillDirectoryURL], skillFiles: [skillFileURL])
                        }
                        Divider()
                        Button("Make Paths Portable…") {
                            scanForPersonalPaths()
                        }
                        .disabled(!row.canEditDocument || isCheckingPortablePaths)
                    }
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 760, height: 720)
        .task {
            loadDocument()
        }
        .confirmationDialog(
            "Make paths portable?",
            isPresented: $showsPortablePathConfirmation,
            titleVisibility: .visible
        ) {
            if (portablePathScan?.replaceableOccurrenceCount ?? 0) > 0 {
                Button("Replace in documentation") {
                    replacePersonalPaths()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let scan = portablePathScan {
                Text(portablePathConfirmationMessage(scan))
            }
        }
    }

    private var skillDirectoryURL: URL {
        URL(fileURLWithPath: currentSkillPath).standardizedFileURL
    }

    private var skillFileURL: URL {
        skillDirectoryURL.appendingPathComponent("SKILL.md")
    }

    private var currentSkillPath: String {
        renamedSkillPath ?? initialSkillPath ?? row.canonicalPath
    }

    private var canSave: Bool {
        guard !isSaving, !isCheckingPortablePaths, let document else { return false }
        let cleanName = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDescription = draftDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return !cleanName.isEmpty
            && !cleanDescription.isEmpty
            && (
                cleanName != document.name
                    || cleanDescription != (document.description ?? "")
                    || draftBody != document.bodyMarkdown
            )
    }

    private func loadDocument() {
        do {
            document = try MetagentCore.loadSkillDocument(at: currentSkillPath)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func beginEditing() {
        guard row.canEditDocument, let document else { return }
        draftName = document.name
        draftDescription = document.description ?? ""
        draftBody = document.bodyMarkdown
        saveError = nil
        isEditing = true
    }

    private func cancelEditing() {
        isEditing = false
        saveError = nil
    }

    private func saveChanges() {
        guard canSave, let original = document else { return }
        let name = draftName
        let description = draftDescription
        let body = draftBody
        let path = currentSkillPath
        isSaving = true
        saveError = nil
        Task {
            do {
                let updated = try await Task.detached(priority: .userInitiated) {
                    try MetagentCore.updateSkillDocument(
                        at: path,
                        expectedRawText: original.rawText,
                        name: name,
                        description: description,
                        bodyMarkdown: body
                    )
                }.value
                document = updated
                renamedSkillPath = updated.directoryPath
                onDocumentChange?(updated)
                isEditing = false
                model.refreshStatus()
            } catch {
                saveError = error.localizedDescription
            }
            isSaving = false
        }
    }

    private func scanForPersonalPaths() {
        let path = currentSkillPath
        isCheckingPortablePaths = true
        Task {
            do {
                let scan = try await Task.detached(priority: .userInitiated) {
                    try MetagentCore.scanSkillForPersonalPaths(at: path)
                }.value
                portablePathScan = scan
                if scan.findings.isEmpty {
                    actionMessage = "No personal home-directory references were found."
                } else {
                    actionMessage = nil
                    showsPortablePathConfirmation = true
                }
            } catch {
                actionMessage = error.localizedDescription
            }
            isCheckingPortablePaths = false
        }
    }

    private func replacePersonalPaths() {
        let path = currentSkillPath
        isCheckingPortablePaths = true
        Task {
            do {
                let report = try await Task.detached(priority: .userInitiated) {
                    try MetagentCore.replacePersonalPathsWithTilde(at: path)
                }.value
                actionMessage = "Replaced \(report.replacedOccurrenceCount) path reference(s) in \(report.updatedFiles.count) documentation file(s). Scripts and config files were left for manual review."
                loadDocument()
                model.refreshStatus()
            } catch {
                actionMessage = error.localizedDescription
            }
            isCheckingPortablePaths = false
        }
    }

    private func portablePathConfirmationMessage(_ scan: SkillPortablePathScan) -> String {
        var parts = [
            "Replace \(scan.replaceableOccurrenceCount) exact home-directory reference(s) with ~ in SKILL.md and reference documentation."
        ]
        if scan.reviewOccurrenceCount > 0 {
            parts.append("\(scan.reviewOccurrenceCount) reference(s) in scripts or config will not be changed because ~ may not expand there.")
        }
        return parts.joined(separator: "\n\n")
    }
}

private struct SkillMarkdownDocumentView: View {
    let blocks: [SkillMarkdownBlock]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(blocks) { block in
                SkillMarkdownBlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

private struct SkillMarkdownBlockView: View {
    let block: SkillMarkdownBlock

    var body: some View {
        switch block.kind {
        case let .heading(level):
            Text(inlineMarkdown(block.text))
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 5 : 1)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph:
            Text(inlineMarkdown(block.text))
                .font(.body)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case .unorderedListItem:
            listRow(marker: "•")
        case let .orderedListItem(marker):
            listRow(marker: marker)
        case .quote:
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(.tertiary)
                    .frame(width: 3)
                Text(inlineMarkdown(block.text))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .code(language):
            VStack(alignment: .leading, spacing: 6) {
                if let language {
                    Text(language.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    Text(block.text)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        case .divider:
            Divider()
        }
    }

    private func listRow(marker: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker)
                .foregroundStyle(.secondary)
                .frame(minWidth: 18, alignment: .trailing)
            Text(inlineMarkdown(block.text))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 4)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2.weight(.semibold)
        case 2: .title3.weight(.semibold)
        case 3: .headline
        default: .callout.weight(.semibold)
        }
    }

    private func inlineMarkdown(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(markdown)
    }
}

private struct ScoreExplanationView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("How skill scores work")
                        .font(.title2.weight(.semibold))
                    Text("Every input, weight, and missing-data rule is shown here.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            Form {
                Section("Quality") {
                    Text("A stable 0–100 content and operational score. It deliberately excludes usage and calendar age.")
                    LabeledContent("Plugin Eval", value: "60%")
                    LabeledContent("Management confidence", value: "20%")
                    LabeledContent("Codex review", value: "20% · optional")
                    Text("Missing inputs are excluded, then the remaining weights are normalized to 100. Example: Plugin Eval 81 and management confidence 100, with no Codex review, becomes (81 × 60 + 100 × 20) ÷ 80 = 86.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Section("Plugin Eval") {
                    Text("The official Plugin Eval analyzer starts at 100 and deducts for concrete findings such as invalid metadata, weak trigger descriptions, broken references, excessive token budgets, and poor progressive disclosure. The 60% above is its weight inside Quality—not Plugin Eval's own formula.")
                }

                Section("Management confidence") {
                    Text("Measures whether Metagent can resolve one canonical skill, its lifecycle manager, authority, mutability, and provenance. It does not judge whether the instructions are good.")
                }

                Section("Utility") {
                    LabeledContent("Quality", value: "70%")
                    LabeledContent("Observed adoption", value: "30%")
                    Text("Adoption uses recency, distinct Codex threads, repeat reads in a turn, and total reads. Incomplete usage coverage receives a neutral provisional value; complete coverage with no reads receives zero adoption credit.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Section("Grades") {
                    Text("Quality, Utility, and Codex: A 90+, B 80+, C 70+, D 60+, F below 60. Plugin Eval uses its evaluator-owned stricter bands: A 93+, B 85+, C 70+, D 55+. Grades are absolute, never relative to the other skills in your table.")
                }
            }
            .formStyle(.grouped)
        }
        .padding(22)
        .frame(width: 680, height: 690)
    }
}

private enum SkillIconSource: String, CaseIterable, Identifiable {
    case emoji = "Emoji"
    case lucide = "Lucide"
    case image = "Image"

    var id: String { rawValue }
}

private struct SkillIconSourceSelector: View {
    @Binding var selection: SkillIconSource

    var body: some View {
        Picker("Icon source", selection: $selection) {
            ForEach(SkillIconSource.allCases) { source in
                Text(source.rawValue).tag(source)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityLabel("Icon source")
    }
}

private struct LucideSkillIcon: Identifiable {
    let id: String
    let name: String
    let body: String
    var tags: [String] = []

    var svgData: Data {
        Data("""
        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
        \(body)
        </svg>
        """.utf8)
    }

    var image: NSImage? { NSImage(data: svgData) }

    static let catalog = loadCatalog()

    private static let fallbackCatalog = [
        LucideSkillIcon(id: "sparkles", name: "Sparkles", body: #"""
        <path d="M11.017 2.814a1 1 0 0 1 1.966 0l1.051 5.558a2 2 0 0 0 1.594 1.594l5.558 1.051a1 1 0 0 1 0 1.966l-5.558 1.051a2 2 0 0 0-1.594 1.594l-1.051 5.558a1 1 0 0 1-1.966 0l-1.051-5.558a2 2 0 0 0-1.594-1.594l-5.558-1.051a1 1 0 0 1 0-1.966l5.558-1.051a2 2 0 0 0 1.594-1.594z"/><path d="M20 2v4"/><path d="M22 4h-4"/><circle cx="4" cy="20" r="2"/>
        """#),
        LucideSkillIcon(id: "search", name: "Search", body: #"""
        <path d="m21 21-4.34-4.34"/><circle cx="11" cy="11" r="8"/>
        """#),
        LucideSkillIcon(id: "wrench", name: "Wrench", body: #"""
        <path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.106-3.105c.32-.322.863-.22.983.218a6 6 0 0 1-8.259 7.057l-7.91 7.91a1 1 0 0 1-2.999-3l7.91-7.91a6 6 0 0 1 7.057-8.259c.438.12.54.662.219.984z"/>
        """#),
        LucideSkillIcon(id: "brain", name: "Brain", body: #"""
        <path d="M12 18V5"/><path d="M15 13a4.17 4.17 0 0 1-3-4 4.17 4.17 0 0 1-3 4"/><path d="M17.598 6.5A3 3 0 1 0 12 5a3 3 0 1 0-5.598 1.5"/><path d="M17.997 5.125a4 4 0 0 1 2.526 5.77"/><path d="M18 18a4 4 0 0 0 2-7.464"/><path d="M19.967 17.483A4 4 0 1 1 12 18a4 4 0 1 1-7.967-.517"/><path d="M6 18a4 4 0 0 1-2-7.464"/><path d="M6.003 5.125a4 4 0 0 0-2.526 5.77"/>
        """#),
        LucideSkillIcon(id: "palette", name: "Palette", body: #"""
        <path d="M12 22a1 1 0 0 1 0-20 10 9 0 0 1 10 9 5 5 0 0 1-5 5h-2.25a1.75 1.75 0 0 0-1.4 2.8l.3.4a1.75 1.75 0 0 1-1.4 2.8z"/><circle cx="13.5" cy="6.5" r=".5" fill="white"/><circle cx="17.5" cy="10.5" r=".5" fill="white"/><circle cx="6.5" cy="12.5" r=".5" fill="white"/><circle cx="8.5" cy="7.5" r=".5" fill="white"/>
        """#),
        LucideSkillIcon(id: "shield-check", name: "Shield Check", body: #"""
        <path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z"/><path d="m9 12 2 2 4-4"/>
        """#),
        LucideSkillIcon(id: "rocket", name: "Rocket", body: #"""
        <path d="M12 15v5s3.03-.55 4-2c1.08-1.62 0-5 0-5"/><path d="M4.5 16.5c-1.5 1.26-2 5-2 5s3.74-.5 5-2c.71-.84.7-2.13-.09-2.91a2.18 2.18 0 0 0-2.91-.09"/><path d="M9 12a22 22 0 0 1 2-3.95A12.88 12.88 0 0 1 22 2c0 2.72-.78 7.5-6 11a22.4 22.4 0 0 1-4 2z"/><path d="M9 12H4s.55-3.03 2-4c1.62-1.08 5 .05 5 .05"/>
        """#),
        LucideSkillIcon(id: "file-text", name: "Document", body: #"""
        <path d="M6 22a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h8a2.4 2.4 0 0 1 1.704.706l3.588 3.588A2.4 2.4 0 0 1 20 8v12a2 2 0 0 1-2 2z"/><path d="M14 2v5a1 1 0 0 0 1 1h5"/><path d="M10 9H8"/><path d="M16 13H8"/><path d="M16 17H8"/>
        """#),
        LucideSkillIcon(id: "code-xml", name: "Code", body: #"""
        <path d="m18 16 4-4-4-4"/><path d="m6 8-4 4 4 4"/><path d="m14.5 4-5 16"/>
        """#),
        LucideSkillIcon(id: "bot", name: "Bot", body: #"""
        <path d="M12 8V4H8"/><rect width="16" height="12" x="4" y="8" rx="2"/><path d="M2 14h2"/><path d="M20 14h2"/><path d="M15 13v2"/><path d="M9 13v2"/>
        """#),
        LucideSkillIcon(id: "database", name: "Database", body: #"""
        <ellipse cx="12" cy="5" rx="9" ry="3"/><path d="M3 5V19A9 3 0 0 0 21 19V5"/><path d="M3 12A9 3 0 0 0 21 12"/>
        """#),
        LucideSkillIcon(id: "globe", name: "Globe", body: #"""
        <circle cx="12" cy="12" r="10"/><path d="M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20"/><path d="M2 12h20"/>
        """#),
        LucideSkillIcon(id: "workflow", name: "Workflow", body: #"""
        <rect width="8" height="8" x="3" y="3" rx="2"/><path d="M7 11v4a2 2 0 0 0 2 2h4"/><rect width="8" height="8" x="13" y="13" rx="2"/>
        """#),
        LucideSkillIcon(id: "terminal", name: "Terminal", body: #"""
        <path d="M12 19h8"/><path d="m4 17 6-6-6-6"/>
        """#),
        LucideSkillIcon(id: "package", name: "Package", body: #"""
        <path d="M11 21.73a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73z"/><path d="M12 22V12"/><polyline points="3.29 7 12 12 20.71 7"/><path d="m7.5 4.27 9 5.15"/>
        """#),
        LucideSkillIcon(id: "plug", name: "Plug", body: #"""
        <path d="M12 22v-5"/><path d="M15 8V2"/><path d="M17 8a1 1 0 0 1 1 1v4a4 4 0 0 1-4 4h-4a4 4 0 0 1-4-4V9a1 1 0 0 1 1-1z"/><path d="M9 8V2"/>
        """#)
    ]

    var searchText: String {
        ([id, name] + tags).joined(separator: " ")
    }

    private static func loadCatalog() -> [LucideSkillIcon] {
        guard let spriteURL = resourceURL(
            packagedName: "Lucide-sprite",
            sourceName: "sprite",
            extension: "svg"
        ),
        let sprite = try? String(contentsOf: spriteURL, encoding: .utf8),
        let expression = try? NSRegularExpression(
            pattern: #"<symbol id="([^"]+)" viewBox="0 0 24 24">\s*(.*?)\s*</symbol>"#,
            options: [.dotMatchesLineSeparators]
        )
        else { return fallbackCatalog }

        let tags = loadTags()
        let range = NSRange(sprite.startIndex..<sprite.endIndex, in: sprite)
        let icons = expression.matches(in: sprite, range: range).compactMap { match -> LucideSkillIcon? in
            guard match.numberOfRanges == 3,
                  let idRange = Range(match.range(at: 1), in: sprite),
                  let bodyRange = Range(match.range(at: 2), in: sprite)
            else { return nil }
            let id = String(sprite[idRange])
            return LucideSkillIcon(
                id: id,
                name: id
                    .split(separator: "-")
                    .map { $0.capitalized }
                    .joined(separator: " "),
                body: String(sprite[bodyRange]),
                tags: tags[id] ?? []
            )
        }
        return icons.isEmpty ? fallbackCatalog : icons
    }

    private static func loadTags() -> [String: [String]] {
        guard let url = resourceURL(
            packagedName: "Lucide-tags",
            sourceName: "tags",
            extension: "json"
        ),
        let data = try? Data(contentsOf: url),
        let tags = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return [:] }
        return tags
    }

    private static func resourceURL(
        packagedName: String,
        sourceName: String,
        extension fileExtension: String
    ) -> URL? {
        resourceURL(
            in: .main,
            packagedName: packagedName,
            sourceName: sourceName,
            extension: fileExtension
        ) ?? resourceURL(
            in: .module,
            packagedName: packagedName,
            sourceName: sourceName,
            extension: fileExtension
        )
    }

    private static func resourceURL(
        in bundle: Bundle,
        packagedName: String,
        sourceName: String,
        extension fileExtension: String
    ) -> URL? {
        if let packaged = bundle.url(forResource: packagedName, withExtension: fileExtension) {
            return packaged
        }
        if let source = bundle.url(
            forResource: sourceName,
            withExtension: fileExtension,
            subdirectory: "Lucide"
        ) {
            return source
        }
        return bundle.url(forResource: sourceName, withExtension: fileExtension)
    }
}

private struct SkillIconEditorView: View {
    @ObservedObject var model: MetagentModel
    let row: InventorySkillRow
    var skillPath: String? = nil
    var skillName: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var selectedSource = SkillIconSource.emoji
    @State private var selectedEmoji = "✨"
    @State private var selectedLucideID = LucideSkillIcon.catalog[0].id
    @State private var lucideQuery = ""
    @FocusState private var emojiFieldIsFocused: Bool

    private var selectedLucide: LucideSkillIcon {
        LucideSkillIcon.catalog.first { $0.id == selectedLucideID } ?? LucideSkillIcon.catalog[0]
    }

    private var visibleLucideIcons: [LucideSkillIcon] {
        let query = lucideQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return LucideSkillIcon.catalog }
        return LucideSkillIcon.catalog.filter {
            $0.searchText.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.skillIconPath == nil ? "Add an icon" : "Change icon")
                        .font(.title2.weight(.semibold))
                    Text(skillName ?? row.skillName)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
            }

            SkillIconSourceSelector(selection: $selectedSource)

            Group {
                switch selectedSource {
                case .emoji: emojiPane
                case .lucide: lucidePane
                case .image: imagePane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Text("Metagent writes a portable PNG to assets/metagent-icon.png and records it in agents/openai.yaml. Lucide icons are provided under the ISC license.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(primaryActionTitle) { saveSelectedIcon() }
                .buttonStyle(.glassProminent)
                .disabled(
                    model.isRunning
                        || (selectedSource == .emoji && selectedEmoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                )
            }
        }
        .padding(22)
        .frame(width: 680, height: 600)
    }

    private var emojiPane: some View {
        HStack(alignment: .top, spacing: 20) {
            emojiPreview.frame(width: 96, height: 96)
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose an emoji").font(.headline)
                TextField("Selected emoji", text: $selectedEmoji)
                    .textFieldStyle(.roundedBorder)
                    .focused($emojiFieldIsFocused)
                    .frame(width: 190)
                Button {
                    emojiFieldIsFocused = true
                    DispatchQueue.main.async {
                        NSApp.orderFrontCharacterPalette(nil)
                    }
                } label: {
                    Label("Open Emoji & Symbols", systemImage: "face.smiling")
                }
                Text("Use the macOS character palette to search the complete emoji library. Your selection is inserted into the field above.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var lucidePane: some View {
        HStack(alignment: .top, spacing: 20) {
            lucidePreview.frame(width: 96, height: 96)
            VStack(alignment: .leading, spacing: 10) {
                GlassSearchField(placeholder: "Search Lucide icons", text: $lucideQuery, width: 430)
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(54)), count: 7), spacing: 8) {
                        ForEach(visibleLucideIcons) { icon in
                            Button {
                                selectedLucideID = icon.id
                            } label: {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(Color.accentColor.opacity(selectedLucideID == icon.id ? 1 : 0.72))
                                    if let image = icon.image {
                                        Image(nsImage: image).resizable().scaledToFit().padding(12)
                                    }
                                }
                                .frame(width: 50, height: 50)
                            }
                            .buttonStyle(.plain)
                            .help(icon.name)
                            .accessibilityLabel(icon.name)
                            .accessibilityAddTraits(selectedLucideID == icon.id ? .isSelected : [])
                        }
                    }
                }
                HStack {
                    Text(selectedLucide.name)
                    Spacer()
                    Text("\(visibleLucideIcons.count.formatted()) of \(LucideSkillIcon.catalog.count.formatted())")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var imagePane: some View {
        ContentUnavailableView {
            Label("Choose an image", systemImage: "photo")
        } description: {
            Text("Import a PNG, JPEG, or HEIC—including artwork exported from Icon Composer.")
        }
    }

    private var emojiPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
            Text(selectedEmoji)
                .font(.system(size: 54))
                .lineLimit(1)
        }
    }

    private var lucidePreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.accentColor)
            if let image = selectedLucide.image {
                Image(nsImage: image).resizable().scaledToFit().padding(24)
            }
        }
    }

    private var primaryActionTitle: String {
        switch selectedSource {
        case .emoji: "Use Emoji"
        case .lucide: "Use Lucide Icon"
        case .image: "Choose Image…"
        }
    }

    private func saveSelectedIcon() {
        if selectedSource == .image {
            chooseImage()
            return
        }
        let data = selectedSource == .emoji ? emojiPNG(selectedEmoji) : lucidePNG(selectedLucide)
        guard let data, model.updateSkillIcon(
            path: skillPath ?? row.canonicalPath,
            pngData: data
        ) else {
            NSSound.beep()
            return
        }
        dismiss()
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        panel.prompt = "Use Icon"
        guard panel.runModal() == .OK,
              let url = panel.url,
              let image = NSImage(contentsOf: url),
              let data = normalizedPNG(image),
              model.updateSkillIcon(path: skillPath ?? row.canonicalPath, pngData: data)
        else { return }
        dismiss()
    }
}

private func emojiPNG(_ emoji: String) -> Data? {
    let value = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    guard let (bitmap, context) = iconBitmap() else { return nil }
    let size = NSSize(width: 512, height: 512)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSColor.clear.setFill()
    NSRect(origin: .zero, size: size).fill()
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 340)
    ]
    let attributed = NSAttributedString(string: value, attributes: attributes)
    let textSize = attributed.size()
    attributed.draw(at: NSPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2))
    context.flushGraphics()
    return bitmap.representation(using: .png, properties: [:])
}

private func lucidePNG(_ icon: LucideSkillIcon) -> Data? {
    guard let source = icon.image,
          let (bitmap, context) = iconBitmap()
    else { return nil }
    let size = NSSize(width: 512, height: 512)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSColor.clear.setFill()
    NSRect(origin: .zero, size: size).fill()
    NSColor.controlAccentColor.setFill()
    NSBezierPath(
        roundedRect: NSRect(x: 16, y: 16, width: 480, height: 480),
        xRadius: 112,
        yRadius: 112
    ).fill()
    source.draw(
        in: NSRect(x: 104, y: 104, width: 304, height: 304),
        from: .zero,
        operation: .sourceOver,
        fraction: 1
    )
    context.flushGraphics()
    return bitmap.representation(using: .png, properties: [:])
}

private func normalizedPNG(_ source: NSImage) -> Data? {
    guard source.size.width > 0, source.size.height > 0,
          let (bitmap, context) = iconBitmap()
    else { return nil }
    let size = NSSize(width: 512, height: 512)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSColor.clear.setFill()
    NSRect(origin: .zero, size: size).fill()
    let sourceSize = source.size
    let scale = min(size.width / sourceSize.width, size.height / sourceSize.height)
    let drawSize = NSSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
    source.draw(
        in: NSRect(
            x: (size.width - drawSize.width) / 2,
            y: (size.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        ),
        from: .zero,
        operation: .sourceOver,
        fraction: 1
    )
    context.flushGraphics()
    return bitmap.representation(using: .png, properties: [:])
}

private func iconBitmap() -> (NSBitmapImageRep, NSGraphicsContext)? {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 512,
        pixelsHigh: 512,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [],
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
    return (bitmap, context)
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

private func skillFileURLs(for rows: [SkillTableRow]) -> [URL] {
    skillDirectoryURLs(for: rows).compactMap { directory in
        let file = directory.appendingPathComponent("SKILL.md")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }
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

@MainActor private func openSkillFiles(_ urls: [URL]) {
    urls.forEach { NSWorkspace.shared.open($0) }
}

@MainActor private func openSkillDirectoriesInEditor(_ directories: [URL], skillFiles: [URL]) {
    guard !directories.isEmpty else { return }
    guard let editor = preferredCodeEditor(for: skillFiles.first) else {
        openSkillFiles(skillFiles)
        return
    }
    openSkillDirectories(directories, with: editor)
}

@MainActor private func preferredCodeEditor(for skillFile: URL?) -> URL? {
    let knownEditorBundleIdentifiers = [
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.microsoft.VSCode",
        "com.exafunction.windsurf",
        "dev.zed.Zed",
        "com.sublimetext.4",
        "com.panic.Nova",
        "com.barebones.bbedit",
        "com.macromates.TextMate",
        "com.apple.dt.Xcode",
    ]
    if let override = UserDefaults.standard.string(forKey: "metagent.editor.bundle-id"),
       let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: override)
    {
        return application
    }
    if let skillFile,
       let defaultApplication = NSWorkspace.shared.urlForApplication(toOpen: skillFile),
       let bundleIdentifier = Bundle(url: defaultApplication)?.bundleIdentifier,
       knownEditorBundleIdentifiers.contains(bundleIdentifier)
    {
        return defaultApplication
    }
    return knownEditorBundleIdentifiers.lazy.compactMap {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
    }.first
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

private func displayUserPath(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path == home {
        return "~"
    }
    guard path.hasPrefix(home + "/") else {
        return path
    }
    return "~" + path.dropFirst(home.count)
}

private func parseISO8601Date(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
}

private func githubRepositoryName(url: String?) -> String? {
    guard let url, !url.isEmpty else { return nil }
    let normalized = url
        .replacingOccurrences(of: "git@github.com:", with: "https://github.com/")
        .replacingOccurrences(of: "ssh://git@github.com/", with: "https://github.com/")
    guard let components = URL(string: normalized)?.pathComponents.filter({ $0 != "/" }),
          components.count >= 2
    else { return nil }
    return components.prefix(2).joined(separator: "/").replacingOccurrences(of: ".git", with: "")
}

private func githubRepositoryName(source: String?) -> String? {
    guard let source, !source.isEmpty, !source.hasPrefix("path:") else { return nil }
    guard !source.hasPrefix("/"),
          !source.hasPrefix("~/"),
          !source.hasPrefix("./"),
          !source.hasPrefix("../"),
          !source.hasPrefix("file:")
    else { return nil }
    if source.contains("github.com") { return githubRepositoryName(url: source) }
    let components = source.split(separator: "/")
    guard components.count >= 2 else { return nil }
    return components.prefix(2).joined(separator: "/").replacingOccurrences(of: ".git", with: "")
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

private struct DirectoryFilterOption: Identifiable {
    let root: String
    let name: String

    var id: String { root }
}

private func directoryFilterOptions(
    projects: [ProjectStatus],
    mcpHealth: MCPHealthSnapshot,
    doctorIssues: [DoctorIssue]
) -> [DirectoryFilterOption] {
    var namesByRoot: [String: String] = [:]
    for project in projects {
        let isPluginProject = !project.skills.isEmpty && project.skills.allSatisfy { $0.location == "plugin" }
        guard !isPluginProject else { continue }
        namesByRoot[standardizedDirectoryPath(project.root)] = project.name
    }
    let additionalRoots = mcpHealth.servers.flatMap { $0.projectStates.map(\.path) }
        + doctorIssues.compactMap(\.projectRoot)
    for root in additionalRoots {
        let canonicalRoot = standardizedDirectoryPath(root)
        if namesByRoot[canonicalRoot] == nil {
            namesByRoot[canonicalRoot] = URL(fileURLWithPath: canonicalRoot).lastPathComponent
        }
    }
    return namesByRoot.map { DirectoryFilterOption(root: $0.key, name: $0.value) }
        .sorted { left, right in
            if left.root == NSHomeDirectory() { return true }
            if right.root == NSHomeDirectory() { return false }
            let nameOrder = left.name.localizedStandardCompare(right.name)
            return nameOrder == .orderedSame ? left.root < right.root : nameOrder == .orderedAscending
        }
}

private func directoryFilterLabel(_ directory: DirectoryFilterOption, options: [DirectoryFilterOption]) -> String {
    guard options.filter({ $0.name == directory.name }).count > 1 else {
        return directory.name
    }
    let parent = URL(fileURLWithPath: directory.root).deletingLastPathComponent().lastPathComponent
    return "\(directory.name) — \(parent)"
}

private func logicalSkillCount(projects: [ProjectStatus], selectedProjectRoot: String) -> Int {
    Set<String>(projects.flatMap { project in
        project.skills.compactMap { skill in
            guard skill.scope == "project", project.root == selectedProjectRoot else { return nil }
            return "\(project.root)\u{0}\(skill.name)"
        }
    }).count
}

private func projectFilteredMCPHealth(
    _ snapshot: MCPHealthSnapshot,
    selectedProjectRoot: String?
) -> MCPHealthSnapshot {
    guard let selectedProjectRoot else { return snapshot }
    return snapshot.projectOnly(at: selectedProjectRoot)
}

private func groupedDoctorActionCount(_ findings: [DoctorIssue]) -> Int {
    Set(findings.map { issue in
        [
            issue.projectRoot ?? "general",
            issue.category?.rawValue ?? "general",
            issue.repairAction?.rawValue ?? "review",
            issue.summary ?? issue.message
        ].joined(separator: "|")
    }).count
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
                    Text(displayUserPath(project.root))
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

#if DEBUG
// MARK: - Duplicate review previews

private enum DuplicateReviewPreviewData {
    static func skillItem(
        name: String,
        description: String,
        path: String,
        location: String,
        locationLabel: String,
        scope: String,
        manager: String,
        authority: String
    ) -> SkillInventoryItem {
        SkillInventoryItem(
            name: name,
            description: description,
            path: path,
            location: location,
            locationLabel: locationLabel,
            originKind: "installed",
            scope: scope,
            manager: manager,
            authority: authority,
            mutability: "editable",
            representation: "canonical",
            canonicalPath: path,
            source: nil,
            sourceType: nil,
            sourceURL: nil,
            ref: nil,
            installedAt: nil,
            updatedAt: nil,
            symlinkedContainer: false,
            folderKind: scope == "global" ? "home" : "project",
            characterCount: 5400,
            wordCount: 820,
            tokenEstimate: 1100,
            skillFileCharacterCount: 5400,
            skillFileWordCount: 820,
            skillFileTokenEstimate: 1100,
            textFileCount: 3,
            referenceFileCount: 2,
            scriptFileCount: 1,
            assetFileCount: 0,
            otherFileCount: 0,
            otherFolderCount: 0,
            hasOpenAIYaml: false,
            hasIconSmall: false,
            hasIconLarge: false,
            hasIconAndLogo: false,
            iconSmallPath: nil,
            iconLargePath: nil
        )
    }

    static func row(
        projectRoot: String,
        skill: SkillInventoryItem,
        invocations30d: Int,
        totalInvocations: Int,
        overlap: SkillOverlapMembership
    ) -> SkillTableRow {
        let project = ProjectStatus.previewFixture(project: SkillProject(
            root: projectRoot,
            skillsDir: projectRoot + "/.agents/skills",
            validSkills: [skill.name],
            skills: [skill]
        ))
        let inventory = InventorySkillRow(
            project: project,
            skill: project.skills[0],
            variants: project.skills,
            metagentScore: MetagentSkillScore(score: 78, confidence: .medium, components: []),
            pluginEval: nil,
            codexReview: nil
        )
        return SkillTableRow(
            inventory: inventory,
            usage: UsageSkillRow(
                id: "preview:\(projectRoot):\(skill.name)",
                skillName: skill.name,
                canonicalPath: skill.canonicalPath,
                scope: skill.scope,
                totalInvocations: totalInvocations,
                invocations7d: invocations30d / 3,
                invocations30d: invocations30d,
                distinctThreads: max(totalInvocations / 3, 1),
                repeatInvocations: 4,
                lastUsedDate: Date().addingTimeInterval(-2 * 86_400),
                lastUsedSortValue: 0,
                status: .active
            ),
            historicalProjectRoot: nil,
            pluginInventoryAvailable: true,
            overlap: overlap
        )
    }

    static var groups: [DuplicateReviewGroup] {
        let metagentDescription = "Analyze tooling, MCP/plugin availability, skill portfolios, and "
            + "instruction ownership. Use when diagnosing tool or namespace availability."
        let scraperDescription = "Scrape public data from social platforms via the ScrapeCreators "
            + "REST API. Use for profiles, posts, transcripts, and engagement metrics."

        let sameSkillGroup = DuplicateReviewGroup(
            id: "preview:metagent",
            kind: .globalProject,
            similarity: 1.0,
            rows: [
                row(
                    projectRoot: "/Users/preview/code_projects/agent-tools",
                    skill: skillItem(
                        name: "metagent",
                        description: metagentDescription,
                        path: "/Users/preview/code_projects/agent-tools/.agents/skills/metagent",
                        location: "agents",
                        locationLabel: ".agents",
                        scope: "project",
                        manager: "local",
                        authority: "local"
                    ),
                    invocations30d: 60,
                    totalInvocations: 67,
                    overlap: SkillOverlapMembership(
                        groupID: "preview:metagent",
                        kind: .globalProject,
                        similarity: 1.0,
                        suggestedRemoval: false
                    )
                ),
                row(
                    projectRoot: "/Users/preview",
                    skill: skillItem(
                        name: "metagent",
                        description: metagentDescription,
                        path: "/Users/preview/.agents/skills/metagent",
                        location: "agents",
                        locationLabel: ".agents",
                        scope: "global",
                        manager: "skills-cli",
                        authority: "skills-cli"
                    ),
                    invocations30d: 25,
                    totalInvocations: 33,
                    overlap: SkillOverlapMembership(
                        groupID: "preview:metagent",
                        kind: .globalProject,
                        similarity: 1.0,
                        suggestedRemoval: false
                    )
                ),
            ]
        )

        let pluginGroup = DuplicateReviewGroup(
            id: "preview:scrapecreators-api",
            kind: .pluginReplacement,
            similarity: 0.95,
            rows: [
                row(
                    projectRoot: "/Users/preview/.codex/plugins/scrape-pack",
                    skill: skillItem(
                        name: "scrapecreators-api",
                        description: scraperDescription,
                        path: "/Users/preview/.codex/plugins/scrape-pack/skills/scrapecreators-api",
                        location: "plugin",
                        locationLabel: "plugin",
                        scope: "plugin",
                        manager: "codex-plugin",
                        authority: "scrape-pack@skills"
                    ),
                    invocations30d: 18,
                    totalInvocations: 54,
                    overlap: SkillOverlapMembership(
                        groupID: "preview:scrapecreators-api",
                        kind: .pluginReplacement,
                        similarity: 0.95,
                        suggestedRemoval: false
                    )
                ),
                row(
                    projectRoot: "/Users/preview",
                    skill: skillItem(
                        name: "scrapecreators-api",
                        description: scraperDescription,
                        path: "/Users/preview/.agents/skills/scrapecreators-api",
                        location: "agents",
                        locationLabel: ".agents",
                        scope: "global",
                        manager: "skills-cli",
                        authority: "skills-cli"
                    ),
                    invocations30d: 2,
                    totalInvocations: 41,
                    overlap: SkillOverlapMembership(
                        groupID: "preview:scrapecreators-api",
                        kind: .pluginReplacement,
                        similarity: 0.95,
                        suggestedRemoval: true
                    )
                ),
            ]
        )

        return [sameSkillGroup, pluginGroup]
    }
}

#Preview("Duplicate review", traits: .fixedLayout(width: 980, height: 640)) {
    @Previewable @State var selectedGroupID: String?
    @Previewable @State var removalIDs = Set<SkillTableRow.ID>()
    DuplicateReviewExperience(
        groups: DuplicateReviewPreviewData.groups,
        hasVisibleGroups: true,
        hasDetectedGroups: true,
        selectedGroupID: $selectedGroupID,
        removalIDs: $removalIDs,
        isRunning: false,
        onView: { _ in },
        onInfo: { _ in },
        onReviewRemoval: { _ in },
        onKeepAll: { _ in },
        onReviewAgain: {}
    )
    .padding(20)
}

#Preview("Candidate card", traits: .fixedLayout(width: 380, height: 360)) {
    @Previewable @State var marked = false
    DuplicateCandidateCard(
        row: DuplicateReviewPreviewData.groups[0].rows[0],
        isMarkedForRemoval: $marked,
        onView: {},
        onInfo: {}
    )
    .padding(20)
}
#endif
