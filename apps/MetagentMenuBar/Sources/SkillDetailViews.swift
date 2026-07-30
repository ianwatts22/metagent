import AppKit
import Foundation
import MetagentCore
import SwiftUI
import UniformTypeIdentifiers

struct SkillDetailHeader<Trailing: View>: View {
    let iconPath: String?
    let fallbackSymbol: String
    let title: String
    let path: String
    let pathIsSelectable: Bool
    let trailing: Trailing

    init(
        iconPath: String?,
        fallbackSymbol: String,
        title: String,
        path: String,
        pathIsSelectable: Bool = false,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.iconPath = iconPath
        self.fallbackSymbol = fallbackSymbol
        self.title = title
        self.path = path
        self.pathIsSelectable = pathIsSelectable
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let icon = AppBrand.skillIcon(path: iconPath) {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: fallbackSymbol)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                        .padding(6)
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2.weight(.semibold))
                if pathIsSelectable {
                    pathText
                        .textSelection(.enabled)
                } else {
                    pathText
                }
            }
            Spacer()
            trailing
        }
    }

    private var pathText: some View {
        Text(displayUserPath(path))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

extension SkillDetailHeader where Trailing == EmptyView {
    init(
        iconPath: String?,
        fallbackSymbol: String,
        title: String,
        path: String,
        pathIsSelectable: Bool = false
    ) {
        self.init(
            iconPath: iconPath,
            fallbackSymbol: fallbackSymbol,
            title: title,
            path: path,
            pathIsSelectable: pathIsSelectable
        ) {
            EmptyView()
        }
    }
}

struct SkillInfoView: View {
    @ObservedObject var model: MetagentModel
    let row: InventorySkillRow
    @Environment(\.dismiss) private var dismiss
    @State private var showsIconEditor = false
    @State private var scoreDetailsRow: InventorySkillRow?
    @State private var showsReader = false
    @State private var updatedSkillName: String?
    @State private var updatedSkillPath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SkillDetailHeader(
                iconPath: row.skillIconPath,
                fallbackSymbol: "sparkles",
                title: updatedSkillName ?? row.skillName,
                path: currentSkillPath
            )

            if row.descriptionText != "—" {
                Text(row.descriptionText)
                    .font(.body)
                    .textSelection(.enabled)
            }

            Form {
                Section("Source") {
                    LabeledContent("Manager", value: row.skill.tableOriginText)
                    LabeledContent("Upstream", value: row.upstreamText)
                    LabeledContent("Version", value: row.versionText)
                    LabeledContent("Updated", value: row.updatedText)
                    LabeledContent("Path") {
                        Text(displayUserPath(currentSkillPath))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }

                Section("Contents") {
                    LabeledContent("Tokens", value: row.tokenEstimate.formatted())
                    LabeledContent("References", value: row.referenceFileCount.formatted())
                    LabeledContent("Scripts", value: row.scriptFileCount.formatted())
                    LabeledContent("Assets", value: row.assetFileCount.formatted())
                    LabeledContent("Other files", value: row.otherFileCount.formatted())
                }

                if let inventory = row.skill.coreSkill.scriptInventory,
                   !inventory.scripts.isEmpty || !inventory.warnings.isEmpty
                {
                    SkillScriptsSection(inventory: inventory)
                }

                Section("Scores") {
                    if let currentScoreRow {
                        LabeledContent("Quality", value: currentScoreRow.metagentScoreText)
                        LabeledContent("Plugin Eval", value: currentScoreRow.pluginEvalText)
                        LabeledContent("Utility", value: currentScoreRow.portfolioScoreText)
                        LabeledContent("Codex", value: currentScoreRow.codexReviewText)
                        Button("Score details and improvements…") {
                            scoreDetailsRow = currentScoreRow
                        }
                    } else if model.isRunning || model.isSkillEvaluating {
                        ProgressView("Refreshing scores…")
                    } else {
                        Text("Scores are unavailable for the current skill.")
                            .foregroundStyle(.secondary)
                    }
                }

                SkillTimelineSection(skillPath: currentSkillPath)
            }
            .formStyle(.grouped)

            HStack {
                Button("Open Skill") {
                    showsReader = true
                }
                .buttonStyle(.glassProminent)
                Menu("Actions") {
                    Button("Open Folder") {
                        openSkillDirectories([URL(fileURLWithPath: currentSkillPath)])
                    }
                    Button("Open SKILL.md") {
                        openSkillFiles([URL(fileURLWithPath: currentSkillPath).appendingPathComponent("SKILL.md")])
                    }
                    Button("Open in Editor") {
                        let directory = URL(fileURLWithPath: currentSkillPath)
                        openSkillDirectoriesInEditor(
                            [directory],
                            skillFiles: [directory.appendingPathComponent("SKILL.md")]
                        )
                    }
                    Divider()
                    Button("Copy Path") {
                        copyToPasteboard(currentSkillPath)
                    }
                    Button(row.skillIconPath == nil ? "Add Icon…" : "Change Icon…") {
                        showsIconEditor = true
                    }
                    .disabled(!row.canEditIcon)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 620, height: 600)
        .sheet(isPresented: $showsIconEditor) {
            SkillIconEditorView(
                model: model,
                row: row,
                skillPath: currentSkillPath,
                skillName: updatedSkillName ?? row.skillName
            )
        }
        .sheet(item: $scoreDetailsRow) { currentRow in
            SkillScoreGuidanceView(row: currentRow) {
                model.affirmModelReleaseReview(canonicalPath: currentRow.canonicalPath)
            }
        }
        .sheet(isPresented: $showsReader) {
            SkillReaderView(
                model: model,
                row: row,
                initialSkillPath: currentSkillPath
            ) { updated in
                updatedSkillName = updated.name
                updatedSkillPath = updated.directoryPath
            }
        }
    }

    private var currentSkillPath: String {
        updatedSkillPath ?? row.canonicalPath
    }

    private var currentScoreRow: InventorySkillRow? {
        guard !model.isRunning, !model.isSkillEvaluating else {
            return nil
        }
        return model.inventorySkillRow(canonicalPath: currentSkillPath)
            ?? (updatedSkillPath == nil ? row : nil)
    }

}

private struct SkillScriptsSection: View {
    let inventory: SkillScriptInventory

    var body: some View {
        Section("Scripts") {
            ForEach(inventory.scripts) { script in
                SkillScriptDetailRow(script: script)
            }
            ForEach(inventory.missingReferences) { missing in
                Label(
                    "Missing \(missing.relativePath), referenced by \(missing.referencedBy.joined(separator: ", "))",
                    systemImage: "questionmark.folder"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
            ForEach(otherWarnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var otherWarnings: [String] {
        inventory.warnings.filter {
            !$0.hasPrefix("Referenced script is missing:")
        }
    }
}

private struct SkillScriptDetailRow: View {
    let script: SkillScriptItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(script.relativePath)
                .font(.body.monospaced())
                .textSelection(.enabled)
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            if !script.referencedBy.isEmpty {
                Text("Referenced by \(script.referencedBy.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let hash = script.sha256 {
                Text("SHA-256 \(hash)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            ForEach(script.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    private var summary: String {
        let role = script.role.rawValue.replacingOccurrences(of: "_", with: " ")
        var parts = [
            script.runtime,
            role,
            script.executable ? "executable" : "not executable",
            ByteCountFormatter.string(fromByteCount: Int64(script.byteCount), countStyle: .file),
        ]
        if script.symlink {
            parts.append(script.containment.rawValue.replacingOccurrences(of: "_", with: " "))
        }
        return parts.joined(separator: " · ")
    }
}

struct SkillReaderView: View {
    @ObservedObject var model: MetagentModel
    let row: InventorySkillRow
    var initialSkillPath: String? = nil
    var onDocumentChange: ((SkillDocument) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var document: SkillDocument?
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var isEditing = false
    @State private var isSaving = false
    @State private var draftName = ""
    @State private var draftDescription = ""
    @State private var draftBody = ""
    @State private var renamedSkillPath: String?
    @State private var portablePathScan: SkillPortablePathScan?
    @State private var showsPortablePathConfirmation = false
    @State private var actionMessage: String?
    @State private var isCheckingPortablePaths = false
    @State private var scoreDetailsRow: InventorySkillRow?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SkillDetailHeader(
                iconPath: row.skillIconPath,
                fallbackSymbol: "doc.text",
                title: document?.name ?? row.skillName,
                path: currentSkillPath,
                pathIsSelectable: true
            ) {
                if document != nil {
                    HStack(spacing: 8) {
                        Button("Scores", systemImage: "chart.bar.doc.horizontal") {
                            scoreDetailsRow = currentScoreRow
                        }
                        .disabled(currentScoreRow == nil)
                        Button(isEditing ? "Reading" : "Edit") {
                            if isEditing {
                                cancelEditing()
                            } else {
                                beginEditing()
                            }
                        }
                        .disabled(!row.canEditDocument || isSaving || isCheckingPortablePaths)
                        .help(row.canEditDocument
                            ? (isEditing ? "Discard unsaved edits and return to the reader." : "Edit this local SKILL.md.")
                            : "This skill is managed by \(row.skill.tableOriginText) and is read-only here.")
                    }
                }
            }

            if let document {
                if isEditing {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Name")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            TextField("Skill name", text: $draftName)
                                .textFieldStyle(.roundedBorder)
                        }

                        VStack(alignment: .leading, spacing: 5) {
                            Text("Description")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            TextEditor(text: $draftDescription)
                                .font(.body)
                                .scrollContentBackground(.hidden)
                                .padding(7)
                                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                                .frame(minHeight: 72, maxHeight: 110)
                        }

                        VStack(alignment: .leading, spacing: 5) {
                            Text("Instructions")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            TextEditor(text: $draftBody)
                                .font(.system(.body, design: .monospaced))
                                .scrollContentBackground(.hidden)
                                .padding(8)
                                .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
                                .frame(maxHeight: .infinity)
                        }

                        if let saveError {
                            Label(saveError, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    if let description = document.description {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Description")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(description)
                                .font(.body)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                    }

                    if !document.metadata.isEmpty {
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                            ForEach(document.metadata) { item in
                                GridRow {
                                    Text(item.key)
                                        .foregroundStyle(.secondary)
                                    Text(item.value)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .font(.callout)
                    }

                    Divider()

                    ScrollView {
                        SkillMarkdownDocumentView(
                            blocks: MetagentCore.skillMarkdownBlocks(document.bodyMarkdown)
                        )
                        .padding(.trailing, 10)
                    }
                }
            } else if let loadError {
                ContentUnavailableView(
                    "Couldn’t read this skill",
                    systemImage: "doc.badge.ellipsis",
                    description: Text(loadError)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("Loading skill…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let actionMessage {
                Text(actionMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack {
                if isEditing {
                    Button("Cancel", action: cancelEditing)
                        .disabled(isSaving)
                    Spacer()
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button("Save changes", action: saveChanges)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSave)
                } else {
                    Menu("Actions") {
                        Button("Open SKILL.md") {
                            openSkillFiles([skillFileURL])
                        }
                        Button("Open in Editor") {
                            openSkillDirectoriesInEditor([skillDirectoryURL], skillFiles: [skillFileURL])
                        }
                        Divider()
                        Button("Make Paths Portable…") {
                            scanForPersonalPaths()
                        }
                        .disabled(!row.canEditDocument || isCheckingPortablePaths)
                    }
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 760, height: 720)
        .task {
            loadDocument()
        }
        .confirmationDialog(
            "Make paths portable?",
            isPresented: $showsPortablePathConfirmation,
            titleVisibility: .visible
        ) {
            if (portablePathScan?.replaceableOccurrenceCount ?? 0) > 0 {
                Button("Replace in documentation") {
                    replacePersonalPaths()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let scan = portablePathScan {
                Text(portablePathConfirmationMessage(scan))
            }
        }
        .sheet(item: $scoreDetailsRow) { currentRow in
            SkillScoreGuidanceView(row: currentRow) {
                model.affirmModelReleaseReview(canonicalPath: currentRow.canonicalPath)
            }
        }
    }

    private var skillDirectoryURL: URL {
        URL(fileURLWithPath: currentSkillPath).standardizedFileURL
    }

    private var skillFileURL: URL {
        skillDirectoryURL.appendingPathComponent("SKILL.md")
    }

    private var currentSkillPath: String {
        renamedSkillPath ?? initialSkillPath ?? row.canonicalPath
    }

    private var canSave: Bool {
        guard !isSaving, !isCheckingPortablePaths, let document else { return false }
        let cleanName = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDescription = draftDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return !cleanName.isEmpty
            && !cleanDescription.isEmpty
            && (
                cleanName != document.name
                    || cleanDescription != (document.description ?? "")
                    || draftBody != document.bodyMarkdown
            )
    }

    private var currentScoreRow: InventorySkillRow? {
        guard !model.isRunning, !model.isSkillEvaluating else {
            return nil
        }
        return model.inventorySkillRow(canonicalPath: currentSkillPath)
            ?? (renamedSkillPath == nil ? row : nil)
    }

    private func loadDocument() {
        do {
            document = try MetagentCore.loadSkillDocument(at: currentSkillPath)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func beginEditing() {
        guard row.canEditDocument, let document else { return }
        draftName = document.name
        draftDescription = document.description ?? ""
        draftBody = document.bodyMarkdown
        saveError = nil
        isEditing = true
    }

    private func cancelEditing() {
        isEditing = false
        saveError = nil
    }

    private func saveChanges() {
        guard canSave, let original = document else { return }
        let name = draftName
        let description = draftDescription
        let body = draftBody
        let path = currentSkillPath
        isSaving = true
        saveError = nil
        Task {
            do {
                let updated = try await Task.detached(priority: .userInitiated) {
                    try MetagentCore.updateSkillDocument(
                        at: path,
                        expectedRawText: original.rawText,
                        name: name,
                        description: description,
                        bodyMarkdown: body
                    )
                }.value
                document = updated
                renamedSkillPath = updated.directoryPath
                onDocumentChange?(updated)
                isEditing = false
                model.refreshStatus()
            } catch {
                saveError = error.localizedDescription
            }
            isSaving = false
        }
    }

    private func scanForPersonalPaths() {
        let path = currentSkillPath
        isCheckingPortablePaths = true
        Task {
            do {
                let scan = try await Task.detached(priority: .userInitiated) {
                    try MetagentCore.scanSkillForPersonalPaths(at: path)
                }.value
                portablePathScan = scan
                if scan.findings.isEmpty {
                    actionMessage = "No personal home-directory references were found."
                } else {
                    actionMessage = nil
                    showsPortablePathConfirmation = true
                }
            } catch {
                actionMessage = error.localizedDescription
            }
            isCheckingPortablePaths = false
        }
    }

    private func replacePersonalPaths() {
        let path = currentSkillPath
        isCheckingPortablePaths = true
        Task {
            do {
                let report = try await Task.detached(priority: .userInitiated) {
                    try MetagentCore.replacePersonalPathsWithTilde(at: path)
                }.value
                actionMessage = "Replaced \(report.replacedOccurrenceCount) path reference(s) in \(report.updatedFiles.count) documentation file(s). Scripts and config files were left for manual review."
                loadDocument()
                model.refreshStatus()
            } catch {
                actionMessage = error.localizedDescription
            }
            isCheckingPortablePaths = false
        }
    }

    private func portablePathConfirmationMessage(_ scan: SkillPortablePathScan) -> String {
        var parts = [
            "Replace \(scan.replaceableOccurrenceCount) exact home-directory reference(s) with ~ in SKILL.md and reference documentation."
        ]
        if scan.reviewOccurrenceCount > 0 {
            parts.append("\(scan.reviewOccurrenceCount) reference(s) in scripts or config will not be changed because ~ may not expand there.")
        }
        return parts.joined(separator: "\n\n")
    }
}

struct SkillMarkdownDocumentView: View {
    let blocks: [SkillMarkdownBlock]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(blocks) { block in
                SkillMarkdownBlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

struct SkillMarkdownBlockView: View {
    let block: SkillMarkdownBlock

    var body: some View {
        switch block.kind {
        case let .heading(level):
            Text(inlineMarkdown(block.text))
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 5 : 1)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph:
            Text(inlineMarkdown(block.text))
                .font(.body)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case .unorderedListItem:
            listRow(marker: "•")
        case let .orderedListItem(marker):
            listRow(marker: marker)
        case .quote:
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(.tertiary)
                    .frame(width: 3)
                Text(inlineMarkdown(block.text))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .code(language):
            VStack(alignment: .leading, spacing: 6) {
                if let language {
                    Text(language.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    Text(block.text)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        case .divider:
            Divider()
        }
    }

    private func listRow(marker: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker)
                .foregroundStyle(.secondary)
                .frame(minWidth: 18, alignment: .trailing)
            Text(inlineMarkdown(block.text))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 4)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2.weight(.semibold)
        case 2: .title3.weight(.semibold)
        case 3: .headline
        default: .callout.weight(.semibold)
        }
    }

    private func inlineMarkdown(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(markdown)
    }
}

struct ScoreExplanationView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("How skill scores work")
                        .font(.title2.weight(.semibold))
                    Text("Every input, weight, and missing-data rule is shown here.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            Form {
                Section("Quality") {
                    Text("A stable 0–100 content and operational score. It deliberately excludes usage and calendar age.")
                    LabeledContent("Plugin Eval", value: "60%")
                    LabeledContent("Management confidence", value: "20%")
                    LabeledContent("Codex review", value: "20% · optional")
                    Text("Missing inputs are excluded, then the remaining weights are normalized to 100. Example: Plugin Eval 81 and management confidence 100, with no Codex review, becomes (81 × 60 + 100 × 20) ÷ 80 = 86.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Section("Plugin Eval") {
                    Text("The official Plugin Eval analyzer starts at 100 and deducts for concrete findings such as invalid metadata, weak trigger descriptions, broken references, excessive token budgets, and poor progressive disclosure. The 60% above is its weight inside Quality—not Plugin Eval's own formula.")
                }

                Section("Management confidence") {
                    Text("Measures whether Metagent can resolve one canonical skill, its lifecycle manager, authority, mutability, and provenance. It does not judge whether the instructions are good.")
                }

                Section("Utility") {
                    LabeledContent("Quality", value: "70%")
                    LabeledContent("Observed adoption", value: "30%")
                    Text("Adoption uses recency, distinct Codex threads, repeat reads in a turn, and total reads. Incomplete usage coverage receives a neutral provisional value; complete coverage with no reads receives zero adoption credit.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Section("Grades") {
                    Text("Quality, Utility, and Codex: A 90+, B 80+, C 70+, D 60+, F below 60. Plugin Eval uses its evaluator-owned stricter bands: A 93+, B 85+, C 70+, D 55+. Grades are absolute, never relative to the other skills in your table.")
                }
            }
            .formStyle(.grouped)
        }
        .padding(22)
        .frame(width: 680, height: 690)
    }
}

struct SkillScoreGuidanceView: View {
    let row: InventorySkillRow
    var onAffirmModelReleases: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var didAffirmModelReleases = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Score details")
                        .font(.title2.weight(.semibold))
                    Text(row.skillName)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                headlineScore("Quality", row.metagentScoreText, row.metagentScoreTint)
                headlineScore("Utility", row.portfolioScoreText, row.portfolioScoreTint)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            Form {
                fixFirstSection
                advisoriesSection
                scoreSummarySection
                evidenceSection
            }
            .formStyle(.grouped)
        }
        .padding(22)
        .frame(width: 760, height: 760)
    }

    private func headlineScore(_ label: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(tint)
        }
    }

    @ViewBuilder
    private var advisoriesSection: some View {
        if !row.advisories.isEmpty {
            Section("Advisories · Metagent") {
                ForEach(row.advisories) { advisory in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(advisory.message)
                                .font(.headline)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Text(didAffirmModelReleases ? "cleared" : "review due")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(didAffirmModelReleases ? .green : .orange)
                        }
                        Text("Metagent advisory · \(advisory.category) · \(advisory.severity)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(Array(advisory.remediation.enumerated()), id: \.offset) { _, step in
                            Label(step, systemImage: "arrow.turn.down.right")
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(advisory.clearance)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 3)
                }
                if let onAffirmModelReleases {
                    Button(
                        didAffirmModelReleases
                            ? "Marked Reviewed"
                            : "Mark Reviewed — No Changes Needed"
                    ) {
                        onAffirmModelReleases()
                        didAffirmModelReleases = true
                    }
                    .disabled(didAffirmModelReleases)
                }
            }
        }
    }

    @ViewBuilder
    private var fixFirstSection: some View {
        Section("Fix first") {
            if !fixFirstDeductions.isEmpty {
                ForEach(Array(fixFirstDeductions.enumerated()), id: \.element.id) { index, deduction in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(index + 1). \(deduction.message)")
                                .font(.headline)
                            Spacer()
                            Text("−\(formatPenalty(deduction.penalty))")
                                .font(.callout.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                        Text("Plugin Eval · \(deduction.category) · \(deduction.severity)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let firstStep = deduction.remediation.first {
                            Text(firstStep)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 3)
                }
            } else if !codexFeedback.isEmpty {
                ForEach(Array(codexFeedback.prefix(3).enumerated()), id: \.offset) { index, item in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text("\(index + 1).")
                                .font(.headline)
                            markdownText(item)
                                .font(.headline)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text("Codex feedback")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
            } else if let codexRecommendation {
                VStack(alignment: .leading, spacing: 5) {
                    Text(codexRecommendation)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Codex review recommendation")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if row.pluginEvalIsStale || row.codexReviewIsStale {
                Label(
                    "The skill changed after its saved evaluation. Re-run the stale evaluator before acting on its advice.",
                    systemImage: "clock.badge.exclamationmark"
                )
                .foregroundStyle(.orange)
            } else {
                Text("No evaluator returned an actionable improvement for the current skill.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var scoreSummarySection: some View {
        Section("How the numbers combine") {
            VStack(alignment: .leading, spacing: 3) {
                Text("Quality")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(qualityCalculation)
                    .font(.callout.monospacedDigit())
                    .textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Utility")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(utilityCalculation)
                    .font(.callout.monospacedDigit())
                    .textSelection(.enabled)
            }
            Text("Quality is static content quality. Utility adds observed adoption; advisories remain separate.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Full ledgers stay available but collapsed, so the sheet reads
    /// top-to-bottom as: what to do, the two numbers, then optional depth.
    private var evidenceSection: some View {
        Section("Evidence") {
            DisclosureGroup {
                managementContent
            } label: {
                evidenceGroupLabel(
                    "Management confidence",
                    detail: "\(row.metagentScore.structuralScore)/100 · 20% of Quality"
                )
            }

            if let evaluation = row.pluginEval, !row.pluginEvalIsStale {
                DisclosureGroup {
                    pluginEvalContent(evaluation)
                } label: {
                    evidenceGroupLabel(
                        "Plugin Eval",
                        detail: "\(evaluation.score) \(evaluation.grade) · \(evaluation.riskLevel) risk · \(evaluatedDateText(evaluation.evaluatedAt))"
                    )
                }
            } else {
                evidenceGroupLabel(
                    "Plugin Eval",
                    detail: row.pluginEvalIsStale
                        ? "stale — the skill changed after its saved result"
                        : "not run"
                )
            }

            if let review = row.codexReview, !row.codexReviewIsStale {
                DisclosureGroup {
                    codexReviewContent(review)
                } label: {
                    evidenceGroupLabel(
                        "Codex review",
                        detail: "\(review.score) \(review.grade.rawValue) · \(evaluatedDateText(review.evaluatedAt))"
                    )
                }
            } else {
                evidenceGroupLabel(
                    "Codex review",
                    detail: row.codexReviewIsStale
                        ? "stale — the skill changed after its saved result"
                        : "not run · optional, excluded from Quality"
                )
            }
        }
    }

    private func evidenceGroupLabel(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.body.weight(.medium))
            Spacer()
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var managementContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(row.metagentScore.components.filter { $0.id != "adoption" }, id: \.id) { component in
                VStack(alignment: .leading, spacing: 3) {
                    LabeledContent(
                        component.label,
                        value: "\(component.score)/\(component.maximum)"
                    )
                    Text(component.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("This ledger measures whether Metagent can safely identify and manage the skill. It does not judge the instructions.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func pluginEvalContent(_ evaluation: PluginEvalSkillAssessment) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if evaluation.deductions.isEmpty {
                Text("Plugin Eval returned no point deductions.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(evaluation.deductions, id: \.id) { deduction in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(deduction.message)
                                .font(.callout.weight(.medium))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Text("−\(formatPenalty(deduction.penalty))")
                                .font(.callout.monospacedDigit().weight(.semibold))
                                .foregroundStyle(deduction.penalty > 0 ? .orange : .secondary)
                        }
                        Text("\(deduction.category) · \(deduction.severity)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(Array(deduction.remediation.enumerated()), id: \.offset) { _, step in
                            Label(step, systemImage: "arrow.turn.down.right")
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            Text("plugin-eval \(evaluation.toolVersion) · content current")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func codexReviewContent(_ review: CodexSkillReview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                codexDimensionRow("Trigger and scope", review.dimensions.triggerAndScope, 25)
                codexDimensionRow("Workflow effectiveness", review.dimensions.workflowEffectiveness, 25)
                codexDimensionRow("Progressive disclosure", review.dimensions.progressiveDisclosure, 20)
                codexDimensionRow("Safety and operability", review.dimensions.safetyAndOperability, 15)
                codexDimensionRow("Maintainability", review.dimensions.maintainability, 15)
            }
            evidenceText("Summary", review.summary)
            if let feedback = review.feedback, !feedback.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Improvement feedback")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(Array(feedback.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.caption)
                            markdownText(item)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if !review.strengths.isEmpty {
                evidenceList("Strengths", review.strengths, symbol: "plus.circle")
            }
            if !review.risks.isEmpty {
                evidenceList("Risks", review.risks, symbol: "exclamationmark.triangle")
            }
            evidenceText("Recommendation", review.recommendation)
        }
        .padding(.vertical, 4)
    }

    private var fixFirstDeductions: ArraySlice<PluginEvalDeduction> {
        (row.pluginEval?.prioritizedDeductions ?? []).prefix(3)
    }

    private var codexFeedback: [String] {
        row.codexReview?.feedback ?? []
    }

    /// Feedback items are model-authored markdown; render inline styling and
    /// fall back to the raw string when parsing fails.
    private func markdownText(_ value: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: value,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(value)
    }

    private var codexRecommendation: String? {
        guard fixFirstDeductions.isEmpty,
              let value = row.codexReview?.recommendation.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    private var qualityCalculation: String {
        var inputs = [("Management", row.metagentScore.structuralScore, 20)]
        if let pluginEval = row.pluginEval {
            inputs.insert(("Plugin Eval", pluginEval.score, 60), at: 0)
        }
        if let codexReview = row.codexReview {
            inputs.append(("Codex", codexReview.score, 20))
        }
        let weight = inputs.reduce(0) { $0 + $1.2 }
        let terms = inputs.map { "\($0.0) \($0.1)×\($0.2)" }.joined(separator: " + ")
        return "(\(terms)) ÷ \(weight) = \(row.metagentStaticScore)"
    }

    private var utilityCalculation: String {
        let adoption = row.metagentScore.components.first { $0.id == "adoption" }
        let adoptionScore = adoption.flatMap { component in
            component.maximum > 0
                ? Int((Double(component.score) / Double(component.maximum) * 100).rounded())
                : nil
        } ?? 0
        return "Quality \(row.metagentStaticScore)×70% + adoption \(adoptionScore)×30% = \(row.utilityScore)"
    }

    private func scoreBadge(_ value: String, tint: Color) -> some View {
        Text(value)
            .font(.callout.monospacedDigit().weight(.semibold))
            .foregroundStyle(tint)
    }

    private func staleEvaluationLabel(_ provider: String) -> some View {
        Label(
            "\(provider) is stale because the installed content changed. Its old result is excluded from every displayed score.",
            systemImage: "clock.badge.exclamationmark"
        )
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func missingEvaluationLabel(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func codexDimensionRow(_ label: String, _ score: Int, _ maximum: Int) -> some View {
        GridRow {
            Text(label)
            Text("\(score)/\(maximum)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func evidenceText(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func evidenceList(_ label: String, _ values: [String], symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Label(value, systemImage: symbol)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func evaluatedDateText(_ value: String) -> String {
        parseISO8601Date(value)?.formatted(date: .abbreviated, time: .shortened) ?? value
    }

    private func formatPenalty(_ penalty: Double) -> String {
        penalty.formatted(.number.precision(.fractionLength(0...2)))
    }
}
