import AppKit
import Foundation
import MetagentCore
import SwiftUI
import UniformTypeIdentifiers

enum UsageFilter: String, CaseIterable, Identifiable {
    case all
    case observed
    case neverObserved
    case dormant
    case insufficient

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All skills"
        case .observed: "Observed"
        case .neverObserved: "Never observed"
        case .dormant: "Dormant (90d)"
        case .insufficient: "Insufficient data"
        }
    }
    func includes(status: UsageSkillRow.Status, totalInvocations: Int) -> Bool {
        switch self {
        case .all: true
        case .observed: totalInvocations > 0
        case .neverObserved: status == .neverObserved
        case .dormant: status == .dormant
        case .insufficient: status == .insufficient
        }
    }
}

enum SkillScopeFilter: String, CaseIterable, Identifiable {
    case all
    case global
    case project

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All locations"
        case .global: "Global"
        case .project: "Project"
        }
    }

    func includes(_ row: SkillTableRow) -> Bool {
        switch self {
        case .all: true
        case .global: row.scope != "project"
        case .project: row.scope == "project"
        }
    }
}

/// The complete Skills table predicate, kept as one pass over the cached rows.
///
/// `InventorySection` is recomputed for selection, sorting, search, and model
/// updates. Chaining one `filter` per condition used to allocate as many as
/// eight intermediate row arrays on every recomputation. Resolving the root
/// scope once also avoids normalizing the same path for every candidate row.
struct SkillTableFilter {
    let selectedView: SkillTableView
    let selectedProjectRoot: String?
    let selectedProjectRootKey: String?
    let selectedProjectIsGlobal: Bool
    let hiddenSources: Set<SkillSourceCategory>
    let scope: SkillScopeFilter
    let usage: UsageFilter
    let searchQuery: String
    let pendingRemovalIDs: Set<String>
    let completedRemovalIDs: Set<String>

    init(
        selectedView: SkillTableView,
        selectedProjectRoot: String?,
        selectedProjectRootKey: String? = nil,
        globalRootKey: String? = nil,
        hiddenSources: Set<SkillSourceCategory>,
        scope: SkillScopeFilter,
        usage: UsageFilter,
        query: String,
        pendingRemovalIDs: Set<String>,
        completedRemovalIDs: Set<String>
    ) {
        let rootKey = selectedProjectRootKey
            ?? selectedProjectRoot.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        self.selectedView = selectedView
        self.selectedProjectRoot = selectedProjectRoot
        self.selectedProjectRootKey = rootKey
        self.selectedProjectIsGlobal = rootKey == (globalRootKey
            ?? URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path)
        self.hiddenSources = hiddenSources
        self.scope = scope
        self.usage = usage
        self.searchQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.pendingRemovalIDs = pendingRemovalIDs
        self.completedRemovalIDs = completedRemovalIDs
    }

    func apply(to candidates: [SkillTableRow]) -> [SkillTableRow] {
        candidates.filter(includes)
    }

    func includes(_ row: SkillTableRow) -> Bool {
        if let removalID = row.inventory?.removalRequest?.id,
           pendingRemovalIDs.contains(removalID) || completedRemovalIDs.contains(removalID) {
            return false
        }
        if selectedView != .usage, !row.isInstalled { return false }
        if selectedView == .duplicates, row.overlap == nil { return false }
        if selectedProjectRoot != nil {
            if selectedProjectIsGlobal {
                if row.scope == "project" { return false }
            } else if row.scope != "project" || row.projectRootKey != selectedProjectRootKey {
                return false
            }
        }
        if hiddenSources.contains(row.sourceCategory) { return false }
        if !scope.includes(row) { return false }
        if !usage.includes(status: row.usageStatus, totalInvocations: row.totalInvocations) { return false }
        if !searchQuery.isEmpty, !row.matches(searchQuery) { return false }
        return true
    }
}

/// The filtered, sorted rows for one `InventorySection.body` evaluation.
///
/// SwiftUI evaluates both branches of `ViewThatFits`, and the Skills screen
/// needs the same row set for its count, selection, and table. Keeping that
/// work in one value prevents each consumer from independently filtering and
/// sorting the full portfolio.
struct SkillTablePresentation {
    let rows: [SkillTableRow]
    let displayRows: [SkillTableRow]
    let usesHierarchy: Bool

    init(
        candidates: [SkillTableRow],
        filter: SkillTableFilter,
        grouping: SkillGrouping,
        sortOrder: [KeyPathComparator<SkillTableRow>]
    ) {
        let rows = filter.apply(to: candidates)
        self.rows = rows
        usesHierarchy = grouping != .none

        guard grouping != .none else {
            displayRows = rows.sorted(using: sortOrder)
            return
        }

        let groupedRows = Dictionary(grouping: rows, by: grouping.key(for:))
            .map { key, children in
                SkillTableRow.group(
                    id: "\(grouping.rawValue):\(key)",
                    title: children.first.map(grouping.title(for:)) ?? key,
                    children: children.sorted(using: sortOrder)
                )
            }
        displayRows = groupedRows.sorted { left, right in
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

    func resolvedRows(for ids: Set<SkillTableRow.ID>) -> [SkillTableRow] {
        guard !ids.isEmpty else { return [] }
        return displayRows.flatMap { row -> [SkillTableRow] in
            if ids.contains(row.id) {
                return row.children ?? [row]
            }
            return row.children?.filter { ids.contains($0.id) } ?? []
        }
    }
}

enum SkillGrouping: String, CaseIterable, Identifiable {
    case none
    case source
    case location
    case upstream

    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "No grouping"
        case .source: "Source"
        case .location: "Location"
        case .upstream: "Upstream"
        }
    }

    func title(for row: SkillTableRow) -> String {
        switch self {
        case .none: ""
        case .source: row.sourceText
        case .location: row.displaysGlobalLocation ? "Global" : row.projectName
        case .upstream: row.upstreamText == "—" ? "No upstream recorded" : row.upstreamText
        }
    }

    func key(for row: SkillTableRow) -> String {
        switch self {
        case .none: ""
        case .source: row.sourceCategory.rawValue
        case .location:
            row.displaysGlobalLocation
                ? "global"
                : "project:\(row.projectRootKey ?? row.displayLocationSortValue)"
        case .upstream: row.upstreamText
        }
    }
}

struct UsageSkillRow: Identifiable, Sendable {
    enum Status: Sendable { case active, dormant, neverObserved, insufficient }

    let id: String
    let skillName: String
    let canonicalPath: String?
    let scope: String
    let totalInvocations: Int
    let invocations7d: Int
    let invocations30d: Int
    let distinctThreads: Int
    let repeatInvocations: Int
    let lastUsedDate: Date?
    let lastUsedSortValue: TimeInterval
    let status: Status

    var scopeLabel: String { skillScopeLabel(scope) }

    static func placeholder(
        id: String,
        skillName: String,
        canonicalPath: String?,
        scope: String,
        status: Status
    ) -> UsageSkillRow {
        UsageSkillRow(
            id: id,
            skillName: skillName,
            canonicalPath: canonicalPath,
            scope: scope,
            totalInvocations: 0,
            invocations7d: 0,
            invocations30d: 0,
            distinctThreads: 0,
            repeatInvocations: 0,
            lastUsedDate: nil,
            lastUsedSortValue: -.infinity,
            status: status
        )
    }

    static func inventoryPlaceholder(
        id: String,
        skillName: String,
        canonicalPath: String?,
        folderKind: String,
        projectRoot: String,
        isBackfillComplete: Bool
    ) -> UsageSkillRow {
        placeholder(
            id: id,
            skillName: skillName,
            canonicalPath: canonicalPath,
            scope: folderKind == "system"
                ? "system"
                : (projectRoot == NSHomeDirectory() ? "global" : "project"),
            status: isBackfillComplete ? .neverObserved : .insufficient
        )
    }

    static func rows(
        projects: [ProjectStatus],
        summaries: [SkillUsageSummary],
        isBackfillComplete: Bool
    ) -> [UsageSkillRow] {
        var canonicalizer = SkillPathCanonicalizer()
        return rows(
            projects: projects,
            summaries: summaries,
            isBackfillComplete: isBackfillComplete,
            canonicalizer: &canonicalizer
        )
    }

    static func rows(
        projects: [ProjectStatus],
        summaries: [SkillUsageSummary],
        isBackfillComplete: Bool,
        canonicalizer: inout SkillPathCanonicalizer
    ) -> [UsageSkillRow] {
        var rows = summaries.map { summary in
            from(
                summary: summary,
                canonicalPath: canonicalizer.canonicalPath(summary.canonicalPath),
                isBackfillComplete: isBackfillComplete
            )
        }
        let summaryPaths = Set(rows.compactMap(\.canonicalPath))
        let summaryPluginKeys = Set(summaries.compactMap {
            pluginUsageMatchKey(id: $0.id, canonicalPath: $0.canonicalPath)
        })

        var inventoryPaths = Set<String>()
        for (project, skill) in projects.flatMap({ project in
            project.skills.map { (project, $0) }
        }) {
            let directory = canonicalizer.canonicalPath(skill.path)
            let pluginAlreadyRepresented = pluginUsageMatchKey(skill).map(summaryPluginKeys.contains) ?? false
            guard !summaryPaths.contains(directory),
                  !pluginAlreadyRepresented,
                  inventoryPaths.insert(directory).inserted
            else {
                continue
            }
            rows.append(UsageSkillRow.inventoryPlaceholder(
                id: "inventory:\(project.root):\(skill.path)",
                skillName: skill.name,
                canonicalPath: directory,
                folderKind: skill.folderKind,
                projectRoot: project.root,
                isBackfillComplete: isBackfillComplete
            ))
        }
        return rows
    }

    private static func from(
        summary: SkillUsageSummary,
        canonicalPath: String?,
        isBackfillComplete: Bool
    ) -> UsageSkillRow {
        let lastDate = MetagentCore.parseSkillUsageTimestamp(summary.lastUsedAt)
        let isDormant = lastDate.map { $0 < Date().addingTimeInterval(-90 * 24 * 60 * 60) } ?? false
        return UsageSkillRow(
            id: summary.id,
            skillName: summary.skillName,
            canonicalPath: canonicalPath,
            scope: summary.scope,
            totalInvocations: summary.totalInvocations,
            invocations7d: summary.invocations7d,
            invocations30d: summary.invocations30d,
            distinctThreads: summary.distinctThreads,
            repeatInvocations: summary.repeatInvocations,
            lastUsedDate: lastDate,
            lastUsedSortValue: lastDate?.timeIntervalSinceReferenceDate ?? -.infinity,
            status: isDormant ? .dormant : .active
        )
    }

}

enum InventoryConfirmation: Identifiable {
    case removal([InventorySkillRow])
    case archive([InventorySkillRow])
    case codexReview([InventorySkillRow])

    var id: String {
        switch self {
        case let .removal(rows):
            "removal:" + rows.map(\.id).sorted().joined(separator: ",")
        case let .archive(rows):
            "archive:" + rows.map(\.id).sorted().joined(separator: ",")
        case let .codexReview(rows):
            "codex-review:" + rows.map(\.id).sorted().joined(separator: ",")
        }
    }
}

enum SkillTableView: String, CaseIterable, Identifiable {
    case summary
    case review
    case duplicates
    case published
    case inventory
    case usage

    var id: String { rawValue }
    var title: String {
        switch self {
        case .duplicates: "Duplicates"
        case .published: "Published"
        default: rawValue.capitalized
        }
    }
}

/// A segmented `Picker` wrapped in glass drew a squared selection inside the
/// capsule and resized as labels changed. This mirrors the main navigation
/// instead: one glass track, an accent capsule for the active view.
struct SkillViewSelector: View {
    @Binding var selection: SkillTableView

    var body: some View {
        HStack(spacing: 3) {
            ForEach(SkillTableView.allCases) { view in
                let isSelected = selection == view
                Button {
                    selection = view
                } label: {
                    Text(view.title)
                        .font(.callout.weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(isSelected ? Color.accentColor : Color.clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("metagent.skills.view.\(view.rawValue)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(4)
        .glassEffect(.regular, in: Capsule())
    }
}

enum SkillSourceCategory: String, CaseIterable, Identifiable {
    case plugin
    case skillsCLI
    case dotagentsLocal
    case dotagentsManaged
    case externalCLI
    case codexSystem
    case codexInstalled
    case claude
    case local
    case notInstalled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plugin: "Codex plugins"
        case .skillsCLI: "Skills CLI"
        case .dotagentsLocal: "dotagents · external path"
        case .dotagentsManaged: "dotagents · package"
        case .externalCLI: "External CLI"
        case .codexSystem: "Codex system"
        case .codexInstalled: "Codex installed"
        case .claude: "Claude installed"
        case .local: "Local or unknown"
        case .notInstalled: "Not installed"
        }
    }

    var explanation: String {
        switch self {
        case .dotagentsLocal:
            "dotagents manages this installation from a distinct local source path. Self-referential orphan-adoption records are classified as local instead."
        case .dotagentsManaged:
            "The skill is declared as a package managed by dotagents rather than as a local path."
        case .skillsCLI:
            "Skills CLI owns this installation because its lockfile records the skill and upstream package."
        case .externalCLI:
            "A known third-party CLI owns this versioned bundle. Metagent matched a specific bundle signature rather than inferring ownership from Git or folder location."
        case .local:
            "No installer, lockfile, or independent upstream source is recorded. The skill may be locally authored or imported; ordinary Git tracking does not establish provenance."
        case .notInstalled:
            "Historical Codex usage matched this skill, but no current installed bundle matches its recorded path or identity."
        case .codexInstalled:
            "The canonical skill bundle is installed in Codex. It may also be projected into another agent."
        case .claude:
            "The canonical skill bundle is installed in Claude. It may also be projected into another agent."
        default:
            title
        }
    }

    static func resolve(
        inventory: InventorySkillRow?,
        usage: UsageSkillRow,
        pluginInventoryAvailable: Bool
    ) -> SkillSourceCategory {
        guard let inventory else {
            return usage.scope == "plugin" ? .plugin : .notInstalled
        }
        switch inventory.skill.manager {
        case "codex-plugin": return .plugin
        case "skills-cli": return .skillsCLI
        case "dotagents":
            return inventory.skill.originKind == "dotagents-managed" ? .dotagentsManaged : .dotagentsLocal
        case "external-cli": return .externalCLI
        case "codex":
            return inventory.skill.authority == "codex-system" ? .codexSystem : .codexInstalled
        case "claude": return .claude
        default: return .local
        }
    }
}

struct SkillOverlapMembership: Sendable {
    let groupID: String
    let kind: SkillOverlapKind
    let similarity: Double
    let suggestedRemoval: Bool
    var contentFingerprint: String? = nil

    var title: String {
        switch kind {
        case .pluginReplacement: suggestedRemoval ? "Plugin replaces this" : "Plugin replacement"
        case .exactDuplicate: "Exact duplicate"
        case .globalProject: "Global + project"
        case .sameName: "Same name"
        }
    }

    var sortValue: Int {
        switch kind {
        case .pluginReplacement: 0
        case .exactDuplicate: 1
        case .globalProject: 2
        case .sameName: 3
        }
    }

    var help: String {
        let percent = (similarity * 100).rounded().formatted(.number.precision(.fractionLength(0)))
        switch kind {
        case .pluginReplacement:
            return suggestedRemoval
                ? "This global standalone bundle closely overlaps an installed plugin skill (\(percent)% content similarity). Removing the standalone copy is recommended; the plugin remains available."
                : "An installed plugin and standalone bundle closely overlap (\(percent)% content similarity). Compare the copies before removing anything."
        case .exactDuplicate:
            return "These bundles have identical file contents and executable permissions. Keep the copy whose scope and lifecycle owner you actually need."
        case .globalProject:
            return "The same skill name exists globally and in a project. This may be intentional so collaborators receive the project copy."
        case .sameName:
            return "Distinct installed bundles share this skill name, but their contents are not similar enough for Metagent to call one a replacement."
        }
    }
}

struct SkillTableRow: Identifiable, Sendable {
    let id: String
    let inventory: InventorySkillRow?
    let usage: UsageSkillRow
    let historicalProjectRoot: String?
    let pluginInventoryAvailable: Bool
    let canonicalPathKey: String?
    let projectRootKey: String?
    var overlap: SkillOverlapMembership? = nil
    var groupTitle: String? = nil
    var children: [SkillTableRow]? = nil

    init(
        inventory: InventorySkillRow?,
        usage: UsageSkillRow,
        historicalProjectRoot: String?,
        pluginInventoryAvailable: Bool,
        canonicalPathKey: String? = nil,
        projectRootKey: String? = nil,
        overlap: SkillOverlapMembership? = nil,
        groupTitle: String? = nil,
        children: [SkillTableRow]? = nil,
        id: String? = nil
    ) {
        self.inventory = inventory
        self.usage = usage
        self.historicalProjectRoot = historicalProjectRoot
        self.pluginInventoryAvailable = pluginInventoryAvailable
        self.canonicalPathKey = canonicalPathKey
            ?? inventory?.canonicalPathKey
            ?? usage.canonicalPath.map(standardizedDirectoryPath)
        self.projectRootKey = projectRootKey
            ?? inventory?.projectRootKey
            ?? historicalProjectRoot.map(standardizedDirectoryPath)
        self.overlap = overlap
        self.groupTitle = groupTitle
        self.children = children
        self.id = id
            ?? (groupTitle == nil ? (inventory?.id ?? "historical:\(usage.id)") : usage.id)
    }

    var isGroup: Bool { children != nil }
    var skillName: String { inventory?.skillName ?? usage.skillName }
    var projectName: String {
        inventory?.projectName
            ?? historicalProjectRoot.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? (usage.scope == "plugin" ? "Codex plugins" : "Not installed")
    }
    var projectRoot: String? { inventory?.projectRoot ?? historicalProjectRoot }
    var skillPath: String { inventory?.skillPath ?? usage.canonicalPath ?? "" }
    var canonicalPath: String? { inventory?.canonicalPath ?? usage.canonicalPath }
    var locationLabel: String { inventory?.locationLabel ?? "Historical" }
    var locationHelp: String {
        if let inventory { return inventory.locationHelp }
        if usage.scope == "plugin" {
            return pluginInventoryAvailable
                ? "Previously observed in Codex; no active plugin inventory match was found."
                : "Previously observed in Codex; plugin inventory is unavailable, so the current location cannot be confirmed."
        }
        return "Previously observed; no installed bundle matched this path."
    }
    var sourceCategory: SkillSourceCategory {
        SkillSourceCategory.resolve(
            inventory: inventory,
            usage: usage,
            pluginInventoryAvailable: pluginInventoryAvailable
        )
    }
    var sourceText: String { sourceCategory.title }
    var sourceHelp: String {
        let detail: String
        if inventory == nil, usage.scope == "plugin" {
            detail = pluginInventoryAvailable
                ? "No active plugin inventory match was found; the plugin may be disabled or removed."
                : "Codex plugin inventory is unavailable; current installation state is unknown."
        } else {
            detail = inventory?.originHelp ?? "Historical usage record\nScope: \(usage.scopeLabel)"
        }
        return "\(sourceCategory.explanation)\n\(detail)"
    }
    var scope: String { inventory?.skill.scope ?? usage.scope }
    var scopeLabel: String { skillScopeLabel(scope) }
    var displayLocationText: String {
        scope == "project" ? projectName : ""
    }
    var displayLocationSortValue: String {
        scope == "project" ? projectName : "Global"
    }
    var displayLocationHelp: String {
        scope == "project"
            ? (projectRoot ?? projectName)
            : "Available globally · \(scopeLabel)"
    }
    var displaysGlobalLocation: Bool { scope != "project" }
    var metagentScoreSortValue: Int { inventory?.metagentStaticScore ?? -1 }
    var metagentScoreText: String { inventory?.metagentScoreText ?? "—" }
    var metagentScoreTint: Color? { inventory?.metagentScoreTint }
    var metagentScoreHelp: String { inventory?.metagentScoreHelp ?? "Not available for an uninstalled skill." }
    var portfolioScoreSortValue: Int { inventory?.utilityScore ?? -1 }
    var portfolioScoreText: String { inventory?.portfolioScoreText ?? "—" }
    var portfolioScoreTint: Color? { inventory?.portfolioScoreTint }
    var portfolioScoreHelp: String { inventory?.portfolioScoreHelp ?? "Not available for an uninstalled skill." }
    var pluginEvalSortValue: Int { inventory?.pluginEvalSortValue ?? -1 }
    var pluginEvalText: String { inventory?.pluginEvalText ?? "—" }
    var pluginEvalTint: Color? { inventory?.pluginEvalTint }
    var pluginEvalHelp: String { inventory?.pluginEvalHelp ?? "Not available for an uninstalled skill." }
    var codexReviewSortValue: Int { inventory?.codexReviewSortValue ?? -1 }
    var codexReviewText: String { inventory?.codexReviewText ?? "—" }
    var codexReviewTint: Color? { inventory?.codexReviewTint }
    var codexReviewHelp: String { inventory?.codexReviewHelp ?? "Not available for an uninstalled skill." }
    var tokenEstimate: Int { inventory?.tokenEstimate ?? -1 }
    var descriptionText: String { inventory?.descriptionText ?? "—" }
    var descriptionHelp: String { inventory?.descriptionHelp ?? "Not available for an uninstalled skill." }
    var upstreamText: String { inventory?.upstreamText ?? "—" }
    var upstreamHelp: String { inventory?.upstreamHelp ?? "No installed source metadata is available." }
    var versionText: String { inventory?.versionText ?? "—" }
    var versionHelp: String { inventory?.versionHelp ?? "No installed version metadata is available." }
    var updatedDate: Date? { inventory?.updatedDate }
    var updatedSortValue: Int { inventory?.weeksOld ?? Int.max }
    var updatedText: String { inventory?.updatedText ?? "—" }
    var updatedDateText: String { inventory?.updatedDateText ?? "Unknown" }
    var updatedHelp: String { inventory?.updatedHelp ?? "No installed update metadata is available." }
    var modelReviewTargets: [ModelReviewTarget] { inventory?.modelReviewTargets ?? [] }
    var modelReviewGaps: [ModelReviewTarget] { modelReviewTargets.filter(\.needsReview) }
    var modelReviewUnknownTargets: [ModelReviewTarget] { modelReviewTargets.filter(\.isUnknown) }
    var modelReviewSortValue: Int {
        modelReviewGaps.count * 10 + (modelReviewUnknownTargets.isEmpty ? 0 : 1)
    }
    var modelReviewText: String {
        if !modelReviewGaps.isEmpty {
            return modelReviewGaps.map(\.providerName).joined(separator: ", ")
        }
        return modelReviewUnknownTargets.isEmpty ? "—" : "Unknown"
    }
    var modelReviewHelp: String {
        guard !modelReviewTargets.isEmpty else {
            return "No tracked model-release target is available."
        }
        let targets = modelReviewTargets.map { target in
            let release = target.releaseDate.formatted(date: .abbreviated, time: .omitted)
            guard let baseline = target.baselineDate else {
                return "\(target.providerName): \(target.modelLabel) released \(release). This skill has no reliable change date, so review status is unknown."
            }
            let changed = baseline.formatted(date: .abbreviated, time: .omitted)
            return target.needsReview
                ? "\(target.providerName): \(target.modelLabel) released \(release); skill last changed or reviewed \(changed). Review suggested."
                : "\(target.providerName): current through \(target.modelLabel), released \(release); skill changed or reviewed \(changed)."
        }.joined(separator: "\n")
        guard let fetchedAt = inventory?.modelReleaseCatalogFetchedAt else { return targets }
        return targets + "\nModel catalog checked \(fetchedAt.formatted(date: .abbreviated, time: .shortened))."
    }
    var referenceFileCount: Int { inventory?.referenceFileCount ?? -1 }
    var scriptFileCount: Int { inventory?.scriptFileCount ?? -1 }
    var skillIconPath: String? { inventory?.skillIconPath }
    var totalInvocations: Int { usage.totalInvocations }
    var invocations7d: Int { usage.invocations7d }
    var invocations30d: Int { usage.invocations30d }
    var distinctThreads: Int { usage.distinctThreads }
    var readsPerThread: Double {
        guard distinctThreads > 0 else { return 0 }
        return Double(totalInvocations) / Double(distinctThreads)
    }
    var readsPerThreadText: String {
        guard distinctThreads > 0 else { return "—" }
        return readsPerThread.formatted(.number.precision(.fractionLength(1)))
    }
    var repeatInvocations: Int { usage.repeatInvocations }
    var lastUsedDate: Date? { usage.lastUsedDate }
    var lastUsedSortValue: TimeInterval { usage.lastUsedSortValue }
    var lastUsedText: String {
        lastUsedDate?.formatted(.relative(presentation: .named, unitsStyle: .wide)) ?? "Never"
    }
    var lastUsedHelp: String {
        lastUsedDate?.formatted(date: .abbreviated, time: .shortened) ?? "No observed usage"
    }
    var usageStatus: UsageSkillRow.Status { usage.status }
    var isInstalled: Bool { inventory != nil }
    var installationText: String {
        if isInstalled { return "Installed" }
        if usage.scope == "plugin" { return "Unknown" }
        return "Not installed"
    }
    var installationHelp: String {
        switch installationText {
        case "Installed": "A matching skill bundle is currently installed."
        case "Unknown": pluginInventoryAvailable
            ? "No active plugin inventory match was found; the plugin may be disabled or removed."
            : "Codex plugin inventory is unavailable, so installation state cannot be confirmed."
        default: "Historical usage with no matching installed bundle."
        }
    }
    var overlapSortValue: Int { overlap?.sortValue ?? Int.max }
    var overlapText: String { overlap?.title ?? "—" }
    var overlapHelp: String { overlap?.help ?? "No duplicate or overlapping installation detected." }

    func matches(_ query: String) -> Bool {
        [
            skillName,
            projectName,
            locationLabel,
            sourceText,
            scopeLabel,
            descriptionText,
            upstreamText,
            versionText,
            metagentScoreText,
            pluginEvalText,
            codexReviewText,
        ]
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }

    static func rows(
        inventoryRows: [InventorySkillRow],
        usageRows: [UsageSkillRow],
        projectRoots: [String],
        pluginInventoryAvailable: Bool,
        isBackfillComplete: Bool,
        overlaps: [SkillOverlapGroup]
    ) -> [SkillTableRow] {
        var canonicalizer = SkillPathCanonicalizer()
        return rows(
            inventoryRows: inventoryRows,
            usageRows: usageRows,
            projectRoots: projectRoots,
            pluginInventoryAvailable: pluginInventoryAvailable,
            isBackfillComplete: isBackfillComplete,
            overlaps: overlaps,
            canonicalizer: &canonicalizer
        )
    }

    static func rows(
        inventoryRows: [InventorySkillRow],
        usageRows: [UsageSkillRow],
        projectRoots: [String],
        pluginInventoryAvailable: Bool,
        isBackfillComplete: Bool,
        overlaps: [SkillOverlapGroup],
        canonicalizer: inout SkillPathCanonicalizer
    ) -> [SkillTableRow] {
        let canonicalProjectRoots = projectRoots.map { canonicalizer.canonicalPath($0) }
        let usageByPath = Dictionary(grouping: usageRows.compactMap { row -> (String, UsageSkillRow)? in
            guard let path = row.canonicalPath else { return nil }
            return (canonicalizer.canonicalPath(path), row)
        }, by: \.0).compactMapValues { $0.first?.1 }
        let usageByPlugin = Dictionary(grouping: usageRows.compactMap { row in
            pluginUsageMatchKey(id: row.id, canonicalPath: row.canonicalPath).map { ($0, row) }
        }, by: \.0).compactMapValues { $0.first?.1 }
        var matchedUsageIDs = Set<String>()
        let overlapsByPath = Dictionary(
            overlaps.flatMap { group in
                group.members.map { member in
                    (
                        canonicalizer.canonicalPath(member.canonicalPath),
                        SkillOverlapMembership(
                            groupID: group.id,
                            kind: group.kind,
                            similarity: group.similarity,
                            suggestedRemoval: member.suggestedRemoval,
                            contentFingerprint: member.contentFingerprint
                        )
                    )
                }
            },
            uniquingKeysWith: { first, _ in first }
        )

        var rows = inventoryRows.map { inventory -> SkillTableRow in
            let canonicalPath = inventory.canonicalPathKey
            let matched = usageByPath[canonicalPath]
                ?? pluginUsageMatchKey(inventory.skill).flatMap { usageByPlugin[$0] }
            if let matched { matchedUsageIDs.insert(matched.id) }
            let usage = matched ?? UsageSkillRow.inventoryPlaceholder(
                id: "inventory:\(inventory.id)",
                skillName: inventory.skillName,
                canonicalPath: inventory.canonicalPath,
                folderKind: inventory.skill.folderKind,
                projectRoot: inventory.projectRoot,
                isBackfillComplete: isBackfillComplete
            )
            return SkillTableRow(
                inventory: inventory,
                usage: usage,
                historicalProjectRoot: nil,
                pluginInventoryAvailable: pluginInventoryAvailable,
                canonicalPathKey: canonicalPath,
                projectRootKey: inventory.projectRootKey,
                overlap: inventory.skill.representation == "projection"
                    ? nil
                    : overlapsByPath[canonicalPath]
            )
        }

        rows.append(contentsOf: usageRows
            .filter { !matchedUsageIDs.contains($0.id) }
            .map { usage in
                let historicalProjectRoot = inferredProjectRoot(
                    forCanonicalPath: canonicalizer.canonicalPath(usage.canonicalPath),
                    canonicalRoots: canonicalProjectRoots
                )
                return SkillTableRow(
                    inventory: nil,
                    usage: usage,
                    historicalProjectRoot: historicalProjectRoot,
                    pluginInventoryAvailable: pluginInventoryAvailable,
                    canonicalPathKey: canonicalizer.canonicalPath(usage.canonicalPath),
                    projectRootKey: historicalProjectRoot
                )
            })
        return rows
    }

    static func group(id: String, title: String, children: [SkillTableRow]) -> SkillTableRow {
        SkillTableRow(
            inventory: nil,
            usage: UsageSkillRow.placeholder(
                id: "group:\(id)",
                skillName: title,
                canonicalPath: nil,
                scope: "group",
                status: .insufficient
            ),
            historicalProjectRoot: nil,
            pluginInventoryAvailable: true,
            groupTitle: title,
            children: children
        )
    }

    private static func inferredProjectRoot(
        forCanonicalPath canonicalPath: String?,
        canonicalRoots: [String]
    ) -> String? {
        guard let canonicalPath else { return nil }
        return canonicalRoots
            .filter { canonicalPath == $0 || canonicalPath.hasPrefix($0 + "/") }
            .max { $0.count < $1.count }
    }
}

struct DuplicateReviewGroup: Identifiable {
    let id: String
    let kind: SkillOverlapKind
    let similarity: Double
    let rows: [SkillTableRow]

    var recommendationRevision: [String] {
        [id, recommendationTitle] + rows.flatMap {
            [$0.id, $0.overlap?.contentFingerprint ?? "unknown", String($0.overlap?.suggestedRemoval ?? false), String($0.inventory?.removalRequest != nil)]
        }
    }

    var skillName: String { rows.first?.skillName ?? "Unnamed skill" }
    var suggestedRemovalRows: [SkillTableRow] {
        rows.filter { $0.overlap?.suggestedRemoval == true && $0.inventory?.removalRequest != nil }
    }
    var recommendedRemovalRows: [SkillTableRow] {
        suggestedRemovalRows
    }
    var similarityText: String {
        similarity.formatted(.percent.precision(.fractionLength(0)))
    }
    var similarityHelp: String {
        "Word-set overlap between the closest pair of SKILL.md files. Metagent normalizes provider-specific skill paths and whitespace, lowercases the text, then divides shared unique words by all unique words across the pair. It is a vocabulary comparison, not an AI quality judgment."
    }
    var recommendationTitle: String {
        switch kind {
        case .pluginReplacement:
            suggestedRemovalRows.isEmpty
                ? "Compare the plugin and standalone copies"
                : "Keep the plugin; remove the standalone copy"
        case .exactDuplicate:
            "Choose one canonical copy"
        case .globalProject:
            recommendedRemovalRows.isEmpty
                ? "Keep global; project copies are optional"
                : "Keep global; remove the identical project copy"
        case .sameName:
            "Compare before removing anything"
        }
    }
    var recommendationDetail: String {
        switch kind {
        case .pluginReplacement:
            suggestedRemovalRows.isEmpty
                ? "The contents overlap, but Metagent cannot safely choose a removable standalone copy."
                : "The plugin owns updates and remains available. The selected standalone bundle is redundant."
        case .exactDuplicate:
            "The contents match. Keep the copy whose location and lifecycle owner you want."
        case .globalProject:
            recommendedRemovalRows.isEmpty
                ? "Review each project copy before removal because same-name skills can differ. Keep a project copy when the project must share it with collaborators."
                : "The project copy has identical instructions. Metagent preselects it for removal; keep it instead when the project must share the skill with collaborators. Nothing is removed until you approve it."
        case .sameName:
            "These bundles share a name but differ enough that one is not a safe replacement for the other."
        }
    }
    var symbol: String {
        switch kind {
        case .pluginReplacement: "powerplug.fill"
        case .exactDuplicate: "square.on.square"
        case .globalProject: "folder.badge.plus"
        case .sameName: "questionmark.diamond"
        }
    }
}

struct InventorySkillRow: Identifiable, Sendable {
    let project: ProjectStatus
    let skill: SkillStatus
    let variants: [SkillStatus]
    let metagentScore: MetagentSkillScore
    let pluginEval: PluginEvalSkillAssessment?
    let codexReview: CodexSkillReview?
    let pluginEvalIsStale: Bool
    let codexReviewIsStale: Bool
    var modelReviewTargets: [ModelReviewTarget] = []
    var modelReleaseCatalogFetchedAt: Date? = nil
    var advisories: [SkillAdvisory] = []
    let canonicalPathKey: String
    let projectRootKey: String
    private let canonicalIdentityKey: String

    init(
        project: ProjectStatus,
        skill: SkillStatus,
        variants: [SkillStatus],
        metagentScore: MetagentSkillScore,
        pluginEval: PluginEvalSkillAssessment?,
        codexReview: CodexSkillReview?,
        pluginEvalIsStale: Bool,
        codexReviewIsStale: Bool,
        modelReviewTargets: [ModelReviewTarget] = [],
        modelReleaseCatalogFetchedAt: Date? = nil,
        advisories: [SkillAdvisory] = [],
        canonicalPathKey: String? = nil,
        projectRootKey: String? = nil,
        canonicalIdentityKey: String? = nil
    ) {
        let resolvedCanonicalPath = canonicalPathKey ?? standardizedDirectoryPath(skill.canonicalPath)
        self.project = project
        self.skill = skill
        self.variants = variants
        self.metagentScore = metagentScore
        self.pluginEval = pluginEval
        self.codexReview = codexReview
        self.pluginEvalIsStale = pluginEvalIsStale
        self.codexReviewIsStale = codexReviewIsStale
        self.modelReviewTargets = modelReviewTargets
        self.modelReleaseCatalogFetchedAt = modelReleaseCatalogFetchedAt
        self.advisories = advisories
        self.canonicalPathKey = resolvedCanonicalPath
        self.projectRootKey = projectRootKey ?? standardizedDirectoryPath(project.root)
        self.canonicalIdentityKey = canonicalIdentityKey
            ?? Self.canonicalSkillIdentity(skill, canonicalPathKey: resolvedCanonicalPath)
    }

    static func rows(
        from projects: [ProjectStatus],
        usage: SkillUsageSnapshot,
        evaluations: SkillEvaluationSnapshot,
        modelReleases: ModelReleaseSnapshot = .empty,
        releaseAffirmations: [String: Date] = [:],
        trackedModelProviders: [String] = MetagentCore.defaultTrackedModelProviders
    ) -> [InventorySkillRow] {
        var canonicalizer = SkillPathCanonicalizer()
        return rows(
            from: projects,
            usage: usage,
            evaluations: evaluations,
            modelReleases: modelReleases,
            releaseAffirmations: releaseAffirmations,
            trackedModelProviders: trackedModelProviders,
            canonicalizer: &canonicalizer
        )
    }

    static func rows(
        from projects: [ProjectStatus],
        usage: SkillUsageSnapshot,
        evaluations: SkillEvaluationSnapshot,
        modelReleases: ModelReleaseSnapshot = .empty,
        releaseAffirmations: [String: Date] = [:],
        trackedModelProviders: [String] = MetagentCore.defaultTrackedModelProviders,
        canonicalizer: inout SkillPathCanonicalizer
    ) -> [InventorySkillRow] {
        let usageByPath = Dictionary(grouping: usage.summaries.compactMap { summary -> (String, SkillUsageSummary)? in
            guard let canonicalPath = summary.canonicalPath else { return nil }
            return (canonicalizer.canonicalPath(canonicalPath), summary)
        }, by: \.0).compactMapValues { values in
            values.map(\.1).max { $0.totalInvocations < $1.totalInvocations }
        }
        let usageByIdentity = Dictionary(grouping: usage.summaries, by: {
            "\($0.skillName):\($0.scope)"
        }).compactMapValues { values in
            values.max { $0.totalInvocations < $1.totalInvocations }
        }
        let pluginUsageByKey = Dictionary(grouping: usage.summaries.compactMap { summary in
            pluginUsageMatchKey(id: summary.id, canonicalPath: summary.canonicalPath).map { ($0, summary) }
        }, by: \.0).compactMapValues { values in
            values.map(\.1).max { $0.totalInvocations < $1.totalInvocations }
        }
        let evaluationsByPath = Dictionary(evaluations.records.values.map {
            (canonicalizer.canonicalPath($0.canonicalPath), $0)
        }, uniquingKeysWith: { first, _ in first })
        let portfolioVariantsByName = Dictionary(grouping: projects.flatMap(\.skills), by: \.name)
        return projects.flatMap { project in
            let projectRootKey = canonicalizer.canonicalPath(project.root)
            let variantsByIdentity = Dictionary(grouping: project.skills) { skill in
                let pathKey = canonicalizer.canonicalPath(skill.canonicalPath)
                return canonicalSkillIdentity(skill, canonicalPathKey: pathKey, canonicalizer: &canonicalizer)
            }
            return variantsByIdentity.values.map { variants in
                let sortedVariants = variants.sorted(by: canonicalSkillOrder)
                let skill = sortedVariants[0]
                let canonicalPath = canonicalizer.canonicalPath(skill.canonicalPath)
                let identityKey = canonicalSkillIdentity(
                    skill,
                    canonicalPathKey: canonicalPath,
                    canonicalizer: &canonicalizer
                )
                let matchedUsage = usageByPath[canonicalPath]
                    ?? pluginUsageMatchKey(skill).flatMap { pluginUsageByKey[$0] }
                    ?? (skill.canonicalPath.isEmpty ? usageByIdentity["\(skill.name):\(skill.scope)"] : nil)
                let modelReviewTargets = MetagentCore.modelReviewTargets(
                    skillUpdatedAt: skill.updatedAt.flatMap(parseISO8601Date),
                    affirmedAt: releaseAffirmations[canonicalPath],
                    releases: modelReleases.releases,
                    trackedProviders: trackedModelProviders
                )
                return InventorySkillRow(
                    project: project,
                    skill: skill,
                    variants: sortedVariants,
                    metagentScore: MetagentCore.scoreSkill(
                        skill.coreSkill,
                        variants: (portfolioVariantsByName[skill.name] ?? sortedVariants).map(\.coreSkill),
                        usage: matchedUsage,
                        usageCoverageComplete: usage.isBackfillComplete
                    ),
                    pluginEval: evaluationsByPath[canonicalPath]?.pluginEval,
                    codexReview: evaluationsByPath[canonicalPath]?.codexReview,
                    pluginEvalIsStale: evaluations.stalePluginEvalPaths.contains(canonicalPath),
                    codexReviewIsStale: evaluations.staleCodexReviewPaths.contains(canonicalPath),
                    modelReviewTargets: modelReviewTargets,
                    modelReleaseCatalogFetchedAt: modelReleases.fetchedAt,
                    advisories: MetagentCore.modelReleaseAdvisory(targets: modelReviewTargets).map { [$0] } ?? [],
                    canonicalPathKey: canonicalPath,
                    projectRootKey: projectRootKey,
                    canonicalIdentityKey: identityKey
                )
            }
        }
    }

    private static func canonicalSkillOrder(_ left: SkillStatus, _ right: SkillStatus) -> Bool {
        let leftRepresentationPriority = left.representation == "canonical" ? 0 : 1
        let rightRepresentationPriority = right.representation == "canonical" ? 0 : 1
        if leftRepresentationPriority != rightRepresentationPriority {
            return leftRepresentationPriority < rightRepresentationPriority
        }
        let priority = ["agents": 0, "codex": 1, "claude": 2]
        let leftPriority = priority[left.location, default: 3]
        let rightPriority = priority[right.location, default: 3]
        if leftPriority != rightPriority {
            return leftPriority < rightPriority
        }
        return left.path < right.path
    }

    private static func canonicalSkillIdentity(
        _ skill: SkillStatus,
        canonicalPathKey: String
    ) -> String {
        if let pluginKey = pluginUsageMatchKey(skill) {
            return "plugin:\(pluginKey)"
        }
        if !skill.canonicalPath.isEmpty {
            return "path:\(canonicalPathKey)"
        }
        return "installed:\(skill.location):\(standardizedDirectoryPath(skill.path))"
    }

    private static func canonicalSkillIdentity(
        _ skill: SkillStatus,
        canonicalPathKey: String,
        canonicalizer: inout SkillPathCanonicalizer
    ) -> String {
        if let pluginKey = pluginUsageMatchKey(skill) {
            return "plugin:\(pluginKey)"
        }
        if !skill.canonicalPath.isEmpty {
            return "path:\(canonicalPathKey)"
        }
        return "installed:\(skill.location):\(canonicalizer.canonicalPath(skill.path))"
    }

    var id: String {
        "\(project.root):\(canonicalIdentityKey)"
    }

    var skillName: String { skill.name }
    var projectName: String { project.name }
    var projectRoot: String { project.root }
    var skillPath: String { skill.path }
    var canonicalPath: String { skill.canonicalPath }
    var locationLabel: String {
        variants
            .map(\.locationLabel)
            .uniqued()
            .joined(separator: " + ")
    }
    var locationHelp: String {
        variants.map { "\($0.locationLabel): \(displayUserPath($0.path))" }.joined(separator: "\n")
    }
    var originText: String { skill.tableOriginText }
    var originHelp: String {
        [
            skill.tableOriginText,
            "Manager: \(skill.manager)",
            "Authority: \(skill.authority)",
            skill.source.map { "Source: \($0)" },
            skill.sourceType.map { "Evidence: \($0)" },
            skill.sourceURL
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
    }
    var descriptionText: String { skill.description ?? "—" }
    var descriptionHelp: String { skill.description ?? "No description in SKILL.md frontmatter." }
    var upstreamText: String {
        githubRepositoryName(url: skill.sourceURL)
            ?? githubRepositoryName(source: skill.source)
            ?? (skill.manager == "codex-plugin" ? skill.authority : nil)
            ?? "—"
    }
    var upstreamHelp: String {
        [
            upstreamText == "—" ? "No upstream repository is recorded." : "Upstream: \(upstreamText)",
            skill.sourceURL,
            skill.source.map { "Recorded source: \($0)" },
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
    }
    var versionText: String { skill.ref ?? "—" }
    var versionHelp: String {
        skill.ref.map { "Recorded version or Git ref: \($0)" }
            ?? "No version or Git ref is recorded for this source."
    }
    var updatedDate: Date? { skill.updatedAt.flatMap(parseISO8601Date) }
    var weeksOld: Int? {
        updatedDate.map { max(0, Calendar.current.dateComponents([.day], from: $0, to: Date()).day ?? 0) / 7 }
    }
    var updatedText: String {
        weeksOld?.formatted() ?? "—"
    }
    var updatedDateText: String {
        updatedDate?.formatted(date: .abbreviated, time: .omitted) ?? "Unknown"
    }
    var updatedHelp: String {
        guard let updatedDate else { return "No update timestamp is available." }
        return "Recorded update or latest local content change: \(updatedDate.formatted(date: .abbreviated, time: .shortened)). Calendar age alone does not lower Quality."
    }
    var tokenEstimate: Int { skill.tokenEstimate }
    var referenceFileCount: Int { skill.referenceFileCount }
    var scriptFileCount: Int { skill.scriptFileCount }
    var assetFileCount: Int { skill.assetFileCount }
    var otherFileCount: Int { skill.otherFileCount }
    var skillIconPath: String? { skill.iconSmallPath ?? skill.iconLargePath }
    var canEditIcon: Bool {
        skill.representation == "canonical"
            && skill.mutability == "editable"
            && skill.manager != "codex-plugin"
    }
    var canEditDocument: Bool { canEditIcon }
    var metagentStaticScore: Int {
        metagentScore.qualityScore(
            pluginEvalScore: pluginEval?.score,
            codexReviewScore: codexReview?.score
        )
    }
    var metagentStaticGrade: SkillGrade { .forScore(metagentStaticScore) }
    var utilityScore: Int {
        metagentScore.utilityScore(qualityScore: metagentStaticScore)
    }
    var utilityGrade: SkillGrade { .forScore(utilityScore) }
    var metagentScoreText: String { "\(metagentStaticScore) \(metagentStaticGrade.rawValue)" }
    var metagentScoreTint: Color { scoreTint(metagentStaticGrade) }
    var metagentScoreHelp: String {
        let breakdown = metagentScore.components.filter { $0.id != "adoption" }.map {
            "\($0.label): \($0.score)/\($0.maximum) — \($0.explanation)"
        }.joined(separator: "\n")
        let pluginLine = pluginEval.map { "Plugin Eval: \($0.score)/100 · 60% weight" }
            ?? "Plugin Eval: not run · excluded"
        let codexLine = codexReview.map { "Codex review: \($0.score)/100 · 20% weight" }
            ?? "Codex review: not run · excluded"
        return "Quality excludes usage and update age. Available inputs are normalized.\nPlugin Eval (skill correctness and efficiency): 60%\nManagement confidence (known source, owner, manager, and canonical identity): 20%\nCodex review (optional judgment): 20%\n\nManagement confidence: \(metagentScore.structuralScore)/100\n\(pluginLine)\n\(codexLine)\nAbsolute grades: A 90+, B 80+, C 70+, D 60+, F below 60.\n\(breakdown)"
    }
    var portfolioScoreText: String { "\(utilityScore) \(utilityGrade.rawValue)" }
    var portfolioScoreTint: Color { scoreTint(utilityGrade) }
    var portfolioScoreHelp: String {
        let adoption = metagentScore.components.first { $0.id == "adoption" }
        let adoptionText = adoption.map {
            "Observed adoption: \($0.score)/\($0.maximum) — \($0.explanation)"
        } ?? "Observed adoption: unavailable"
        let advisoryText = advisories.isEmpty
            ? ""
            : "\n" + advisories.map { "Review due: \($0.message)" }.joined(separator: "\n")
        return "Utility combines Quality at 70% with observed adoption at 30%. Advisories do not change scores.\nQuality: \(metagentStaticScore)/100\n\(adoptionText)\(advisoryText)"
    }
    var pluginEvalText: String {
        guard let pluginEval else { return "—" }
        return "\(pluginEval.score) \(pluginEval.grade)"
    }
    var pluginEvalSortValue: Int { pluginEval?.score ?? -1 }
    var pluginEvalTint: Color? {
        pluginEval.flatMap { SkillGrade(rawValue: $0.grade.uppercased()) }.map(scoreTint)
    }
    var pluginEvalHelp: String {
        if pluginEvalIsStale {
            return "The saved Plugin Eval result is stale because the installed skill changed. Re-run Plugin Eval for current evidence."
        }
        guard let pluginEval else { return "Not evaluated. Use Evaluate → Run Plugin Eval." }
        return "Plugin Eval \(pluginEval.toolVersion) · \(pluginEval.riskLevel) risk\nA separate static evaluator that starts at 100 and deducts for concrete findings such as invalid frontmatter, weak trigger descriptions, broken links, excessive token budgets, and missing progressive disclosure. Its number supplies 60% of Quality when present; 60% is not its internal formula.\nThe letter uses Plugin Eval's stricter absolute bands: A 93+, B 85+, C 70+, D 55+. It is not relative.\n\(pluginEval.riskReasons.joined(separator: "\n"))"
    }
    var codexReviewText: String {
        guard let codexReview else { return "—" }
        return "\(codexReview.score) \(codexReview.grade.rawValue)"
    }
    var codexReviewSortValue: Int { codexReview?.score ?? -1 }
    var codexReviewTint: Color? { codexReview.map { scoreTint($0.grade) } }
    var codexReviewHelp: String {
        if codexReviewIsStale {
            return "The saved Codex review is stale because the installed skill changed. Run a new review for current evidence."
        }
        guard let codexReview else { return "Not reviewed. Use Evaluate → Review with Codex." }
        return "Absolute grades: A 90+, B 80+, C 70+, D 60+, F below 60.\n\(codexReview.summary)\nNext: \(codexReview.recommendation)"
    }
    var removalRequest: SkillRemovalRequest? {
        MetagentCore.resolveSkillRemovalTarget(
            projectRoot: project.root,
            skill: skill.coreSkill,
            variants: variants.map(\.coreSkill)
        )
    }
    /// Archiving is a pure file move, so only unmanaged file-backed skills
    /// qualify; managed skills and plugins keep their remove-only path.
    var archiveRequest: SkillRemovalRequest? {
        guard let request = removalRequest,
              request.method != .codexPlugin,
              !["skills-cli", "dotagents"].contains(skill.manager)
        else { return nil }
        return request
    }
    func matches(_ query: String) -> Bool {
        [
            skillName,
            projectName,
            locationLabel,
            originText,
            descriptionText,
            upstreamText,
            versionText,
            metagentScoreText,
            pluginEvalText,
            codexReviewText,
        ]
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

func pluginUsageMatchKey(id: String, canonicalPath: String?) -> String? {
    let components = id.split(separator: ":", maxSplits: 2).map(String.init)
    guard components.count == 3,
          components[0] == "plugin",
          let canonicalPath,
          let identity = pluginCacheIdentity(canonicalPath),
          [identity.owner, identity.plugin].contains(components[1]),
          identity.skill == components[2]
    else { return nil }
    return identity.key
}

func pluginUsageMatchKey(_ skill: SkillStatus) -> String? {
    guard skill.location == "plugin",
          let identity = pluginCacheIdentity(skill.canonicalPath)
    else { return nil }
    return identity.key
}

func pluginCacheIdentity(
    _ canonicalPath: String
) -> (marketplace: String, plugin: String, skill: String, owner: String, key: String)? {
    let url = URL(fileURLWithPath: canonicalPath)
    let components = url.pathComponents
    guard let skillsIndex = components.lastIndex(of: "skills"),
          skillsIndex >= 4,
          components[skillsIndex - 4] == "cache"
    else { return nil }
    let marketplace = components[skillsIndex - 3]
    let plugin = components[skillsIndex - 2]
    let skill = url.lastPathComponent
    // OpenAI renamed this marketplace directory without changing plugin
    // identity. Preserve every other marketplace so unrelated installations
    // with matching folder names do not share usage.
    let stableMarketplace = MetagentCore.normalizedPluginMarketplace(marketplace)
    let owner = "\(stableMarketplace)/\(plugin)"
    return (marketplace, plugin, skill, owner, "\(owner):\(skill)")
}

func skillRemovalMessage(for rows: [InventorySkillRow]) -> String {
    let requests = rows.compactMap(\.removalRequest)
    let pluginCount = requests.filter { $0.method == .codexPlugin }.count
    let managedCount = rows.filter { ["skills-cli", "dotagents"].contains($0.skill.manager) }.count
    var parts: [String] = []
    if pluginCount > 0 {
        parts.append("Removing a plugin skill uninstalls its entire Codex plugin, including its other skills; duplicate selections from one plugin are collapsed into one action.")
    }
    if managedCount > 0 {
        parts.append("Managed skills are removed through their owning CLI after recovery state is saved; skills sharing one project are sent in a single batch.")
    }
    if requests.count > 1 {
        parts.append("Independent projects can finish in parallel. A failed item returns to the table with details while successful removals stay removed.")
    }
    return parts.joined(separator: " ")
}
