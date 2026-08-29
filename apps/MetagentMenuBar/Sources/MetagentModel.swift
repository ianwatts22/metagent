import AppKit
import Foundation
import MetagentCore
import SwiftUI

typealias SkillRemovalRequest = SkillRemovalTarget

private struct SkillRemovalOutcome: Sendable {
    let succeededIDs: Set<String>
    let failedIDs: Set<String>
    let reconciliationIDs: Set<String>
    let lines: [String]
}

/// Launch cache reads are deliberately split by whether the first frame needs
/// them. Inventory is small enough to make the initial view useful immediately;
/// the usage snapshot can run a comparatively expensive SQLite aggregation and
/// model releases can decode a megabyte-scale catalog, so both hydrate after
/// SwiftUI has had a chance to present the window.
struct MetagentDeferredLaunchSnapshot: Sendable {
    let usage: SkillUsageSnapshot?
    let evaluations: SkillEvaluationSnapshot
    let modelReleases: ModelReleaseSnapshot
    let releaseAffirmations: [String: Date]
    let publications: SkillPublicationSnapshot
}

struct MetagentLaunchCacheLoader: Sendable {
    let loadInventory: @Sendable () -> SkillScanReport?
    let loadDeferred: @Sendable () -> MetagentDeferredLaunchSnapshot

    static let live = MetagentLaunchCacheLoader(
        loadInventory: {
            MetagentCore.loadInventorySnapshot()
        },
        loadDeferred: {
            MetagentDeferredLaunchSnapshot(
                usage: MetagentCore.loadSkillUsageSnapshot(),
                evaluations: MetagentCore.loadSkillEvaluationSnapshot(),
                modelReleases: MetagentCore.loadModelReleaseSnapshot(),
                releaseAffirmations: MetagentCore.loadModelReleaseAffirmations(),
                publications: MetagentCore.loadSkillPublicationSnapshot()
            )
        }
    )
}

@MainActor
final class MetagentModel: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var statusText = "Checking status..."
    @Published private(set) var lastRunText: String?
    @Published private(set) var systemImage = "wrench.and.screwdriver"
    @Published private(set) var coreStatusText = "Resolving core..."
    @Published private(set) var repoCount = 0
    @Published private(set) var skillCount = 0
    @Published private(set) var warningCount = 0
    @Published private(set) var failureCount = 0
    @Published private(set) var doctorIssues: [DoctorIssue] = []
    @Published private(set) var rootsText = "Checking roots..."
    @Published private(set) var locationSummaryText = "Checking skill locations..."
    @Published private(set) var projects: [ProjectStatus] = []
    @Published private(set) var lastOutputTitle: String?
    @Published private(set) var lastOutputLines: [String] = []
    @Published private(set) var lastOutputWasFailure = false
    @Published private(set) var repairPreview: RepairPreview?
    @Published private(set) var showsRawOutput = false
    @Published private(set) var usageSnapshot = SkillUsageSnapshot.empty
    @Published private(set) var isUsageRefreshing = false
    @Published private(set) var usageStatusText = "Usage history not scanned"
    @Published private(set) var isUsageIndexingStalled = false
    @Published private(set) var skillEvaluations = SkillEvaluationSnapshot()
    @Published private(set) var isSkillEvaluating = false
    @Published private(set) var skillEvaluationStatusText: String?
    /// Fraction complete for a multi-skill Plugin Eval run; nil when the run
    /// has no meaningful total (single skill, Codex review).
    @Published private(set) var skillEvaluationProgress: Double?
    @Published private(set) var isPluginInventoryAvailable = false
    @Published private(set) var pluginInventory = PluginInventorySnapshot.empty
    @Published private(set) var isPluginInventoryRefreshing = false
    @Published private(set) var pluginUpdateReport: PluginUpdateReport?
    @Published private(set) var isUpdatingPlugins = false
    @Published private(set) var mcpHealth = MCPHealthSnapshot()
    @Published private(set) var isMCPRefreshing = false
    /// Measured codebase size per standardized project root. Only git
    /// repositories appear; everything else has no tracked codebase to size.
    @Published private(set) var codebaseSizes: [String: CodebaseSizeReport] = [:]
    @Published private(set) var isCodebaseSizeRefreshing = false
    @Published private(set) var archivedSkills: [ArchivedSkill] = []
    @Published private(set) var skillTableRevision = 0
    @Published private(set) var pendingSkillRemovalIDs = Set<String>()
    @Published private(set) var isRemovingSkills = false
    @Published private(set) var modelReleases = ModelReleaseSnapshot.empty
    @Published private(set) var releaseAffirmations: [String: Date] = [:]
    @Published private(set) var publicationSnapshot = SkillPublicationSnapshot.empty
    @Published private(set) var isPublicationSyncing = false
    @Published private(set) var publicationStatusText = "No skills selected for publishing"
    @Published private(set) var hasHydratedLaunchCaches = false

    private let fileManager = FileManager.default
    private var statusRefreshGeneration = 0
    private var statusRefreshQueued = false
    private var skillRemovalQueues: [String: [[SkillRemovalRequest]]] = [:]
    private var activeSkillRemovalKeys = Set<String>()
    private(set) var completedSkillRemovalIDs = Set<String>()
    private var accumulatedSkillRemovalLines: [String] = []
    private var accumulatedSkillRemovalFailedIDs = Set<String>()
    private var isReconcilingSkillRemovals = false
    private var autoEvaluatedPaths = Set<String>()
    private var hasCapturedHistory = false
    private var hasAttemptedHistoryBackfill = false
    private var historyBackfillAwaitingCompleteUsage = false
    private var pendingHistoryTrigger: SkillHistoryTrigger?
    private var pluginAutoUpdateTask: Task<Void, Never>?
    private var usageMaintenanceTask: Task<Void, Never>?
    private var usageForegroundRefreshQueued = false
    private var publicationSyncQueued = false
    private var codebaseSizeRefreshQueued = false
    private let launchCacheLoader: MetagentLaunchCacheLoader
    private var hasStarted = false
    private var isHydratingLaunchCaches = false

    /// A refresh advances recent usage by one bounded slice. Historical parser
    /// upgrades can span tens of gigabytes; the menu-bar app must never turn
    /// that maintenance into an unbounded, full-core loop.
    private static let usageRefreshSliceBytes: Int64 = 8 * 1_024 * 1_024
    private static let usageRefreshSliceFiles = 12

    init(launchCacheLoader: MetagentLaunchCacheLoader = .live) {
        self.launchCacheLoader = launchCacheLoader
        if let snapshot = launchCacheLoader.loadInventory() {
            projects = Self.mergeProjects(snapshot.projects.map(ProjectStatus.init(project:)))
            updateInventorySummary()
            rootsText = "cached SQLite snapshot"
            statusText = "\(repoCount) cached locations, \(skillCount) skills"
            systemImage = "externaldrive"
        }
    }

    // MARK: - Liveness

    /// When a full status scan last landed. Gates the cheap "am I stale"
    /// refreshes so opening the window twice in a minute costs one scan.
    private var lastStatusAppliedAt = Date.distantPast

    private lazy var skillRootsWatcher = SkillRootsWatcher { [weak self] in
        self?.skillRootsChangedExternally()
    }

    /// Starts launch hydration exactly once. Scene appearance is the boundary:
    /// constructing the model no longer blocks AppKit launch on the large usage
    /// aggregation, but every previously automatic refresh still starts as soon
    /// as the first app surface is actually visible.
    private func start() {
        guard !hasStarted else { return }
        hasStarted = true
        isHydratingLaunchCaches = true
        Task { [weak self] in
            // Let the current SwiftUI/AppKit update reach presentation before
            // scheduling cache I/O, even on an otherwise idle machine.
            await Task.yield()
            guard let self else { return }
            await hydrateLaunchCaches()
            isHydratingLaunchCaches = false

            refreshStatus(preloadedEvaluations: skillEvaluations)
            refreshUsage()
            refreshModelReleases()
            startWatchingSkillRoots()
            reconcileSkillPublications()
        }
    }

    /// Shared by launch and a deterministic unit test. The expensive loader is
    /// always detached from the main actor; applying the immutable result stays
    /// on the main actor so observers see one coherent cache generation.
    func hydrateLaunchCaches() async {
        let loader = launchCacheLoader.loadDeferred
        let cached = await Task.detached(priority: .userInitiated) {
            loader()
        }.value
        var refreshesSkillPresentation = false
        if let usage = cached.usage {
            refreshesSkillPresentation = usage != usageSnapshot
            usageSnapshot = usage
            usageStatusText = Self.usageStatus(usage)
        }
        refreshesSkillPresentation = refreshesSkillPresentation
            || cached.evaluations != skillEvaluations
            || cached.modelReleases != modelReleases
            || cached.releaseAffirmations != releaseAffirmations
        skillEvaluations = cached.evaluations
        modelReleases = cached.modelReleases
        releaseAffirmations = cached.releaseAffirmations
        publicationSnapshot = cached.publications
        updatePublicationStatus()
        if refreshesSkillPresentation {
            // Overview health and Skills rows may have rendered their loading
            // state while the detached cache read ran. Publish one coherent
            // revision after every cached input is in place.
            skillTableRevision += 1
        }
        hasHydratedLaunchCaches = true
    }

    /// Everything the inventory scan reads that can change behind the app's
    /// back: the global collections, every known project's canonical skills
    /// directory, and the plugin cache whose versioned folders change on
    /// plugin updates.
    private func startWatchingSkillRoots() {
        var paths = [
            homeURL().appendingPathComponent(".agents/skills").path,
            homeURL().appendingPathComponent(".claude/skills").path,
            homeURL().appendingPathComponent(".codex/plugins/cache").path,
        ]
        paths += projects.map { project in
            URL(fileURLWithPath: project.coreProject.skillsDir).path
        }
        skillRootsWatcher.watch(paths: paths)
    }

    private func skillRootsChangedExternally() {
        // Publication mirroring is independent of inventory work. FSEvents is
        // only a signal; reconciliation hashes every selected canonical skill.
        reconcileSkillPublications()
        // Our own mutations already end in a rescan; their file events would
        // only buy a second, redundant one.
        guard !isRunning,
              !isRemovingSkills,
              !isReconcilingSkillRemovals,
              !isUpdatingPlugins
        else { return }
        guard Date().timeIntervalSince(lastStatusAppliedAt) > 3 else { return }
        refreshStatus()
    }

    /// Refreshes when the last landed scan is old enough to matter. Called when
    /// a window or panel opens, which is exactly when staleness becomes visible.
    func refreshIfStale(maxAgeSeconds: TimeInterval = 60) {
        guard hasStarted else {
            start()
            return
        }
        guard !isHydratingLaunchCaches else { return }
        guard Date().timeIntervalSince(lastStatusAppliedAt) > maxAgeSeconds else { return }
        guard !isRunning else { return }
        refreshAll()
    }

    // MARK: - Dev channel

    /// True only for the side-installed dev build; gates affordances that have
    /// no business in a released app.
    var isDevChannel: Bool {
        Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true
    }

    /// Disposable global skills for exercising the removal, archive, and
    /// history flows without touching anything real. Deliberately re-runnable:
    /// deleted ones come back, existing ones are left alone.
    func addTestSkills() {
        guard isDevChannel, !isRunning else { return }
        let skillsRoot = homeURL().appendingPathComponent(".agents/skills")
        runOperation(
            title: "Add test skills",
            runningText: "Writing test skills…"
        ) {
            var lines: [String] = []
            for skill in Self.testSkillFixtures {
                let root = skillsRoot.appendingPathComponent(skill.directory)
                if FileManager.default.fileExists(atPath: root.path) {
                    lines.append("\(skill.directory): already present, left alone")
                    continue
                }
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try skill.skillFile.write(
                    to: root.appendingPathComponent("SKILL.md"),
                    atomically: true,
                    encoding: .utf8
                )
                for (relativePath, content) in skill.extraFiles {
                    let url = root.appendingPathComponent(relativePath)
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try content.write(to: url, atomically: true, encoding: .utf8)
                }
                lines.append("\(skill.directory): created")
            }
            return CommandOutcome(succeeded: true, lines: lines, repairPreview: nil)
        } completion: { [weak self] result in
            if result.succeeded {
                self?.refreshStatus()
            }
        }
    }

    private struct TestSkillFixture {
        let directory: String
        let skillFile: String
        var extraFiles: [(String, String)] = []
    }

    /// Obviously-fake names so nothing here can be mistaken for a real skill,
    /// with enough variety to light up different table columns: a plain one, one
    /// with a script, and one with reference documentation.
    private nonisolated static let testSkillFixtures: [TestSkillFixture] = [
        TestSkillFixture(
            directory: "test-zz-plain",
            skillFile: """
            ---
            name: test-zz-plain
            description: Disposable dev-channel test skill with a minimal body. Safe to remove.
            ---

            # Test skill: plain

            This skill exists only so the dev build has something safe to select,
            archive, and remove. It does nothing.
            """
        ),
        TestSkillFixture(
            directory: "test-zz-scripted",
            skillFile: """
            ---
            name: test-zz-scripted
            description: Disposable dev-channel test skill carrying a script. Safe to remove.
            ---

            # Test skill: scripted

            Carries one inert script so script-count columns and removal of
            multi-file bundles get exercised.

            Run `scripts/noop.sh` to do nothing successfully.
            """,
            extraFiles: [
                ("scripts/noop.sh", "#!/bin/sh\nexit 0\n"),
            ]
        ),
        TestSkillFixture(
            directory: "test-zz-referenced",
            skillFile: """
            ---
            name: test-zz-referenced
            description: Disposable dev-channel test skill with reference documentation. Safe to remove.
            ---

            # Test skill: referenced

            Carries reference documentation so reference-count columns, token
            estimates, and the skill viewer's document handling get exercised.

            See `references/details.md` for absolutely nothing of value.
            """,
            extraFiles: [
                (
                    "references/details.md",
                    "# Details\n\nThere are no details. This file pads the reference count.\n"
                ),
            ]
        ),
    ]

    /// Provider keys whose releases trigger skill-review advisories. Stored as
    /// a comma-separated default so Settings and the model read one value.
    var trackedModelProviders: [String] {
        guard let stored = UserDefaults.standard.string(forKey: Self.trackedModelProvidersKey) else {
            return MetagentCore.defaultTrackedModelProviders
        }
        // "none" records a deliberate opt-out; a missing value means defaults.
        if stored == "none" { return [] }
        let keys = stored.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        return keys.isEmpty ? MetagentCore.defaultTrackedModelProviders : keys
    }

    static let trackedModelProvidersKey = "metagent.model-releases.providers.v1"

    func setTrackedModelProviders(_ providers: [String]) {
        UserDefaults.standard.set(
            providers.isEmpty ? "none" : providers.joined(separator: ","),
            forKey: Self.trackedModelProvidersKey
        )
        skillTableRevision += 1
    }

    /// Polls models.dev at most once a day; the catalog is small and the poll
    /// falls back to the cached snapshot when offline.
    func refreshModelReleases() {
        Task {
            let snapshot = await MetagentCore.refreshModelReleaseSnapshot()
            if snapshot != modelReleases {
                modelReleases = snapshot
                skillTableRevision += 1
            }
        }
    }

    /// Records that a skill was reviewed against current models with no
    /// changes needed, clearing its release-staleness advisory.
    func affirmModelReleaseReview(canonicalPath: String) {
        do {
            try MetagentCore.affirmModelReleaseReview(canonicalPath: canonicalPath)
            releaseAffirmations = MetagentCore.loadModelReleaseAffirmations()
            skillTableRevision += 1
        } catch {
            lastOutputWasFailure = true
            lastOutputTitle = "Mark reviewed failed"
            lastOutputLines = [error.localizedDescription]
        }
    }

    /// Everything the app can be busy with, reported in one place, or `nil` when
    /// it is idle and there is nothing worth saying.
    ///
    /// Attention states outrank work in progress, because a stalled index is
    /// still true while an unrelated scan runs.
    var activity: AppActivity? {
        if isUsageIndexingStalled {
            return .attention(usageStatusText)
        }
        if !isUsageRefreshing, usageSnapshot.totalFiles == 0 {
            return .attention("No retained sessions indexed")
        }
        if isRunning {
            return .working(progress: nil, label: "Scanning skills…")
        }
        if isUsageRefreshing {
            return .working(progress: usageIndexingProgress, label: usageStatusText)
        }
        if isSkillEvaluating {
            return .working(
                progress: skillEvaluationProgress,
                label: skillEvaluationStatusText ?? "Evaluating skills…"
            )
        }
        if isMCPRefreshing {
            return .working(progress: nil, label: "Checking MCP servers…")
        }
        return usageSnapshot.isBackfillComplete ? nil : .attention(usageStatusText)
    }

    var isRefreshing: Bool {
        isRunning || isUsageRefreshing || isMCPRefreshing
    }

    /// The single reload: rescan installed skills and Doctor findings, recheck
    /// MCP configuration, and continue indexing session history.
    func refreshAll() {
        refreshStatus()
        refreshUsage()
        reconcileSkillPublications()
    }

    func isPrimaryPublishableSkill(_ skill: InventorySkillRow) -> Bool {
        guard skill.skill.representation == "canonical",
              skill.skill.mutability == "editable",
              skill.skill.manager != "codex-plugin"
        else { return false }
        let source = URL(fileURLWithPath: skill.canonicalPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let primaryRoot = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".agents/skills", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        return source.deletingLastPathComponent().path == primaryRoot.path
    }

    @discardableResult
    func enableSkillPublication(
        sourcePath: String,
        skillName: String,
        repositoryPath: String,
        destinationName: String
    ) -> Bool {
        guard !isPublicationSyncing else {
            publicationStatusText = "Finish the current sync, then try publishing again."
            return false
        }
        let source = URL(fileURLWithPath: sourcePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let primaryRoot = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".agents/skills", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard source.deletingLastPathComponent().path == primaryRoot.path else {
            publicationStatusText = "Only canonical ~/.agents/skills can be published."
            return false
        }
        isPublicationSyncing = true
        publicationStatusText = "Checking and mirroring \(skillName)…"
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                do {
                    let report: SkillPublicationReconcileReport? = try MetagentCore.enableSkillPublication(
                        sourcePath: source.path,
                        skillName: skillName,
                        repositoryPath: repositoryPath,
                        destinationName: destinationName
                    )
                    return (
                        report,
                        nil as String?
                    )
                } catch {
                    return (nil, error.localizedDescription)
                }
            }.value
            guard let self else { return }
            if let report = result.0 {
                publicationSnapshot = report.snapshot
                updatePublicationStatus()
            }
            isPublicationSyncing = false
            if let error = result.1 {
                publicationStatusText = error
            }
            ProductAnalytics.shared.capture(.skillPublicationEnabled(
                result: result.0 == nil ? .failure : .success
            ))
            finishQueuedPublicationSyncIfNeeded()
        }
        return true
    }

    func disableSkillPublication(recordID: String) {
        guard !isPublicationSyncing else { return }
        isPublicationSyncing = true
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                do {
                    let snapshot: SkillPublicationSnapshot? = try MetagentCore.disableSkillPublication(
                        recordID: recordID
                    )
                    return (snapshot, nil as String?)
                } catch {
                    return (nil, error.localizedDescription)
                }
            }.value
            guard let self else { return }
            if let snapshot = result.0 {
                publicationSnapshot = snapshot
            }
            isPublicationSyncing = false
            publicationStatusText = result.1 ?? "Automatic local mirroring stopped."
            finishQueuedPublicationSyncIfNeeded()
        }
    }

    func reconcileSkillPublications() {
        guard !isPublicationSyncing else {
            publicationSyncQueued = true
            return
        }
        isPublicationSyncing = true
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                do {
                    let report: SkillPublicationReconcileReport? = try MetagentCore.reconcileSkillPublications()
                    return (report, nil as String?)
                } catch {
                    return (nil, error.localizedDescription)
                }
            }.value
            guard let self else { return }
            if let report = result.0 {
                publicationSnapshot = report.snapshot
                updatePublicationStatus()
            } else if let error = result.1 {
                publicationStatusText = error
            }
            let enabled = publicationSnapshot.records.filter(\.automaticMirroringEnabled)
            if !enabled.isEmpty {
                let blockedCount = enabled.count { $0.state != .mirrored }
                let analyticsResult: ProductAnalyticsResult
                if result.0 == nil {
                    analyticsResult = .failure
                } else if blockedCount > 0 {
                    analyticsResult = .partial
                } else {
                    analyticsResult = .success
                }
                ProductAnalytics.shared.capture(.skillPublicationSyncCompleted(
                    result: analyticsResult,
                    publishedSkillCount: enabled.count,
                    blockedSkillCount: blockedCount
                ))
            }
            isPublicationSyncing = false
            finishQueuedPublicationSyncIfNeeded()
        }
    }

    private func finishQueuedPublicationSyncIfNeeded() {
        guard publicationSyncQueued else { return }
        publicationSyncQueued = false
        reconcileSkillPublications()
    }

    private func updatePublicationStatus() {
        let enabled = publicationSnapshot.records.filter(\.automaticMirroringEnabled)
        guard !enabled.isEmpty else {
            publicationStatusText = "No skills selected for publishing"
            return
        }
        let blocked = enabled.filter { $0.state != .mirrored }.count
        publicationStatusText = blocked == 0
            ? "\(enabled.count) skills mirrored locally"
            : "\(blocked) of \(enabled.count) publications need attention"
    }

    private var usageIndexingProgress: Double? {
        guard usageSnapshot.totalBytes > 0 else { return nil }
        return min(1, max(
            0,
            Double(usageSnapshot.processedBytes) / Double(usageSnapshot.totalBytes)
        ))
    }

    var problemCount: Int {
        warningCount + failureCount
    }

    var doctorFindings: [DoctorIssue] {
        doctorIssues.filter { $0.severity != .ok }
    }

    var logicalSkillCount: Int {
        Self.logicalSkillCount(projects: projects)
    }

    func inventorySkillRow(canonicalPath: String) -> InventorySkillRow? {
        guard !isRunning, !isSkillEvaluating else { return nil }
        let targetPath = standardizedDirectoryPath(canonicalPath)
        return InventorySkillRow.rows(
            from: projects,
            usage: usageSnapshot,
            evaluations: skillEvaluations,
            modelReleases: modelReleases,
            releaseAffirmations: releaseAffirmations,
            trackedModelProviders: trackedModelProviders
        ).first {
            standardizedDirectoryPath($0.canonicalPath) == targetPath
        }
    }

    func refreshStatus(preloadedEvaluations: SkillEvaluationSnapshot? = nil) {
        guard !isRunning, !isSkillEvaluating else {
            statusRefreshQueued = true
            return
        }
        statusRefreshGeneration += 1
        let generation = statusRefreshGeneration
        isRunning = true
        refreshArchivedSkills()
        refreshMCPHealth()
        refreshPluginInventory()
        statusText = "Checking status..."
        systemImage = "arrow.triangle.2.circlepath"
        coreStatusText = "Swift core"

        Task {
            async let inventoryResults = Self.scanInventory()
            let evaluations: SkillEvaluationSnapshot
            if let preloadedEvaluations {
                evaluations = preloadedEvaluations
            } else {
                evaluations = await Task.detached(priority: .utility) {
                    MetagentCore.loadSkillEvaluationSnapshot()
                }.value
            }
            let (scan, homeScan, pluginScan) = await inventoryResults
            let doctor = await Task.detached(priority: .utility) {
                Self.doctorResult(scan: scan, homeScan: homeScan)
            }.value

            applyStatus(
                scan: scan,
                homeScan: homeScan,
                pluginScan: pluginScan,
                doctor: doctor,
                evaluations: evaluations,
                generation: generation
            )
        }
    }

    private func runQueuedStatusRefreshIfNeeded() {
        guard statusRefreshQueued else { return }
        statusRefreshQueued = false
        refreshStatus()
    }

    private func finishRunningOperation() {
        isRunning = false
        runQueuedStatusRefreshIfNeeded()
    }

    /// Sizes every known project root that is a git repository. The Projects
    /// view calls this only while it is visible; ordinary inventory refreshes
    /// do not need to open every tracked source file on the machine.
    func refreshCodebaseSizes() {
        guard !isCodebaseSizeRefreshing else {
            codebaseSizeRefreshQueued = true
            return
        }
        let roots = codebaseSizeRoots
        guard !roots.isEmpty else {
            codebaseSizes = [:]
            return
        }

        isCodebaseSizeRefreshing = true
        Task {
            let measured = await Task.detached(priority: .utility) {
                MetagentCore.measureCodebaseSizes(roots: roots)
            }.value
            if roots == codebaseSizeRoots {
                codebaseSizes = measured
            }
            isCodebaseSizeRefreshing = false
            if codebaseSizeRefreshQueued {
                codebaseSizeRefreshQueued = false
                refreshCodebaseSizes()
            }
        }
    }

    var codebaseSizeInputKey: String {
        codebaseSizeRoots.joined(separator: "\u{1F}")
    }

    private var codebaseSizeRoots: [String] {
        directoryFilterOptions(
            projects: projects,
            mcpHealth: mcpHealth,
            doctorIssues: doctorIssues
        ).map(\.root).sorted()
    }

    func refreshMCPHealth() {
        guard !isMCPRefreshing else { return }
        isMCPRefreshing = true
        Task {
            let snapshot = await Task.detached(priority: .utility) {
                MetagentCore.scanMCPHealth()
            }.value
            mcpHealth = snapshot
            isMCPRefreshing = false
        }
    }

    func refreshPluginInventory() {
        guard !isPluginInventoryRefreshing else { return }
        isPluginInventoryRefreshing = true
        Task {
            let snapshot = await Task.detached(priority: .utility) {
                MetagentCore.scanPluginInventory()
            }.value
            pluginInventory = snapshot
            isPluginInventoryRefreshing = false
            autoUpdatePluginsIfDue()
        }
    }

    static let pluginAutoUpdateEnabledKey = "metagent.plugins.auto-update.v1"
    static let pluginAutoUpdateLastRunKey = "metagent.plugins.auto-update.last-run.v1"
    /// Third-party marketplace refreshes hit the network, so scheduled runs
    /// stay spaced out; the manual button bypasses the interval entirely.
    private static let pluginAutoUpdateInterval: TimeInterval = 6 * 60 * 60

    var isPluginAutoUpdateEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.pluginAutoUpdateEnabledKey) == nil
            ? false
            : UserDefaults.standard.bool(forKey: Self.pluginAutoUpdateEnabledKey)
    }

    func setPluginAutoUpdateEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.pluginAutoUpdateEnabledKey)
        if enabled {
            autoUpdatePluginsIfDue()
        } else {
            pluginAutoUpdateTask?.cancel()
            pluginAutoUpdateTask = nil
        }
    }

    var lastPluginAutoUpdateAt: Date? {
        let stored = UserDefaults.standard.double(forKey: Self.pluginAutoUpdateLastRunKey)
        return stored > 0 ? Date(timeIntervalSince1970: stored) : nil
    }

    private func autoUpdatePluginsIfDue() {
        guard isPluginAutoUpdateEnabled,
              pluginInventory.records.contains(where: { $0.updatePolicy == .manual })
        else {
            pluginAutoUpdateTask?.cancel()
            pluginAutoUpdateTask = nil
            return
        }
        if let lastRun = lastPluginAutoUpdateAt,
           Date().timeIntervalSince(lastRun) < Self.pluginAutoUpdateInterval
        {
            schedulePluginAutoUpdate(
                after: Self.pluginAutoUpdateInterval - Date().timeIntervalSince(lastRun)
            )
            return
        }
        updateThirdPartyPlugins()
    }

    private func schedulePluginAutoUpdate(after delay: TimeInterval) {
        pluginAutoUpdateTask?.cancel()
        pluginAutoUpdateTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, delay)))
            guard !Task.isCancelled else { return }
            self?.autoUpdatePluginsIfDue()
        }
    }

    func updateThirdPartyPlugins() {
        guard !isUpdatingPlugins else { return }
        isUpdatingPlugins = true
        UserDefaults.standard.set(
            Date().timeIntervalSince1970,
            forKey: Self.pluginAutoUpdateLastRunKey
        )
        Task {
            let report = await Task.detached(priority: .utility) {
                MetagentCore.updateThirdPartyPlugins()
            }.value
            pluginUpdateReport = report
            isUpdatingPlugins = false
            autoUpdatePluginsIfDue()
            if report.updatedCount > 0 {
                // Versions moved, so the plugin list and any plugin-provided
                // skills are stale; one scheduled refresh reconciles both.
                refreshStatus()
            }
        }
    }

    func openMCPServer(_ server: MCPServerHealth) {
        if server.supportsAuthentication {
            do {
                if let command = try MetagentCore.mcpAuthenticationCommand(for: server) {
                    openMCPAuthentication(command: command)
                }
            } catch {
                recordTerminalLaunchFailure(
                    title: "Could not start MCP authentication",
                    message: error.localizedDescription
                )
            }
            return
        }

        if server.client == .claude,
           server.state == .pendingApproval,
           server.projectPaths.count == 1,
           let projectPath = server.projectPaths.first
        {
            openClaudeCode(at: projectPath)
            return
        }

        openMCPClient(server.client)
    }

    private func openMCPAuthentication(command: [String]) {
        let script = """
        on run argv
            set shellCommand to ""
            repeat with argumentValue in argv
                if shellCommand is not "" then set shellCommand to shellCommand & " "
                set shellCommand to shellCommand & quoted form of argumentValue
            end repeat
            tell application "Terminal"
                activate
                do script "exec " & shellCommand
            end tell
        end run
        """
        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, "--"] + command
        process.standardError = standardError
        process.terminationHandler = { [weak self] process in
            guard process.terminationStatus != 0 else { return }
            let data = standardError.fileHandleForReading.readDataToEndOfFile()
            let message = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            Task { @MainActor [weak self] in
                self?.recordTerminalLaunchFailure(
                    title: "Could not start MCP authentication",
                    message: message,
                    status: process.terminationStatus
                )
            }
        }
        do {
            try process.run()
        } catch {
            recordTerminalLaunchFailure(
                title: "Could not start MCP authentication",
                message: error.localizedDescription
            )
        }
    }

    private func openMCPClient(_ client: MCPClient) {
        switch client {
        case .codex:
            if let applicationURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: client.bundleIdentifier
            ) {
                NSWorkspace.shared.openApplication(at: applicationURL, configuration: .init())
            } else {
                NSWorkspace.shared.open(homeURL().appendingPathComponent(".codex"))
            }
        case .claude:
            NSWorkspace.shared.open(homeURL().appendingPathComponent(".claude"))
        }
    }

    private func openClaudeCode(at projectPath: String) {
        let script = """
        on run argv
            set projectPath to item 1 of argv
            tell application "Terminal"
                activate
                do script "cd -- " & quoted form of projectPath & " && exec claude"
            end tell
        end run
        """
        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, "--", projectPath]
        process.standardError = standardError
        process.terminationHandler = { [weak self] process in
            guard process.terminationStatus != 0 else { return }
            let data = standardError.fileHandleForReading.readDataToEndOfFile()
            let message = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            Task { @MainActor [weak self] in
                self?.recordTerminalLaunchFailure(
                    title: "Could not open Claude",
                    message: message,
                    status: process.terminationStatus
                )
            }
        }
        do {
            try process.run()
        } catch {
            recordTerminalLaunchFailure(
                title: "Could not open Claude",
                message: error.localizedDescription
            )
        }
    }

    private func recordTerminalLaunchFailure(
        title: String,
        message: String,
        status: Int32? = nil
    ) {
        lastOutputWasFailure = true
        lastOutputTitle = title
        lastOutputLines = [message.isEmpty
            ? "osascript exited with status \(status ?? -1)"
            : message]
        showsRawOutput = true
    }

    func refreshUsage(maintenancePlan: SkillUsageMaintenancePlan? = nil) {
        if maintenancePlan == nil {
            usageMaintenanceTask?.cancel()
            usageMaintenanceTask = nil
            if isUsageRefreshing {
                usageForegroundRefreshQueued = true
                return
            }
        }
        guard !isUsageRefreshing else { return }
        isUsageRefreshing = true
        isUsageIndexingStalled = false
        usageStatusText = usageSnapshot.totalFiles == 0 ? "Discovering Codex history…" : "Updating usage history…"
        let maxBytes = maintenancePlan?.maxBytes ?? Self.usageRefreshSliceBytes
        let maxFiles = maintenancePlan?.maxFiles ?? Self.usageRefreshSliceFiles
        let refreshOptions = maintenancePlan?.refreshOptions()
            ?? SkillUsageRefreshOptions(maxBytes: maxBytes, maxFiles: maxFiles)

        Task {
            var shouldContinueMaintenance = false
            do {
                let report = try await Task.detached(priority: .background) {
                    try autoreleasepool {
                        try MetagentCore.refreshSkillUsage(options: refreshOptions)
                    }
                }.value
                usageSnapshot = report.snapshot
                skillTableRevision += 1
                usageStatusText = Self.usageStatus(report.snapshot)
                shouldContinueMaintenance = report.hasMore
                    && (report.wasDeferred || report.processedBytesAdvanced > 0)
                if report.hasMore,
                   !report.wasDeferred,
                   report.processedBytesAdvanced == 0
                {
                    if let warning = report.warnings.first {
                        usageStatusText = "Usage backfill paused: \(warning)"
                    } else {
                        usageStatusText = "Usage backfill paused at an incomplete session record"
                    }
                    isUsageIndexingStalled = true
                }
            } catch is CancellationError {
                usageStatusText = Self.usageStatus(usageSnapshot)
            } catch {
                usageStatusText = "Usage refresh failed: \(error.localizedDescription)"
                isUsageIndexingStalled = true
            }
            isUsageRefreshing = false
            let shouldRunForegroundRefresh = usageForegroundRefreshQueued
            usageForegroundRefreshQueued = false
            if shouldRunForegroundRefresh {
                refreshUsage()
            } else if shouldContinueMaintenance {
                scheduleUsageMaintenance()
            }
            if let trigger = pendingHistoryTrigger {
                pendingHistoryTrigger = nil
                recordHistory(trigger: trigger)
            } else if usageSnapshot.isBackfillComplete,
                      historyBackfillAwaitingCompleteUsage
            {
                // The first bounded slice recorded a partial reconstruction.
                // Retry exactly when later maintenance reaches full coverage.
                recordHistory(trigger: hasCapturedHistory ? .refresh : .launch)
            }
        }
    }

    private func scheduleUsageMaintenance() {
        usageMaintenanceTask?.cancel()
        let processInfo = ProcessInfo.processInfo
        let isThermallyConstrained = processInfo.thermalState == .serious
            || processInfo.thermalState == .critical
        let plan = SkillUsageMaintenancePlan.recommended(
            isEnergyConstrained: processInfo.isLowPowerModeEnabled || isThermallyConstrained
        )
        usageMaintenanceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(plan.delaySeconds))
            guard !Task.isCancelled, let self else { return }
            usageMaintenanceTask = nil
            if isRunning || isSkillEvaluating || isCodebaseSizeRefreshing {
                scheduleUsageMaintenance()
                return
            }
            refreshUsage(maintenancePlan: plan)
        }
    }

    func evaluateSkillWithPluginEval(path: String) {
        evaluateSkillsWithPluginEval(paths: [path])
    }

    /// Evaluates only skills with no result yet, in the background, so the score
    /// columns fill in on their own rather than waiting on a menu command.
    ///
    /// Paths are recorded before the run so a skill whose evaluation fails is
    /// not retried forever; an explicit re-run is still available per skill.
    func evaluateMissingSkills(paths: [String]) {
        guard hasHydratedLaunchCaches, !isRunning, !isSkillEvaluating else { return }
        let missing = paths.filter {
            skillEvaluations.records[$0] == nil && !autoEvaluatedPaths.contains($0)
        }
        guard !missing.isEmpty else { return }
        autoEvaluatedPaths.formUnion(missing)
        evaluateSkillsWithPluginEval(paths: missing)
    }

    func evaluateSkillsWithPluginEval(paths: [String]) {
        guard !isRunning, !isSkillEvaluating else { return }
        let uniquePaths = Array(Set(paths)).sorted()
        guard !uniquePaths.isEmpty else { return }
        isSkillEvaluating = true
        skillEvaluationStatusText = uniquePaths.count == 1
            ? "Running Plugin Eval…"
            : "Running Plugin Eval for \(uniquePaths.count) skills…"
        skillEvaluationProgress = uniquePaths.count == 1 ? nil : 0

        Task {
            var failedSkillNames: [String] = []
            var firstFailureDetail: String?
            var updatedEvaluations = skillEvaluations
            for (index, path) in uniquePaths.enumerated() {
                do {
                    let record = try await Task.detached(priority: .utility) {
                        try MetagentCore.evaluateSkillWithPluginEval(at: path)
                    }.value
                    updatedEvaluations.applyPluginEvalResult(record)
                    skillEvaluationStatusText = uniquePaths.count == 1
                        ? "Plugin Eval complete"
                        : "Plugin Eval \(index + 1) of \(uniquePaths.count)"
                    skillEvaluationProgress = Double(index + 1) / Double(uniquePaths.count)
                } catch {
                    failedSkillNames.append(URL(fileURLWithPath: path).lastPathComponent)
                    if firstFailureDetail == nil {
                        firstFailureDetail = error.localizedDescription
                    }
                    skillEvaluationStatusText = "Plugin Eval \(index + 1) of \(uniquePaths.count) · \(failedSkillNames.count) failed"
                    skillEvaluationProgress = Double(index + 1) / Double(uniquePaths.count)
                }
                let completed = index + 1
                if SkillEvaluationBatchPolicy.shouldPublish(
                    completed: completed,
                    total: uniquePaths.count
                ) {
                    skillEvaluations = updatedEvaluations
                    skillTableRevision += 1
                }
            }
            if !failedSkillNames.isEmpty {
                let preview = failedSkillNames.prefix(3).joined(separator: ", ")
                let suffix = failedSkillNames.count > 3 ? ", …" : ""
                let detail = firstFailureDetail.map { " · \($0)" } ?? ""
                skillEvaluationStatusText = "Plugin Eval finished · \(failedSkillNames.count) failed: \(preview)\(suffix)\(detail)"
            }
            skillEvaluationProgress = nil
            isSkillEvaluating = false
            runQueuedStatusRefreshIfNeeded()
        }
    }

    func reviewSkillWithCodex(path: String, projectRoot: String? = nil) {
        reviewSkillsWithCodex([(path: path, projectRoot: projectRoot)])
    }

    /// Reviews every selected skill in a single Codex session, so a batch
    /// leaves one chat in the user's Codex history rather than one per skill.
    func reviewSkillsWithCodex(_ targets: [(path: String, projectRoot: String?)]) {
        guard !isRunning, !isSkillEvaluating, !targets.isEmpty else { return }
        isSkillEvaluating = true
        skillEvaluationStatusText = targets.count == 1
            ? "Codex is reviewing \(URL(fileURLWithPath: targets[0].path).lastPathComponent)…"
            : "Codex is reviewing \(targets.count) skills in one session…"
        // Project skills are reviewed inside their project; global skills are
        // reviewed from the home directory so every skills location and the
        // rest of the local setup is visible context.
        let coreTargets = targets.map { target in
            (
                path: target.path,
                contextRoot: {
                    if let projectRoot = target.projectRoot, !isGlobalRoot(projectRoot) {
                        return projectRoot
                    }
                    return NSHomeDirectory()
                }() as String?
            )
        }
        Task {
            do {
                let outcome = try await Task.detached(priority: .utility) {
                    try MetagentCore.reviewSkillsWithCodexSession(targets: coreTargets)
                }.value
                var snapshot = skillEvaluations
                for record in outcome.records {
                    snapshot.applyCodexReviewResult(record)
                }
                skillEvaluations = snapshot
                skillTableRevision += 1
                if outcome.failures.isEmpty {
                    skillEvaluationStatusText = targets.count == 1
                        ? "Codex review complete"
                        : "Codex reviews complete (\(outcome.records.count))"
                } else {
                    let first = outcome.failures[0]
                    let name = URL(fileURLWithPath: first.path).lastPathComponent
                    skillEvaluationStatusText = "Codex review finished · \(outcome.failures.count) failed · \(name): \(first.message)"
                }
            } catch {
                skillEvaluationStatusText = "Codex review failed: \(error.localizedDescription)"
            }
            isSkillEvaluating = false
            runQueuedStatusRefreshIfNeeded()
        }
    }

    @discardableResult
    func updateSkillIcon(path: String, pngData: Data) -> Bool {
        runOperation(
            title: "Update skill icon",
            runningText: "Updating skill icon..."
        ) {
            let report = try MetagentCore.updateSkillIcon(skillPath: path, pngData: pngData)
            return CommandOutcome(
                succeeded: true,
                lines: [
                    "updated \(report.iconPath)",
                    "updated \(report.metadataPath)"
                ],
                repairPreview: nil
            )
        } completion: { [weak self] result in
            if result.succeeded {
                self?.refreshStatus()
            }
        }
    }

    func repairNow() {
        guard !isRunning, let repairPreview, repairPreview.canApply else { return }
        let roots = repairPreview.projects.map(\.root)
        runOperation(
            title: "Resolve Cleanup",
            runningText: "Applying cleanup..."
        ) {
            let report = try MetagentCore.repairSkills(options: SkillsRepairOptions(
                apply: true,
                scanOptions: SkillScanOptions(
                    roots: roots,
                    maxDepth: 0,
                    respectConfiguredIgnores: false
                ),
                approvedCodexProjectionPaths: repairPreview.plannedCodexProjectionPaths,
                approvedActionsByProject: repairPreview.actionsByProject
            ))
            return CommandOutcome(succeeded: true, lines: Self.renderRepairReport(report), repairPreview: nil)
        } completion: { [weak self] result in
            if result.succeeded {
                self?.refreshStatus()
            }
        }
    }

    func previewRepair(projectRoot: String? = nil) {
        guard !isRunning else { return }
        repairPreview = nil
        showsRawOutput = false
        let scanOptions = projectRoot.map {
            SkillScanOptions(roots: [$0], maxDepth: 0, respectConfiguredIgnores: false)
        } ?? SkillScanOptions()
        runOperation(
            title: "Cleanup Preview",
            runningText: "Preparing cleanup preview..."
        ) {
            let report = try MetagentCore.repairSkills(options: SkillsRepairOptions(scanOptions: scanOptions))
            return CommandOutcome(
                succeeded: true,
                lines: Self.renderRepairReport(report),
                repairPreview: RepairPreview(report: report)
            )
        } completion: { [weak self] result in
            guard let self, result.succeeded else { return }
            repairPreview = result.repairPreview
            showsRawOutput = false
            lastOutputWasFailure = false
            lastOutputTitle = nil
            statusText = "\(repoCount) locations, \(skillCount) skills"
            systemImage = problemCount == 0 ? "checkmark.circle" : "exclamationmark.triangle"
        }
    }

    func runDoctor() {
        runOperation(
            title: "Skills Doctor",
            runningText: "Running doctor..."
        ) {
            let report = try MetagentCore.doctor()
            return CommandOutcome(
                succeeded: report.failureCount == 0,
                lines: report.issues.map { "\($0.severity.rawValue): \($0.message)" },
                repairPreview: nil,
                doctorReport: report
            )
        } completion: { [weak self] result in
            guard let report = result.doctorReport else { return }
            self?.applyDoctorReport(report)
        }
    }

    func refreshArchivedSkills() {
        archivedSkills = MetagentCore.listArchivedSkills()
    }

    /// Sets skills aside in the Archived Skills folder. Unlike removal this is
    /// always a plain file move, so one operation covers the whole batch and a
    /// status refresh picks up the result.
    @discardableResult
    func archiveSkills(_ requests: [SkillRemovalRequest]) -> Bool {
        guard !requests.isEmpty else { return false }
        return runOperation(
            title: requests.count == 1 ? "Archive skill" : "Archive \(requests.count) skills",
            runningText: requests.count == 1
                ? "Archiving \(requests[0].displayName)…"
                : "Archiving \(requests.count) skills…"
        ) {
            let report = MetagentCore.archiveSkills(targets: requests, apply: true)
            return CommandOutcome(
                succeeded: report.outcomes.allSatisfy(\.succeeded),
                lines: report.outcomes.flatMap { outcome in
                    ["\(outcome.target.displayName):"]
                        + outcome.lines.map { "  \($0)" }
                        + (outcome.failureMessage.map { ["  error: \($0)"] } ?? [])
                },
                repairPreview: nil
            )
        } completion: { [weak self] _ in
            self?.refreshArchivedSkills()
            self?.refreshStatus()
        }
    }

    /// Brings an archived skill back to its recorded canonical path and
    /// projections, then refreshes inventory so it reappears in the table.
    @discardableResult
    func restoreArchivedSkill(named skillName: String) -> Bool {
        runOperation(
            title: "Restore skill",
            runningText: "Restoring \(skillName)…"
        ) {
            let report = try MetagentCore.restoreArchivedSkill(named: skillName)
            return CommandOutcome(
                succeeded: true,
                lines: report.lines,
                repairPreview: nil
            )
        } completion: { [weak self] _ in
            self?.refreshArchivedSkills()
            self?.refreshStatus()
        }
    }

    @discardableResult
    func uninstallSkills(_ requests: [SkillRemovalRequest]) -> Bool {
        guard !isRunning || isRemovingSkills else { return false }
        let uniqueRequests = Dictionary(requests.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            .values
            .filter { !pendingSkillRemovalIDs.contains($0.id) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        guard !uniqueRequests.isEmpty else { return false }

        if !isRemovingSkills {
            accumulatedSkillRemovalLines = []
            accumulatedSkillRemovalFailedIDs = []
            isRemovingSkills = true
            isRunning = true
        }
        pendingSkillRemovalIDs.formUnion(uniqueRequests.map(\.id))
        skillTableRevision += 1
        statusText = uniqueRequests.count == 1
            ? "Removing \(uniqueRequests[0].displayName)…"
            : "Removing \(uniqueRequests.count) skills…"
        systemImage = "arrow.triangle.2.circlepath"

        let groups = Dictionary(grouping: uniqueRequests, by: Self.skillRemovalQueueKey)
        for (key, group) in groups {
            skillRemovalQueues[key, default: []].append(group)
            startNextSkillRemoval(for: key)
        }
        return true
    }

    private static func skillRemovalQueueKey(_ request: SkillRemovalRequest) -> String {
        switch request.method {
        case .canonical, .standalone:
            return "root:\(request.projectRoot ?? request.id)"
        case .codexPlugin:
            return "plugin:\(request.pluginID ?? request.id)"
        }
    }

    private func startNextSkillRemoval(for key: String) {
        guard !activeSkillRemovalKeys.contains(key),
              var queue = skillRemovalQueues[key],
              !queue.isEmpty
        else { return }

        let requests = queue.removeFirst()
        skillRemovalQueues[key] = queue.isEmpty ? nil : queue
        activeSkillRemovalKeys.insert(key)

        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Self.performSkillRemovals(requests)
            }.value
            finishSkillRemoval(outcome, key: key)
        }
    }

    nonisolated private static func performSkillRemovals(
        _ requests: [SkillRemovalRequest]
    ) -> SkillRemovalOutcome {
        let batch = MetagentCore.removeSkills(targets: requests, apply: true)
        return SkillRemovalOutcome(
            succeededIDs: batch.succeededIDs,
            failedIDs: batch.failedIDs,
            reconciliationIDs: batch.reconciliationIDs,
            lines: batch.lines
        )
    }

    private func finishSkillRemoval(_ outcome: SkillRemovalOutcome, key: String) {
        activeSkillRemovalKeys.remove(key)
        pendingSkillRemovalIDs.subtract(outcome.failedIDs.subtracting(outcome.reconciliationIDs))
        completedSkillRemovalIDs.formUnion(outcome.succeededIDs.union(outcome.reconciliationIDs))
        accumulatedSkillRemovalLines += outcome.lines
        accumulatedSkillRemovalFailedIDs.formUnion(outcome.failedIDs)
        skillTableRevision += 1
        lastRunText = Self.timestamp()

        startNextSkillRemoval(for: key)
        guard activeSkillRemovalKeys.isEmpty, skillRemovalQueues.values.allSatisfy(\.isEmpty) else {
            statusText = "Removing \(pendingSkillRemovalIDs.count) skills…"
            systemImage = "arrow.triangle.2.circlepath"
            return
        }

        let hadFailures = !accumulatedSkillRemovalFailedIDs.isEmpty
        lastOutputWasFailure = hadFailures
        lastOutputTitle = hadFailures ? "Some skills could not be removed" : "Remove skills"
        lastOutputLines = accumulatedSkillRemovalLines
        statusText = hadFailures ? "Some skill removals failed" : "Skill removal finished"
        systemImage = hadFailures ? "exclamationmark.triangle" : "checkmark.circle"
        accumulatedSkillRemovalLines = []
        accumulatedSkillRemovalFailedIDs = []
        if completedSkillRemovalIDs.isEmpty {
            isRemovingSkills = false
            finishRunningOperation()
        }
        reconcileCompletedSkillRemovalsIfIdle()
    }

    private func reconcileCompletedSkillRemovalsIfIdle() {
        guard activeSkillRemovalKeys.isEmpty,
              skillRemovalQueues.values.allSatisfy(\.isEmpty),
              !completedSkillRemovalIDs.isEmpty,
              !isReconcilingSkillRemovals
        else { return }

        isReconcilingSkillRemovals = true
        isRemovingSkills = false
        statusRefreshGeneration += 1
        let reconcilingIDs = completedSkillRemovalIDs
        Task {
            let (scan, homeScan, pluginScan) = await Self.scanInventory()

            let refreshedProjects = [
                scan.value?.projects,
                homeScan.value?.projects,
                pluginScan.value?.projects
            ]
            .compactMap { $0 }
            .flatMap { $0 }
            .map(ProjectStatus.init(project:))

            let didRefreshInventory = scan.isSuccess || homeScan.isSuccess || pluginScan.isSuccess
            if didRefreshInventory {
                projects = Self.mergeProjects(refreshedProjects)
                updateInventorySummary()
                MetagentCore.saveInventorySnapshot(SkillScanReport(projects: projects.map(\.coreProject), warnings: []))
                completedSkillRemovalIDs.subtract(reconcilingIDs)
                pendingSkillRemovalIDs.subtract(reconcilingIDs)
            } else {
                recordFailureOutput(
                    title: "Inventory refresh failed",
                    sources: [
                        ("Configured skills", scan.error),
                        ("Global skills", homeScan.error),
                        ("Codex plugins", pluginScan.error),
                    ]
                )
                statusText = "Removed skills; inventory refresh failed"
                systemImage = "exclamationmark.triangle"
            }
            isReconcilingSkillRemovals = false
            finishRunningOperation()
            skillTableRevision += 1
            if didRefreshInventory {
                reconcileCompletedSkillRemovalsIfIdle()
            }
        }
    }

    func toggleRawOutput() {
        showsRawOutput.toggle()
    }

    func copyLastOutput() {
        copyToPasteboard(lastOutputLines.joined(separator: "\n"))
    }

    func clearLastOutput() {
        lastOutputWasFailure = false
        lastOutputTitle = nil
        lastOutputLines = []
        showsRawOutput = false
    }

    var canDismissFailure: Bool {
        lastOutputWasFailure
    }

    var failureOutputTitle: String? {
        lastOutputWasFailure ? lastOutputTitle : nil
    }

    var failureOutputLines: [String] {
        lastOutputWasFailure ? lastOutputLines : []
    }

    func dismissFailure() {
        guard canDismissFailure else { return }
        clearLastOutput()
        statusText = "\(repoCount) locations, \(skillCount) skills"
        systemImage = problemCount == 0 ? "checkmark.circle" : "exclamationmark.triangle"
    }

    func copyRepairSummary() {
        guard let repairPreview else { return }
        copyToPasteboard(repairPreview.summaryText)
    }

    func openProject(_ project: RepairProjectPreview) {
        openProjectRoot(project.root)
    }

    func openProjectRoot(_ root: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: root))
    }

    func openConfig() {
        let configURL = homeURL()
            .appending(path: ".config")
            .appending(path: "metagent")
            .appending(path: "config.toml")
        NSWorkspace.shared.open(configURL)
    }

    func openLogs() {
        let logsURL = homeURL()
            .appending(path: "Library")
            .appending(path: "Logs")
            .appending(path: "metagent")
        NSWorkspace.shared.open(logsURL)
    }

    private func applyStatus(
        scan: Result<SkillScanReport, Error>,
        homeScan: Result<SkillScanReport, Error>,
        pluginScan: Result<SkillScanReport, Error>,
        doctor: Result<DoctorReport, Error>,
        evaluations: SkillEvaluationSnapshot,
        generation: Int
    ) {
        guard generation == statusRefreshGeneration else { return }
        skillEvaluations = evaluations
        lastRunText = Self.timestamp()

        let configuredProjects = scan.value?.projects.map(ProjectStatus.init(project:)) ?? []
        let homeProjects = homeScan.value?.projects.map(ProjectStatus.init(project:)) ?? []
        let pluginProjects = pluginScan.value?.projects.map(ProjectStatus.init(project:)) ?? []
        isPluginInventoryAvailable = pluginScan.isSuccess

        if scan.isSuccess || homeScan.isSuccess || pluginScan.isSuccess {
            projects = Self.mergeProjects(homeProjects + configuredProjects + pluginProjects)
            // Only release the optimistic hide when no removal is in flight.
            // Removal queues drain independently, and a refresh whose scan read
            // the disk before a queue's deletions would otherwise unhide those
            // rows against stale data — a one-frame resurrection in the table.
            if activeSkillRemovalKeys.isEmpty, !isRemovingSkills, !isReconcilingSkillRemovals {
                pendingSkillRemovalIDs.subtract(completedSkillRemovalIDs)
                completedSkillRemovalIDs.removeAll()
            }
            skillTableRevision += 1
            let warnings = pluginScan.error.map { ["Codex plugin inventory unavailable: \($0.localizedDescription)"] } ?? []
            MetagentCore.saveInventorySnapshot(SkillScanReport(projects: projects.map(\.coreProject), warnings: warnings))
            updateInventorySummary()
            rootsText = Self.rootsSummary(
                configuredProjects: configuredProjects,
                homeProjects: homeProjects,
                pluginProjects: pluginProjects,
                configuredScanSucceeded: scan.isSuccess,
                homeScanSucceeded: homeScan.isSuccess,
                pluginScanSucceeded: pluginScan.isSuccess
            )
        } else {
            projects = []
            skillTableRevision += 1
            repoCount = 0
            skillCount = 0
            locationSummaryText = "Skill locations unavailable"
            rootsText = "Roots unavailable"
        }

        if let doctorReport = doctor.value {
            var issues = doctorReport.issues
            if let pluginError = pluginScan.error {
                issues.append(DoctorIssue(
                    severity: .warning,
                    message: "Codex plugin inventory unavailable: \(pluginError.localizedDescription)",
                    summary: "Codex plugin inventory unavailable",
                    category: .skills,
                    guidance: "Confirm the Codex CLI is installed and `codex plugin list --json` succeeds."
                ))
            }
            applyDoctorReport(DoctorReport(issues: issues))
        } else {
            doctorIssues = []
            warningCount = 0
            failureCount = 0
        }

        if (scan.isSuccess || homeScan.isSuccess || pluginScan.isSuccess) && doctor.isSuccess {
            clearResolvedStatusFailure()
            statusText = "\(repoCount) locations, \(skillCount) skills"
            systemImage = problemCount == 0 ? "checkmark.circle" : "exclamationmark.triangle"
            recordHistory(trigger: hasCapturedHistory ? .refresh : .launch)
        } else {
            recordFailureOutput(
                title: "Status check failed",
                sources: [
                    ("Configured skills", scan.error),
                    ("Global skills", homeScan.error),
                    ("Codex plugins", pluginScan.error),
                    ("Skills Doctor", doctor.error),
                ]
            )
            statusText = "Status check failed"
            systemImage = "exclamationmark.triangle"
        }

        let inventoryResult: ProductAnalyticsResult
        if scan.isSuccess, homeScan.isSuccess, pluginScan.isSuccess, doctor.isSuccess {
            inventoryResult = .success
        } else if scan.isSuccess || homeScan.isSuccess || pluginScan.isSuccess {
            inventoryResult = .partial
        } else {
            inventoryResult = .failure
        }
        ProductAnalytics.shared.capture(.inventoryScanCompleted(
            result: inventoryResult,
            projectCount: repoCount,
            skillCount: skillCount,
            warningCount: warningCount,
            failureCount: failureCount
        ))

        finishRunningOperation()
    }

    /// Appends one sample to the portfolio history, at most once per local day.
    ///
    /// A scan that failed is never recorded: a partial inventory would read as a
    /// day when skills disappeared. The first capture of a session also seeds
    /// whatever history can be reconstructed from creation dates, the removal
    /// archive, and the usage event log.
    private func recordHistory(trigger: SkillHistoryTrigger) {
        // Inventory and usage refresh concurrently. Backfill reads the usage
        // database directly, so starting it while indexing is in flight can
        // reconstruct against a partial corpus. Queue the capture until the
        // indexer reaches its terminal state; the core also leaves an incomplete
        // backfill eligible to retry after a stall or an indexing failure.
        guard !isUsageRefreshing else {
            if pendingHistoryTrigger != .launch {
                pendingHistoryTrigger = trigger
            }
            return
        }
        let coreProjects = projects.map(\.coreProject)
        let usage = usageSnapshot
        let issues = doctorIssues
        let mcp = mcpHealth
        let shouldBackfill = !hasAttemptedHistoryBackfill
            || (historyBackfillAwaitingCompleteUsage && usage.isBackfillComplete)
        hasAttemptedHistoryBackfill = true
        historyBackfillAwaitingCompleteUsage = !usage.isBackfillComplete
        hasCapturedHistory = true
        Task.detached(priority: .background) {
            if shouldBackfill {
                // An incomplete first pass is retried when this session's usage
                // snapshot transitions to complete. Machines with no session
                // corpus do not rebuild the same history on every refresh.
                _ = try? MetagentCore.backfillSkillHistory(projects: coreProjects)
            }
            _ = try? MetagentCore.captureSkillHistory(
                projects: coreProjects,
                usage: usage,
                activity: MetagentCore.scanProjectActivity(roots: coreProjects.map(\.root)),
                doctorIssues: issues,
                mcp: mcp,
                trigger: trigger
            )
        }
    }

    private func applyDoctorReport(_ report: DoctorReport) {
        doctorIssues = report.issues
        warningCount = report.warningCount
        failureCount = report.failureCount
    }

    private func updateInventorySummary() {
        lastStatusAppliedAt = Date()
        // The project set may have changed, and each project's skills
        // directory is a watch root.
        startWatchingSkillRoots()
        repoCount = projects.count
        skillCount = Self.logicalSkillCount(projects: projects)
        locationSummaryText = Self.locationSummary(projects: projects)
    }

    private func recordFailureOutput(
        title: String,
        sources: [(String, Error?)]
    ) {
        lastOutputWasFailure = true
        lastOutputTitle = title
        lastOutputLines = sources.compactMap { label, error in
            error.map { "\(label): \($0.localizedDescription)" }
        }
        showsRawOutput = false
    }

    private func clearResolvedStatusFailure() {
        guard lastOutputWasFailure,
              let lastOutputTitle,
              ["Status check failed", "Inventory refresh failed"].contains(lastOutputTitle)
        else { return }
        clearLastOutput()
    }

    nonisolated private static func scanInventory() async -> (
        scan: Result<SkillScanReport, Error>,
        homeScan: Result<SkillScanReport, Error>,
        pluginScan: Result<SkillScanReport, Error>
    ) {
        async let scanResult = Task.detached {
            Result { try MetagentCore.scanSkills() }
        }.value
        async let homeScanResult = Task.detached {
            // Preserve shallow project discovery outside configured roots while
            // avoiding a concurrent rescan of roots such as ~/code_projects.
            Result {
                try MetagentCore.scanHomeSkills(
                    maxDepth: 2,
                    pruningConfiguredRoots: true
                )
            }
        }.value
        async let pluginScanResult = Task.detached {
            Result { try MetagentCore.scanCodexPlugins() }
        }.value
        return await (scanResult, homeScanResult, pluginScanResult)
    }

    nonisolated private static func doctorResult(
        scan: Result<SkillScanReport, Error>,
        homeScan: Result<SkillScanReport, Error>
    ) -> Result<DoctorReport, Error> {
        switch scan {
        case .failure(let error):
            return .failure(error)
        case .success(let report):
            let homeReport: SkillScanReport
            switch homeScan {
            case .failure(let error):
                return .failure(error)
            case .success(let report):
                homeReport = report
            }
            return .success(MetagentCore.doctor(reports: [report, homeReport]))
        }
    }

    @discardableResult
    private func runOperation(
        title: String,
        runningText: String,
        operation: @escaping @Sendable () throws -> CommandOutcome,
        completion: ((CommandOutcome) -> Void)? = nil
    ) -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        statusText = runningText
        systemImage = "arrow.triangle.2.circlepath"

        Task {
            let result = await Task.detached {
                do {
                    return try operation()
                } catch {
                    return CommandOutcome(succeeded: false, lines: [error.localizedDescription], repairPreview: nil)
                }
            }.value
            lastRunText = Self.timestamp()
            lastOutputWasFailure = !result.succeeded
            lastOutputTitle = title
            lastOutputLines = result.lines

            if result.succeeded {
                statusText = "\(title) finished"
                systemImage = "checkmark.circle"
            } else {
                statusText = "\(title) failed"
                systemImage = "exclamationmark.triangle"
                repairPreview = nil
                showsRawOutput = false
            }

            completion?(result)
            finishRunningOperation()
        }
        return true
    }

    nonisolated private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return "Last run \(formatter.string(from: Date()))"
    }

    nonisolated private static func usageStatus(_ snapshot: SkillUsageSnapshot) -> String {
        if snapshot.totalFiles == 0 {
            return "No retained Codex sessions found"
        }
        if snapshot.isBackfillComplete {
            return "Usage history current"
        }
        let progress = snapshot.totalBytes > 0
            ? Double(snapshot.processedBytes) / Double(snapshot.totalBytes)
            : 0
        if snapshot.isParserUpgradeBackfill {
            return "Updating Usage parser · \(progress.formatted(.percent.precision(.fractionLength(1))))"
        }
        return "Backfilling usage · \(progress.formatted(.percent.precision(.fractionLength(1))))"
    }

    nonisolated private static func mergeProjects(_ projects: [ProjectStatus]) -> [ProjectStatus] {
        var merged: [String: ProjectStatus] = [:]
        for project in projects {
            if let existing = merged[project.root] {
                merged[project.root] = existing.merged(with: project)
            } else {
                merged[project.root] = project
            }
        }

        return merged.values.sorted { left, right in
            if left.root == NSHomeDirectory() {
                return true
            }
            if right.root == NSHomeDirectory() {
                return false
            }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
    }

    nonisolated private static func locationSummary(projects: [ProjectStatus]) -> String {
        let agents = projects.reduce(0) { $0 + $1.agentsSkillCount }
        let codex = projects.reduce(0) { $0 + $1.codexSkillCount }
        let claude = projects.reduce(0) { $0 + $1.claudeSkillCount }
        let plugin = projects.reduce(0) { $0 + $1.pluginSkillCount }
        let skillsCLI = projects.reduce(0) { $0 + $1.agentsSkillCount(manager: "skills-cli") }
        let dotagents = projects.reduce(0) { $0 + $1.agentsSkillCount(manager: "dotagents") }
        let local = projects.reduce(0) { $0 + $1.agentsSkillCount(manager: "local") }
        let ownership = [
            skillsCLI > 0 ? "\(skillsCLI) skills CLI" : nil,
            dotagents > 0 ? "\(dotagents) dotagents" : nil,
            local > 0 ? "\(local) local" : nil
        ].compactMap { $0 }.joined(separator: ", ")

        return ".agents \(agents) (\(ownership)), plugins \(plugin), .codex \(codex), .claude \(claude)"
    }

    nonisolated private static func logicalSkillCount(projects: [ProjectStatus]) -> Int {
        Set(projects.flatMap { project in
            project.skills.map { "\(project.root)\u{0}\($0.name)" }
        }).count
    }

    nonisolated private static func rootsSummary(
        configuredProjects: [ProjectStatus],
        homeProjects: [ProjectStatus],
        pluginProjects: [ProjectStatus],
        configuredScanSucceeded: Bool,
        homeScanSucceeded: Bool,
        pluginScanSucceeded: Bool
    ) -> String {
        var labels: [String] = []
        if configuredScanSucceeded {
            labels.append("configured roots: \(configuredProjects.count)")
        }
        if homeScanSucceeded {
            labels.append("home scan: \(homeProjects.count)")
        }
        if pluginScanSucceeded {
            labels.append("plugins: \(pluginProjects.count)")
        }
        return labels.isEmpty ? "No roots scanned" : labels.joined(separator: ", ")
    }

    nonisolated private static func renderRepairReport(_ report: SkillsRepairReport) -> [String] {
        var lines = ["metagent skills repair: \(report.mode)"]
        for project in report.projects {
            lines.append("")
            lines.append("Project: \(project.root)")
            lines.append(contentsOf: project.lines.map { "  \($0.text)" })
        }
        return lines
    }

    private func homeURL() -> URL {
        fileManager.homeDirectoryForCurrentUser
    }
}

struct CommandOutcome: Sendable {
    let succeeded: Bool
    let lines: [String]
    let repairPreview: RepairPreview?
    var doctorReport: DoctorReport? = nil
}

struct ProjectStatus: Identifiable, Sendable {
    let id: String
    let root: String
    let validSkills: [String]
    let skills: [SkillStatus]

    var coreProject: SkillProject {
        SkillProject(
            root: root,
            skillsDir: skills.first?.location == "plugin"
                ? URL(fileURLWithPath: root).appendingPathComponent("skills").path
                : URL(fileURLWithPath: root).appendingPathComponent(".agents/skills").path,
            validSkills: validSkills,
            skills: skills.map(\.coreSkill)
        )
    }

    fileprivate init(project: SkillProject) {
        self.id = project.root
        self.root = project.root
        self.validSkills = project.validSkills
        self.skills = project.skills.map(SkillStatus.init(skill:))
    }

    var name: String {
        if skills.first?.location == "plugin", let authority = skills.first?.authority {
            return authority
        }
        return URL(fileURLWithPath: root).lastPathComponent
    }

    var agentsSkillCount: Int {
        skills.filter { $0.location == "agents" }.count
    }

    var codexSkillCount: Int {
        skills.filter { $0.location == "codex" }.count
    }

    var claudeSkillCount: Int {
        skills.filter { $0.location == "claude" }.count
    }

    var pluginSkillCount: Int {
        skills.filter { $0.location == "plugin" }.count
    }

    func agentsSkillCount(manager: String) -> Int {
        skills.filter { $0.location == "agents" && $0.manager == manager }.count
    }

    func merged(with other: ProjectStatus) -> ProjectStatus {
        var validSkills = self.validSkills
        for skill in other.validSkills where !validSkills.contains(skill) {
            validSkills.append(skill)
        }

        var skillsByID = Dictionary(uniqueKeysWithValues: skills.map { ($0.id, $0) })
        for skill in other.skills {
            skillsByID[skill.id] = skill
        }

        return ProjectStatus(
            id: id,
            root: root,
            validSkills: validSkills.sorted(),
            skills: skillsByID.values.sorted()
        )
    }

    private init(id: String, root: String, validSkills: [String], skills: [SkillStatus]) {
        self.id = id
        self.root = root
        self.validSkills = validSkills
        self.skills = skills
    }
}

#if DEBUG
extension ProjectStatus {
    /// Fixture builder for SwiftUI previews; production rows are always derived from scans.
    static func previewFixture(project: SkillProject) -> ProjectStatus {
        ProjectStatus(project: project)
    }
}
#endif

struct SkillStatus: Identifiable, Comparable, Sendable {
    let skill: SkillInventoryItem

    fileprivate init(skill: SkillInventoryItem) {
        self.skill = skill
    }

    var id: String { skill.id }
    var coreSkill: SkillInventoryItem { skill }

    var name: String { skill.name }
    var description: String? { skill.description }
    var path: String { skill.path }
    var location: String { skill.location }
    var locationLabel: String { skill.locationLabel }
    var originKind: String { skill.originKind }
    var scope: String { skill.scope }
    var manager: String { skill.manager }
    var authority: String { skill.authority }
    var mutability: String { skill.mutability }
    var representation: String { skill.representation }
    var canonicalPath: String { skill.canonicalPath }
    var source: String? { skill.source }
    var sourceType: String? { skill.sourceType }
    var sourceURL: String? { skill.sourceURL }
    var ref: String? { skill.ref }
    var updatedAt: String? { skill.updatedAt }
    var folderKind: String { skill.folderKind }
    var tokenEstimate: Int { skill.tokenEstimate }
    var referenceFileCount: Int { skill.referenceFileCount }
    var scriptFileCount: Int { skill.scriptFileCount }
    var assetFileCount: Int { skill.assetFileCount }
    var otherFileCount: Int { skill.otherFileCount }
    var iconSmallPath: String? { skill.iconSmallPath }
    var iconLargePath: String? { skill.iconLargePath }

    var originText: String? {
        switch manager {
        case "skills-cli":
            return "Skills CLI"
        case "dotagents":
            return "dotagents"
        case "external-cli":
            return authority
        case "local":
            return "Local / unknown"
        case "codex-plugin":
            return "Plugin"
        case "codex":
            return authority == "codex-system" ? "Codex system" : "Codex installed"
        case "claude":
            return "Claude installed"
        default:
            return "\(manager) · \(authority)"
        }
    }

    var tableOriginText: String {
        originText ?? (skill.symlinkedContainer ? "symlink mirror" : "n/a")
    }

    static func < (left: SkillStatus, right: SkillStatus) -> Bool {
        if left.location != right.location {
            return left.location < right.location
        }
        if left.name != right.name {
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
        return left.path < right.path
    }

}

struct RepairPreview: Sendable {
    let apply: Bool
    let mode: String
    let summary: RepairSummaryPreview
    let projects: [RepairProjectPreview]

    init(report: SkillsRepairReport) {
        self.apply = report.apply
        self.mode = report.mode
        self.summary = RepairSummaryPreview(summary: report.summary)
        self.projects = report.projects.map(RepairProjectPreview.init(project:))
    }

    var title: String {
        apply ? "Resolve Cleanup" : "Cleanup Preview"
    }

    var plannedCodexProjectionPaths: [String] {
        projects.flatMap(\.plannedCodexProjectionPaths)
    }

    var canApply: Bool {
        !projects.isEmpty && summary.actionCount > 0
    }

    var actionsByProject: [String: [String]] {
        Dictionary(uniqueKeysWithValues: projects.map { project in
            (project.root, project.actions.map(\.text).sorted())
        })
    }

    var summaryText: String {
        [
            "\(title): \(summary.projectCount) projects",
            "\(summary.validSkillCount) valid skills",
            "\(summary.actionCount) planned actions",
            "\(summary.warningCount) warnings"
        ].joined(separator: ", ")
    }
}

struct RepairSummaryPreview: Sendable {
    let projectCount: Int
    let validSkillCount: Int
    let warningCount: Int
    let actionCount: Int
    let skippedCount: Int

    init(summary: SkillsRepairSummary) {
        self.projectCount = summary.projectCount
        self.validSkillCount = summary.validSkillCount
        self.warningCount = summary.warningCount
        self.actionCount = summary.actionCount
        self.skippedCount = summary.skippedCount
    }
}

struct RepairProjectPreview: Identifiable, Sendable {
    let root: String
    let name: String
    let validSkillCount: Int
    let warningCount: Int
    let actionCount: Int
    let skippedCount: Int
    let lines: [RepairLinePreview]
    let plannedCodexProjectionPaths: [String]

    var id: String { root }

    init(project: SkillsRepairProject) {
        self.root = project.root
        self.name = project.name
        self.validSkillCount = project.validSkillCount
        self.warningCount = project.warningCount
        self.actionCount = project.actionCount
        self.skippedCount = project.skippedCount
        self.lines = project.lines.map(RepairLinePreview.init(line:))
        self.plannedCodexProjectionPaths = project.plannedCodexProjectionPaths
    }

    var displayName: String {
        name.isEmpty ? URL(fileURLWithPath: root).lastPathComponent : name
    }

    var actions: [RepairLinePreview] {
        lines.filter { $0.kind == .action }
    }

    var warnings: [RepairLinePreview] {
        lines.filter { $0.kind == .warning }
    }

    var skipped: [RepairLinePreview] {
        lines.filter { $0.kind == .skipped }
    }

    var info: [RepairLinePreview] {
        lines.filter { $0.kind == .info }
    }
}

struct RepairLinePreview: Identifiable, Sendable {
    let kind: RepairLineKind
    let text: String

    var id: String { "\(kind.rawValue)-\(text)" }

    init(line: SkillsRepairLine) {
        self.kind = RepairLineKind(rawValue: line.kind.rawValue) ?? .info
        self.text = line.text
    }
}

enum RepairLineKind: String, Sendable {
    case action
    case warning
    case skipped
    case info
}

private extension Result {
    var value: Success? {
        guard case .success(let value) = self else { return nil }
        return value
    }

    var isSuccess: Bool {
        guard case .success = self else { return false }
        return true
    }

    var error: Failure? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}
