import MetagentCore
import SwiftUI

/// One skill's recorded lifetime, shown inside Get Info.
///
/// The portfolio charts answer "what is happening to my skills"; this answers
/// "what happened to this one" — installed when, edited how often, last touched
/// when. That is the view that actually changes a keep-or-remove decision.
struct SkillTimelineSection: View {
    let skillPath: String
    @State private var events: [SkillHistoryEvent] = []
    @State private var isLoading = true
    @State private var loadedPath: String?

    var body: some View {
        Section("Timeline") {
            if isLoading || loadedPath != skillPath {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading recorded history…")
                        .foregroundStyle(.secondary)
                }
            } else if events.isEmpty {
                Text("No recorded history for this skill yet.")
                    .foregroundStyle(.secondary)
            } else {
                if let summary {
                    LabeledContent("Installed", value: summary.installed)
                    if let edits = summary.edits {
                        LabeledContent("Edited", value: edits)
                    }
                    if let removed = summary.removed {
                        LabeledContent("Removed", value: removed)
                    }
                }

                ForEach(events.prefix(12)) { event in
                    HStack(spacing: 8) {
                        Text(dayText(event.occurredAt))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 82, alignment: .leading)
                        Text(event.kind.displayLabel)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(event.kind.tint)
                        if let from = event.detail["from"], event.kind == .renamed {
                            Text("from \(from)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if event.kind == .updated,
                           let from = event.detail["from"], !from.isEmpty,
                           let to = event.detail["to"], !to.isEmpty
                        {
                            Text("\(from) → \(to)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        if let evidence = event.detail["evidence"] {
                            Text(evidence)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                if events.count > 12 {
                    Text("\(events.count - 12) earlier changes not shown.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .task(id: skillPath) {
            await load()
        }
    }

    /// The headline facts, so the common questions are answered without reading
    /// the whole list.
    private var summary: (installed: String, edits: String?, removed: String?)? {
        guard let oldest = events.last else { return nil }
        let installedEvent = events.last { $0.kind == .added } ?? oldest
        let editCount = events.count { $0.kind == .contentChanged }
        let lastEdit = events.first { $0.kind == .contentChanged }
        let removal = events.first { $0.kind == .removed }
        return (
            installed: dayText(installedEvent.occurredAt),
            edits: editCount == 0
                ? nil
                : "\(editCount) \(editCount == 1 ? "change" : "changes"), last \(dayText(lastEdit?.occurredAt ?? installedEvent.occurredAt))",
            removed: removal.map { dayText($0.occurredAt) }
        )
    }

    private func dayText(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.abbreviated).day())
    }

    @MainActor
    private func load() async {
        let path = skillPath
        isLoading = true
        let loaded = await Task.detached(priority: .utility) {
            (try? MetagentCore.skillHistoryTimeline(skillKey: path)) ?? []
        }.value
        guard !Task.isCancelled, path == skillPath else { return }
        events = loaded
        loadedPath = path
        isLoading = false
    }
}
