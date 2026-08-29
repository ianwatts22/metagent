import Foundation
import MetagentCore
import SwiftUI

enum PluginInventoryFilter: String, CaseIterable, Identifiable {
    case all
    case manual
    case automatic
    case disabled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .manual: "Manual updates"
        case .automatic: "Auto-updated"
        case .disabled: "Disabled"
        }
    }

    func includes(_ row: PluginInventoryRow) -> Bool {
        switch self {
        case .all: true
        case .manual: row.record.updatePolicy == .manual
        case .automatic: row.record.updatePolicy == .automatic
        case .disabled: !row.record.enabled
        }
    }
}

struct PluginInventoryRow: Identifiable {
    let record: PluginRecord
    let outcome: PluginUpdateOutcome?

    var id: String { record.id }
    var name: String { record.name }
    var runtimeSortValue: String { record.runtime.displayName }
    var version: String { record.version }
    var scope: String { record.scope ?? "user" }
    var marketplace: String { record.marketplace }
    var policySortValue: String { record.updatePolicy.rawValue }
    var statusSortValue: String { record.enabled ? "enabled" : "disabled" }

    var policyHelp: String {
        switch record.updatePolicy {
        case .automatic:
            return "Kept current by its owner (the runtime, an official marketplace, or the app that installed it)."
        case .manual:
            let source = record.sourceDetail.isEmpty ? "a third-party marketplace" : record.sourceDetail
            var lines = ["Installed from \(source); only updates when the marketplace is refreshed."]
            if record.runtime == .claude, record.scope != "user" {
                lines.append("This \(record.scope ?? "unknown") scope must be updated from its owning project.")
            }
            if let outcome {
                lines.append(outcomeDescription(outcome))
            }
            return lines.joined(separator: "\n")
        }
    }

    private func outcomeDescription(_ outcome: PluginUpdateOutcome) -> String {
        switch outcome.status {
        case .updated: "Last run: updated \(outcome.fromVersion) → \(outcome.toVersion ?? "?")"
        case .upToDate: "Last run: already up to date"
        case .failed: "Last run failed: \(outcome.detail ?? "unknown error")"
        }
    }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return [name, record.pluginID, marketplace, scope, record.runtime.displayName, record.sourceDetail]
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

func pluginInventoryRows(
    _ snapshot: PluginInventorySnapshot,
    report: PluginUpdateReport?
) -> [PluginInventoryRow] {
    let outcomes = Dictionary(
        uniqueKeysWithValues: (report?.outcomes ?? []).map { ($0.id, $0) }
    )
    return snapshot.records.map {
        PluginInventoryRow(record: $0, outcome: outcomes[$0.id])
    }
}

struct PluginsSection: View {
    @ObservedObject var model: MetagentModel
    @State private var searchText = ""
    @State private var filter = PluginInventoryFilter.all
    @State private var sortOrder = [KeyPathComparator(\PluginInventoryRow.name)]

    private var allRows: [PluginInventoryRow] {
        pluginInventoryRows(model.pluginInventory, report: model.pluginUpdateReport)
    }

    private func filteredRows(from allRows: [PluginInventoryRow]) -> [PluginInventoryRow] {
        allRows
            .filter { filter.includes($0) && $0.matches(searchText) }
            .sorted(using: sortOrder)
    }

    private func manualCount(in allRows: [PluginInventoryRow]) -> Int {
        allRows.filter { $0.record.updatePolicy == .manual }.count
    }

    private var warnings: [String] {
        Array(Set(
            model.pluginInventory.warnings
                + (model.pluginUpdateReport?.warnings ?? [])
        )).sorted()
    }

    var body: some View {
        let allRows = allRows
        let rows = filteredRows(from: allRows)
        let manualCount = manualCount(in: allRows)
        let readyIdentifier = presentationReadyIdentifier(
            section: "plugins",
            state: [filter.rawValue, searchText, sortPresentationState(sortOrder)],
            orderedRowIDs: rows.map(\.id)
        )
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                GlassSearchField(
                    placeholder: "Search plugins",
                    text: $searchText,
                    width: 200,
                    accessibilityIdentifier: "metagent.plugins.search"
                )

                GlassSelectionMenu(
                    title: "Show",
                    selection: $filter,
                    options: Array(PluginInventoryFilter.allCases),
                    optionTitle: { $0.title },
                    width: 165
                )
                .accessibilityIdentifier("metagent.plugins.show-filter")

                CountChip(text: "\(allRows.count) plugins")

                Spacer(minLength: 8)

                PluginAutoUpdateControls(model: model, manualCount: manualCount)
            }

            if !warnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if rows.isEmpty {
                EmptyStateView(
                    title: allRows.isEmpty ? "No plugins found" : "No matching plugins",
                    message: allRows.isEmpty
                        ? "Refresh after installing a plugin in Codex or Claude Code."
                        : "Clear the search or choose a different filter.",
                    symbol: "puzzlepiece.extension"
                )
                .accessibilityIdentifier(readyIdentifier)
            } else {
                Table(rows, sortOrder: $sortOrder) {
                    TableColumn("Plugin", value: \.name) { row in
                        Text(row.name)
                            .font(.callout.weight(.medium))
                            .help(row.record.pluginID)
                    }
                    .width(min: 150, ideal: 220)

                    TableColumn("Runtime", value: \.runtimeSortValue) { row in
                        MCPClientIcons(clients: [row.record.runtime.client])
                    }
                    .width(min: 70, ideal: 80)

                    TableColumn("Version", value: \.version) { row in
                        Text(row.version)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 80, ideal: 110)

                    TableColumn("Scope", value: \.scope) { row in
                        Text(row.scope.capitalized)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .help(row.record.projectPath ?? row.scope.capitalized)
                    }
                    .width(min: 70, ideal: 85)

                    TableColumn("Marketplace", value: \.marketplace) { row in
                        Text(row.marketplace)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(row.record.sourceDetail.isEmpty
                                ? row.marketplace
                                : row.record.sourceDetail)
                    }
                    .width(min: 130, ideal: 190)

                    TableColumn("Updates", value: \.policySortValue) { row in
                        PluginPolicyCell(row: row)
                    }
                    .width(min: 90, ideal: 110)

                    TableColumn("Status", value: \.statusSortValue) { row in
                        Label(
                            row.record.enabled ? "Enabled" : "Disabled",
                            systemImage: row.record.enabled ? "checkmark.circle" : "minus.circle"
                        )
                        .font(.callout)
                        .foregroundStyle(row.record.enabled ? Color.secondary : Color.orange)
                    }
                    .width(min: 100, ideal: 120)
                }
                .tableStyle(.inset)
                .alternatingRowBackgrounds(.enabled)
                .accessibilityIdentifier(readyIdentifier)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// The auto-update switch and the run-now button live together so the state
/// of "who keeps these current" is decided in one place.
struct PluginAutoUpdateControls: View {
    @ObservedObject var model: MetagentModel
    let manualCount: Int

    var body: some View {
        HStack(spacing: 10) {
            Toggle("Auto-update", isOn: Binding(
                get: { model.isPluginAutoUpdateEnabled },
                set: { model.setPluginAutoUpdateEnabled($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("Periodically refresh third-party marketplaces and update their installed plugins. Official runtime plugins already update themselves.")

            Button {
                model.updateThirdPartyPlugins()
            } label: {
                if model.isUpdatingPlugins {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Updating…")
                    }
                } else {
                    Label("Update Now", systemImage: "arrow.down.circle")
                }
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .disabled(model.isUpdatingPlugins || manualCount == 0)
            .help(manualCount == 0
                ? "No third-party marketplace plugins installed."
                : "Refresh third-party marketplaces and update \(manualCount) plugin\(manualCount == 1 ? "" : "s") now.")
        }
    }
}

struct PluginPolicyCell: View {
    let row: PluginInventoryRow

    var body: some View {
        HStack(spacing: 5) {
            Text(row.record.updatePolicy.displayLabel)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    row.record.updatePolicy == .automatic
                        ? Color.secondary.opacity(0.14)
                        : Color.accentColor.opacity(0.16),
                    in: Capsule()
                )
            if let outcome = row.outcome {
                Image(systemName: outcomeSymbol(outcome))
                    .font(.caption)
                    .foregroundStyle(outcomeTint(outcome))
                    .accessibilityHidden(true)
            }
        }
        .help(row.policyHelp)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.record.updatePolicy.displayLabel) updates")
        .accessibilityHint(row.policyHelp)
    }

    private func outcomeSymbol(_ outcome: PluginUpdateOutcome) -> String {
        switch outcome.status {
        case .updated: "checkmark.circle.fill"
        case .upToDate: "checkmark.circle"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private func outcomeTint(_ outcome: PluginUpdateOutcome) -> Color {
        switch outcome.status {
        case .updated: .green
        case .upToDate: .secondary
        case .failed: .orange
        }
    }
}

struct PluginsMenuSection: View {
    @ObservedObject var model: MetagentModel
    let openMainWindow: () -> Void

    private var records: [PluginRecord] { model.pluginInventory.records }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Plugins")
                    .font(.headline)
                Spacer()
                Button(action: openMainWindow) {
                    Label("Window", systemImage: "macwindow")
                }
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                MetricView(
                    title: "Installed",
                    value: "\(records.count)",
                    symbol: "puzzlepiece.extension"
                )
                MetricView(
                    title: "Manual updates",
                    value: "\(records.filter { $0.updatePolicy == .manual }.count)",
                    symbol: "arrow.down.circle"
                )
            }

            Button(action: openMainWindow) {
                Label("Open Plugins", systemImage: "arrow.up.right.square")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)

            Spacer()
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
