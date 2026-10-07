import AppKit
import MetagentCore
import SwiftUI

struct ProjectSkillSyncDestination: Identifiable {
    let root: String
    var id: String { root }
}

@MainActor
final class ProjectSkillSyncCollectionLoader: ObservableObject {
    typealias Scan = @Sendable (ProjectSkillSyncCollection) async throws -> [ProjectSkillSyncCandidate]
    @Published private(set) var candidates: [ProjectSkillSyncCandidate] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    private var generation = UUID()

    var names: [String] { candidates.map(\.name) }

    func load(_ collection: ProjectSkillSyncCollection, projectRoot: String) async {
        await load(collection, scan: { collection in
            try await Task.detached(priority: .userInitiated) {
                try MetagentCore.projectSkillSyncCandidates(projectRoot: projectRoot, collection: collection)
            }.value
        })
    }

    func load(_ collection: ProjectSkillSyncCollection, scan: Scan) async {
        guard !Task.isCancelled else { return }
        let request = UUID()
        generation = request
        isLoading = true
        candidates = []
        error = nil
        defer { if generation == request { isLoading = false } }
        do {
            let result = try await scan(collection)
            guard !Task.isCancelled, generation == request else { return }
            candidates = result
        } catch {
            guard !Task.isCancelled, generation == request else { return }
            self.error = error.localizedDescription
        }
    }
}

/// Explicit, action-time reads only. No portfolio scan, automatic mirroring,
/// or bundle I/O on the main actor.
struct ProjectSkillSyncView: View {
    @ObservedObject var model: MetagentModel
    let projectRoot: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var collectionLoader = ProjectSkillSyncCollectionLoader()
    @State private var selection = Set<String>()
    @State private var search = ""
    @State private var preview: ProjectSkillSyncPlan?
    @State private var busy = false
    @State private var error: String?
    @State private var completion: String?
    @State private var collection = ProjectSkillSyncCollection.agents
    private var isBusy: Bool { busy || collectionLoader.isLoading }
    private var offered: [ProjectSkillSyncCandidate] { collectionLoader.candidates.filter { !$0.isInProject } }
    private var alreadyInProject: [ProjectSkillSyncCandidate] { collectionLoader.candidates.filter(\.isInProject) }

    private func matchesSearch(_ candidate: ProjectSkillSyncCandidate) -> Bool {
        search.isEmpty || candidate.name.localizedCaseInsensitiveContains(search)
    }

    private func alreadyInProjectDescription(_ candidate: ProjectSkillSyncCandidate) -> String {
        guard case let .inProject(locations, sameSkillFile) = candidate.status else { return candidate.name }
        let places = locations.map(\.relativePath).joined(separator: ", ")
        return "\(candidate.name) · \(places)\(sameSkillFile ? "" : " · SKILL.md differs from global")"
    }

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
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isBusy)
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
                    Button("Change selection") { self.preview = nil; error = nil }.disabled(isBusy)
                    Spacer()
                    Button(preview.changeCount == 0 ? "Confirm unchanged" : "Copy \(preview.changeCount) skills") {
                        apply(preview)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy || model.isRunning || !preview.canApply)
                    .accessibilityIdentifier("metagent.project-skills.copy")
                }
            } else {
                Picker("Global collection", selection: $collection) {
                    ForEach(ProjectSkillSyncCollection.allCases, id: \.self) { value in
                        Text("~/\(value.relativePath)").tag(value)
                    }
                }
                .disabled(isBusy)
                TextField("Search global skills", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("metagent.project-skills.search")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(offered.filter(matchesSearch), id: \.name) { candidate in
                            HStack(spacing: 8) {
                                Toggle(candidate.name, isOn: Binding(
                                    get: { selection.contains(candidate.name) },
                                    set: { selected in
                                        if selected { selection.insert(candidate.name) } else { selection.remove(candidate.name) }
                                    }
                                ))
                                .toggleStyle(.checkbox)
                                .disabled(isBusy || (!selection.contains(candidate.name) && selection.count >= 32))
                                if candidate.status == .metagentCopy {
                                    Text("Copied · refresh")
                                        .font(.caption).foregroundStyle(.secondary)
                                        .help("Metagent copied this skill into the project earlier. Select it to bring the project copy up to date.")
                                }
                            }
                        }
                        if collectionLoader.candidates.isEmpty && !isBusy {
                            Text("No direct global bundles found in ~/\(collection.relativePath). Linked projections, built-in system skills and plugin runtime copies are excluded; choose their canonical collection instead.")
                                .foregroundStyle(.secondary)
                        } else if offered.isEmpty && !isBusy {
                            Text("Every global skill in ~/\(collection.relativePath) is already in this project.")
                                .foregroundStyle(.secondary)
                        }
                        if !alreadyInProject.isEmpty {
                            DisclosureGroup("\(alreadyInProject.count) already in this project, hidden") {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(alreadyInProject.filter(matchesSearch), id: \.name) { candidate in
                                        Text(alreadyInProjectDescription(candidate))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 4)
                            }
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                            .accessibilityIdentifier("metagent.project-skills.already-in-project")
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
                HStack {
                    Text("\(selection.count) selected · up to 32 per copy").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Preview files") { makePreview() }
                        .buttonStyle(.borderedProminent)
                        .disabled(isBusy || selection.isEmpty)
                        .accessibilityIdentifier("metagent.project-skills.preview")
                }
            }
            if isBusy { ProgressView().controlSize(.small) }
            if let error = error ?? collectionLoader.error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
        }
        .padding(24)
        .frame(width: 660, height: 560)
        .task(id: collection) { selection = []; preview = nil; error = nil; await collectionLoader.load(collection, projectRoot: projectRoot) }
        .interactiveDismissDisabled(isBusy)
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
