import AppKit
import MetagentCore
import SwiftUI

struct PublishedSkillsView: View {
    @ObservedObject var model: MetagentModel

    private var records: [SkillPublicationRecord] {
        model.publicationSnapshot.records.sorted {
            if $0.automaticMirroringEnabled != $1.automaticMirroringEnabled {
                return $0.automaticMirroringEnabled
            }
            return $0.skillName.localizedCaseInsensitiveCompare($1.skillName) == .orderedAscending
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
                Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                    model.reconcileSkillPublications()
                }
                .disabled(model.isPublicationSyncing)
            }

            if records.isEmpty {
                EmptyStateView(
                    title: "No published skills",
                    message: "Right-click a canonical skill from ~/.agents/skills and choose Publish. Metagent will keep its local public-repository copy current without committing or pushing.",
                    symbol: "shippingbox"
                )
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
                    .disabled(model.isPublicationSyncing)
                }
            }

            if let catalog {
                Text("\(displayUserPath(catalog.localRepositoryPath))/\(catalog.skillsRelativePath)/\(record.destinationName)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
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

struct SkillPublicationSetupSheet: View {
    @ObservedObject var model: MetagentModel
    let row: InventorySkillRow
    @Environment(\.dismiss) private var dismiss
    @State private var repositoryPath = ""
    @State private var destinationName: String

    init(model: MetagentModel, row: InventorySkillRow) {
        self.model = model
        self.row = row
        _destinationName = State(initialValue: row.skillName.lowercased().replacingOccurrences(of: "_", with: "-"))
    }

    private var readiness: SkillPublishReadiness? {
        guard !repositoryPath.isEmpty else { return nil }
        return MetagentCore.assessSkillPublicationReadiness(
            sourcePath: row.canonicalPath,
            repositoryPath: repositoryPath,
            destinationName: destinationName
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Publish \(row.skillName)")
                .font(.title2.bold())
            Text("Metagent will continuously mirror this canonical skill into an existing public Git checkout. It will never commit or push; unsafe updates keep the last safe public copy in place.")
                .foregroundStyle(.secondary)

            LabeledContent("Canonical source") {
                Text(displayUserPath(row.canonicalPath))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
            LabeledContent("Public repository") {
                HStack {
                    Text(repositoryPath.isEmpty ? "Choose a local checkout" : displayUserPath(repositoryPath))
                        .font(.callout.monospaced())
                        .lineLimit(1)
                    Button("Choose…") { chooseRepository() }
                }
            }
            LabeledContent("Public skill name") {
                TextField("skill-name", text: $destinationName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }

            if let readiness {
                Label(
                    readiness.status == .ready ? "Ready to mirror" : "Fix these before publishing",
                    systemImage: readiness.status == .ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(readiness.status == .ready ? .green : .orange)
                ForEach(readiness.findings) { finding in
                    Text("• \(finding.message) \(finding.remediation)")
                        .font(.caption)
                        .foregroundStyle(finding.severity == .blocking ? .orange : .secondary)
                }
            }

            Spacer()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start Publishing") {
                    model.enableSkillPublication(
                        sourcePath: row.canonicalPath,
                        skillName: row.skillName,
                        repositoryPath: repositoryPath,
                        destinationName: destinationName
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(readiness?.status != .ready || model.isPublicationSyncing)
            }
        }
        .padding(22)
        .frame(minWidth: 620, minHeight: 420)
    }

    private func chooseRepository() {
        let panel = NSOpenPanel()
        panel.title = "Choose Public Skills Repository"
        panel.prompt = "Choose Repository"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        repositoryPath = url.standardizedFileURL.path
    }
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
