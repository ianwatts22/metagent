import AppKit
import Foundation
import MetagentCore
import SwiftUI

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

    private let fileManager = FileManager.default

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
        refreshStatus()
        refreshUsage()
    }

    var problemCount: Int {
        warningCount + failureCount
    }

    var problemText: String {
        if problemCount == 0 {
            return "No doctor issues"
        }
        if failureCount > 0 {
            return "\(failureCount) fail, \(warningCount) warn"
        }
        if doctorReviewCount > 0, doctorRepairableCount > 0 {
            return "\(doctorRepairableCount) repairable, \(doctorReviewCount) review"
        }
        if doctorRepairableCount > 0 {
            return "\(doctorRepairableCount) repairable"
        }
        return "\(doctorReviewCount) to review"
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
        isRunning = true
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
            async let doctorResult = Task.detached {
                Result { try MetagentCore.doctor() }
            }.value
            let (scan, homeScan, doctor) = await (
                scanResult,
                homeScanResult,
                doctorResult
            )

            applyStatus(
                scan: scan,
                homeScan: homeScan,
                doctor: doctor
            )
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
                        try MetagentCore.refreshSkillUsage(options: SkillUsageRefreshOptions(
                            maxBytes: 32 * 1_024 * 1_024,
                            maxFiles: 100,
                            throttleEveryBytes: 8 * 1_024 * 1_024,
                            throttleDelayMilliseconds: 750
                        ))
                    }.value
                    usageSnapshot = report.snapshot
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
                    try await Task.sleep(for: .seconds(1))
                }
            } catch is CancellationError {
                usageStatusText = Self.usageStatus(usageSnapshot)
            } catch {
                usageStatusText = "Usage refresh failed: \(error.localizedDescription)"
            }
            isUsageRefreshing = false
        }
    }

    func repairNow() {
        guard !isRunning else { return }
        runOperation(
            title: "Repair Skill Links",
            runningText: "Repairing skill links..."
        ) {
            let report = try MetagentCore.repairSkills(options: SkillsRepairOptions(apply: true))
            return CommandOutcome(succeeded: true, lines: Self.renderRepairReport(report), repairPreview: nil)
        } completion: { [weak self] result in
            if result.succeeded {
                self?.refreshStatus()
            }
        }
    }

    func previewRepair() {
        runOperation(
            title: "Repair Preview",
            runningText: "Checking skill links..."
        ) {
            let report = try MetagentCore.repairSkills()
            return CommandOutcome(
                succeeded: true,
                lines: Self.renderRepairReport(report),
                repairPreview: RepairPreview(report: report)
            )
        } completion: { [weak self] result in
            self?.repairPreview = result.repairPreview
            self?.showsRawOutput = false
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
            let report = try MetagentCore.uninstallSkill(projectRoot: projectRoot, skillName: skillName)
            return CommandOutcome(succeeded: true, lines: report.lines, repairPreview: nil)
        } completion: { [weak self] result in
            if result.succeeded {
                self?.refreshStatus()
            }
        }
    }

    func runMorphStatus() {
        runOperation(
            title: "Morph MCP Status",
            runningText: "Checking morph-mcp..."
        ) {
            CommandOutcome(
                succeeded: true,
                lines: try MetagentCore.morphMCPStatus().lines,
                repairPreview: nil
            )
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

    func restartMenuBar() {
        guard !isRunning else { return }
        statusText = "Restarting app..."
        systemImage = "arrow.clockwise.circle"

        do {
            try Self.startReplacementProcess()
            NSApplication.shared.terminate(nil)
        } catch {
            statusText = "Restart failed"
            systemImage = "exclamationmark.triangle"
            lastOutputTitle = "Restart App"
            lastOutputLines = [error.localizedDescription]
        }
    }

    private func applyStatus(
        scan: Result<SkillScanReport, Error>,
        homeScan: Result<SkillScanReport, Error>,
        doctor: Result<DoctorReport, Error>
    ) {
        isRunning = false
        lastRunText = Self.timestamp()

        let configuredProjects = scan.value?.projects.map(ProjectStatus.init(project:)) ?? []
        let homeProjects = homeScan.value?.projects.map(ProjectStatus.init(project:)) ?? []

        if scan.isSuccess || homeScan.isSuccess {
            projects = Self.mergeProjects(homeProjects + configuredProjects)
            MetagentCore.saveInventorySnapshot(SkillScanReport(projects: projects.map(\.coreProject)))
            repoCount = projects.count
            skillCount = Self.logicalSkillCount(projects: projects)
            locationSummaryText = Self.locationSummary(projects: projects)
            rootsText = Self.rootsSummary(
                configuredProjects: configuredProjects,
                homeProjects: homeProjects,
                configuredScanSucceeded: scan.isSuccess,
                homeScanSucceeded: homeScan.isSuccess
            )
        } else {
            projects = []
            repoCount = 0
            skillCount = 0
            locationSummaryText = "Skill locations unavailable"
            rootsText = "Roots unavailable"
        }

        if let doctorReport = doctor.value {
            applyDoctorReport(doctorReport)
        } else {
            doctorIssues = []
            warningCount = 0
            failureCount = 0
        }

        if (scan.isSuccess || homeScan.isSuccess) && doctor.isSuccess {
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

    private func runOperation(
        title: String,
        runningText: String,
        operation: @escaping @Sendable () throws -> CommandOutcome,
        completion: ((CommandOutcome) -> Void)? = nil
    ) {
        guard !isRunning else { return }
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
        let installed = projects.reduce(0) { $0 + $1.npxInstalledAgentsSkillCount }
        let native = projects.reduce(0) { $0 + $1.nativeAgentsSkillCount }

        return ".agents \(agents) (\(installed) npx, \(native) native), .codex \(codex), .claude \(claude)"
    }

    nonisolated private static func logicalSkillCount(projects: [ProjectStatus]) -> Int {
        Set(projects.flatMap { project in
            project.skills.map { "\(project.root)\u{0}\($0.name)" }
        }).count
    }

    nonisolated private static func rootsSummary(
        configuredProjects: [ProjectStatus],
        homeProjects: [ProjectStatus],
        configuredScanSucceeded: Bool,
        homeScanSucceeded: Bool
    ) -> String {
        var labels: [String] = []
        if configuredScanSucceeded {
            labels.append("configured roots: \(configuredProjects.count)")
        }
        if homeScanSucceeded {
            labels.append("home scan: \(homeProjects.count)")
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

    nonisolated private static func startReplacementProcess() throws {
        let process = Process()
        let bundleURL = Bundle.main.bundleURL

        if bundleURL.pathExtension == "app" {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", bundleURL.path]
        } else if let executableURL = Bundle.main.executableURL {
            process.executableURL = executableURL
            process.arguments = []
        } else {
            throw RestartError.missingExecutable
        }

        try process.run()
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
            skillsDir: URL(fileURLWithPath: root).appendingPathComponent(".agents/skills").path,
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
        URL(fileURLWithPath: root).lastPathComponent
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

    var npxInstalledAgentsSkillCount: Int {
        skills.filter { $0.location == "agents" && $0.originKind == "npx-skills" }.count
    }

    var nativeAgentsSkillCount: Int {
        skills.filter { $0.location == "agents" && $0.originKind == "native" }.count
    }

    var locationSummary: String {
        [
            agentsSkillCount > 0 ? ".agents \(agentsSkillCount)" : nil,
            codexSkillCount > 0 ? ".codex \(codexSkillCount)" : nil,
            claudeSkillCount > 0 ? ".claude \(claudeSkillCount)" : nil
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
    let path: String
    let location: String
    let locationLabel: String
    let originKind: String
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
            path: path,
            location: location,
            locationLabel: locationLabel,
            originKind: originKind,
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
        self.path = skill.path
        self.location = skill.location
        self.locationLabel = skill.locationLabel
        self.originKind = skill.originKind
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
        switch originKind {
        case "npx-skills":
            if let source, !source.isEmpty {
                return "npx: \(source)"
            }
            return "npx skills"
        case "native":
            return "native"
        default:
            return nil
        }
    }

    var tableOriginText: String {
        originText ?? (symlinkedContainer ? "symlink mirror" : "n/a")
    }

    var folderKindLabel: String {
        switch folderKind {
        case "npx-installed": "npx installed"
        case "agents-local": "agents local"
        case "codex-local": "codex local"
        case "claude-local": "claude local"
        case "symlinked": "symlinked"
        case "system": "system"
        case "native": "native"
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
        apply ? "Repair Skill Links" : "Repair Preview"
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

    var id: String { root }

    init(project: SkillsRepairProject) {
        self.root = project.root
        self.name = project.name
        self.validSkillCount = project.validSkillCount
        self.warningCount = project.warningCount
        self.actionCount = project.actionCount
        self.skippedCount = project.skippedCount
        self.lines = project.lines.map(RepairLinePreview.init(line:))
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
}

private enum RestartError: LocalizedError {
    case missingExecutable

    var errorDescription: String? {
        "Could not resolve the current app executable."
    }
}
