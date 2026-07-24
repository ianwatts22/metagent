import AppKit
import Foundation
import MetagentCore
import SwiftUI

struct SkillRemovalRequest: Sendable {
    enum Kind: Sendable {
        case canonical(projectRoot: String, skillName: String)
        case standalone(projectRoot: String, skillPath: String, skillName: String)
        case plugin(pluginID: String)
    }

    let id: String
    let displayName: String
    let kind: Kind
}

private struct SkillRemovalOutcome: Sendable {
    let succeededIDs: Set<String>
    let failedIDs: Set<String>
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
    @Published private(set) var skillEvaluations = SkillEvaluationSnapshot()
    @Published private(set) var isSkillEvaluating = false
    @Published private(set) var skillEvaluationStatusText: String?
    @Published private(set) var isPluginInventoryAvailable = false
    @Published private(set) var mcpHealth = MCPHealthSnapshot()
    @Published private(set) var isMCPRefreshing = false
    @Published private(set) var skillTableRevision = 0
    @Published private(set) var pendingSkillRemovalIDs = Set<String>()
    @Published private(set) var isRemovingSkills = false

    private let fileManager = FileManager.default
    private var skillEvaluationRefreshGeneration = 0
    private var statusRefreshGeneration = 0
    private var skillRemovalQueues: [String: [[SkillRemovalRequest]]] = [:]
    private var activeSkillRemovalKeys = Set<String>()
    private var completedSkillRemovalIDs = Set<String>()
    private var accumulatedSkillRemovalLines: [String] = []
    private var accumulatedSkillRemovalFailedIDs = Set<String>()
    private var isReconcilingSkillRemovals = false

    init() {
        if let snapshot = MetagentCore.loadInventorySnapshot() {
            projects = Self.mergeProjects(snapshot.projects.map(ProjectStatus.init(project:)))
            repoCount = projects.count
            skillCount = Self.logicalSkillCount(projects: projects)
            locationSummaryText = Self.locationSummary(projects: projects)
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

    var problemCount: Int {
        warningCount + failureCount
    }

    var problemText: String {
        if doctorActionCount == 0 {
            return "No doctor issues"
        }
        if failureCount > 0 {
            return "\(failureCount) fail, \(warningCount) warn"
        }
        if doctorReviewCount > 0, doctorRepairableCount > 0 {
            return "\(doctorRepairableCount) fixable, \(doctorReviewCount) review"
        }
        if doctorRepairableCount > 0 {
            return "\(doctorRepairableCount) fixable"
        }
        return "\(doctorActionCount) \(doctorActionCount == 1 ? "cleanup" : "cleanups")"
    }

    var doctorRepairableCount: Int {
        doctorIssues.filter { $0.severity != .ok && $0.repairAction != nil }.count
    }

    var doctorReviewCount: Int {
        problemCount - doctorRepairableCount
    }

    var doctorFindings: [DoctorIssue] {
        doctorIssues.filter { $0.severity != .ok }
    }

    var doctorActionCount: Int {
        Set(doctorFindings.map { issue in
            [
                issue.projectRoot ?? "general",
                issue.category?.rawValue ?? "general",
                issue.repairAction?.rawValue ?? "review",
                issue.summary ?? issue.message
            ].joined(separator: "|")
        }).count
    }

    var skillInventory: [SkillStatus] {
        projects.flatMap { $0.skills }.sorted()
    }

    var logicalSkillCount: Int {
        Self.logicalSkillCount(projects: projects)
    }

    var refreshPolicyText: String {
        "Cached immediately; low-priority usage backfill, no polling"
    }

    var usageProgress: Double {
        guard usageSnapshot.totalBytes > 0 else { return 0 }
        return min(1, Double(usageSnapshot.processedBytes) / Double(usageSnapshot.totalBytes))
    }

    var usageProgressText: String {
        if usageSnapshot.totalFiles == 0 {
            return "No retained Codex sessions found"
        }
        let processed = ByteCountFormatter.string(fromByteCount: usageSnapshot.processedBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: usageSnapshot.totalBytes, countStyle: .file)
        return "\(processed) of \(total) · \(usageSnapshot.completedFiles)/\(usageSnapshot.totalFiles) files"
    }

    var usageCoverageText: String {
        if usageSnapshot.isParserUpgradeBackfill {
            return "Showing saved history while parser v\(usageSnapshot.targetParserVersion) updates"
        }
        guard let startedAt = usageSnapshot.coverageStartedAt,
              let date = MetagentCore.parseSkillUsageTimestamp(startedAt)
        else {
            return usageSnapshot.isBackfillComplete ? "No observed skill reads" : "Coverage building"
        }
        let formatted = date.formatted(date: .abbreviated, time: .omitted)
        return usageSnapshot.isBackfillComplete ? "Retained history since \(formatted)" : "Observed coverage currently reaches \(formatted)"
    }

    func refreshStatus() {
        guard !isRunning else { return }
        statusRefreshGeneration += 1
        let generation = statusRefreshGeneration
        isRunning = true
        refreshMCPHealth()
        statusText = "Checking status..."
        systemImage = "arrow.triangle.2.circlepath"
        coreStatusText = "Swift core"

        Task {
            async let scanResult = Task.detached {
                Result { try MetagentCore.scanSkills() }
            }.value
            async let homeScanResult = Task.detached {
                Result { try MetagentCore.scanHomeSkills(maxDepth: 2) }
            }.value
            async let pluginScanResult = Task.detached {
                Result { try MetagentCore.scanCodexPlugins() }
            }.value
            async let doctorResult = Task.detached {
                Result { try MetagentCore.doctor() }
            }.value
            let (scan, homeScan, pluginScan, doctor) = await (
                scanResult,
                homeScanResult,
                pluginScanResult,
                doctorResult
            )

            applyStatus(
                scan: scan,
                homeScan: homeScan,
                pluginScan: pluginScan,
                doctor: doctor,
                generation: generation
            )
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
                withBundleIdentifier: "com.openai.codex"
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
                        break
                    }
                    try await Task.sleep(for: .milliseconds(500))
                }
            } catch is CancellationError {
                usageStatusText = Self.usageStatus(usageSnapshot)
            } catch {
                usageStatusText = "Usage refresh failed: \(error.localizedDescription)"
            }
            isUsageRefreshing = false
        }
    }

    func evaluateSkillWithPluginEval(path: String) {
        evaluateSkillsWithPluginEval(paths: [path])
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
                    snapshot.records[record.canonicalPath] = record
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
                snapshot.records[record.canonicalPath] = record
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

    func uninstallSkill(projectRoot: String, skillName: String) {
        runOperation(
            title: "Uninstall \(skillName)",
            runningText: "Uninstalling \(skillName)..."
        ) {
            let report = try MetagentCore.uninstallSkill(
                projectRoot: projectRoot,
                skillName: skillName,
                allowManagedRemoval: true
            )
            return CommandOutcome(succeeded: true, lines: report.lines, repairPreview: nil)
        } completion: { [weak self] result in
            if result.succeeded {
                self?.refreshStatus()
            }
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
        switch request.kind {
        case let .canonical(projectRoot, _), let .standalone(projectRoot, _, _):
            return "root:\(projectRoot)"
        case let .plugin(pluginID):
            return "plugin:\(pluginID)"
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
        var succeededIDs = Set<String>()
        var failedIDs = Set<String>()
        var lines: [String] = []

        let canonical = requests.compactMap { request -> (SkillRemovalRequest, String, String)? in
            guard case let .canonical(projectRoot, skillName) = request.kind else { return nil }
            return (request, projectRoot, skillName)
        }
        if let projectRoot = canonical.first?.1 {
            let batch = MetagentCore.uninstallSkills(
                projectRoot: projectRoot,
                skillNames: canonical.map(\.2),
                allowManagedRemoval: true
            )
            let succeededNames = Set(batch.reports.map(\.skillName))
            let failedNames = Set(batch.failures.map(\.skillName))
            succeededIDs.formUnion(canonical.filter { succeededNames.contains($0.2) }.map(\.0.id))
            failedIDs.formUnion(canonical.filter { failedNames.contains($0.2) }.map(\.0.id))
            for report in batch.reports {
                lines.append("\(report.skillName):")
                lines.append(contentsOf: report.lines.map { "  \($0)" })
            }
            for failure in batch.failures {
                lines.append("\(failure.skillName): failed")
                lines.append("  \(failure.message)")
            }
        }

        for request in requests where !canonical.contains(where: { $0.0.id == request.id }) {
            do {
                let report: SkillUninstallReport
                switch request.kind {
                case .canonical:
                    continue
                case let .standalone(projectRoot, skillPath, skillName):
                    report = try MetagentCore.uninstallStandaloneSkill(
                        projectRoot: projectRoot,
                        skillPath: skillPath,
                        skillName: skillName
                    )
                case let .plugin(pluginID):
                    report = try MetagentCore.uninstallCodexPlugin(pluginID: pluginID)
                }
                succeededIDs.insert(request.id)
                lines.append("\(request.displayName):")
                lines.append(contentsOf: report.lines.map { "  \($0)" })
            } catch {
                failedIDs.insert(request.id)
                lines.append("\(request.displayName): failed")
                lines.append("  \(error.localizedDescription)")
            }
        }
        return SkillRemovalOutcome(
            succeededIDs: succeededIDs,
            failedIDs: failedIDs,
            lines: lines
        )
    }

    private func finishSkillRemoval(_ outcome: SkillRemovalOutcome, key: String) {
        activeSkillRemovalKeys.remove(key)
        pendingSkillRemovalIDs.subtract(outcome.failedIDs)
        completedSkillRemovalIDs.formUnion(outcome.succeededIDs)
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
            isRunning = false
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
            async let scanResult = Task.detached { Result { try MetagentCore.scanSkills() } }.value
            async let homeScanResult = Task.detached { Result { try MetagentCore.scanHomeSkills(maxDepth: 2) } }.value
            async let pluginScanResult = Task.detached { Result { try MetagentCore.scanCodexPlugins() } }.value
            let (scan, homeScan, pluginScan) = await (scanResult, homeScanResult, pluginScanResult)

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
                repoCount = projects.count
                skillCount = Self.logicalSkillCount(projects: projects)
                locationSummaryText = Self.locationSummary(projects: projects)
                MetagentCore.saveInventorySnapshot(SkillScanReport(projects: projects.map(\.coreProject), warnings: []))
                completedSkillRemovalIDs.subtract(reconcilingIDs)
                pendingSkillRemovalIDs.subtract(reconcilingIDs)
            } else {
                statusText = "Removed skills; inventory refresh failed"
                systemImage = "exclamationmark.triangle"
            }
            isReconcilingSkillRemovals = false
            isRunning = false
            skillTableRevision += 1
            if didRefreshInventory {
                reconcileCompletedSkillRemovalsIfIdle()
            }
        }
    }

    func toggleRawOutput() {
        showsRawOutput.toggle()
    }

    func clearRepairPreview() {
        repairPreview = nil
        showsRawOutput = false
    }

    func copyLastOutput() {
        let text = lastOutputLines.joined(separator: "\n")
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func clearLastOutput() {
        lastOutputTitle = nil
        lastOutputLines = []
        showsRawOutput = false
    }

    func copyRepairSummary() {
        guard let repairPreview else { return }
        let text = repairPreview.summaryText
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func openProject(_ project: RepairProjectPreview) {
        NSWorkspace.shared.open(URL(fileURLWithPath: project.root))
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
        refreshSkillEvaluations()
        isRunning = false
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
            repoCount = projects.count
            skillCount = Self.logicalSkillCount(projects: projects)
            locationSummaryText = Self.locationSummary(projects: projects)
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
            statusText = "\(repoCount) locations, \(skillCount) skills"
            systemImage = problemCount == 0 ? "checkmark.circle" : "exclamationmark.triangle"
        } else {
            statusText = "Status check failed"
            systemImage = "exclamationmark.triangle"
        }
    }

    private func applyDoctorReport(_ report: DoctorReport) {
        doctorIssues = report.issues
        warningCount = report.warningCount
        failureCount = report.failureCount
    }

    private func refreshSkillEvaluations() {
        guard !isSkillEvaluating else { return }
        skillEvaluationRefreshGeneration += 1
        let generation = skillEvaluationRefreshGeneration
        Task {
            let snapshot = await Task.detached(priority: .utility) {
                MetagentCore.loadSkillEvaluationSnapshot()
            }.value
            guard generation == skillEvaluationRefreshGeneration else { return }
            skillEvaluations = snapshot
            skillTableRevision += 1
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
            isRunning = false
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
    let doctorReport: DoctorReport?

    init(
        succeeded: Bool,
        lines: [String],
        repairPreview: RepairPreview?,
        doctorReport: DoctorReport? = nil
    ) {
        self.succeeded = succeeded
        self.lines = lines
        self.repairPreview = repairPreview
        self.doctorReport = doctorReport
    }
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

    var skillCount: Int {
        skills.count
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

    var locationSummary: String {
        [
            agentsSkillCount > 0 ? ".agents \(agentsSkillCount)" : nil,
            codexSkillCount > 0 ? ".codex \(codexSkillCount)" : nil,
            claudeSkillCount > 0 ? ".claude \(claudeSkillCount)" : nil,
            pluginSkillCount > 0 ? "plugins \(pluginSkillCount)" : nil
        ]
        .compactMap { $0 }
        .joined(separator: "  ")
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

struct SkillStatus: Identifiable, Comparable, Sendable {
    let name: String
    let description: String?
    let path: String
    let location: String
    let locationLabel: String
    let originKind: String
    let scope: String
    let manager: String
    let authority: String
    let mutability: String
    let representation: String
    let canonicalPath: String
    let source: String?
    let sourceType: String?
    let sourceURL: String?
    let ref: String?
    let installedAt: String?
    let updatedAt: String?
    let symlinkedContainer: Bool
    let folderKind: String
    let characterCount: Int
    let wordCount: Int
    let tokenEstimate: Int
    let skillFileCharacterCount: Int
    let skillFileWordCount: Int
    let skillFileTokenEstimate: Int
    let textFileCount: Int
    let referenceFileCount: Int
    let scriptFileCount: Int
    let assetFileCount: Int
    let otherFileCount: Int
    let otherFolderCount: Int
    let hasOpenAIYaml: Bool
    let hasIconSmall: Bool
    let hasIconLarge: Bool
    let hasIconAndLogo: Bool
    let iconSmallPath: String?
    let iconLargePath: String?

    var id: String {
        "\(location):\(path)"
    }

    var coreSkill: SkillInventoryItem {
        SkillInventoryItem(
            name: name,
            description: description,
            path: path,
            location: location,
            locationLabel: locationLabel,
            originKind: originKind,
            scope: scope,
            manager: manager,
            authority: authority,
            mutability: mutability,
            representation: representation,
            canonicalPath: canonicalPath,
            source: source,
            sourceType: sourceType,
            sourceURL: sourceURL,
            ref: ref,
            installedAt: installedAt,
            updatedAt: updatedAt,
            symlinkedContainer: symlinkedContainer,
            folderKind: folderKind,
            characterCount: characterCount,
            wordCount: wordCount,
            tokenEstimate: tokenEstimate,
            skillFileCharacterCount: skillFileCharacterCount,
            skillFileWordCount: skillFileWordCount,
            skillFileTokenEstimate: skillFileTokenEstimate,
            textFileCount: textFileCount,
            referenceFileCount: referenceFileCount,
            scriptFileCount: scriptFileCount,
            assetFileCount: assetFileCount,
            otherFileCount: otherFileCount,
            otherFolderCount: otherFolderCount,
            hasOpenAIYaml: hasOpenAIYaml,
            hasIconSmall: hasIconSmall,
            hasIconLarge: hasIconLarge,
            hasIconAndLogo: hasIconAndLogo,
            iconSmallPath: iconSmallPath,
            iconLargePath: iconLargePath
        )
    }

    fileprivate init(skill: SkillInventoryItem) {
        self.name = skill.name
        self.description = skill.description
        self.path = skill.path
        self.location = skill.location
        self.locationLabel = skill.locationLabel
        self.originKind = skill.originKind
        self.scope = skill.scope
        self.manager = skill.manager
        self.authority = skill.authority
        self.mutability = skill.mutability
        self.representation = skill.representation
        self.canonicalPath = skill.canonicalPath
        self.source = skill.source
        self.sourceType = skill.sourceType
        self.sourceURL = skill.sourceURL
        self.ref = skill.ref
        self.installedAt = skill.installedAt
        self.updatedAt = skill.updatedAt
        self.symlinkedContainer = skill.symlinkedContainer
        self.folderKind = skill.folderKind
        self.characterCount = skill.characterCount
        self.wordCount = skill.wordCount
        self.tokenEstimate = skill.tokenEstimate
        self.skillFileCharacterCount = skill.skillFileCharacterCount
        self.skillFileWordCount = skill.skillFileWordCount
        self.skillFileTokenEstimate = skill.skillFileTokenEstimate
        self.textFileCount = skill.textFileCount
        self.referenceFileCount = skill.referenceFileCount
        self.scriptFileCount = skill.scriptFileCount
        self.assetFileCount = skill.assetFileCount
        self.otherFileCount = skill.otherFileCount
        self.otherFolderCount = skill.otherFolderCount
        self.hasOpenAIYaml = skill.hasOpenAIYaml
        self.hasIconSmall = skill.hasIconSmall
        self.hasIconLarge = skill.hasIconLarge
        self.hasIconAndLogo = skill.hasIconAndLogo
        self.iconSmallPath = skill.iconSmallPath
        self.iconLargePath = skill.iconLargePath
    }

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
        originText ?? (symlinkedContainer ? "symlink mirror" : "n/a")
    }

    var folderKindLabel: String {
        switch folderKind {
        case "npx-installed": "npx installed"
        case "dotagents-local": "dotagents local"
        case "dotagents-managed": "dotagents managed"
        case "external-cli": "external CLI"
        case "user-local": "user local"
        case "project-local": "project local"
        case "agents-local", "native", "unmanaged": "unmanaged"
        case "codex-local": "codex local"
        case "claude-local": "claude local"
        case "symlinked": "symlinked"
        case "system": "system"
        case "versioned-cache": "versioned cache"
        default: folderKind
        }
    }

    var iconLogoText: String {
        if hasIconAndLogo {
            return "icon + logo"
        }
        if hasIconSmall {
            return "icon only"
        }
        if hasIconLarge {
            return "logo only"
        }
        if hasOpenAIYaml {
            return "metadata only"
        }
        return "none"
    }

    var locationSymbol: String {
        switch location {
        case "agents": "sparkles"
        case "codex": "chevron.left.forwardslash.chevron.right"
        case "claude": "link"
        default: "folder"
        }
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

struct RepairPreview: Decodable, Sendable {
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

struct RepairSummaryPreview: Decodable, Sendable {
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

    private enum CodingKeys: String, CodingKey {
        case projectCount = "project_count"
        case validSkillCount = "valid_skill_count"
        case warningCount = "warning_count"
        case actionCount = "action_count"
        case skippedCount = "skipped_count"
    }
}

struct RepairProjectPreview: Decodable, Identifiable, Sendable {
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

    private enum CodingKeys: String, CodingKey {
        case root
        case name
        case validSkillCount = "valid_skill_count"
        case warningCount = "warning_count"
        case actionCount = "action_count"
        case skippedCount = "skipped_count"
        case lines
        case plannedCodexProjectionPaths = "planned_codex_projection_paths"
    }

}

struct RepairLinePreview: Decodable, Identifiable, Sendable {
    let kind: RepairLineKind
    let text: String

    var id: String { "\(kind.rawValue)-\(text)" }

    init(line: SkillsRepairLine) {
        self.kind = RepairLineKind(rawValue: line.kind.rawValue) ?? .info
        self.text = line.text
    }
}

enum RepairLineKind: String, Decodable, Sendable {
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
