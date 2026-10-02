import AppKit
import MetagentCore
import SwiftUI

struct PublishedSkillsView: View {
    @ObservedObject var model: MetagentModel
    let availableSkills: [InventorySkillRow]
    let onChooseSkill: (InventorySkillRow) -> Void

    private var records: [SkillPublicationRecord] {
        model.publicationSnapshot.records.sorted {
            if $0.automaticMirroringEnabled != $1.automaticMirroringEnabled {
                return $0.automaticMirroringEnabled
            }
            return $0.skillName.localizedCaseInsensitiveCompare($1.skillName) == .orderedAscending
        }
    }

    private var hasEnabledRecords: Bool {
        records.contains(where: \.automaticMirroringEnabled)
    }

    private var selectableSkills: [InventorySkillRow] {
        availableSkills.filter { skill in
            !records.contains {
                $0.automaticMirroringEnabled && $0.sourceCanonicalPath == skill.canonicalPath
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: model.isPublicationSyncing ? "arrow.triangle.2.circlepath" : "shippingbox")
                    .foregroundStyle(.secondary)
                Text(model.publicationStatusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if !records.isEmpty {
                    skillPicker
                }
                Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                    model.reconcileSkillPublications()
                }
                .disabled(model.isPublicationSyncing || model.isPublicationPublishing || !hasEnabledRecords)
            }

            if records.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "shippingbox")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No skills selected for publishing")
                        .font(.callout.weight(.semibold))
                    Text("Choose an editable personal or project skill. Metagent will keep its public-repository copy current without committing or pushing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    skillPicker
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(records) { record in
                            publicationCard(record)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var skillPicker: some View {
        Menu("Choose a Skill…", systemImage: "plus") {
            if selectableSkills.isEmpty {
                Text("No more editable skills available to publish")
            } else {
                ForEach(selectableSkills) { skill in
                    Button("\(skill.skillName) — \(displayUserPath(skill.canonicalPath))") {
                        onChooseSkill(skill)
                    }
                }
            }
        }
        .disabled(selectableSkills.isEmpty || model.isPublicationSyncing || model.isPublicationPublishing)
        .buttonStyle(.borderedProminent)
    }

    @ViewBuilder
    private func publicationCard(_ record: SkillPublicationRecord) -> some View {
        let catalog = model.publicationSnapshot.catalogs.first { $0.id == record.catalogID }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.skillName)
                        .font(.headline)
                    Text(record.automaticMirroringEnabled ? record.state.displayTitle : "Mirroring stopped")
                        .font(.caption)
                        .foregroundStyle(record.state.displayColor)
                }
                Spacer()
                if let catalog {
                    Button("Public Copy", systemImage: "folder") {
                        let destination = URL(fileURLWithPath: catalog.localRepositoryPath)
                            .appendingPathComponent(catalog.skillsRelativePath, isDirectory: true)
                            .appendingPathComponent(record.destinationName, isDirectory: true)
                        NSWorkspace.shared.open(destination)
                    }
                    .buttonStyle(.borderless)
                }
                if record.automaticMirroringEnabled {
                    Button("Stop Mirroring", systemImage: "pause.circle") {
                        model.disableSkillPublication(recordID: record.id)
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.isPublicationSyncing || model.isPublicationPublishing)
                }
            }

            if let catalog {
                Text("\(displayUserPath(catalog.localRepositoryPath))/\(catalog.skillsRelativePath)/\(record.destinationName)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                SkillPublicationGitDetails(model: model, record: record, catalog: catalog)
            }
            if let lastMirroredAt = record.lastMirroredAt {
                Text("Last mirrored \(lastMirroredAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = record.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            ForEach(record.findings.prefix(3)) { finding in
                Text("• \(finding.message)")
                    .font(.caption)
                    .foregroundStyle(finding.severity == .blocking ? .orange : .secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct SkillPublicationGitDetails: View {
    @ObservedObject var model: MetagentModel
    let record: SkillPublicationRecord
    let catalog: SkillPublicationCatalog
    @State private var status: SkillPublicationGitStatus?
    @State private var isChecking = false
    @State private var generation = UUID()
    @State private var showsPublishSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Label(status?.state.title ?? "Git status not checked", systemImage: "arrow.triangle.branch")
                    .font(.callout.weight(.medium))
                Spacer()
                Button(status?.state == .matchesKnownUpstream ? "Up to date" : status?.suggestedPublishAction.map { "\($0.title)…" } ?? "Publish…") {
                    showsPublishSheet = true
                }
                .disabled(isChecking || model.isPublicationSyncing || model.isPublicationPublishing || status?.state == .matchesKnownUpstream)
                Button(isChecking ? "Checking…" : "Check Git Status") { checkGit() }
                    .disabled(isChecking)
            }
            if let status {
                HStack {
                    Text("Local check \(status.checkedAt.formatted(date: .abbreviated, time: .shortened))")
                    if let commit = status.checkoutCommit {
                        Text("Checkout \(commit.prefix(8))")
                            .font(.caption.monospaced())
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let links = status.links {
                    HStack {
                        Link("GitHub Repository", destination: links.repositoryURL)
                        Link("View on skills.sh ↗", destination: links.skillsURL)
                        Button("Copy Link", systemImage: "link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(links.skillsURL.absoluteString, forType: .string)
                        }
                        .buttonStyle(.borderless)
                        Spacer()
                        Button("Copy Install Command", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(links.installCommand, forType: .string)
                        }
                        .buttonStyle(.borderless)
                    }
                    .font(.caption)
                } else {
                    Text("Install links require a credential-free github.com origin and a supported SKILL.md name.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                DisclosureGroup("Details and next steps") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(status.detail)
                        if let links = status.links {
                            Text(links.installCommand)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            Text("Installs from the repository's default branch. Review your diff, commit and push there, then confirm public visibility before sharing.")
                        }
                        Text("The skills.sh page may not exist until a normal CLI install indexes the skill. Its install telemetry is not downloads or active users.")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                }
                .font(.caption)
            }
            Text("Local Git only · Public listing unverified · Installs not connected")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Mirroring never commits or pushes. Git checks read local tracking refs, without fetching. GitHub visibility, current remote contents, and skills.sh indexing are not verified; per-skill installs are unavailable in Metagent.")
        }
        .onChange(of: record) { _, _ in invalidateStatus() }
        .onChange(of: catalog) { _, _ in invalidateStatus() }
        .onDisappear { invalidateStatus() }
        .sheet(isPresented: $showsPublishSheet, onDismiss: {
            invalidateStatus()
            checkGit()
        }) {
            SkillPublicationPublishSheet(model: model, record: record, catalog: catalog)
        }
    }

    private func checkGit() {
        isChecking = true
        let expectedRecord = record
        let expectedCatalog = catalog
        let expectedGeneration = generation
        Task {
            let result = await Task.detached(priority: .utility) {
                MetagentCore.inspectSkillPublicationGit(record: expectedRecord, catalog: expectedCatalog)
            }.value
            // A sync can finish while Git is being inspected. Its old result
            // must not be presented as a check of the newly mirrored snapshot.
            if generation == expectedGeneration {
                status = result
            }
            isChecking = false
        }
    }

    private func invalidateStatus() {
        status = nil
        generation = UUID()
    }
}

private struct SkillPublicationPublishSheet: View {
    @ObservedObject var model: MetagentModel
    let record: SkillPublicationRecord
    let catalog: SkillPublicationCatalog
    @Environment(\.dismiss) private var dismiss
    @State private var preview: SkillPublicationPublishPreview?
    @State private var result: SkillPublicationPublishResult?
    @State private var isPreparing = false
    @State private var commitMessage: String

    init(model: MetagentModel, record: SkillPublicationRecord, catalog: SkillPublicationCatalog) {
        self.model = model
        self.record = record
        self.catalog = catalog
        _commitMessage = State(initialValue: "Publish \(record.skillName)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(preview?.action?.title ?? "Review publication")
                        .font(.title2.bold())
                    Text(record.skillName)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let repositoryURL = preview?.repositoryURL {
                    Link("GitHub Repository", destination: repositoryURL)
                }
            }

            if isPreparing {
                ProgressView("Checking the branch and remote…")
                    .controlSize(.small)
            } else if let preview {
                publicationPreview(preview)
            }

            if let result {
                Label(result.message, systemImage: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(result.succeeded ? .green : .orange)
            }

            Spacer()
            HStack {
                Button("Refresh Preview", systemImage: "arrow.clockwise") { prepare() }
                    .disabled(isPreparing || model.isPublicationPublishing)
                Spacer()
                Button(result?.succeeded == true ? "Done" : "Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isPublicationPublishing)
                if result?.succeeded != true {
                    Button("Commit & Publish") { publish() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(preview?.isReady != true || isPreparing || model.isPublicationPublishing)
                }
            }
        }
        .padding(22)
        .frame(minWidth: 680, minHeight: 500)
        .interactiveDismissDisabled(model.isPublicationPublishing)
        .task { prepare() }
    }

    @ViewBuilder
    private func publicationPreview(_ preview: SkillPublicationPublishPreview) -> some View {
        if let blocker = preview.blocker {
            Label(blocker, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                GridRow {
                    Text("Repository").foregroundStyle(.secondary)
                    Text(displayUserPath(preview.repositoryPath)).font(.callout.monospaced())
                }
                GridRow {
                    Text("Branch").foregroundStyle(.secondary)
                    Text(preview.branch ?? "—").font(.callout.monospaced())
                }
                GridRow {
                    Text("Push target").foregroundStyle(.secondary)
                    Text(preview.pushDestination ?? "—")
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                GridRow {
                    Text("Skill folder").foregroundStyle(.secondary)
                    Text(preview.destinationPath).font(.callout.monospaced())
                }
                GridRow {
                    Text("Starting commit").foregroundStyle(.secondary)
                    Text(preview.baseCommit.map { String($0.prefix(12)) } ?? "—")
                        .font(.callout.monospaced())
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Exact files in this publication")
                    .font(.headline)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(preview.changes) { change in
                            HStack(spacing: 8) {
                                Text(change.kind.shortLabel)
                                    .font(.caption.monospaced().weight(.semibold))
                                    .foregroundStyle(change.kind.color)
                                    .frame(width: 18, alignment: .leading)
                                Text(change.path)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
            }

            LabeledContent("Commit message") {
                TextField("Publish \(record.skillName)", text: $commitMessage)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 360)
            }
            Text("Metagent will commit only the files above and push this exact commit to the branch shown. It will not stash, pull, rebase, or force-push. Any change invalidates this preview.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func prepare() {
        isPreparing = true
        result = nil
        let expectedRecord = record
        let expectedCatalog = catalog
        Task {
            let prepared = await Task.detached(priority: .utility) {
                MetagentCore.prepareSkillPublicationPublish(record: expectedRecord, catalog: expectedCatalog)
            }.value
            preview = prepared
            if prepared.action == .update, commitMessage == "Publish \(record.skillName)" {
                commitMessage = "Update \(record.skillName)"
            }
            isPreparing = false
        }
    }

    private func publish() {
        guard let preview else { return }
        Task {
            result = await model.commitAndPublishSkill(
                preview: preview,
                record: record,
                catalog: catalog,
                commitMessage: commitMessage
            )
            if result?.outcome == .previewExpired {
                self.preview = nil
            }
        }
    }
}

private extension SkillPublicationChangeKind {
    var shortLabel: String {
        switch self {
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        }
    }

    var color: Color {
        switch self {
        case .added: .green
        case .modified: .orange
        case .deleted: .red
        }
    }
}

func activeSkillPublication(for canonicalPath: String, in snapshot: SkillPublicationSnapshot) -> SkillPublicationRecord? {
    snapshot.records.first {
        $0.automaticMirroringEnabled && $0.sourceCanonicalPath == canonicalPath
    }
}

func skillPublicationUnavailableReason(_ skill: SkillInventoryItem) -> String? {
    guard skill.mutability == "editable", skill.manager != "codex-plugin" else {
        return "Publish the editable source, not an installed package."
    }
    guard skill.representation == "canonical",
          MetagentCore.isSkillPublicationSource(skill.canonicalPath)
    else {
        return "Publish from a personal or project .agents/skills folder."
    }
    return nil
}

struct SkillPublicationSetupSheet: View {
    @ObservedObject var model: MetagentModel
    let row: InventorySkillRow
    let onStartCopy: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var repositoryPath = ""
    @State private var destinationName: String
    @State private var readiness: SkillPublishReadiness?
    @State private var isCheckingReadiness = false
    @State private var isCreatingRepository = false
    @State private var repositorySetup: SkillPublicationRepositorySetup?
    @State private var repositorySetupRevision = 0
    @State private var showsDetails = false

    init(model: MetagentModel, row: InventorySkillRow, onStartCopy: @escaping () -> Void) {
        self.model = model
        self.row = row
        self.onStartCopy = onStartCopy
        _destinationName = State(initialValue: row.skillName.lowercased().replacingOccurrences(of: "_", with: "-"))
        _repositoryPath = State(initialValue: model.publicationSnapshot.preferredRepositoryPath ?? "")
    }

    private var readinessInput: String {
        "\(repositoryPath)\u{1f}\(destinationName)\u{1f}\(skillsRelativePath)\u{1f}\(repositorySetupRevision)"
    }

    private var skillsRelativePath: String {
        publicationSkillsRelativePath(repositoryPath: repositoryPath, catalogs: model.publicationSnapshot.catalogs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Copy \(row.skillName)")
                .font(.title2.bold())
                .lineLimit(2)
            Text("Choose a folder for your publishing copy.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Publishing folder")
                    .font(.callout.weight(.medium))
                HStack(spacing: 12) {
                    Image(systemName: "folder")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    if repositoryPath.isEmpty {
                        Button("Choose Folder…") { chooseRepository() }
                        Button(isCreatingRepository ? "Preparing…" : "Use Default Folder") {
                            createPublishingRepository()
                        }
                        .help("Create ~/public-agent-setup with local Git. Nothing is uploaded.")
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(URL(fileURLWithPath: repositoryPath).lastPathComponent)
                                .font(.callout.weight(.medium))
                            Text(displayUserPath(repositoryPath))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                        Menu("Change…") {
                            Button("Choose Folder…") { chooseRepository() }
                            if !model.publicationSnapshot.catalogs.isEmpty {
                                Menu("Recent Folders") {
                                    ForEach(model.publicationSnapshot.catalogs) { catalog in
                                        Button(displayUserPath(catalog.localRepositoryPath)) {
                                            repositoryPath = catalog.localRepositoryPath
                                            repositorySetup = nil
                                        }
                                    }
                                }
                            }
                            Divider()
                            Button("Use Default Folder") { createPublishingRepository() }
                        }
                        .fixedSize()
                    }
                }
                .disabled(isCreatingRepository)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }
            if let repositorySetup, !repositorySetup.succeeded {
                Text(repositorySetup.message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if isCheckingReadiness {
                Label("Checking…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let readiness {
                Label(
                    readiness.status == .ready ? "Ready to copy" : "Fix these before copying",
                    systemImage: readiness.status == .ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(readiness.status == .ready ? .green : .orange)
                ForEach(readiness.findings.filter { $0.severity == .blocking }) { finding in
                    Text("\(finding.message) \(finding.remediation)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            DisclosureGroup("Details", isExpanded: $showsDetails) {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Folder name") {
                        TextField("skill-name", text: $destinationName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 240)
                    }
                    Text("Source: \(displayUserPath(row.canonicalPath))")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    if !repositoryPath.isEmpty {
                        Text("Copy: \(displayUserPath(repositoryPath))/\(skillsRelativePath)/\(destinationName)")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    Text("Metagent keeps this skill's copy up to date. It never commits or uploads automatically, and unsafe updates leave the last safe copy in place. Review and publish from Published.")
                        .font(.caption)
                    if let repositorySetup, repositorySetup.succeeded {
                        Text(repositorySetup.message)
                            .font(.caption)
                    }
                    ForEach(readiness?.findings.filter { $0.severity != .blocking } ?? []) { finding in
                        Text("\(finding.message) \(finding.remediation)")
                            .font(.caption)
                    }
                }
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            }
            Text("Kept in sync locally. Review and publish in Published.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Copy Skill") {
                    let accepted = model.enableSkillPublication(
                        sourcePath: row.canonicalPath,
                        skillName: row.skillName,
                        repositoryPath: repositoryPath,
                        destinationName: destinationName
                    )
                    if accepted {
                        dismiss()
                        onStartCopy()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(readiness?.status != .ready || isCheckingReadiness || model.isPublicationSyncing || isCreatingRepository)
            }
        }
        .padding(22)
        .frame(width: 520)
        .task(id: readinessInput) {
            readiness = nil
            guard !repositoryPath.isEmpty else {
                isCheckingReadiness = false
                return
            }
            isCheckingReadiness = true
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            let sourcePath = row.canonicalPath
            let repositoryPath = repositoryPath
            let destinationName = destinationName
            let skillsRelativePath = skillsRelativePath
            let result = await Task.detached(priority: .utility) {
                MetagentCore.assessSkillPublicationReadiness(
                    sourcePath: sourcePath,
                    repositoryPath: repositoryPath,
                    skillsRelativePath: skillsRelativePath,
                    destinationName: destinationName
                )
            }.value
            guard !Task.isCancelled else { return }
            readiness = result
            isCheckingReadiness = false
        }
    }

    private func chooseRepository() {
        let panel = NSOpenPanel()
        panel.title = "Choose Publishing Folder"
        panel.prompt = "Choose Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if !repositoryPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: repositoryPath, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        repositoryPath = url.standardizedFileURL.path
        repositorySetup = nil
    }

    private func createPublishingRepository() {
        isCreatingRepository = true
        repositorySetup = nil
        Task {
            let result = await Task.detached(priority: .utility) {
                MetagentCore.prepareDefaultSkillPublicationRepository()
            }.value
            repositorySetup = result
            if result.succeeded {
                readiness = nil
                repositoryPath = result.path
                // An empty folder may already be selected. Its new Git state
                // must invalidate readiness even when the path stays the same.
                repositorySetupRevision += 1
            }
            isCreatingRepository = false
        }
    }
}

/// The preview and readiness gate must use the same destination as enablement,
/// which preserves a previously configured catalog's relative skills folder.
func publicationSkillsRelativePath(repositoryPath: String, catalogs: [SkillPublicationCatalog]) -> String {
    let repository = URL(fileURLWithPath: repositoryPath).resolvingSymlinksInPath().standardizedFileURL.path
    return catalogs.first {
        URL(fileURLWithPath: $0.localRepositoryPath).resolvingSymlinksInPath().standardizedFileURL.path == repository
    }?.skillsRelativePath ?? "skills"
}

private extension SkillPublicationState {
    var displayTitle: String {
        switch self {
        case .disabled: "Mirroring stopped"
        case .mirrored: "Mirrored locally"
        case .updateBlocked: "Update blocked"
        case .sourceMissing: "Source missing"
        case .repositoryMissing: "Repository missing"
        }
    }

    var displayColor: Color {
        switch self {
        case .mirrored: .green
        case .disabled: .secondary
        case .updateBlocked, .sourceMissing, .repositoryMissing: .orange
        }
    }
}
