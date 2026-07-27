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
    @Published private(set) var repairPreview: RepairPreview?
    @Published private(set) var showsRawOutput = false
    @Published private(set) var usageSnapshot = SkillUsageSnapshot.empty
    @Published private(set) var isUsageRefreshing = false
    @Published private(set) var usageStatusText = "Usage history not scanned"
    @Published private(set) var isUsageIndexingStalled = false
    @Published private(set) var skillEvaluations = SkillEvaluationSnapshot()
    @Published private(set) var isSkillEvaluating = false
    @Published private(set) var isSkillEvaluationRefreshing = false
    @Published private(set) var skillEvaluationStatusText: String?
    @Published private(set) var isPluginInventoryAvailable = false
    @Published private(set) var mcpHealth = MCPHealthSnapshot()
    @Published private(set) var isMCPRefreshing = false
    /// Measured codebase size per standardized project root. Only git
    /// repositories appear; everything else has no tracked codebase to size.
    @Published private(set) var codebaseSizes: [String: CodebaseSizeReport] = [:]
    @Published private(set) var isCodebaseSizeRefreshing = false
    @Published private(set) var skillTableRevision = 0
    @Published private(set) var pendingSkillRemovalIDs = Set<String>()
    @Published private(set) var isRemovingSkills = false

    private let fileManager = FileManager.default
    private var skillEvaluationRefreshGeneration = 0
    private var statusRefreshGeneration = 0
    private var statusRefreshQueued = false
    private var skillRemovalQueues: [String: [[SkillRemovalRequest]]] = [:]
    private var activeSkillRemovalKeys = Set<String>()
    private var completedSkillRemovalIDs = Set<String>()
    private var accumulatedSkillRemovalLines: [String] = []
    private var accumulatedSkillRemovalFailedIDs = Set<String>()
    private var isReconcilingSkillRemovals = false
    private var autoEvaluatedPaths = Set<String>()
    private var hasCapturedHistory = false
    private var hasAttemptedHistoryBackfill = false
    private var historyBackfillAwaitingCompleteUsage = false
    private var pendingHistoryTrigger: SkillHistoryTrigger?

    init() {
        if let snapshot = MetagentCore.loadInventorySnapshot() {
            projects = Self.mergeProjects(snapshot.projects.map(ProjectStatus.init(project:)))
            updateInventorySummary()
            rootsText = "cached SQLite snapshot"
            statusText = "\(repoCount) cached locations, \(skillCount) skills"
            systemImage = "externaldrive"
        }
        if let usage = MetagentCore.loadSkillUsageSnapshot() {
            usageSnapshot = usage
            usageStatusText = Self.usageStatus(usage)
        }
        refreshSkillEvaluations()
        refreshStatus()
        refreshUsage()
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
            return .working(progress: nil, label: skillEvaluationStatusText ?? "Evaluating skills…")
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
        guard !isRunning, !isSkillEvaluating, !isSkillEvaluationRefreshing else { return nil }
        let targetPath = standardizedDirectoryPath(canonicalPath)
        return InventorySkillRow.rows(
            from: projects,
            usage: usageSnapshot,
            evaluations: skillEvaluations
        ).first {
            standardizedDirectoryPath($0.canonicalPath) == targetPath
        }
    }

    func refreshStatus() {
        guard !isRunning else {
            statusRefreshQueued = true
            return
        }
        statusRefreshGeneration += 1
        let generation = statusRefreshGeneration
        isRunning = true
        refreshMCPHealth()
        statusText = "Checking status..."
        systemImage = "arrow.triangle.2.circlepath"
        coreStatusText = "Swift core"

        Task {
            async let doctorResult = Task.detached {
                Result { try MetagentCore.doctor() }
            }.value
            let (scan, homeScan, pluginScan) = await Self.scanInventory()
            let doctor = await doctorResult

            applyStatus(
                scan: scan,
                homeScan: homeScan,
                pluginScan: pluginScan,
                doctor: doctor,
                generation: generation
            )
        }
    }

    private func finishRunningOperation() {
        isRunning = false
        guard statusRefreshQueued else { return }
        statusRefreshQueued = false
        refreshStatus()
    }

    /// Sizes every known project root that is a git repository. This walks each
    /// repository's tracked files, so it runs off the main actor and replaces
    /// the published map only once the whole sweep finishes.
    func refreshCodebaseSizes() {
        guard !isCodebaseSizeRefreshing else { return }
        let roots = directoryFilterOptions(
            projects: projects,
            mcpHealth: mcpHealth,
            doctorIssues: doctorIssues
        ).map(\.root)
        guard !roots.isEmpty else {
            codebaseSizes = [:]
            return
        }

        isCodebaseSizeRefreshing = true
        Task {
            codebaseSizes = await Task.detached(priority: .utility) {
                MetagentCore.measureCodebaseSizes(roots: roots)
            }.value
            isCodebaseSizeRefreshing = false
        }
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

    func openMCPServer(_ server: MCPServerHealth) {
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
                self?.lastOutputTitle = "Could not open Claude"
                self?.lastOutputLines = [message.isEmpty
                    ? "osascript exited with status \(process.terminationStatus)"
                    : message]
                self?.showsRawOutput = true
            }
        }
        do {
            try process.run()
        } catch {
            lastOutputTitle = "Could not open Claude"
            lastOutputLines = [error.localizedDescription]
            showsRawOutput = true
        }
    }

    func refreshUsage() {
        guard !isUsageRefreshing else { return }
        isUsageRefreshing = true
        isUsageIndexingStalled = false
        usageStatusText = usageSnapshot.totalFiles == 0 ? "Discovering Codex history…" : "Updating usage history…"

        Task {
            do {
                while true {
                    let report = try await Task.detached(priority: .background) {
                        try autoreleasepool {
                            try MetagentCore.refreshSkillUsage(options: SkillUsageRefreshOptions(
                                maxBytes: 64 * 1_024 * 1_024,
                                maxFiles: 200,
                                throttleEveryBytes: 16 * 1_024 * 1_024,
                                throttleDelayMilliseconds: 500
                            ))
                        }
                    }.value
                    usageSnapshot = report.snapshot
                    skillTableRevision += 1
                    usageStatusText = Self.usageStatus(report.snapshot)
                    guard report.hasMore else { break }
                    guard report.processedBytesAdvanced > 0 else {
                        if let warning = report.warnings.first {
                            usageStatusText = "Usage backfill paused: \(warning)"
                        } else {
                            usageStatusText = "Usage backfill paused at an incomplete session record"
                        }
                        isUsageIndexingStalled = true
                        break
                    }
                    try await Task.sleep(for: .milliseconds(500))
                }
            } catch is CancellationError {
                usageStatusText = Self.usageStatus(usageSnapshot)
            } catch {
                usageStatusText = "Usage refresh failed: \(error.localizedDescription)"
                isUsageIndexingStalled = true
            }
            isUsageRefreshing = false
            if let trigger = pendingHistoryTrigger {
                pendingHistoryTrigger = nil
                recordHistory(trigger: trigger)
            }
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
        guard !isSkillEvaluating else { return }
        let missing = paths.filter {
            skillEvaluations.records[$0] == nil && !autoEvaluatedPaths.contains($0)
        }
        guard !missing.isEmpty else { return }
        autoEvaluatedPaths.formUnion(missing)
        evaluateSkillsWithPluginEval(paths: missing)
    }

    func evaluateSkillsWithPluginEval(paths: [String]) {
        guard !isSkillEvaluating else { return }
        let uniquePaths = Array(Set(paths)).sorted()
        guard !uniquePaths.isEmpty else { return }
        skillEvaluationRefreshGeneration += 1
        isSkillEvaluating = true
        skillEvaluationStatusText = uniquePaths.count == 1
            ? "Running Plugin Eval…"
            : "Running Plugin Eval for \(uniquePaths.count) skills…"

        Task {
            var failedSkillNames: [String] = []
            var firstFailureDetail: String?
            for (index, path) in uniquePaths.enumerated() {
                do {
                    let record = try await Task.detached(priority: .utility) {
                        try MetagentCore.evaluateSkillWithPluginEval(at: path)
                    }.value
                    var snapshot = skillEvaluations
                    snapshot.applyPluginEvalResult(record)
                    skillEvaluations = snapshot
                    skillTableRevision += 1
                    skillEvaluationStatusText = uniquePaths.count == 1
                        ? "Plugin Eval complete"
                        : "Plugin Eval \(index + 1) of \(uniquePaths.count)"
                } catch {
                    failedSkillNames.append(URL(fileURLWithPath: path).lastPathComponent)
                    if firstFailureDetail == nil {
                        firstFailureDetail = error.localizedDescription
                    }
                    skillEvaluationStatusText = "Plugin Eval \(index + 1) of \(uniquePaths.count) · \(failedSkillNames.count) failed"
                }
            }
            if !failedSkillNames.isEmpty {
                let preview = failedSkillNames.prefix(3).joined(separator: ", ")
                let suffix = failedSkillNames.count > 3 ? ", …" : ""
                let detail = firstFailureDetail.map { " · \($0)" } ?? ""
                skillEvaluationStatusText = "Plugin Eval finished · \(failedSkillNames.count) failed: \(preview)\(suffix)\(detail)"
            }
            isSkillEvaluating = false
        }
    }

    func reviewSkillWithCodex(path: String) {
        guard !isSkillEvaluating else { return }
        skillEvaluationRefreshGeneration += 1
        isSkillEvaluating = true
        skillEvaluationStatusText = "Codex is reviewing \(URL(fileURLWithPath: path).lastPathComponent)…"
        Task {
            do {
                let record = try await Task.detached(priority: .utility) {
                    try MetagentCore.reviewSkillWithCodex(at: path)
                }.value
                var snapshot = skillEvaluations
                snapshot.applyCodexReviewResult(record)
                skillEvaluations = snapshot
                skillTableRevision += 1
                skillEvaluationStatusText = "Codex review complete"
            } catch {
                skillEvaluationStatusText = "Codex review failed: \(error.localizedDescription)"
            }
            isSkillEvaluating = false
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
        lastOutputTitle = nil
        lastOutputLines = []
        showsRawOutput = false
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
        generation: Int
    ) {
        guard generation == statusRefreshGeneration else { return }
        lastRunText = Self.timestamp()

        let configuredProjects = scan.value?.projects.map(ProjectStatus.init(project:)) ?? []
        let homeProjects = homeScan.value?.projects.map(ProjectStatus.init(project:)) ?? []
        let pluginProjects = pluginScan.value?.projects.map(ProjectStatus.init(project:)) ?? []
        isPluginInventoryAvailable = pluginScan.isSuccess

        if scan.isSuccess || homeScan.isSuccess || pluginScan.isSuccess {
            projects = Self.mergeProjects(homeProjects + configuredProjects + pluginProjects)
            pendingSkillRemovalIDs.subtract(completedSkillRemovalIDs)
            completedSkillRemovalIDs.removeAll()
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

        refreshCodebaseSizes()

        if (scan.isSuccess || homeScan.isSuccess || pluginScan.isSuccess) && doctor.isSuccess {
            statusText = "\(repoCount) locations, \(skillCount) skills"
            systemImage = problemCount == 0 ? "checkmark.circle" : "exclamationmark.triangle"
            recordHistory(trigger: hasCapturedHistory ? .refresh : .launch)
        } else {
            statusText = "Status check failed"
            systemImage = "exclamationmark.triangle"
        }

        refreshSkillEvaluations {
            self.finishRunningOperation()
        }
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
        repoCount = projects.count
        skillCount = Self.logicalSkillCount(projects: projects)
        locationSummaryText = Self.locationSummary(projects: projects)
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
            Result { try MetagentCore.scanHomeSkills(maxDepth: 2) }
        }.value
        async let pluginScanResult = Task.detached {
            Result { try MetagentCore.scanCodexPlugins() }
        }.value
        return await (scanResult, homeScanResult, pluginScanResult)
    }

    private func refreshSkillEvaluations(completion: (() -> Void)? = nil) {
        guard !isSkillEvaluating else {
            completion?()
            return
        }
        skillEvaluationRefreshGeneration += 1
        let generation = skillEvaluationRefreshGeneration
        isSkillEvaluationRefreshing = true
        Task {
            let snapshot = await Task.detached(priority: .utility) {
                MetagentCore.loadSkillEvaluationSnapshot()
            }.value
            guard generation == skillEvaluationRefreshGeneration else { return }
            skillEvaluations = snapshot
            skillTableRevision += 1
            isSkillEvaluationRefreshing = false
            completion?()
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
