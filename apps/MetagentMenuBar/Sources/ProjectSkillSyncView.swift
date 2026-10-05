import AppKit
import MetagentCore
import SwiftUI

struct ProjectSkillSyncDestination: Identifiable {
    let root: String
    var id: String { root }
}

/// Explicit, action-time reads only. No portfolio scan, automatic mirroring,
/// or bundle I/O on the main actor.
struct ProjectSkillSyncView: View {
    @ObservedObject var model: MetagentModel
    let projectRoot: String
    @Environment(\.dismiss) private var dismiss
    @State private var names: [String] = []
    @State private var selection = Set<String>()
    @State private var search = ""
    @State private var preview: ProjectSkillSyncPlan?
    @State private var busy = false
    @State private var error: String?
    @State private var completion: String?
    @State private var collection = ProjectSkillSyncCollection.agents

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sync global skills").font(.title2.weight(.semibold))
                    Text("Global → \(URL(fileURLWithPath: projectRoot).lastPathComponent) / .agents / skills")
                        .font(.callout).foregroundStyle(.secondary)
                        .help(projectRoot)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
            }
            Text("Copy selected bundles for fresh and cloud checkouts. Nothing is committed or pushed; local agents may show both copies.")
                .font(.callout).foregroundStyle(.secondary)

            if let completion {
                Label(completion, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Review the Git diff, include .agents/skills and .agents/project-skills.json in your commit, then push separately. Git-ignored files will not reach cloud. Other skills were left untouched.")
                    .font(.callout)
            } else if let preview {
                previewContent(preview)
                Text("Review private content and outside dependencies before copying. This check is not a complete security or portability audit; instructions are never rewritten.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Change selection") { self.preview = nil; error = nil }.disabled(busy)
                    Spacer()
                    Button(preview.changeCount == 0 ? "Confirm unchanged" : "Copy \(preview.changeCount) skills") {
                        apply(preview)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || model.isRunning || !preview.canApply)
                    .accessibilityIdentifier("metagent.project-skills.copy")
                }
            } else {
                Picker("Global collection", selection: $collection) {
                    ForEach(ProjectSkillSyncCollection.allCases, id: \.self) { value in
                        Text("~/\(value.relativePath)").tag(value)
                    }
                }
                .disabled(busy)
                TextField("Search global skills", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("metagent.project-skills.search")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(names.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }, id: \.self) { name in
                            Toggle(name, isOn: Binding(
                                get: { selection.contains(name) },
                                set: { selected in
                                    if selected { selection.insert(name) } else { selection.remove(name) }
                                }
                            ))
                            .toggleStyle(.checkbox)
                            .disabled(busy || (!selection.contains(name) && selection.count >= 32))
                        }
                        if names.isEmpty && !busy {
                            Text("No direct global bundles found in ~/\(collection.relativePath). Linked projections, built-in system skills and plugin runtime copies are excluded; choose their canonical collection instead.")
                                .foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
                HStack {
                    Text("\(selection.count) selected · up to 32 per copy").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Preview files") { makePreview() }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || selection.isEmpty)
                        .accessibilityIdentifier("metagent.project-skills.preview")
                }
            }
            if busy { ProgressView().controlSize(.small) }
            if let error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
        }
        .padding(24)
        .frame(width: 660, height: 560)
        .task(id: collection) { selection = []; preview = nil; await loadNames() }
        .interactiveDismissDisabled(busy)
        .accessibilityIdentifier("metagent.project-skills.sheet")
    }

    private func previewContent(_ preview: ProjectSkillSyncPlan) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(preview.items) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(item.name).font(.headline)
                            Spacer()
                            Text(item.action.rawValue.capitalized)
                                .foregroundStyle(item.action == .blocked ? .red : .secondary)
                        }
                        Text(".agents/skills/\(item.name)").font(.caption.monospaced()).foregroundStyle(.secondary)
                        DisclosureGroup("\(item.files.count) files · \(item.files.reduce(0) { $0 + $1.byteCount }.formatted()) bytes") {
                            ForEach(item.files, id: \.relativePath) { file in
                                Text("\(file.relativePath) · \(file.byteCount) bytes").font(.caption.monospaced())
                            }
                            ForEach(item.removedFiles, id: \.self) { path in
                                Text("Remove obsolete copied file: \(path)").font(.caption.monospaced()).foregroundStyle(.orange)
                            }
                        }
                        ForEach(item.findings) { finding in
                            Label(finding.message, systemImage: finding.severity == .blocking ? "xmark.circle" : "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(finding.severity == .blocking ? .red : .orange)
                        }
                    }
                    Divider()
                }
            }.padding(4)
        }
    }

    @MainActor private func loadNames() async {
        busy = true
        names = []
        error = nil
        defer { busy = false }
        let selectedCollection = collection
        do {
            names = try await Task.detached(priority: .userInitiated) {
                try MetagentCore.globalProjectSyncSkillNames(collection: selectedCollection)
            }.value
        } catch { self.error = error.localizedDescription }
    }

    @MainActor private func makePreview() {
        let selected = selection.sorted()
        let root = projectRoot
        let selectedCollection = collection
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                preview = try await Task.detached(priority: .userInitiated) {
                    try MetagentCore.previewProjectSkillSync(projectRoot: root, skillNames: selected, collection: selectedCollection)
                }.value
            } catch { self.error = error.localizedDescription }
        }
    }

    @MainActor private func apply(_ preview: ProjectSkillSyncPlan) {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let report = try await Task.detached(priority: .userInitiated) {
                    try MetagentCore.applyProjectSkillSync(preview)
                }.value
                completion = "Copied \(report.copiedNames.count), updated \(report.updatedNames.count), \(preview.items.count - preview.changeCount) unchanged."
                model.refreshStatus()
            } catch { self.error = error.localizedDescription; self.preview = nil }
        }
    }
}
