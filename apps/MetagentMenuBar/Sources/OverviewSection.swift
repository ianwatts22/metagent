import AppKit
import Foundation
import MetagentCore
import SwiftUI
import UniformTypeIdentifiers

struct OverviewSection: View {
    @ObservedObject var model: MetagentModel
    let isCompact: Bool
    let selectedProjectRoot: String?
    let openDuplicateReview: () -> Void
    @State private var showsDoctorFindings = false
    @State private var showsRepair = false
    @State private var showsMCPDetails = false
    @State private var repairProjectRoot: String?
    @State private var skillHealth = SkillSystemHealth.empty
    @State private var isSkillHealthLoading = true
    @State private var loadedSkillHealthRefreshID: String?

    var body: some View {
        ScrollView(.vertical) {
            overviewContent
        }
        .scrollIndicators(.hidden)
        .task(id: skillHealthRefreshID) {
            await refreshSkillHealth()
        }
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

    private var overviewContent: some View {
        VStack(alignment: .leading, spacing: isCompact ? 8 : 12) {
            skillHealthSummary
            mcpConnections
            if doctorActionCount > 0 {
                cleanupStatus
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var skillHealthSummary: some View {
        VStack(alignment: .leading, spacing: isCompact ? 8 : 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Skill system")
                        .font(.title3.weight(.semibold))
                    Text(skillHealthScopeDetail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                if !isSkillHealthStale, skillHealth.duplicateGroupCount > 0 {
                    Button(action: openDuplicateReview) {
                        Label(
                            "Review \(skillHealth.duplicateGroupCount)",
                            systemImage: "square.on.square"
                        )
                    }
                    .buttonStyle(.glass)
                    .help("Review duplicate and overlapping skill installations")
                }
            }

            if isSkillHealthStale {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Calculating skill health…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
            } else if skillHealth.skillCount > 0 {
                HStack(spacing: 8) {
                    SkillHealthMetric(
                        title: "30d active",
                        value: recentActivityValue,
                        detail: recentActivityDetail,
                        symbol: "clock.arrow.circlepath",
                        help: recentActivityHelp,
                        isCompact: isCompact
                    )
                    SkillHealthMetric(
                        title: "Ever observed",
                        value: everObservedValue,
                        detail: everObservedDetail,
                        symbol: "eye",
                        help: usageCoverageHelp,
                        isCompact: isCompact
                    )
                }

                HStack(spacing: 6) {
                    Image(systemName: historyIndexingSymbol)
                        .foregroundStyle(.secondary)
                    Text(historyIndexingLabel)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .help(usageCoverageHelp)

                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: 16, alignment: .leading),
                        count: 2
                    ),
                    spacing: 10
                ) {
                    SkillHealthEvidence(
                        title: "Reads per installed skill",
                        value: invocationDistributionText,
                        detail: "lifetime indexed usage",
                        help: "Lifetime reads per installed skill in indexed session history, including zero-read skills.",
                        isCompact: isCompact
                    )
                    SkillHealthEvidence(
                        title: "Skill instructions",
                        value: "\(formatNumber(skillHealth.skillBodyTokenEstimate)) tokens",
                        detail: "SKILL.md estimate",
                        help: "Estimated tokens across installed SKILL.md files in the selected scope. References, scripts, and assets are excluded.",
                        isCompact: isCompact
                    )
                    SkillHealthEvidence(
                        title: "Catalog metadata",
                        value: "\(formatNumber(skillHealth.catalogTokenEstimate)) tokens",
                        detail: "name + description estimate",
                        help: "A four-characters-per-token estimate for skill names and descriptions. This is a useful discovery-catalog size, not a claim that every client injects all of it on every turn.",
                        isCompact: isCompact
                    )
                    SkillHealthEvidence(
                        title: "Age",
                        value: skillAgeText,
                        detail: skillAgeDetail,
                        help: "Weeks since the recorded upstream update or latest local content change. P50 is the median; P75 shows the older upper quartile. \(skillAgeDetail.capitalized).",
                        isCompact: isCompact,
                        showsDetailInCompact: skillHealth.ageDistribution.unknownCount > 0
                    )
                }
            }
        }
        .padding(isCompact ? 12 : 14)
        .cardBackground()
    }

    private var skillHealthRefreshID: String {
        "\(model.skillTableRevision):\(selectedProjectRoot ?? "all")"
    }

    private var isSkillHealthStale: Bool {
        isSkillHealthLoading || loadedSkillHealthRefreshID != skillHealthRefreshID
    }

    private var skillHealthScope: SkillSystemHealthScope {
        guard let selectedProjectRoot else { return .all }
        return isGlobalRoot(selectedProjectRoot)
            ? .global(root: selectedProjectRoot)
            : .project(root: selectedProjectRoot)
    }

    private var skillHealthScopeDetail: String {
        if isSkillHealthStale {
            return "Calculating installed-skill health"
        }
        guard let selectedProjectRoot else {
            return "\(skillHealth.skillCount) installed skills across global and project scopes"
        }
        if isGlobalRoot(selectedProjectRoot) {
            return "\(skillHealth.skillCount) installed skills in the global scope only"
        }
        return "\(skillHealth.skillCount) installed skills in this directory only"
    }

    private var historyIndexingLabel: String {
        switch skillHealth.usageCoverage {
        case .complete:
            return "History indexing complete"
        case let .updating(progress):
            return "History indexing \(progress.formatted(.percent.precision(.fractionLength(0)))) · rebuilding"
        case let .partial(progress):
            return "History indexing \(progress.formatted(.percent.precision(.fractionLength(0)))) · provisional"
        case .unavailable:
            return "History indexing unavailable"
        }
    }

    private var historyIndexingSymbol: String {
        switch skillHealth.usageCoverage {
        case .complete:
            return "checkmark.circle"
        case .updating:
            return "arrow.triangle.2.circlepath"
        case .partial:
            return "circle.dotted"
        case .unavailable:
            return "questionmark.circle"
        }
    }

    private var recentActivityValue: String {
        if case .unavailable = skillHealth.usageCoverage {
            return "—"
        }
        return "\(skillHealth.active30dSkillCount)"
    }

    private var recentActivityDetail: String {
        switch skillHealth.usageCoverage {
        case .complete:
            return "of \(skillHealth.skillCount) installed skills"
        case .updating, .partial:
            return "of \(skillHealth.skillCount) · provisional"
        case .unavailable:
            return "No indexed 30-day history"
        }
    }

    private var recentActivityHelp: String {
        let definition = "Installed skills with at least one observed read in the last 30 days."
        switch skillHealth.usageCoverage {
        case .complete:
            return "\(definition) Retained session history is fully indexed."
        case .updating, .partial:
            return "\(definition) History indexing is incomplete, so this count is provisional."
        case .unavailable:
            return "\(definition) No retained session corpus is indexed, so a count would be misleading."
        }
    }

    private var everObservedValue: String {
        if case .unavailable = skillHealth.usageCoverage {
            return "—"
        }
        return skillHealth.observedFraction.formatted(
            .percent.precision(.fractionLength(0))
        )
    }

    private var everObservedDetail: String {
        switch skillHealth.usageCoverage {
        case .complete:
            return "\(skillHealth.observedSkillCount) of \(skillHealth.skillCount) · \(skillHealth.neverObservedSkillCount) never observed"
        case .updating, .partial:
            return "\(skillHealth.observedSkillCount) of \(skillHealth.skillCount) so far · provisional"
        case .unavailable:
            return "No indexed session history"
        }
    }

    private var usageCoverageHelp: String {
        let prefix = "\(skillHealth.observedSkillCount) of \(skillHealth.skillCount) installed skills have at least one read in retained, currently indexed session history."
        switch skillHealth.usageCoverage {
        case .complete:
            return "\(prefix) History indexing is complete, so \(skillHealth.neverObservedSkillCount) skills have no observed read in that history."
        case let .updating(progress):
            return "\(prefix) A parser upgrade is rebuilding history and is \(progress.formatted(.percent.precision(.fractionLength(0)))) complete, so this percentage may change."
        case let .partial(progress):
            return "\(prefix) Initial history indexing is \(progress.formatted(.percent.precision(.fractionLength(0)))) complete, so this percentage is provisional."
        case .unavailable:
            return "\(prefix) No retained session corpus was found, so absence of observed reads is not evidence that a skill was never used."
        }
    }

    private var invocationDistributionText: String {
        let distribution = skillHealth.invocationDistribution
        return "P50 \(formatNumber(distribution.p50)) · P75 \(formatNumber(distribution.p75)) · P95 \(formatNumber(distribution.p95))"
    }

    private var skillAgeText: String {
        guard let median = skillHealth.ageDistribution.medianWeeks,
              let p75 = skillHealth.ageDistribution.p75Weeks
        else { return "—" }
        if median == 0, p75 == 0 {
            return "Updated this week"
        }
        return "\(formatAgeWeeks(median)) / \(formatAgeWeeks(p75))"
    }

    private var skillAgeDetail: String {
        let unknown = skillHealth.ageDistribution.unknownCount
        return unknown == 0
            ? "median / P75 age"
            : "median / P75 age · \(unknown) unknown"
    }

    private func formatAgeWeeks(_ weeks: Int) -> String {
        weeks == 0 ? "<1w" : "\(weeks)w"
    }

    @MainActor
    private func refreshSkillHealth() async {
        let refreshID = skillHealthRefreshID
        isSkillHealthLoading = true
        let projects = model.projects.map(\.coreProject)
        let usage = model.usageSnapshot
        let scope = skillHealthScope
        let health = await Task.detached(priority: .utility) {
            MetagentCore.skillSystemHealth(
                projects: projects,
                usage: usage,
                scope: scope
            )
        }.value
        guard !Task.isCancelled, refreshID == skillHealthRefreshID else { return }
        skillHealth = health
        loadedSkillHealthRefreshID = refreshID
        isSkillHealthLoading = false
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
        .cardBackground()
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
        .cardBackground()
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

}

struct MCPClientCount: View {
    let client: MCPClient
    let count: Int

    var body: some View {
        HStack(spacing: 5) {
            if let icon = AppBrand.applicationIcon(bundleIdentifier: client.bundleIdentifier) {
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

struct MCPHealthDisplayRow: Identifiable {
    let id: String
    let server: MCPServerHealth
    let title: String
    let detail: String
}

struct MCPHealthRow: View {
    let row: MCPHealthDisplayRow
    let openClient: () -> Void

    private var server: MCPServerHealth { row.server }

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: server.state.displaySymbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(server.state.displayTint)
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
                Text(server.state.displayLabel)
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
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: MCPClient.codex.bundleIdentifier) == nil
                ? "Show Codex config…"
                : "Open Codex…"
        case .claude: "Show Claude config…"
        }
    }
}

struct SkillHealthMetric: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let help: String
    let isCompact: Bool

    var body: some View {
        HStack(alignment: .top, spacing: isCompact ? 8 : 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: isCompact ? 26 : 30, height: isCompact ? 26 : 30)
                .background(Color.accentColor.opacity(0.1), in: Circle())

            VStack(alignment: .leading, spacing: isCompact ? 1 : 3) {
                Text(title)
                    .font((isCompact ? Font.footnote : .subheadline).weight(.medium))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: isCompact ? 22 : 27, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(detail)
                    .font(isCompact ? .caption : .footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(isCompact ? 1 : 2)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(isCompact ? 9 : 12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityHint(help)
    }
}

struct SkillHealthEvidence: View {
    let title: String
    let value: String
    let detail: String
    let help: String
    let isCompact: Bool
    var showsDetailInCompact = false

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 1 : 2) {
            Text(title)
                .font((isCompact ? Font.caption : .footnote).weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(isCompact ? .subheadline.weight(.semibold) : .headline)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if !isCompact || showsDetailInCompact {
                Text(detail)
                    .font(isCompact ? .caption : .footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, isCompact ? 2 : 5)
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityHint(help)
    }
}

struct DoctorFindingsView: View {
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

struct DoctorFindingRow: View {
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

struct DoctorProjectGroup: Identifiable {
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

struct DoctorCategoryGroup: Identifiable {
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
