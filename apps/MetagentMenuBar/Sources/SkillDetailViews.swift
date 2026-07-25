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
    @State private var showsScoreExplanation = false
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

                Section("Scores") {
                    LabeledContent("Quality", value: row.metagentScoreText)
                    LabeledContent("Plugin Eval", value: row.pluginEvalText)
                    LabeledContent("Utility", value: row.portfolioScoreText)
                    LabeledContent("Codex", value: row.codexReviewText)
                    Button("How scores work…") {
                        showsScoreExplanation = true
                    }
                }
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
        .sheet(isPresented: $showsScoreExplanation) {
            ScoreExplanationView()
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
