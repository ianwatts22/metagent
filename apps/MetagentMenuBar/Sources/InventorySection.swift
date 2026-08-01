import AppKit
import Foundation
import MetagentCore
import SwiftUI
import UniformTypeIdentifiers

struct InventorySection: View {
    @ObservedObject var model: MetagentModel
    let selectedProjectRoot: String?
    @State private var selection = Set<SkillTableRow.ID>()
    @State private var sortOrder = [KeyPathComparator(\SkillTableRow.skillName)]
    @State private var cachedRows: [SkillTableRow] = []
    @State private var query = ""
    @State private var usageFilter = UsageFilter.all
    @State private var scopeFilter = SkillScopeFilter.all
    @State private var pendingConfirmation: InventoryConfirmation?
    @State private var inspectedSkill: InventorySkillRow?
    @State private var viewedSkill: InventorySkillRow?
    @State private var scoreAnalysisSkill: InventorySkillRow?
    @State private var iconTarget: InventorySkillRow?
    @State private var publicationTarget: InventorySkillRow?
    @State private var selectedDuplicateGroupID: String?
    @State private var duplicateRemovalIDs = Set<SkillTableRow.ID>()
    @State private var reviewedDuplicateGroupIDs = Set<String>()
    @State private var hiddenSourceRawBeforeDuplicateReview: String?
    @AppStorage("metagent.skills.view.v2") private var selectedViewRaw = SkillTableView.summary.rawValue
    @AppStorage("metagent.skills.grouping.v1") private var groupingRaw = SkillGrouping.none.rawValue
    @AppStorage("metagent.skills.hidden-sources.v2")
    private var hiddenSourceRaw = "__unmigrated__"
    @SceneStorage("metagent.skills.inventory.columns.v3")
    private var inventoryColumnCustomization = TableColumnCustomization<SkillTableRow>()
    @SceneStorage("metagent.skills.summary.columns.v4")
    private var summaryColumnCustomization = TableColumnCustomization<SkillTableRow>()
    @SceneStorage("metagent.skills.usage.columns.v3")
    private var usageColumnCustomization = TableColumnCustomization<SkillTableRow>()
    @SceneStorage("metagent.skills.review.columns.v2")
    private var reviewColumnCustomization = TableColumnCustomization<SkillTableRow>()
    @SceneStorage("metagent.skills.duplicates.columns.v1")
    private var duplicateColumnCustomization = TableColumnCustomization<SkillTableRow>()

    private var selectedView: SkillTableView {
        SkillTableView(rawValue: selectedViewRaw) ?? .summary
    }

    private var selectedViewBinding: Binding<SkillTableView> {
        Binding(
            get: { selectedView },
            set: { selectedViewRaw = $0.rawValue }
        )
    }

    private var grouping: SkillGrouping {
        SkillGrouping(rawValue: groupingRaw) ?? .none
    }

    private var groupingBinding: Binding<SkillGrouping> {
        Binding(
            get: { grouping },
            set: {
                groupingRaw = $0.rawValue
                selection.removeAll()
            }
        )
    }

    private var hiddenSources: Set<SkillSourceCategory> {
        let rawValue = hiddenSourceRaw == "__unmigrated__"
            ? SkillSourceCategory.notInstalled.rawValue
            : hiddenSourceRaw
        return Set(rawValue.split(separator: ",").compactMap { SkillSourceCategory(rawValue: String($0)) })
    }

    private var columnCustomization: Binding<TableColumnCustomization<SkillTableRow>> {
        switch selectedView {
        case .summary:
            Binding(get: { summaryColumnCustomization }, set: { summaryColumnCustomization = $0 })
        case .review:
            Binding(get: { reviewColumnCustomization }, set: { reviewColumnCustomization = $0 })
        case .duplicates:
            Binding(get: { duplicateColumnCustomization }, set: { duplicateColumnCustomization = $0 })
        case .published:
            Binding(get: { summaryColumnCustomization }, set: { summaryColumnCustomization = $0 })
        case .inventory:
            Binding(get: { inventoryColumnCustomization }, set: { inventoryColumnCustomization = $0 })
        case .usage:
            Binding(get: { usageColumnCustomization }, set: { usageColumnCustomization = $0 })
        }
    }

    private var rows: [SkillTableRow] {
        let searchQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return cachedRows
        .filter {
            guard let removalID = $0.inventory?.removalRequest?.id else { return true }
            // Completed removals stay hidden too: their rows are already gone
            // from disk, and only the reconcile rescan may bring a row back.
            return !model.pendingSkillRemovalIDs.contains(removalID)
                && !model.completedSkillRemovalIDs.contains(removalID)
        }
        .filter { selectedView == .usage || $0.isInstalled }
        .filter { selectedView != .duplicates || $0.overlap != nil }
        .filter {
            guard let selectedProjectRoot else { return true }
            if isGlobalRoot(selectedProjectRoot) {
                return $0.scope != "project"
            }
            return $0.scope == "project" && $0.projectRoot == selectedProjectRoot
        }
        .filter { !hiddenSources.contains($0.sourceCategory) }
        .filter { scopeFilter.includes($0) }
        .filter { usageFilter.includes(status: $0.usageStatus, totalInvocations: $0.totalInvocations) }
        .filter { searchQuery.isEmpty || $0.matches(searchQuery) }
    }

    private var sortedRows: [SkillTableRow] {
        rows.sorted(using: sortOrder)
    }

    private var displayRows: [SkillTableRow] {
        guard grouping != .none else { return sortedRows }
        let groupedRows = Dictionary(grouping: rows, by: grouping.key(for:))
            .map { key, children in
                SkillTableRow.group(
                    id: "\(grouping.rawValue):\(key)",
                    title: children.first.map(grouping.title(for:)) ?? key,
                    children: children.sorted(using: sortOrder)
                )
            }
        return groupedRows.sorted { left, right in
            guard let leftChild = left.children?.first, let rightChild = right.children?.first else {
                return left.skillName.localizedCaseInsensitiveCompare(right.skillName) == .orderedAscending
            }
            for comparator in sortOrder {
                switch comparator.compare(leftChild, rightChild) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: continue
                }
            }
            return left.skillName.localizedCaseInsensitiveCompare(right.skillName) == .orderedAscending
        }
    }

    private var selectedRow: InventorySkillRow? {
        let resolved = resolvedRows(for: selection)
        guard resolved.count == 1 else { return nil }
        return resolved.first?.inventory
    }

    private var selectedRows: [SkillTableRow] {
        resolvedRows(for: selection)
    }

    private var selectedRemovalRows: [InventorySkillRow] {
        selectedRows.compactMap(\.inventory).filter { $0.removalRequest != nil }
    }

    private var visibleInventoryRows: [InventorySkillRow] {
        rows.compactMap(\.inventory)
    }

    private var completeVisibleDuplicateGroups: [DuplicateReviewGroup] {
        let visibleRowIDs = Set(rows.map(\.id))
        return Dictionary(grouping: cachedRows.compactMap { row -> SkillTableRow? in
            row.overlap == nil ? nil : row
        }, by: { $0.overlap?.groupID ?? "" })
            .compactMap { id, groupRows -> DuplicateReviewGroup? in
                guard !id.isEmpty,
                      groupRows.count > 1,
                      groupRows.allSatisfy({ visibleRowIDs.contains($0.id) }),
                      let overlap = groupRows.compactMap(\.overlap).first
                else { return nil }
                return DuplicateReviewGroup(
                    id: id,
                    kind: overlap.kind,
                    similarity: overlap.similarity,
                    rows: groupRows.sorted {
                        if $0.overlap?.suggestedRemoval != $1.overlap?.suggestedRemoval {
                            return $1.overlap?.suggestedRemoval == true
                        }
                        return $0.sourceText.localizedCaseInsensitiveCompare($1.sourceText) == .orderedAscending
                    }
                )
            }
            .sorted {
                let leftPriority = $0.rows.first?.overlap?.sortValue ?? Int.max
                let rightPriority = $1.rows.first?.overlap?.sortValue ?? Int.max
                if leftPriority != rightPriority { return leftPriority < rightPriority }
                return $0.skillName.localizedCaseInsensitiveCompare($1.skillName) == .orderedAscending
            }
    }

    private var duplicateReviewGroups: [DuplicateReviewGroup] {
        completeVisibleDuplicateGroups.filter { !reviewedDuplicateGroupIDs.contains($0.id) }
    }

    private var visibleOverlapGroupCount: Int {
        completeVisibleDuplicateGroups.count
    }

    private var hasDetectedOverlapGroups: Bool {
        cachedRows.contains { $0.overlap != nil }
    }

    private var hasActiveFilter: Bool {
        let effectiveHiddenSources = selectedView == .usage
            ? hiddenSources
            : hiddenSources.subtracting([.notInstalled])
        return usageFilter != .all
            || scopeFilter != .all
            || !effectiveHiddenSources.isEmpty
            || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func rows(for contextSelection: Set<SkillTableRow.ID>) -> [SkillTableRow] {
        let ids = contextSelection.isEmpty ? selection : contextSelection
        return resolvedRows(for: ids)
    }

    private func resolvedRows(for ids: Set<SkillTableRow.ID>) -> [SkillTableRow] {
        displayRows.flatMap { row -> [SkillTableRow] in
            if ids.contains(row.id) {
                return row.children ?? [row]
            }
            return row.children?.filter { ids.contains($0.id) } ?? []
        }
    }

    private func copyPaths(_ rows: [SkillTableRow]) {
        copyToPasteboard(rows.compactMap(\.canonicalPath).uniqued().joined(separator: "\n"))
    }

    private func copyToImprove(_ rows: [SkillTableRow]) {
        copyToPasteboard(improvementPrompt(paths: rows.compactMap(\.canonicalPath)))
    }

    private func setSource(_ source: SkillSourceCategory, visible: Bool) {
        var updated = hiddenSources
        if visible {
            updated.remove(source)
        } else {
            updated.insert(source)
        }
        hiddenSourceRaw = updated.map(\.rawValue).sorted().joined(separator: ",")
        selection.removeAll()
    }

    private func migrateSourceVisibilityIfNeeded() {
        guard hiddenSourceRaw == "__unmigrated__" else { return }
        if let legacyValue = UserDefaults.standard.string(forKey: "metagent.skills.hidden-sources.v1") {
            hiddenSourceRaw = legacyValue
        } else {
            hiddenSourceRaw = SkillSourceCategory.notInstalled.rawValue
        }
    }

    private func beginDuplicateReview() {
        guard hiddenSourceRawBeforeDuplicateReview == nil else { return }
        hiddenSourceRawBeforeDuplicateReview = hiddenSourceRaw
        hiddenSourceRaw = ""
    }

    private func endDuplicateReview() {
        guard let previousValue = hiddenSourceRawBeforeDuplicateReview else { return }
        hiddenSourceRaw = previousValue
        hiddenSourceRawBeforeDuplicateReview = nil
    }

    private var countText: String {
        if selectedView == .published {
            let enabled = model.publicationSnapshot.records.filter(\.automaticMirroringEnabled).count
            return "\(enabled) mirrored"
        }
        if !selectedRows.isEmpty {
            return "\(selectedRows.count) selected"
        }
        if selectedView == .duplicates {
            return "\(visibleOverlapGroupCount) groups · \(rows.count) copies"
        }
        return "\(rows.count) skills"
    }

    /// How many of the tucked-away controls are off their default, so the menu
    /// can say so without the user opening it.
    private var activeAdvancedFilterCount: Int {
        var count = hiddenSources == [.notInstalled] ? 0 : 1
        if scopeFilter != .all { count += 1 }
        return count
    }

    private var advancedFilterTitle: String {
        activeAdvancedFilterCount == 0 ? "Filters" : "Filters · \(activeAdvancedFilterCount)"
    }

    @ViewBuilder
    private var toolbarControls: some View {
        SkillViewSelector(selection: selectedViewBinding)
        CountChip(text: countText)
        if selectedView != .published {
            filterControls
        }
    }

    @ViewBuilder
    private var filterControls: some View {
        GlassSearchField(placeholder: "Search", text: $query, width: 150)

        // Usage is the question this app exists to answer, so it stays in the
        // open alongside search and grouping.
        GlassSelectionMenu(
            title: "Usage",
            selection: $usageFilter,
            options: Array(UsageFilter.allCases),
            optionTitle: { $0.title },
            width: 158
        )

        if selectedView != .duplicates {
            GlassSelectionMenu(
                title: "Group",
                selection: groupingBinding,
                options: Array(SkillGrouping.allCases),
                optionTitle: { $0.title },
                width: 150
            )
            .help("Group the current Skills view. Groups can be expanded or collapsed and apply across every view.")
        }

        Menu {
            Picker("Location", selection: $scopeFilter) {
                ForEach(SkillScopeFilter.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }

            Section("Visible sources") {
                Button("Show All Sources") {
                    hiddenSourceRaw = ""
                    selection.removeAll()
                }
                .disabled(hiddenSources.isEmpty)
                ForEach(SkillSourceCategory.allCases) { source in
                    Toggle(
                        source.title,
                        isOn: Binding(
                            get: { !hiddenSources.contains(source) },
                            set: { setSource(source, visible: $0) }
                        )
                    )
                }
            }
        } label: {
            GlassMenuLabel(
                title: advancedFilterTitle,
                systemImage: "slider.horizontal.3",
                width: activeAdvancedFilterCount == 0 ? 112 : 128
            )
        }
        .help("Location and which skill sources are visible")
        .buttonStyle(.plain)

        if !model.archivedSkills.isEmpty {
            archivedSkillsMenu
        }
    }

    /// Appears only while something is set aside, so the toolbar carries no
    /// extra chrome in the common case of an empty archive.
    private var archivedSkillsMenu: some View {
        Menu {
            Section("Archived skills") {
                ForEach(model.archivedSkills) { entry in
                    Button("Restore \(entry.skillName)") {
                        model.restoreArchivedSkill(named: entry.skillName)
                    }
                    .disabled(model.isRunning)
                }
            }
            Divider()
            Button("Show Archive in Finder") {
                NSWorkspace.shared.open(MetagentCore.archivedSkillsRoot())
            }
        } label: {
            GlassMenuLabel(
                title: "Archived · \(model.archivedSkills.count)",
                systemImage: "archivebox",
                width: 128
            )
        }
        .help("Skills set aside in Metagent's Archived Skills folder. No agent runtime sees them until restored.")
        .buttonStyle(.plain)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // One row when the window allows it, two only when it does not.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    toolbarControls
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        SkillViewSelector(selection: selectedViewBinding)
                        CountChip(text: countText)
                        Spacer(minLength: 0)
                    }
                    if selectedView != .published {
                        HStack(spacing: 8) {
                            filterControls
                            Spacer(minLength: 0)
                        }
                    }
                }
            }

            if selectedView == .published {
                PublishedSkillsView(model: model)
            } else if rows.isEmpty {
                EmptyStateView(
                    title: selectedView == .duplicates
                        ? (hasActiveFilter ? "No matching duplicates" : "No duplicate installations")
                        : (hasActiveFilter ? "No matching skills" : "No skills found"),
                    message: hasActiveFilter
                        ? "Clear the search or choose All Projects."
                        : (selectedView == .duplicates
                            ? "Metagent found no same-name or overlapping canonical skill bundles."
                            : "Refresh after configuring roots or adding skills."),
                    symbol: selectedView == .duplicates ? "checkmark.circle" : "tablecells"
                )
            } else if selectedView == .duplicates {
                DuplicateReviewExperience(
                    groups: duplicateReviewGroups,
                    hasVisibleGroups: !completeVisibleDuplicateGroups.isEmpty,
                    hasDetectedGroups: hasDetectedOverlapGroups,
                    selectedGroupID: $selectedDuplicateGroupID,
                    removalIDs: $duplicateRemovalIDs,
                    isRunning: model.isRunning && !model.isRemovingSkills,
                    onView: { row in viewedSkill = row.inventory },
                    onInfo: { row in inspectedSkill = row.inventory },
                    onReviewRemoval: { candidateRows in
                        let removableRows = candidateRows.compactMap(\.inventory)
                            .filter { $0.removalRequest != nil }
                        guard !removableRows.isEmpty else { return }
                        pendingConfirmation = .removal(removableRows)
                    },
                    onKeepAll: { group in
                        reviewedDuplicateGroupIDs.insert(group.id)
                        duplicateRemovalIDs.subtract(group.rows.map(\.id))
                        selectedDuplicateGroupID = duplicateReviewGroups.first {
                            $0.id != group.id
                        }?.id
                    },
                    onReviewAgain: {
                        reviewedDuplicateGroupIDs.removeAll()
                        selectedDuplicateGroupID = nil
                        duplicateRemovalIDs.removeAll()
                    }
                )
            } else {
                skillsTable
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            Button("") {
                if let selectedRow { inspectedSkill = selectedRow }
            }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(selectedRow == nil)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .onAppear {
            migrateSourceVisibilityIfNeeded()
            if selectedView == .duplicates {
                beginDuplicateReview()
            }
            sortOrder = defaultSortOrder(for: selectedView)
        }
        .onDisappear {
            endDuplicateReview()
        }
        .task(id: model.skillTableRevision) {
            await rebuildRows()
            model.evaluateMissingSkills(paths: visibleInventoryRows.map(\.canonicalPath))
        }
        .onChange(of: model.isSkillEvaluating) { _, isEvaluating in
            // Each batch bumps the revision, so pick up whatever is still
            // unevaluated once the previous pass finishes.
            guard !isEvaluating else { return }
            model.evaluateMissingSkills(paths: visibleInventoryRows.map(\.canonicalPath))
        }
        .onChange(of: selectedViewRaw) { oldRawValue, rawValue in
            let oldView = SkillTableView(rawValue: oldRawValue) ?? .summary
            let view = SkillTableView(rawValue: rawValue) ?? .summary
            if oldView != .duplicates, view == .duplicates {
                beginDuplicateReview()
            } else if oldView == .duplicates, view != .duplicates {
                endDuplicateReview()
            }
            selection.formIntersection(Set(rows.map(\.id)))
            duplicateRemovalIDs.removeAll()
            sortOrder = defaultSortOrder(for: view)
        }
        .alert(item: $pendingConfirmation) { confirmation in
            switch confirmation {
            case let .removal(rows):
                let requests = rows.compactMap(\.removalRequest)
                let names = rows.prefix(6).map(\.skillName).joined(separator: ", ")
                let suffix = rows.count > 6 ? ", …" : ""
                return Alert(
                    title: Text(requests.count == 1 ? "Remove selected skill?" : "Remove \(requests.count) selected items?"),
                    message: Text("\(names)\(suffix)\n\n\(skillRemovalMessage(for: rows))"),
                    primaryButton: .destructive(Text(requests.count == 1 ? "Approve Removal" : "Approve \(requests.count) Removals")) {
                        if model.uninstallSkills(requests) {
                            duplicateRemovalIDs.removeAll()
                            selection.removeAll()
                        }
                    },
                    secondaryButton: .cancel()
                )
            case let .archive(rows):
                let requests = rows.compactMap(\.archiveRequest)
                let names = rows.prefix(6).map(\.skillName).joined(separator: ", ")
                let suffix = rows.count > 6 ? ", …" : ""
                return Alert(
                    title: Text(requests.count == 1 ? "Archive selected skill?" : "Archive \(requests.count) selected skills?"),
                    message: Text("\(names)\(suffix)\n\nArchiving moves the skill and its projection links into Metagent's Archived Skills folder, so no agent runtime sees it until you restore it. Nothing is deleted; Restore puts everything back exactly where it was."),
                    primaryButton: .default(Text(requests.count == 1 ? "Archive" : "Archive \(requests.count) Skills")) {
                        if model.archiveSkills(requests) {
                            selection.removeAll()
                        }
                    },
                    secondaryButton: .cancel()
                )
            case let .codexReview(rows):
                let names = rows.prefix(4).map(\.skillName).joined(separator: ", ")
                let suffix = rows.count > 4 ? ", …" : ""
                return Alert(
                    title: Text(rows.count == 1
                        ? "Review \(rows[0].skillName) with Codex?"
                        : "Review \(rows.count) skills with Codex?"),
                    message: Text("\(names)\(suffix)\n\nCodex reviews each skill in context: it can read the surrounding project and sibling skills (read-only, nothing is edited) to judge fit and overlap, and what it reads is sent to OpenAI for an ephemeral review. A multi-skill selection is reviewed in one Codex session."),
                    primaryButton: .default(Text(rows.count == 1 ? "Run Review" : "Run \(rows.count) Reviews")) {
                        model.reviewSkillsWithCodex(rows.map { (path: $0.canonicalPath, projectRoot: $0.projectRoot) })
                    },
                    secondaryButton: .cancel()
                )
            }
        }
        .sheet(item: $inspectedSkill) { row in
            SkillInfoView(model: model, row: row)
        }
        .sheet(item: $viewedSkill) { row in
            SkillReaderView(model: model, row: row)
        }
        .sheet(item: $scoreAnalysisSkill) { row in
            SkillScoreGuidanceView(row: row) {
                model.affirmModelReleaseReview(canonicalPath: row.canonicalPath)
            }
        }
        .sheet(item: $iconTarget) { row in
            SkillIconEditorView(model: model, row: row)
        }
        .sheet(item: $publicationTarget) { row in
            SkillPublicationSetupSheet(model: model, row: row)
        }
    }

    private var skillsTable: some View {
        Table(
            displayRows,
            children: \.children,
            selection: $selection,
            sortOrder: $sortOrder,
            columnCustomization: columnCustomization
        ) {
            TableColumnForEach(skillColumnSpecs) { column in
                TableColumn(column.title, sortUsing: column.comparator) { row in
                    SkillTableColumnCell(column: column, row: row)
                }
                .width(min: column.minWidth, ideal: column.idealWidth)
                .customizationID(column.id)
                .defaultVisibility(column.defaultVisibility(selectedView))
            }
        }
        .id("\(selectedView.rawValue):\(grouping.rawValue)")
        .tableStyle(.inset)
        .alternatingRowBackgrounds(.enabled)
        .contextMenu(forSelectionType: SkillTableRow.ID.self) { contextSelection in
            skillContextMenu(for: contextSelection)
        }
    }

    @ViewBuilder
    private func skillContextMenu(for contextSelection: Set<SkillTableRow.ID>) -> some View {
        let contextRows = rows(for: contextSelection)
        let removableRows = contextRows.compactMap(\.inventory).filter { $0.removalRequest != nil }
        let paths = contextRows.compactMap(\.canonicalPath)
        let openableURLs = skillDirectoryURLs(for: contextRows)
        let skillFiles = skillFileURLs(for: contextRows)
        if contextRows.count == 1, let inventory = contextRows.first?.inventory {
            Button("View Skill", systemImage: "doc.text.magnifyingglass") {
                viewedSkill = inventory
            }
            Button("Get Info", systemImage: "info.circle") {
                inspectedSkill = inventory
            }
            Button("Score Analysis", systemImage: "chart.bar.doc.horizontal") {
                scoreAnalysisSkill = inventory
            }
            Button("Publish…", systemImage: "shippingbox.and.arrow.backward") {
                publicationTarget = inventory
            }
            .disabled(!model.isPrimaryPublishableSkill(inventory))
            Button(
                inventory.skillIconPath == nil ? "Add Icon…" : "Change Icon…",
                systemImage: "photo.badge.plus"
            ) {
                iconTarget = inventory
            }
            .disabled(!inventory.canEditIcon)
            Divider()
        }
        Button("Show in Finder", systemImage: "folder") {
            openSkillDirectories(openableURLs)
        }
        .disabled(openableURLs.isEmpty)
        Button("Open SKILL.md", systemImage: "doc.text") {
            openSkillFiles(skillFiles)
        }
        .disabled(skillFiles.isEmpty)
        Button("Open in Editor", systemImage: "chevron.left.forwardslash.chevron.right") {
            openSkillDirectoriesInEditor(openableURLs, skillFiles: skillFiles)
        }
        .disabled(openableURLs.isEmpty)
        Divider()
        let reviewableRows = contextRows.compactMap(\.inventory)
        Button(
            reviewableRows.count > 1
                ? "Review \(reviewableRows.count) with Codex…"
                : "Review with Codex…",
            systemImage: "cloud"
        ) {
            pendingConfirmation = .codexReview(reviewableRows)
        }
        .disabled(model.isRunning || model.isSkillEvaluating || reviewableRows.isEmpty)
        Divider()
        Button("Copy Path", systemImage: "doc.on.doc") {
            copyPaths(contextRows)
        }
        .disabled(paths.isEmpty)
        Button("Copy Improvement Instructions", systemImage: "wand.and.sparkles") {
            copyToImprove(contextRows)
        }
        .disabled(paths.isEmpty)
        Divider()
        let archivableRows = contextRows.compactMap(\.inventory).filter { $0.archiveRequest != nil }
        Button(
            archivableRows.count > 1 ? "Archive \(archivableRows.count) Items…" : "Archive…",
            systemImage: "archivebox"
        ) {
            pendingConfirmation = .archive(archivableRows)
        }
        .disabled(archivableRows.isEmpty || model.isRunning)
        Button(
            removableRows.count > 1 ? "Remove \(removableRows.count) Items…" : "Remove…",
            systemImage: "trash",
            role: .destructive
        ) {
            pendingConfirmation = .removal(removableRows)
        }
        .disabled(removableRows.isEmpty)
    }

    private func defaultSortOrder(for view: SkillTableView) -> [KeyPathComparator<SkillTableRow>] {
        switch view {
        case .summary:
            [KeyPathComparator(\SkillTableRow.invocations30d, order: .reverse)]
        case .review:
            [KeyPathComparator(\SkillTableRow.metagentScoreSortValue)]
        case .duplicates:
            [
                KeyPathComparator(\SkillTableRow.overlapSortValue),
                KeyPathComparator(\SkillTableRow.skillName),
            ]
        case .published:
            [KeyPathComparator(\SkillTableRow.skillName)]
        case .inventory:
            [KeyPathComparator(\SkillTableRow.skillName)]
        case .usage:
            [KeyPathComparator(\SkillTableRow.totalInvocations, order: .reverse)]
        }
    }

    private func rebuildRows() async {
        AppBrand.clearSkillIconCache()
        let projects = model.projects
        let usage = model.usageSnapshot
        let evaluations = model.skillEvaluations
        let pluginInventoryAvailable = model.isPluginInventoryAvailable
        let modelReleases = model.modelReleases
        let releaseAffirmations = model.releaseAffirmations
        let trackedModelProviders = model.trackedModelProviders
        let rows = await Task.detached(priority: .utility) {
            let inventoryRows = InventorySkillRow.rows(
                from: projects,
                usage: usage,
                evaluations: evaluations,
                modelReleases: modelReleases,
                releaseAffirmations: releaseAffirmations,
                trackedModelProviders: trackedModelProviders
            )
            let overlaps = MetagentCore.detectSkillOverlaps(inventoryRows.map { $0.skill.coreSkill })
            return SkillTableRow.rows(
                inventoryRows: inventoryRows,
                usageRows: UsageSkillRow.rows(
                    projects: projects,
                    summaries: usage.summaries,
                    isBackfillComplete: usage.isBackfillComplete
                ),
                projectRoots: projects.map(\.root),
                pluginInventoryAvailable: pluginInventoryAvailable,
                isBackfillComplete: usage.isBackfillComplete,
                overlaps: overlaps
            )
        }.value
        guard !Task.isCancelled else { return }
        cachedRows = rows
        selection.formIntersection(Set(cachedRows.map(\.id)))
    }
}

struct SkillsMenuSection: View {
    @ObservedObject var model: MetagentModel
    let selectedProjectRoot: String?
    let openMainWindow: () -> Void

    private var scopedProjects: [ProjectStatus] {
        guard let selectedProjectRoot else { return model.projects }
        return model.projects.filter { $0.root == selectedProjectRoot }
    }

    private var scopedSkillCount: Int {
        guard let selectedProjectRoot else { return model.logicalSkillCount }
        return logicalSkillCount(projects: model.projects, selectedProjectRoot: selectedProjectRoot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Skills")
                    .font(.headline)
                Spacer()
                Button(action: openMainWindow) {
                    Label("Window", systemImage: "macwindow")
                }
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                MetricView(title: "Skills", value: "\(scopedSkillCount)", symbol: "tablecells")
                StatusPathView(
                    title: "Locations",
                    value: selectedProjectRoot == nil ? model.locationSummaryText : (scopedProjects.first?.name ?? "No match"),
                    symbol: "folder.badge.gearshape"
                )
            }

            Button(action: openMainWindow) {
                Label("Open Skills", systemImage: "arrow.up.right.square")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)

            Spacer()
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
