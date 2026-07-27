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
    @State private var historyTrends = SkillHistoryTrends.empty

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
        VStack(alignment: .leading, spacing: isCompact ? 8 : 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Skills")
                        .font((isCompact ? Font.title3 : .title).weight(.semibold))

                    if !isSkillHealthStale, !scopeChips.isEmpty {
                        HStack(spacing: 5) {
                            ForEach(scopeChips, id: \.self) { chip in
                                Text(chip)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(.quaternary.opacity(0.6), in: Capsule())
                            }
                        }
                        .help(scopeChipsHelp)
                    }
                }

                Spacer(minLength: 12)

                if !isSkillHealthStale, skillHealth.duplicateGroupCount > 0 {
                    Button(action: openDuplicateReview) {
                        Label(
                            "Review \(skillHealth.duplicateGroupCount)",
                            systemImage: "checklist"
                        )
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
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
                GlassEffectContainer(spacing: isCompact ? 6 : 8) {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(), spacing: isCompact ? 6 : 8),
                            count: isCompact ? 2 : 3
                        ),
                        spacing: isCompact ? 6 : 8
                    ) {
                        ForEach(metricCards) { card in
                            SkillHealthCard(
                                card: card,
                                isCompact: isCompact,
                                trendCoverage: historyTrends.coverage
                            )
                        }
                    }
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

    /// The scope facts as short, scannable chips rather than a sentence.
    private var scopeChips: [String] {
        var chips = ["\(skillHealth.skillCount) installed"]
        if skillHealth.assessedSkillCount != skillHealth.skillCount {
            chips.append("\(skillHealth.assessedSkillCount) rated")
        }
        if skillHealth.dormantProjectCount > 0 {
            chips.append("\(skillHealth.dormantProjectCount) dormant")
        }
        return chips
    }

    private var scopeChipsHelp: String {
        let scope: String
        if let selectedProjectRoot {
            scope = isGlobalRoot(selectedProjectRoot)
                ? "Counting the global scope only."
                : "Counting this directory only."
        } else {
            scope = "Counting global and project scopes together."
        }
        return "\(scope) \(ratedScopeHelp)"
    }

    private var metricCards: [SkillHealthCardModel] {
        [unusedCard, neverUsedCard, readsCard, instructionsCard, catalogCard, ageCard]
    }

    /// Exactly the metrics the six cards draw, so the history read stays scoped
    /// to what is shown rather than pulling every recorded series.
    private var overviewTrendMetrics: [SkillHistoryMetric] {
        [
            .adoptionUnused30d,
            .adoptionNeverObserved,
            .readsP50,
            .tokensSkillBody,
            .tokensCatalog,
            .ageMedianWeeks,
        ]
    }

    /// Unused rate drives the color ramp: green under 20%, yellow under 40%,
    /// orange under 60%, red at or above 60%.
    private func adoptionSeverity(_ fraction: Double) -> SkillHealthSeverity {
        guard isUsageIndexed else { return .neutral }
        return switch fraction {
        case ..<0.20: .good
        case ..<0.40: .caution
        case ..<0.60: .warning
        default: .alert
        }
    }

    private var isUsageIndexed: Bool {
        if case .unavailable = skillHealth.usageCoverage { return false }
        return true
    }

    /// The share leads because it is what the rate means; the raw counts follow
    /// quietly for anyone who wants to check the arithmetic.
    private func rateValue(_ count: Int, fraction: Double) -> SkillHealthValue {
        guard isUsageIndexed, skillHealth.assessedSkillCount > 0 else {
            return SkillHealthValue(primary: "—", trailing: "not indexed")
        }
        return SkillHealthValue(
            primary: fraction.formatted(.percent.precision(.fractionLength(0))),
            trailing: "\(count) of \(skillHealth.assessedSkillCount)",
            severity: adoptionSeverity(fraction)
        )
    }

    private var ratedScopeHelp: String {
        guard skillHealth.dormantSkillCount > 0 else {
            return "All \(skillHealth.assessedSkillCount) installed skills in this scope are rated."
        }
        return "\(skillHealth.dormantSkillCount) project skills in \(skillHealth.dormantProjectCount) directories with no agent session in the last 30 days are excluded, so dormant work does not distort the rate."
    }

    private var unusedCard: SkillHealthCardModel {
        SkillHealthCardModel(
            id: "unused",
            title: "Unused, last 30 days",
            content: .value(rateValue(
                skillHealth.unused30dSkillCount,
                fraction: skillHealth.unused30dFraction
            )),
            help: "Rated skills with no observed read in the last 30 days. \(ratedScopeHelp) \(coverageCaveat)",
            trend: historyTrends[.adoptionUnused30d],
            risingIsGood: false
        )
    }

    private var neverUsedCard: SkillHealthCardModel {
        SkillHealthCardModel(
            id: "never-used",
            title: "Never used",
            content: .value(rateValue(
                skillHealth.neverObservedSkillCount,
                fraction: skillHealth.neverObservedFraction
            )),
            help: "Rated skills with no observed read anywhere in retained, indexed session history. \(ratedScopeHelp) \(coverageCaveat)",
            trend: historyTrends[.adoptionNeverObserved],
            risingIsGood: false
        )
    }

    private var readsCard: SkillHealthCardModel {
        let distribution = skillHealth.invocationDistribution
        // Only the median carries a health claim: a P50 of zero means most of
        // the portfolio has never been read at all.
        let medianSeverity: SkillHealthSeverity = !isUsageIndexed
            ? .neutral
            : (distribution.p50 == 0 ? .alert : (distribution.p50 < 3 ? .warning : .good))
        return SkillHealthCardModel(
            id: "reads",
            title: "Lifetime reads per skill",
            content: .segments([
                SkillHealthSegment(
                    id: "p50",
                    value: SkillHealthValue(
                        primary: formatNumber(distribution.p50),
                        trailing: "P50",
                        severity: medianSeverity
                    ),
                    label: "P50"
                ),
                SkillHealthSegment(
                    id: "p75",
                    value: SkillHealthValue(primary: formatNumber(distribution.p75), trailing: "P75"),
                    label: "P75"
                ),
                SkillHealthSegment(
                    id: "p95",
                    value: SkillHealthValue(primary: formatNumber(distribution.p95), trailing: "P95"),
                    label: "P95"
                ),
            ]),
            help: "Lifetime reads per rated skill in indexed session history, including zero-read skills. A P50 of zero means most of the portfolio has never been read. \(coverageCaveat)",
            trend: historyTrends[.readsP50],
            risingIsGood: true
        )
    }

    private var instructionsCard: SkillHealthCardModel {
        SkillHealthCardModel(
            id: "instructions",
            title: "SKILL.md instructions",
            content: .value(SkillHealthValue(
                primary: formatNumber(skillHealth.skillBodyTokenEstimate),
                trailing: "tokens"
            )),
            help: "Estimated tokens across every installed SKILL.md in the selected scope, including dormant directories. References, scripts, and assets are excluded. Bodies load on demand, so this is inventory size rather than per-session cost.",
            trend: historyTrends[.tokensSkillBody]
        )
    }

    private var catalogCard: SkillHealthCardModel {
        let tokens = skillHealth.catalogTokenEstimate
        return SkillHealthCardModel(
            id: "catalog",
            title: "Catalog metadata",
            content: .value(SkillHealthValue(
                primary: formatNumber(tokens),
                trailing: "tokens",
                severity: tokens < 10_000 ? .good : (tokens < 20_000 ? .warning : .alert)
            )),
            help: "A four-characters-per-token estimate for skill names and descriptions across every installed skill in scope. This is a useful discovery-catalog size, not a claim that every client injects all of it on every turn.",
            trend: historyTrends[.tokensCatalog],
            risingIsGood: false
        )
    }

    private var ageCard: SkillHealthCardModel {
        let distribution = skillHealth.ageDistribution
        return SkillHealthCardModel(
            id: "age",
            title: skillAgeTitle,
            content: .value(SkillHealthValue(
                primary: distribution.medianWeeks.map(formatAgeWeeks) ?? "—",
                trailing: distribution.p75Weeks.map { "P75 \(formatAgeWeeks($0))" },
                severity: distribution.medianWeeks.map {
                    $0 < 8 ? .good : ($0 < 26 ? .caution : ($0 < 52 ? .warning : .alert))
                } ?? .neutral
            )),
            help: "Weeks since the recorded upstream update or latest local content change. The headline is the median; P75 shows the older upper quartile. Calendar age alone is not evidence of poor quality.",
            trend: historyTrends[.ageMedianWeeks]
        )
    }

    private var coverageCaveat: String {
        switch skillHealth.usageCoverage {
        case .complete:
            return "Retained session history is fully indexed."
        case let .updating(progress):
            return "A parser upgrade is rebuilding history and is \(progress.formatted(.percent.precision(.fractionLength(0)))) complete, so this is provisional."
        case let .partial(progress):
            return "Initial history indexing is \(progress.formatted(.percent.precision(.fractionLength(0)))) complete, so this is provisional."
        case .unavailable:
            return "No retained session corpus is indexed, so absence of observed reads is not evidence a skill was never used."
        }
    }

    private var skillAgeTitle: String {
        let unknown = skillHealth.ageDistribution.unknownCount
        return unknown == 0
            ? "Median time since update"
            : "Median age · \(unknown) unknown"
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
        let historyScope = skillHistoryScope
        let historyMetrics = overviewTrendMetrics
        let (health, trends) = await Task.detached(priority: .utility) {
            (
                MetagentCore.skillSystemHealth(
                    projects: projects,
                    usage: usage,
                    scope: scope,
                    activity: MetagentCore.scanProjectActivity(roots: projects.map(\.root))
                ),
                (try? MetagentCore.skillHistoryTrends(
                    metrics: historyMetrics,
                    scope: historyScope,
                    windowDays: 30
                )) ?? .empty
            )
        }.value
        guard !Task.isCancelled, refreshID == skillHealthRefreshID else { return }
        skillHealth = health
        historyTrends = trends
        loadedSkillHealthRefreshID = refreshID
        isSkillHealthLoading = false
    }

    /// The history scope mirrors the directory menu: no selection means the
    /// whole portfolio, the global root means global only.
    private var skillHistoryScope: SkillHistoryScope {
        guard let selectedProjectRoot else { return .all }
        return isGlobalRoot(selectedProjectRoot)
            ? .global
            : .project(root: selectedProjectRoot)
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
                    if let mcpSummaryText {
                        Text(mcpSummaryText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 16)

                // The configured total lives with the per-client breakdown it
                // decomposes into, rather than in the status line.
                HStack(spacing: 13) {
                    Text("\(scopedMCPHealth.configuredCount) configured")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.secondary)

                    Divider()
                        .frame(height: 20)

                    MCPClientCount(
                        client: .codex,
                        count: scopedMCPHealth.count(for: .codex)
                    )
                    MCPClientCount(
                        client: .claude,
                        count: scopedMCPHealth.count(for: .claude)
                    )
                }

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

    /// Silence is the healthy state: the green check already says everything is
    /// fine, so there is nothing left to write.
    private var mcpSummaryText: String? {
        guard scopedMCPHealth.observedAt != .distantPast else {
            return "Checking configuration…"
        }
        let attention = groupedMCPRows(scopedMCPHealth.attention).count
        guard attention > 0 else { return nil }
        return "\(attention) \(attention == 1 ? "server needs" : "servers need") attention"
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
        HStack(spacing: 7) {
            if let icon = AppBrand.applicationIcon(bundleIdentifier: client.bundleIdentifier) {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            Text("\(client.displayName) \(count)")
                .font(.body.weight(.medium))
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

/// How strongly a metric should be judged. `neutral` means the number is
/// informational and carries no target.
enum SkillHealthSeverity {
    case neutral
    case good
    case caution
    case warning
    case alert

    var tint: Color {
        switch self {
        case .neutral: .secondary
        case .good: .green
        case .caution: .yellow
        case .warning: .orange
        case .alert: .red
        }
    }

    var label: String {
        switch self {
        case .neutral: "No target"
        case .good: "Healthy"
        case .caution: "Worth watching"
        case .warning: "Needs attention"
        case .alert: "Needs action"
        }
    }
}

/// One headline number with an optional muted qualifier beside it.
struct SkillHealthValue {
    let primary: String
    var trailing: String?
    var severity = SkillHealthSeverity.neutral
}

/// One slice of a distribution, shown as its own tile inside a card.
struct SkillHealthSegment: Identifiable {
    let id: String
    let value: SkillHealthValue
    let label: String
}

enum SkillHealthContent {
    case value(SkillHealthValue)
    case segments([SkillHealthSegment])
}

struct SkillHealthCardModel: Identifiable {
    let id: String
    /// The title carries the whole description; there is no sub-label, because
    /// a second line of prose mostly restated the first.
    let title: String
    let content: SkillHealthContent
    let help: String
    /// The recorded movement of this metric, when history has enough days.
    var trend: SkillHistoryTrend?
    /// Whether a rising line is a good outcome. `nil` means the metric carries
    /// no direction worth judging, such as inventory size.
    var risingIsGood: Bool?
}

struct SkillHealthCard: View {
    let card: SkillHealthCardModel
    let isCompact: Bool
    var trendCoverage = SkillHistoryCoverage.empty

    /// The line follows the number's own status colour when the metric carries a
    /// judgment, so a card never says "healthy" in the figure and something else
    /// in the line beside it.
    private var trendTint: Color {
        if case let .value(value) = card.content, value.severity != .neutral {
            return value.severity.tint
        }
        return .secondary
    }

    /// Percentage metrics read as whole points; counts and tokens read as
    /// counts. Both drop the fraction, because a delta is a direction with a
    /// magnitude, not a precise measurement.
    private var deltaFormatter: (Double) -> String {
        { $0.formatted(.number.precision(.fractionLength(0))) }
    }

    var body: some View {
        // The number leads and the label explains it, so a card reads
        // "63% — unused, last 30 days" rather than the reverse.
        VStack(alignment: .leading, spacing: 0) {
            content

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(card.title)
                    .font((isCompact ? Font.subheadline : .headline).weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Spacer(minLength: 0)

                if let trend = card.trend, let change = trend.change {
                    HistoryDelta(
                        change: change,
                        baselineDay: trend.baselineDay,
                        risingIsGood: card.risingIsGood,
                        formatter: deltaFormatter
                    )
                }
            }
            .padding(.top, isCompact ? 5 : 7)

            // The trend is supporting detail, so the compact panel drops it
            // rather than shrinking the number that carries the fact.
            if !isCompact, let trend = card.trend {
                Group {
                    if trend.isPlottable {
                        HistorySparkline(points: HistoryPlot.points(trend.points), tint: trendTint)
                    } else {
                        HistoryTrendPlaceholder(coverage: trendCoverage)
                    }
                }
                .padding(.top, 5)
            }
        }
        .frame(maxWidth: .infinity, minHeight: isCompact ? 52 : 68, alignment: .topLeading)
        .padding(.horizontal, isCompact ? 11 : 13)
        .padding(.vertical, isCompact ? 9 : 11)
        .glassEffect(in: RoundedRectangle(cornerRadius: isCompact ? 11 : 13, style: .continuous))
        .help(card.help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(card.help)
    }

    @ViewBuilder
    private var content: some View {
        switch card.content {
        case let .value(value):
            valueRow(value, size: isCompact ? 24 : 34)
        case let .segments(segments):
            HStack(spacing: isCompact ? 4 : 6) {
                ForEach(segments) { segment in
                    valueRow(segment.value, size: isCompact ? 19 : 25)
                        .padding(.horizontal, isCompact ? 7 : 9)
                        .padding(.vertical, isCompact ? 4 : 5)
                        .background(
                            .quaternary.opacity(0.55),
                            in: RoundedRectangle(cornerRadius: isCompact ? 7 : 9, style: .continuous)
                        )
                }
            }
        }
    }

    /// Every number in the card, headline or percentile, uses the same shape:
    /// the figure, then its qualifier in muted text beside it.
    private func valueRow(_ value: SkillHealthValue, size: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value.primary)
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .foregroundStyle(value.severity == .neutral ? Color.primary : value.severity.tint)
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            if let trailing = value.trailing {
                Text(trailing)
                    .font((isCompact ? Font.caption : .subheadline).weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            Spacer(minLength: 0)
        }
    }

    private var accessibilityText: String {
        switch card.content {
        case let .value(value):
            let trailing = value.trailing.map { ", \($0)" } ?? ""
            return "\(card.title), \(value.primary)\(trailing), \(value.severity.label)"
        case let .segments(segments):
            let readout = segments
                .map { "\($0.label) \($0.value.primary)" }
                .joined(separator: ", ")
            return "\(card.title), \(readout)"
        }
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
