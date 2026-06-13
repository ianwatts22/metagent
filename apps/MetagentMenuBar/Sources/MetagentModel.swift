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
    @Published private(set) var rootsText = "Checking roots..."
    @Published private(set) var locationSummaryText = "Checking skill locations..."
    @Published private(set) var backgroundStatus = "Checking background sync..."
    @Published private(set) var projects: [ProjectStatus] = []
    @Published private(set) var lastOutputTitle: String?
    @Published private(set) var lastOutputLines: [String] = []
    @Published private(set) var syncPreview: SyncPreview?
    @Published private(set) var showsRawOutput = false

    private let fileManager = FileManager.default

    init() {
        if let snapshot = MetagentCore.loadInventorySnapshot() {
            projects = Self.mergeProjects(snapshot.projects.map(ProjectStatus.init(project:)))
            repoCount = projects.count
            skillCount = projects.reduce(0) { $0 + $1.skillCount }
            locationSummaryText = Self.locationSummary(projects: projects)
            rootsText = "cached SQLite snapshot"
            statusText = "\(repoCount) cached locations, \(skillCount) skill entries"
            systemImage = "externaldrive"
        }
        refreshStatus()
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
        return "\(warningCount) warnings"
    }

    var skillInventory: [SkillStatus] {
        projects.flatMap { $0.skills }.sorted()
    }

    var refreshPolicyText: String {
        "Launch/manual refresh; SQLite snapshot, no polling"
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
            async let launchAgentResult = Task.detached {
                MetagentCore.launchAgentStatus()
            }.value

            let (scan, homeScan, doctor, launchAgent) = await (
                scanResult,
                homeScanResult,
                doctorResult,
                launchAgentResult
            )

            applyStatus(
                scan: scan,
                homeScan: homeScan,
                doctor: doctor,
                launchAgent: launchAgent
            )
        }
    }

    func syncNow() {
        guard !isRunning else { return }
        runOperation(
            title: "Skills Sync",
            runningText: "Syncing skills..."
        ) {
            let report = try MetagentCore.syncSkills(options: SkillsSyncOptions(apply: true))
            return CommandOutcome(succeeded: true, lines: Self.renderSyncReport(report), syncPreview: nil)
        } completion: { [weak self] result in
            if result.succeeded {
                self?.refreshStatus()
            }
        }
    }

    func dryRunSkillsSync() {
        runOperation(
            title: "Skills Sync Dry Run",
            runningText: "Checking sync plan..."
        ) {
            let report = try MetagentCore.syncSkills()
            return CommandOutcome(
                succeeded: true,
                lines: Self.renderSyncReport(report),
                syncPreview: SyncPreview(report: report)
            )
        } completion: { [weak self] result in
            self?.syncPreview = result.syncPreview
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
                syncPreview: nil
            )
        }
    }

    func installBackgroundSync() {
        runOperation(
            title: "Install Background Sync",
            runningText: "Installing background sync..."
        ) {
            CommandOutcome(
                succeeded: true,
                lines: try MetagentCore.installLaunchAgent().lines,
                syncPreview: nil
            )
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
                syncPreview: nil
            )
        }
    }

    func toggleRawOutput() {
        showsRawOutput.toggle()
    }

    func clearSyncPreview() {
        syncPreview = nil
        showsRawOutput = false
    }

    func copyLastOutput() {
        let text = lastOutputLines.joined(separator: "\n")
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func copySyncSummary() {
        guard let syncPreview else { return }
        let text = syncPreview.summaryText
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func openProject(_ project: SyncProjectPreview) {
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
        doctor: Result<DoctorReport, Error>,
        launchAgent: LaunchAgentReport
    ) {
        isRunning = false
        lastRunText = Self.timestamp()

        let configuredProjects = scan.value?.projects.map(ProjectStatus.init(project:)) ?? []
        let homeProjects = homeScan.value?.projects.map(ProjectStatus.init(project:)) ?? []

        if scan.isSuccess || homeScan.isSuccess {
            projects = Self.mergeProjects(homeProjects + configuredProjects)
            MetagentCore.saveInventorySnapshot(SkillScanReport(projects: projects.map(\.coreProject)))
            repoCount = projects.count
            skillCount = projects.reduce(0) { $0 + $1.skillCount }
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

        let doctorReport = doctor.value
        warningCount = doctorReport?.warningCount ?? 0
        failureCount = doctorReport?.failureCount ?? 0

        backgroundStatus = Self.backgroundStatus(from: launchAgent.lines)

        if (scan.isSuccess || homeScan.isSuccess) && doctor.isSuccess {
            statusText = "\(repoCount) locations, \(skillCount) skill entries"
            systemImage = problemCount == 0 ? "checkmark.circle" : "exclamationmark.triangle"
        } else {
            statusText = "Status check failed"
            systemImage = "exclamationmark.triangle"
        }
    }

    private func runOperation(
        title: String,
        runningText: String,
        operation: @escaping () throws -> CommandOutcome,
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
                    return CommandOutcome(succeeded: false, lines: [error.localizedDescription], syncPreview: nil)
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
                syncPreview = nil
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

    nonisolated private static func backgroundStatus(from lines: [String]) -> String {
        let text = lines.joined(separator: "\n")
        if text.contains("launchctl status: loaded") {
            return "Loaded"
        }
        if text.contains("plist exists") {
            return "Installed, not loaded"
        }
        if text.contains("plist missing") {
            return "Not installed"
        }
        return "Unknown"
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

    nonisolated private static func renderSyncReport(_ report: SkillsSyncReport) -> [String] {
        var lines = ["metagent skills sync: \(report.mode)"]
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

struct CommandOutcome {
    let succeeded: Bool
    let lines: [String]
    let syncPreview: SyncPreview?
}

struct ProjectStatus: Identifiable {
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

struct SkillStatus: Identifiable, Comparable {
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

struct SyncPreview: Decodable {
    let apply: Bool
    let mode: String
    let summary: SyncSummaryPreview
    let projects: [SyncProjectPreview]

    init(report: SkillsSyncReport) {
        self.apply = report.apply
        self.mode = report.mode
        self.summary = SyncSummaryPreview(summary: report.summary)
        self.projects = report.projects.map(SyncProjectPreview.init(project:))
    }

    var title: String {
        apply ? "Skills Sync" : "Skills Sync Dry Run"
    }

    var summaryText: String {
        [
            "\(title): \(summary.projectCount) projects",
            "\(summary.validSkillCount) valid skills",
            "\(summary.actionCount) planned actions",
            "\(summary.warningCount) warnings",
            "\(summary.dotagentsCount) dotagents syncs"
        ].joined(separator: ", ")
    }
}

struct SyncSummaryPreview: Decodable {
    let projectCount: Int
    let validSkillCount: Int
    let warningCount: Int
    let actionCount: Int
    let skippedCount: Int
    let dotagentsCount: Int

    init(summary: SkillsSyncSummary) {
        self.projectCount = summary.projectCount
        self.validSkillCount = summary.validSkillCount
        self.warningCount = summary.warningCount
        self.actionCount = summary.actionCount
        self.skippedCount = summary.skippedCount
        self.dotagentsCount = summary.dotagentsCount
    }

    private enum CodingKeys: String, CodingKey {
        case projectCount = "project_count"
        case validSkillCount = "valid_skill_count"
        case warningCount = "warning_count"
        case actionCount = "action_count"
        case skippedCount = "skipped_count"
        case dotagentsCount = "dotagents_count"
    }
}

struct SyncProjectPreview: Decodable, Identifiable {
    let root: String
    let name: String
    let validSkillCount: Int
    let warningCount: Int
    let actionCount: Int
    let skippedCount: Int
    let usesDotagents: Bool
    let lines: [SyncLinePreview]

    var id: String { root }

    init(project: SkillsSyncProject) {
        self.root = project.root
        self.name = project.name
        self.validSkillCount = project.validSkillCount
        self.warningCount = project.warningCount
        self.actionCount = project.actionCount
        self.skippedCount = project.skippedCount
        self.usesDotagents = project.usesDotagents
        self.lines = project.lines.map(SyncLinePreview.init(line:))
    }

    var displayName: String {
        name.isEmpty ? URL(fileURLWithPath: root).lastPathComponent : name
    }

    var actions: [SyncLinePreview] {
        lines.filter { $0.kind == .action }
    }

    var warnings: [SyncLinePreview] {
        lines.filter { $0.kind == .warning }
    }

    var skipped: [SyncLinePreview] {
        lines.filter { $0.kind == .skipped }
    }

    var info: [SyncLinePreview] {
        lines.filter { $0.kind == .info }
    }

    private enum CodingKeys: String, CodingKey {
        case root
        case name
        case validSkillCount = "valid_skill_count"
        case warningCount = "warning_count"
        case actionCount = "action_count"
        case skippedCount = "skipped_count"
        case usesDotagents = "uses_dotagents"
        case lines
    }

}

struct SyncLinePreview: Decodable, Identifiable {
    let kind: SyncLineKind
    let text: String

    var id: String { "\(kind.rawValue)-\(text)" }

    init(line: SkillsSyncLine) {
        self.kind = SyncLineKind(rawValue: line.kind.rawValue) ?? .info
        self.text = line.text
    }
}

enum SyncLineKind: String, Decodable {
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
