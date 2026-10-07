import MetagentCore
import SwiftUI

/// One list for choosing the project scope and for hiding projects. Hidden
/// folders stay in the list, dimmed, so hiding and unhiding are the same eye
/// toggle and several can be flipped without the popover closing.
struct ProjectScopePicker: View {
    @ObservedObject var model: MetagentModel
    @Binding var selectedProjectRoot: String?
    let directoryOptions: [DirectoryFilterOption]
    let dismiss: () -> Void
    @State private var search = ""
    @State private var hoveredRoot: String?

    private struct Row: Identifiable {
        let root: String
        let name: String
        let isHidden: Bool
        /// Unhidden this session; selectable once the rescan finds it.
        let isPending: Bool
        var id: String { root }
    }

    /// Visible projects first, alphabetically; hidden ones dimmed at the bottom.
    private var rows: (visible: [Row], hidden: [Row]) {
        let hidden = model.hiddenProjects
        let visible = directoryOptions
            .filter { !isGlobalRoot($0.root) && !hidden.hides($0.root) }
            .map { Row(root: $0.root, name: directoryFilterLabel($0, options: directoryOptions), isHidden: false, isPending: false) }
        let known = Set(visible.map(\.root))
        let pending = model.unhidingProjectRoots
            .filter { !known.contains($0) && !hidden.hides($0) }
            .map { Row(root: $0, name: folderName($0), isHidden: false, isPending: true) }
        let hiddenRows = hidden.entries
            .filter { !isGlobalRoot($0) }
            .map { Row(root: $0, name: folderName($0), isHidden: true, isPending: false) }
        return (sortedMatches(visible + pending), sortedMatches(hiddenRows))
    }

    private func sortedMatches(_ rows: [Row]) -> [Row] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return rows
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.root.localizedCaseInsensitiveContains(query) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        let rows = rows
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search projects", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if search.isEmpty {
                        scopeRow(title: "All projects", detail: "Every project plus global skills",
                                 systemImage: "square.stack", root: nil)
                        if let global = directoryOptions.first(where: { isGlobalRoot($0.root) }) {
                            scopeRow(title: "Global only", detail: "Skills in ~/.agents, ~/.codex and ~/.claude",
                                     systemImage: "globe", root: global.root)
                        }
                        Divider().padding(.vertical, 4)
                    }
                    ForEach(rows.visible) { row in
                        projectRow(row)
                    }
                    ForEach(rows.hidden) { row in
                        projectRow(row)
                    }
                    if rows.visible.isEmpty && rows.hidden.isEmpty {
                        Text("No matching projects")
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 460)
        }
        .frame(width: 320)
    }

    private func scopeRow(title: String, detail: String, systemImage: String, root: String?) -> some View {
        Button {
            selectedProjectRoot = root
            dismiss()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if selectedProjectRoot == root {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func projectRow(_ row: Row) -> some View {
        HStack(spacing: 8) {
            Button {
                if row.isHidden {
                    model.unhideProjects([row.root])
                } else {
                    model.hideProjects([row.root])
                }
            } label: {
                // The eye appears on hover; a hidden row keeps its slashed
                // eye so its state never depends on the pointer.
                Image(systemName: row.isHidden ? "eye.slash" : "eye")
                    .foregroundStyle(row.isHidden ? .tertiary : .secondary)
                    .opacity(row.isHidden || hoveredRoot == row.root ? 1 : 0)
                    .frame(width: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(row.isHidden ? "Show this project again" : "Hide this project and everything inside it")
            .accessibilityLabel(row.isHidden ? "Show \(row.name)" : "Hide \(row.name)")

            Button {
                selectedProjectRoot = row.root
                dismiss()
            } label: {
                HStack {
                    Text(row.name)
                        .foregroundStyle(row.isHidden || row.isPending ? .tertiary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if selectedProjectRoot == row.root {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(row.isHidden || row.isPending)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onHover { hoveredRoot = $0 ? row.root : (hoveredRoot == row.root ? nil : hoveredRoot) }
        .help(displayUserPath(row.root))
    }

    private func folderName(_ root: String) -> String {
        URL(fileURLWithPath: root).lastPathComponent
    }
}
