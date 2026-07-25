import AppKit
import Foundation
import MetagentCore
import SwiftUI
import UniformTypeIdentifiers

struct ProjectDirectoryRow: Identifiable {
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
            isGlobal: isGlobalRoot(directory.root)
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

    static func rows(
        projects: [ProjectStatus],
        mcpHealth: MCPHealthSnapshot,
        doctorIssues: [DoctorIssue],
        selectedProjectRoot: String?
    ) -> [ProjectDirectoryRow] {
        directoryFilterOptions(
            projects: projects,
            mcpHealth: mcpHealth,
            doctorIssues: doctorIssues
        )
        .filter { directory in
            guard let selectedProjectRoot else { return true }
            return standardizedDirectoryPath(directory.root) == standardizedDirectoryPath(selectedProjectRoot)
        }
        .map {
            ProjectDirectoryRow(
                directory: $0,
                projects: projects,
                mcpHealth: mcpHealth,
                doctorIssues: doctorIssues
            )
        }
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

struct ProjectsSection: View {
    @ObservedObject var model: MetagentModel
    let selectedProjectRoot: String?
    @State private var searchText = ""
    @State private var sortOrder = [KeyPathComparator(\ProjectDirectoryRow.name)]

    private var allRows: [ProjectDirectoryRow] {
        ProjectDirectoryRow.rows(
            projects: model.projects,
            mcpHealth: model.mcpHealth,
            doctorIssues: model.doctorIssues,
            selectedProjectRoot: selectedProjectRoot
        )
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

struct ProjectsMenuSection: View {
    @ObservedObject var model: MetagentModel
    let selectedProjectRoot: String?
    let openMainWindow: () -> Void

    private var rows: [ProjectDirectoryRow] {
        ProjectDirectoryRow.rows(
            projects: model.projects,
            mcpHealth: model.mcpHealth,
            doctorIssues: model.doctorIssues,
            selectedProjectRoot: selectedProjectRoot
        )
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

struct ProjectLinkStateCell: View {
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

func isSymbolicLink(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
}
