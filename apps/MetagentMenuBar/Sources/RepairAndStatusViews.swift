import AppKit
import Foundation
import MetagentCore
import SwiftUI
import UniformTypeIdentifiers

struct RepairSection: View {
    @ObservedObject var model: MetagentModel
    let projectRoot: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Resolve cleanup")
                        .font(.title2.weight(.semibold))
                    Text("Review the exact changes before applying them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Close") {
                    dismiss()
                }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
            }

            if let repairPreview = model.repairPreview {
                RepairPreviewView(
                    preview: repairPreview,
                    showsRawOutput: model.showsRawOutput,
                    rawLines: model.lastOutputLines,
                    onApply: model.repairNow,
                    onCopySummary: model.copyRepairSummary,
                    onCopyRawOutput: model.copyLastOutput,
                    onToggleRawOutput: model.toggleRawOutput,
                    onOpenProject: model.openProject
                )
            } else if model.isRunning {
                ProgressView("Preparing preview…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !model.lastOutputLines.isEmpty {
                CleanupFailureView(
                    lines: model.lastOutputLines,
                    onRetry: { model.previewRepair(projectRoot: projectRoot) },
                    onCopy: model.copyLastOutput
                )
            } else {
                Button {
                    model.previewRepair(projectRoot: projectRoot)
                } label: {
                    Label("Preview cleanup", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
        }
        .padding(20)
        .frame(minWidth: 820, minHeight: 580)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct CleanupFailureView: View {
    let lines: [String]
    let onRetry: () -> Void
    let onCopy: () -> Void
    @State private var showsDetails = false

    private var changedAfterPreview: Bool {
        lines.contains { $0.localizedCaseInsensitiveContains("changed after preview") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(
                changedAfterPreview ? "Cleanup changed" : "Cleanup couldn’t be prepared",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.title3.weight(.semibold))
            .foregroundStyle(Color.orange)

            Text(changedAfterPreview
                ? "The files changed after Metagent prepared the preview. Preview them again before applying anything."
                : "Metagent couldn’t prepare a safe cleanup preview. Try again, then inspect the details if it still fails.")
                .foregroundStyle(.secondary)

            Button("Preview again", action: onRetry)
                .buttonStyle(.glassProminent)

            DisclosureGroup("Technical details", isExpanded: $showsDetails) {
                VStack(alignment: .trailing, spacing: 8) {
                    RawOutputBlock(title: nil, lines: Array(lines.prefix(18)))
                    Button("Copy details", systemImage: "doc.on.doc", action: onCopy)
                        .buttonStyle(.glass)
                }
                .padding(.top, 8)
            }
            .font(.caption.weight(.medium))

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct EmptyStateView: View {
    let title: String
    let message: String
    let symbol: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.callout.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}

struct RepairPreviewView: View {
    let preview: RepairPreview
    let showsRawOutput: Bool
    let rawLines: [String]
    let onApply: () -> Void
    let onCopySummary: () -> Void
    let onCopyRawOutput: () -> Void
    let onToggleRawOutput: () -> Void
    let onOpenProject: (RepairProjectPreview) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preview.title)
                        .font(.headline)
                    Text(preview.summaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                if preview.summary.warningCount == 0 {
                    Badge(text: "Ready", symbol: "checkmark.circle", tint: .green)
                } else {
                    Badge(text: "\(preview.summary.warningCount) warn", symbol: "exclamationmark.triangle", tint: .orange)
                }
            }

            HStack(spacing: 8) {
                MetricView(title: "Projects", value: "\(preview.summary.projectCount)", symbol: "folder")
                MetricView(title: "Actions", value: "\(preview.summary.actionCount)", symbol: "list.bullet.rectangle")
                MetricView(title: "Skills", value: "\(preview.summary.validSkillCount)", symbol: "sparkles")
            }

            HStack(spacing: 8) {
                Button {
                    onApply()
                } label: {
                    Label("Apply cleanup", systemImage: "checkmark.circle")
                }
                .buttonStyle(.glassProminent)
                .disabled(!preview.canApply)
                .help(preview.canApply ? "Apply only the reviewed cleanup actions" : "No cleanup actions to apply")

                Button {
                    onCopySummary()
                } label: {
                    Label("Copy Summary", systemImage: "doc.on.doc")
                }
                .buttonStyle(.glass)

                Button {
                    onToggleRawOutput()
                } label: {
                    Label(showsRawOutput ? "Hide Raw" : "Show Raw", systemImage: "terminal")
                }
                .buttonStyle(.glass)

                if showsRawOutput {
                    Button {
                        onCopyRawOutput()
                    } label: {
                        Label("Copy Raw", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.glass)
                }
            }
            .font(.callout)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(preview.projects) { project in
                        RepairProjectView(project: project) {
                            onOpenProject(project)
                        }
                    }

                    if showsRawOutput {
                        RawOutputBlock(title: "Raw Output", lines: rawLines)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct RepairProjectView: View {
    let project: RepairProjectPreview
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.displayName)
                        .font(.callout.weight(.semibold))
                    Text(displayUserPath(project.root))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Button {
                    onOpen()
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.glass)
                .help("Open Project")
            }

            HStack(spacing: 6) {
                Badge(text: "\(project.validSkillCount) skills", symbol: "sparkles", tint: .blue)
                if project.actionCount > 0 {
                    Badge(text: "\(project.actionCount) actions", symbol: "list.bullet", tint: .green)
                }
                if project.warningCount > 0 {
                    Badge(text: "\(project.warningCount) warn", symbol: "exclamationmark.triangle", tint: .orange)
                }
                if project.skippedCount > 0 {
                    Badge(text: "\(project.skippedCount) skipped", symbol: "minus.circle", tint: .secondary)
                }
            }

            LineGroup(lines: project.warnings, tint: .orange)
            LineGroup(lines: project.actions, tint: .green)
            LineGroup(lines: project.skipped, tint: .secondary)
            LineGroup(lines: project.info, tint: .secondary)
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.055), lineWidth: 1)
        }
    }
}

struct LineGroup: View {
    let lines: [RepairLinePreview]
    let tint: Color

    var body: some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle()
                            .fill(tint)
                            .frame(width: 5, height: 5)
                        Text(line.text)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                    }
                }
            }
        }
    }
}

struct RawOutputBlock: View {
    let title: String?
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

struct MetricView: View {
    let title: String
    let value: String
    let symbol: String
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct StatusPathView: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .foregroundStyle(Color.accentColor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct Badge: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(text)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(tint.opacity(0.12), in: Capsule())
    }
}
