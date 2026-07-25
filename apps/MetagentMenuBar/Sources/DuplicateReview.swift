import AppKit
import Foundation
import MetagentCore
import SwiftUI
import UniformTypeIdentifiers

struct DuplicateReviewExperience: View {
    let groups: [DuplicateReviewGroup]
    let hasVisibleGroups: Bool
    let hasDetectedGroups: Bool
    @Binding var selectedGroupID: String?
    @Binding var removalIDs: Set<SkillTableRow.ID>
    let isRunning: Bool
    let onView: (SkillTableRow) -> Void
    let onInfo: (SkillTableRow) -> Void
    let onReviewRemoval: ([SkillTableRow]) -> Void
    let onKeepAll: (DuplicateReviewGroup) -> Void
    let onReviewAgain: () -> Void

    private var selectedGroup: DuplicateReviewGroup? {
        groups.first { $0.id == selectedGroupID } ?? groups.first
    }

    var body: some View {
        if groups.isEmpty {
            if hasVisibleGroups {
                ContentUnavailableView {
                    Label("Duplicate review complete", systemImage: "checkmark.circle")
                } description: {
                    Text("You kept the remaining groups for this session.")
                } actions: {
                    Button("Review again", action: onReviewAgain)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label(
                        hasDetectedGroups ? "No complete groups match" : "No duplicate skills found",
                        systemImage: hasDetectedGroups ? "line.3.horizontal.decrease.circle" : "checkmark.circle"
                    )
                } description: {
                    Text(hasDetectedGroups
                        ? "A directory, source, scope, usage, or search filter is hiding part of each group. Adjust the filters to compare every copy safely."
                        : "Metagent found no same-name or overlapping canonical skill bundles.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            HStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        Text(groups.count == 1 ? "1 group to review" : "\(groups.count) groups to review")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.top, 4)
                            .padding(.bottom, 2)
                        ForEach(groups) { group in
                            Button {
                                select(group)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: group.symbol)
                                        .foregroundStyle(
                                            group.id == selectedGroup?.id ? Color.accentColor : .secondary
                                        )
                                        .frame(width: 18)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(group.skillName)
                                            .font(.callout.weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text("\(group.rows.count) copies · \(group.similarityText)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if group.id == selectedGroup?.id {
                                        Image(systemName: "chevron.right")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 9)
                                .background {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(group.id == selectedGroup?.id
                                            ? Color.accentColor.opacity(0.12)
                                            : Color.clear)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                }
                .frame(width: 220)

                Divider()

                if let selectedGroup {
                    DuplicateReviewDetail(
                        group: selectedGroup,
                        removalIDs: $removalIDs,
                        isRunning: isRunning,
                        onView: onView,
                        onInfo: onInfo,
                        onUseRecommendation: {
                            removalIDs.subtract(selectedGroup.rows.map(\.id))
                            removalIDs.formUnion(selectedGroup.suggestedRemovalRows.map(\.id))
                        },
                        onReviewRemoval: {
                            onReviewRemoval(selectedGroup.rows.filter { removalIDs.contains($0.id) })
                        },
                        onKeepAll: {
                            onKeepAll(selectedGroup)
                        }
                    )
                    .id(selectedGroup.id)
                }
            }
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.quaternary.opacity(0.18))
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.quaternary, lineWidth: 1)
            }
            .onAppear {
                if selectedGroupID == nil {
                    selectedGroupID = groups.first?.id
                }
            }
            .onChange(of: groups.map(\.id)) { _, ids in
                guard !ids.contains(selectedGroupID ?? "") else { return }
                selectedGroupID = ids.first
                removalIDs.removeAll()
            }
        }
    }

    private func select(_ group: DuplicateReviewGroup) {
        guard selectedGroupID != group.id else { return }
        selectedGroupID = group.id
        removalIDs.removeAll()
    }
}

struct DuplicateReviewDetail: View {
    let group: DuplicateReviewGroup
    @Binding var removalIDs: Set<SkillTableRow.ID>
    let isRunning: Bool
    let onView: (SkillTableRow) -> Void
    let onInfo: (SkillTableRow) -> Void
    let onUseRecommendation: () -> Void
    let onReviewRemoval: () -> Void
    let onKeepAll: () -> Void

    private var selectedRemovalCount: Int {
        group.rows.filter { removalIDs.contains($0.id) }.count
    }

    private var candidateColumns: [GridItem] {
        if group.rows.count <= 2 {
            return Array(
                repeating: GridItem(.flexible(minimum: 280), spacing: 10, alignment: .top),
                count: max(group.rows.count, 1)
            )
        }
        return [GridItem(.adaptive(minimum: 280), spacing: 10, alignment: .top)]
    }

    private var recommendationTint: Color {
        group.kind == .pluginReplacement ? .orange : .secondary
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.skillName)
                            .font(.title3.weight(.semibold))
                        Text(group.rows.count == 1
                            ? "1 installed copy"
                            : "\(group.rows.count) installed copies")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label("\(group.similarityText) similar", systemImage: "equal.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.accentColor.opacity(0.10), in: Capsule())
                }

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: group.kind == .pluginReplacement
                        ? "lightbulb.max.fill"
                        : "lightbulb")
                        .foregroundStyle(recommendationTint)
                        .font(.callout)
                        .frame(width: 26, height: 26)
                        .background(recommendationTint.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.recommendationTitle)
                            .font(.callout.weight(.semibold))
                        Text(group.recommendationDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if !group.suggestedRemovalRows.isEmpty {
                        Button("Use recommendation", action: onUseRecommendation)
                            .buttonStyle(.glass)
                            .help("Select Metagent’s recommended copies for removal. Nothing is removed until you approve the final review.")
                    }
                }
                .padding(10)
                .background(recommendationTint.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(recommendationTint.opacity(0.18), lineWidth: 1)
                }

                LazyVGrid(
                    columns: candidateColumns,
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(group.rows) { row in
                        DuplicateCandidateCard(
                            row: row,
                            isMarkedForRemoval: Binding(
                                get: { removalIDs.contains(row.id) },
                                set: { shouldRemove in
                                    if shouldRemove {
                                        removalIDs.insert(row.id)
                                    } else {
                                        removalIDs.remove(row.id)
                                    }
                                }
                            ),
                            onView: { onView(row) },
                            onInfo: { onInfo(row) }
                        )
                    }
                }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 10) {
                Button("Keep all", action: onKeepAll)
                    .buttonStyle(.glass)
                    .disabled(isRunning)
                    .help("Keep every copy in this group and mark it reviewed for this session.")
                Spacer()
                if selectedRemovalCount > 0 {
                    Text(selectedRemovalCount == 1
                        ? "1 copy marked for removal"
                        : "\(selectedRemovalCount) copies marked for removal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(
                    selectedRemovalCount > 1 ? "Review \(selectedRemovalCount) removals…" : "Review removal…",
                    role: .destructive,
                    action: onReviewRemoval
                )
                .buttonStyle(.glassProminent)
                .disabled(selectedRemovalCount == 0 || isRunning)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }
}

struct DuplicateCandidateCard: View {
    let row: SkillTableRow
    @Binding var isMarkedForRemoval: Bool
    let onView: () -> Void
    let onInfo: () -> Void

    private var canRemove: Bool { row.inventory?.removalRequest != nil }
    private var removalLabel: String {
        guard let request = row.inventory?.removalRequest else { return "Keep" }
        if case .plugin = request.kind { return "Remove plugin" }
        return "Remove"
    }

    private var isProjectSkill: Bool { row.scope == "project" }
    private var locationLabel: String {
        isProjectSkill ? row.projectName : "Global"
    }
    private var locationHelp: String {
        guard isProjectSkill else { return "Global skill available across directories" }
        guard let projectRoot = row.projectRoot else {
            return "Project skill available in \(row.projectName)"
        }
        return "Project skill available from \(displayUserPath(projectRoot))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                SkillSourceIconCell(category: row.sourceCategory, help: row.sourceHelp)
                Text(row.sourceText)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if row.overlap?.suggestedRemoval == true {
                    Text("Suggested removal")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.orange.opacity(0.12), in: Capsule())
                }
            }

            Label(locationLabel, systemImage: isProjectSkill ? "folder.fill" : "globe")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isProjectSkill ? Color.accentColor : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    (isProjectSkill ? Color.accentColor : Color.secondary).opacity(0.10),
                    in: Capsule()
                )
                .help(locationHelp)

            if row.descriptionText != "—" {
                Text(row.descriptionText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            HStack(spacing: 12) {
                candidateStat("Last 30 days", row.invocations30d.formatted())
                Divider().frame(height: 24)
                candidateStat("All time", row.totalInvocations.formatted())
                Divider().frame(height: 24)
                candidateStat("Updated", row.updatedText)
                Spacer(minLength: 0)
            }

            Text(displayUserPath(row.canonicalPath ?? row.skillPath))
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .truncationMode(.middle)
                .help(displayUserPath(row.canonicalPath ?? row.skillPath))

            Divider()

            HStack {
                Button("View", action: onView)
                    .buttonStyle(.glass)
                Button(action: onInfo) {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.glass)
                .help("Get Info")
                Spacer()
                if canRemove {
                    Picker("Decision", selection: $isMarkedForRemoval) {
                        Text("Keep").tag(false)
                        Text(removalLabel).tag(true)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .glassEffect(.regular.interactive(), in: Capsule())
                    .tint(isMarkedForRemoval ? .red : .accentColor)
                    .frame(width: removalLabel == "Remove plugin" ? 190 : 155)
                    .accessibilityLabel("Duplicate decision")
                    .help(removalLabel == "Remove plugin"
                        ? "Removing this copy uninstalls its entire plugin."
                        : "The final removal still requires approval.")
                } else {
                    Label("Keep", systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Metagent does not have a safe removal action for this managed copy.")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            isMarkedForRemoval ? AnyShapeStyle(Color.red.opacity(0.07)) : AnyShapeStyle(.background),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isMarkedForRemoval ? AnyShapeStyle(Color.red.opacity(0.4)) : AnyShapeStyle(.quaternary), lineWidth: 1)
        }
    }

    private func candidateStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

#if DEBUG
// MARK: - Duplicate review previews

private enum DuplicateReviewPreviewData {
    static func skillItem(
        name: String,
        description: String,
        path: String,
        location: String,
        locationLabel: String,
        scope: String,
        manager: String,
        authority: String
    ) -> SkillInventoryItem {
        SkillInventoryItem(
            name: name,
            description: description,
            path: path,
            location: location,
            locationLabel: locationLabel,
            originKind: "installed",
            scope: scope,
            manager: manager,
            authority: authority,
            mutability: "editable",
            representation: "canonical",
            canonicalPath: path,
            source: nil,
            sourceType: nil,
            sourceURL: nil,
            ref: nil,
            installedAt: nil,
            updatedAt: nil,
            symlinkedContainer: false,
            folderKind: scope == "global" ? "home" : "project",
            characterCount: 5400,
            wordCount: 820,
            tokenEstimate: 1100,
            skillFileCharacterCount: 5400,
            skillFileWordCount: 820,
            skillFileTokenEstimate: 1100,
            textFileCount: 3,
            referenceFileCount: 2,
            scriptFileCount: 1,
            assetFileCount: 0,
            otherFileCount: 0,
            otherFolderCount: 0,
            hasOpenAIYaml: false,
            hasIconSmall: false,
            hasIconLarge: false,
            hasIconAndLogo: false,
            iconSmallPath: nil,
            iconLargePath: nil
        )
    }

    static func row(
        projectRoot: String,
        skill: SkillInventoryItem,
        invocations30d: Int,
        totalInvocations: Int,
        overlap: SkillOverlapMembership
    ) -> SkillTableRow {
        let project = ProjectStatus.previewFixture(project: SkillProject(
            root: projectRoot,
            skillsDir: projectRoot + "/.agents/skills",
            validSkills: [skill.name],
            skills: [skill]
        ))
        let inventory = InventorySkillRow(
            project: project,
            skill: project.skills[0],
            variants: project.skills,
            metagentScore: MetagentSkillScore(score: 78, confidence: .medium, components: []),
            pluginEval: nil,
            codexReview: nil
        )
        return SkillTableRow(
            inventory: inventory,
            usage: UsageSkillRow(
                id: "preview:\(projectRoot):\(skill.name)",
                skillName: skill.name,
                canonicalPath: skill.canonicalPath,
                scope: skill.scope,
                totalInvocations: totalInvocations,
                invocations7d: invocations30d / 3,
                invocations30d: invocations30d,
                distinctThreads: max(totalInvocations / 3, 1),
                repeatInvocations: 4,
                lastUsedDate: Date().addingTimeInterval(-2 * 86_400),
                lastUsedSortValue: 0,
                status: .active
            ),
            historicalProjectRoot: nil,
            pluginInventoryAvailable: true,
            overlap: overlap
        )
    }

    static var groups: [DuplicateReviewGroup] {
        let metagentDescription = "Analyze tooling, MCP/plugin availability, skill portfolios, and "
            + "instruction ownership. Use when diagnosing tool or namespace availability."
        let scraperDescription = "Scrape public data from social platforms via the ScrapeCreators "
            + "REST API. Use for profiles, posts, transcripts, and engagement metrics."

        let sameSkillGroup = DuplicateReviewGroup(
            id: "preview:metagent",
            kind: .globalProject,
            similarity: 1.0,
            rows: [
                row(
                    projectRoot: "/Users/preview/code_projects/agent-tools",
                    skill: skillItem(
                        name: "metagent",
                        description: metagentDescription,
                        path: "/Users/preview/code_projects/agent-tools/.agents/skills/metagent",
                        location: "agents",
                        locationLabel: ".agents",
                        scope: "project",
                        manager: "local",
                        authority: "local"
                    ),
                    invocations30d: 60,
                    totalInvocations: 67,
                    overlap: SkillOverlapMembership(
                        groupID: "preview:metagent",
                        kind: .globalProject,
                        similarity: 1.0,
                        suggestedRemoval: false
                    )
                ),
                row(
                    projectRoot: "/Users/preview",
                    skill: skillItem(
                        name: "metagent",
                        description: metagentDescription,
                        path: "/Users/preview/.agents/skills/metagent",
                        location: "agents",
                        locationLabel: ".agents",
                        scope: "global",
                        manager: "skills-cli",
                        authority: "skills-cli"
                    ),
                    invocations30d: 25,
                    totalInvocations: 33,
                    overlap: SkillOverlapMembership(
                        groupID: "preview:metagent",
                        kind: .globalProject,
                        similarity: 1.0,
                        suggestedRemoval: false
                    )
                ),
            ]
        )

        let pluginGroup = DuplicateReviewGroup(
            id: "preview:scrapecreators-api",
            kind: .pluginReplacement,
            similarity: 0.95,
            rows: [
                row(
                    projectRoot: "/Users/preview/.codex/plugins/scrape-pack",
                    skill: skillItem(
                        name: "scrapecreators-api",
                        description: scraperDescription,
                        path: "/Users/preview/.codex/plugins/scrape-pack/skills/scrapecreators-api",
                        location: "plugin",
                        locationLabel: "plugin",
                        scope: "plugin",
                        manager: "codex-plugin",
                        authority: "scrape-pack@skills"
                    ),
                    invocations30d: 18,
                    totalInvocations: 54,
                    overlap: SkillOverlapMembership(
                        groupID: "preview:scrapecreators-api",
                        kind: .pluginReplacement,
                        similarity: 0.95,
                        suggestedRemoval: false
                    )
                ),
                row(
                    projectRoot: "/Users/preview",
                    skill: skillItem(
                        name: "scrapecreators-api",
                        description: scraperDescription,
                        path: "/Users/preview/.agents/skills/scrapecreators-api",
                        location: "agents",
                        locationLabel: ".agents",
                        scope: "global",
                        manager: "skills-cli",
                        authority: "skills-cli"
                    ),
                    invocations30d: 2,
                    totalInvocations: 41,
                    overlap: SkillOverlapMembership(
                        groupID: "preview:scrapecreators-api",
                        kind: .pluginReplacement,
                        similarity: 0.95,
                        suggestedRemoval: true
                    )
                ),
            ]
        )

        return [sameSkillGroup, pluginGroup]
    }
}

#Preview("Duplicate review", traits: .fixedLayout(width: 980, height: 640)) {
    @Previewable @State var selectedGroupID: String?
    @Previewable @State var removalIDs = Set<SkillTableRow.ID>()
    DuplicateReviewExperience(
        groups: DuplicateReviewPreviewData.groups,
        hasVisibleGroups: true,
        hasDetectedGroups: true,
        selectedGroupID: $selectedGroupID,
        removalIDs: $removalIDs,
        isRunning: false,
        onView: { _ in },
        onInfo: { _ in },
        onReviewRemoval: { _ in },
        onKeepAll: { _ in },
        onReviewAgain: {}
    )
    .padding(20)
}

#Preview("Candidate card", traits: .fixedLayout(width: 380, height: 360)) {
    @Previewable @State var marked = false
    DuplicateCandidateCard(
        row: DuplicateReviewPreviewData.groups[0].rows[0],
        isMarkedForRemoval: $marked,
        onView: {},
        onInfo: {}
    )
    .padding(20)
}
#endif
