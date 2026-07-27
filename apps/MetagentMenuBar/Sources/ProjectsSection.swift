import AppKit
import Foundation
import MetagentCore
import SwiftUI
import UniformTypeIdentifiers

struct ProjectDirectoryRow: Identifiable {
    enum LinkState: String, Comparable {
        case healthy = "Connected"
        case notApplicable = "Independent"
        case nothingToMirror = "No shared skills"
        case missing = "Not connected"
        case separate = "Separate folder"
        case wrong = "Wrong link"

        static func < (lhs: LinkState, rhs: LinkState) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    let root: String
    let name: String
    let isGlobal: Bool
    let skillCount: Int
    let mcpCount: Int
    let claudeState: LinkState
    let codexOnlyCount: Int
    let claudeOnlyCount: Int
    let issueCount: Int
    let codebaseSize: CodebaseSizeReport?

    var id: String { root }
    var claudeText: String { claudeState.rawValue }
    /// Unmeasured folders sort as -1 so they group at one end of the column
    /// rather than mixing in with the genuinely smallest repositories.
    var codeLines: Int { codebaseSize?.codeLines ?? -1 }

    init(
        directory: DirectoryFilterOption,
        projects: [ProjectStatus],
        mcpHealth: MCPHealthSnapshot,
        doctorIssues: [DoctorIssue],
        codebaseSizes: [String: CodebaseSizeReport]
    ) {
        root = directory.root
        isGlobal = isGlobalRoot(directory.root)
        name = isGlobal ? "Global" : directory.name
        codebaseSize = codebaseSizes[standardizedDirectoryPath(directory.root)]
        let matchingProjects = projects.filter {
            standardizedDirectoryPath($0.root) == standardizedDirectoryPath(directory.root)
        }
        skillCount = Set(matchingProjects.flatMap { project in
            project.skills.map { skill in
                skill.canonicalPath.isEmpty ? "\(skill.name):\(skill.location)" : standardizedDirectoryPath(skill.canonicalPath)
            }
        }).count
        mcpCount = mcpHealth.projectOnly(at: directory.root).inventory.count
        let agentsPaths = Set(matchingProjects.flatMap { project in
            project.skills
                .filter { $0.location == "agents" && $0.representation == "canonical" }
                .map { standardizedDirectoryPath($0.canonicalPath.isEmpty ? $0.path : $0.canonicalPath) }
        })
        claudeState = Self.claudeLinkState(
            root: directory.root,
            isGlobal: isGlobal,
            hasSharedSkills: !agentsPaths.isEmpty
        )
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
        codebaseSizes: [String: CodebaseSizeReport],
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
                doctorIssues: doctorIssues,
                codebaseSizes: codebaseSizes
            )
        }
    }

    /// A missing `.claude/skills` is only a problem when there are shared
    /// skills for it to point at. Folders that reach this table for another
    /// reason — a project MCP server, say — have nothing to mirror, and the
    /// Doctor never scans them, so reporting them as broken would raise an
    /// alarm with no matching fix anywhere in the app.
    private static func claudeLinkState(
        root: String,
        isGlobal: Bool,
        hasSharedSkills: Bool
    ) -> LinkState {
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
            if isGlobal { return .notApplicable }
            return hasSharedSkills ? .missing : .nothingToMirror
        }
        // A `.claude/skills` that exists is worth describing either way: it is a
        // real directory somebody put there, shared skills or not.
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
            codebaseSizes: model.codebaseSizes,
            selectedProjectRoot: selectedProjectRoot
        )
    }

    /// Global is the home directory rather than a peer project, and its counts
    /// are not comparable to a repository's. It stays pinned above the sort so
    /// it never buries itself in the middle of the list.
    private func filteredRows(from allRows: [ProjectDirectoryRow]) -> [ProjectDirectoryRow] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = allRows
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.root.localizedCaseInsensitiveContains(query) }
        return matching.filter(\.isGlobal) + matching.filter { !$0.isGlobal }.sorted(using: sortOrder)
    }

    var body: some View {
        let allRows = allRows
        let rows = filteredRows(from: allRows)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                GlassSearchField(placeholder: "Search projects", text: $searchText, width: 220)
                CountChip(text: "\(allRows.count) directories")
                Spacer(minLength: 8)
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
                        ProjectNameCell(row: row)
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
                    TableColumn("Code", value: \.codeLines) { row in
                        ProjectCodebaseSizeCell(size: row.codebaseSize)
                    }
                    .width(min: 72, ideal: 88)
                    TableColumn("Claude symlink", value: \.claudeText) { row in
                        ProjectLinkStateCell(state: row.claudeState)
                    }
                    .width(min: 108, ideal: 118)
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
            codebaseSizes: model.codebaseSizes,
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

/// Global reads as the place everything else inherits from, so it carries the
/// globe and its own label instead of a folder path.
struct ProjectNameCell: View {
    let row: ProjectDirectoryRow

    var body: some View {
        HStack(spacing: 7) {
            if row.isGlobal {
                Image(systemName: "globe")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tint)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                    .font(.callout.weight(row.isGlobal ? .semibold : .medium))
                Text(row.isGlobal ? "Applies to every project" : displayUserPath(row.root))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .help(displayUserPath(row.root))
    }
}

/// Tracked code lines, so two projects can be compared by the part of the
/// repository a person actually maintains.
struct ProjectCodebaseSizeCell: View {
    let size: CodebaseSizeReport?

    var body: some View {
        if let size {
            Text(abbreviatedLineCount(size.codeLines))
                .monospacedDigit()
                .font(.callout)
                .help(detail(size))
        } else {
            Text("—")
                .foregroundStyle(.secondary)
                .help("Codebase size has not been measured for this project.")
        }
    }

    private func detail(_ size: CodebaseSizeReport) -> String {
        var lines = [
            "\(size.codeLines.formatted()) code lines across \(size.totalFiles.formatted()) tracked files",
            "Tests \(percent(size.signals.testLineRatio)) of code and tests"
                + " · docs \(percent(size.signals.documentationLineRatio))"
                + " · generated \(percent(size.signals.generatedLineRatio))",
            "\(size.signals.longFileCount) file(s) at or over \(size.longFileThreshold) lines"
                + " hold \(percent(size.signals.longFileLineRatio)) of code"
        ]
        if let language = size.languages.first {
            lines.append("Mostly \(language.language)")
        }
        return lines.joined(separator: "\n")
    }

    private func percent(_ ratio: Double) -> String {
        ratio.formatted(.percent.precision(.fractionLength(0)))
    }
}

func abbreviatedLineCount(_ lines: Int) -> String {
    guard lines >= 1_000 else { return lines.formatted() }
    let thousands = Double(lines) / 1_000
    return thousands < 100
        ? "\(thousands.formatted(.number.precision(.fractionLength(1))))k"
        : "\(thousands.formatted(.number.precision(.fractionLength(0))))k"
}

struct ProjectLinkStateCell: View {
    let state: ProjectDirectoryRow.LinkState

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(help)
            .accessibilityLabel(state.rawValue)
    }

    private var symbol: String {
        switch state {
        case .healthy: "checkmark.circle"
        case .notApplicable: "info.circle"
        case .nothingToMirror: "circle.dashed"
        case .missing: "minus.circle"
        case .separate: "folder.badge.questionmark"
        case .wrong: "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch state {
        case .healthy: .green
        case .notApplicable, .nothingToMirror, .missing: .secondary
        case .separate, .wrong: .orange
        }
    }

    private var help: String {
        switch state {
        case .healthy: ".claude/skills points to .agents/skills."
        case .notApplicable: "Global Claude skills are stored independently from .agents/skills. This is allowed, but the two locations do not share one canonical collection."
        case .nothingToMirror: "This folder has no shared .agents skills, so there is nothing for Claude to link to. It appears here for its other agent configuration."
        case .missing: "Claude does not currently see this project's .agents skills."
        case .separate: ".claude/skills is an independent directory, not a shared link."
        case .wrong: ".claude/skills is linked somewhere other than .agents/skills."
        }
    }
}

func isSymbolicLink(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
}
