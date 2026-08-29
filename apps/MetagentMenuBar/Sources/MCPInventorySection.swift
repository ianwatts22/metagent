import AppKit
import Foundation
import MetagentCore
import SwiftUI
import UniformTypeIdentifiers

enum MCPInventoryFilter: String, CaseIterable, Identifiable {
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

struct MCPInventoryRow: Identifiable {
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
    var statusLabel: String { state.displayLabel }
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

func mcpInventoryRows(
    _ snapshot: MCPHealthSnapshot,
    selectedProjectRoot: String?
) -> [MCPInventoryRow] {
    projectFilteredMCPHealth(snapshot, selectedProjectRoot: selectedProjectRoot)
        .inventory
        .map(MCPInventoryRow.init)
}

struct MCPInventorySection: View {
    @ObservedObject var model: MetagentModel
    let selectedProjectRoot: String?
    @State private var searchText = ""
    @State private var filter = MCPInventoryFilter.all
    @State private var sortOrder = [KeyPathComparator(\MCPInventoryRow.name)]

    private var allRows: [MCPInventoryRow] {
        mcpInventoryRows(model.mcpHealth, selectedProjectRoot: selectedProjectRoot)
    }

    private func filteredRows(from allRows: [MCPInventoryRow]) -> [MCPInventoryRow] {
        allRows
            .filter { filter.includes($0) && $0.matches(searchText) }
            .sorted(using: sortOrder)
    }

    var body: some View {
        let allRows = allRows
        let rows = filteredRows(from: allRows)
        let readyIdentifier = presentationReadyIdentifier(
            section: "mcps",
            publicState: "filter-\(filter.rawValue)",
            state: [
                filter.rawValue,
                searchText,
                selectedProjectRoot ?? "",
                sortPresentationState(sortOrder),
            ],
            orderedRowIDs: rows.map(\.id)
        )
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                GlassSearchField(
                    placeholder: "Search MCPs",
                    text: $searchText,
                    width: 220,
                    accessibilityIdentifier: "metagent.mcps.search"
                )

                GlassSelectionMenu(
                    title: "Status",
                    selection: $filter,
                    options: Array(MCPInventoryFilter.allCases),
                    optionTitle: { $0.title },
                    width: 165
                )
                .accessibilityIdentifier("metagent.mcps.status-filter")

                CountChip(text: "\(allRows.count) servers")

                Spacer(minLength: 8)
            }

            if rows.isEmpty {
                VStack(spacing: 6) {
                    MCPServerIcon(size: 24)
                        .foregroundStyle(.secondary)
                    Text(allRows.isEmpty ? "No MCP servers found" : "No matching MCPs")
                        .font(.callout.weight(.semibold))
                    Text(allRows.isEmpty
                        ? "Refresh after configuring an MCP server in Codex or Claude."
                        : "Clear the search or choose a different status.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
                .accessibilityIdentifier(readyIdentifier)
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
                .accessibilityIdentifier(readyIdentifier)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct MCPMenuSection: View {
    @ObservedObject var model: MetagentModel
    let selectedProjectRoot: String?
    let openMainWindow: () -> Void

    private var rows: [MCPInventoryRow] {
        mcpInventoryRows(model.mcpHealth, selectedProjectRoot: selectedProjectRoot)
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
                HStack(spacing: 7) {
                    MCPServerIcon(size: 16)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Servers")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(rows.count.formatted())
                            .font(.callout.weight(.medium))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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

struct MCPClientIcons: View {
    let clients: [MCPClient]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(clients, id: \.self) { client in
                if let icon = AppBrand.applicationIcon(bundleIdentifier: client.bundleIdentifier) {
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
}

struct MCPLocationCell: View {
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

struct MCPStateCell: View {
    let state: MCPConnectionState
    let label: String

    var body: some View {
        Label(label, systemImage: state.displaySymbol)
            .font(.callout)
            .foregroundStyle(state.displayTint)
    }
}
