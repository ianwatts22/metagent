import AppKit
import Foundation
import SwiftUI

@MainActor
final class AgentToolsModel: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var statusText = "Checking status..."
    @Published private(set) var lastRunText: String?
    @Published private(set) var systemImage = "wrench.and.screwdriver"
    @Published private(set) var cliPathText = "Resolving CLI..."
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
        "Launch/manual refresh; in-memory snapshot, no polling"
    }

    func refreshStatus() {
        guard !isRunning else { return }
        isRunning = true
        statusText = "Checking status..."
        systemImage = "arrow.triangle.2.circlepath"
        cliPathText = Self.cliPath()
        let homePath = homeURL().path

        Task {
            async let scanResult = runAgentTools(arguments: ["skills", "scan", "--json"])
            async let homeScanResult = runAgentTools(
                arguments: ["skills", "scan", "--root", homePath, "--max-depth", "2", "--json"]
            )
            async let doctorResult = runAgentTools(arguments: ["skills", "doctor"])
            async let launchAgentResult = runAgentTools(arguments: ["launch-agent", "status"])

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
        runCommand(
            title: "Skills Sync",
            arguments: ["skills", "sync", "--apply"],
            runningText: "Syncing skills..."
        ) { [weak self] result in
            if result.exitCode == 0 {
                self?.refreshStatus()
            }
        }
    }

    func dryRunSkillsSync() {
        runCommand(
            title: "Skills Sync Dry Run",
            arguments: ["skills", "sync"],
            runningText: "Checking sync plan..."
        ) { [weak self] result in
            self?.syncPreview = result.exitCode == 0
                ? Self.syncPreview(from: result.stdout)
                : nil
            self?.showsRawOutput = false
        }
    }

    func runDoctor() {
        runCommand(
            title: "Skills Doctor",
            arguments: ["skills", "doctor"],
            runningText: "Running doctor..."
        )
    }

    func installBackgroundSync() {
        runCommand(
            title: "Install Background Sync",
            arguments: ["launch-agent", "install"],
            runningText: "Installing background sync..."
        ) { [weak self] result in
            if result.exitCode == 0 {
                self?.refreshStatus()
            }
        }
    }

    func runMorphStatus() {
        runCommand(
            title: "Morph MCP Status",
            arguments: ["morph-mcp", "status"],
            runningText: "Checking morph-mcp..."
        )
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
            .appending(path: "agent-tools")
            .appending(path: "config.toml")
        NSWorkspace.shared.open(configURL)
    }

    func openLogs() {
        let logsURL = homeURL()
            .appending(path: "Library")
            .appending(path: "Logs")
            .appending(path: "agent-tools")
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
        scan: ProcessResult,
        homeScan: ProcessResult,
        doctor: ProcessResult,
        launchAgent: ProcessResult
    ) {
        isRunning = false
        lastRunText = Self.timestamp()

        let configuredProjects = (try? JSONDecoder().decode(
            ScanReport.self,
            from: Data(scan.stdout.utf8)
        ))?.projects.map(ProjectStatus.init(project:)) ?? []
        let homeProjects = (try? JSONDecoder().decode(
            ScanReport.self,
            from: Data(homeScan.stdout.utf8)
        ))?.projects.map(ProjectStatus.init(project:)) ?? []

        if scan.exitCode == 0 || homeScan.exitCode == 0 {
            projects = Self.mergeProjects(homeProjects + configuredProjects)
            repoCount = projects.count
            skillCount = projects.reduce(0) { $0 + $1.skillCount }
            locationSummaryText = Self.locationSummary(projects: projects)
            rootsText = Self.rootsSummary(
                configuredProjects: configuredProjects,
                homeProjects: homeProjects,
                configuredScanSucceeded: scan.exitCode == 0,
                homeScanSucceeded: homeScan.exitCode == 0
            )
        } else {
            projects = []
            repoCount = 0
            skillCount = 0
            locationSummaryText = "Skill locations unavailable"
            rootsText = "Roots unavailable"
        }

        let doctorLines = doctor.stdout.lines
        warningCount = doctorLines.filter { $0.hasPrefix("WARN") }.count
        failureCount = doctorLines.filter { $0.hasPrefix("FAIL") }.count

        backgroundStatus = Self.backgroundStatus(from: launchAgent)

        if (scan.exitCode == 0 || homeScan.exitCode == 0) && doctor.exitCode == 0 {
            statusText = "\(repoCount) locations, \(skillCount) skill entries"
            systemImage = problemCount == 0 ? "checkmark.circle" : "exclamationmark.triangle"
        } else {
            statusText = "Status check failed"
            systemImage = "exclamationmark.triangle"
        }
    }

    private func runCommand(
        title: String,
        arguments: [String],
        runningText: String,
        completion: ((ProcessResult) -> Void)? = nil
    ) {
        guard !isRunning else { return }
        isRunning = true
        statusText = runningText
        systemImage = "arrow.triangle.2.circlepath"

        Task {
            let result = await runAgentTools(arguments: arguments)
            isRunning = false
            lastRunText = Self.timestamp()
            lastOutputTitle = title
            lastOutputLines = Self.outputLines(result: result)

            if result.exitCode == 0 {
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

    private func runAgentTools(arguments: [String]) async -> ProcessResult {
        await Task.detached {
            let process = Process()
            let cliPath = Self.cliPath()

            if cliPath == "/usr/bin/env" {
                process.executableURL = URL(fileURLWithPath: cliPath)
                process.arguments = ["agent-tools"] + arguments
            } else {
                process.executableURL = URL(fileURLWithPath: cliPath)
                process.arguments = arguments
            }

            let output = Pipe()
            let error = Pipe()
            process.standardOutput = output
            process.standardError = error

            do {
                try process.run()
                let stdout = output.fileHandleForReading.readDataToEndOfFile()
                let stderr = error.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return ProcessResult(
                    exitCode: process.terminationStatus,
                    stdout: String(data: stdout, encoding: .utf8) ?? "",
                    stderr: String(data: stderr, encoding: .utf8) ?? ""
                )
            } catch {
                return ProcessResult(
                    exitCode: 127,
                    stdout: "",
                    stderr: error.localizedDescription
                )
            }
        }.value
    }

    nonisolated private static func cliPath() -> String {
        if let override = ProcessInfo.processInfo.environment["AGENT_TOOLS_CLI"],
           !override.isEmpty
        {
            return override
        }

        let candidates = [
            "/opt/homebrew/bin/agent-tools",
            "/usr/local/bin/agent-tools",
            "\(NSHomeDirectory())/.cargo/bin/agent-tools"
        ]

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }

        return "/usr/bin/env"
    }

    nonisolated private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return "Last run \(formatter.string(from: Date()))"
    }

    nonisolated private static func backgroundStatus(from result: ProcessResult) -> String {
        if result.exitCode != 0 {
            return "Unavailable"
        }
        if result.stdout.contains("launchctl status: loaded") {
            return "Loaded"
        }
        if result.stdout.contains("plist exists") {
            return "Installed, not loaded"
        }
        if result.stdout.contains("plist missing") {
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

    nonisolated private static func syncPreview(from output: String) -> SyncPreview {
        var projects: [SyncProjectPreview] = []
        var currentRoot: String?
        var currentLines: [SyncLinePreview] = []

        func flushProject() {
            guard let currentRoot else { return }
            projects.append(SyncProjectPreview(root: currentRoot, lines: currentLines))
            currentLines = []
        }

        for rawLine in output.lines {
            if let root = rawLine.removingPrefix("Project: ") {
                flushProject()
                currentRoot = root
                continue
            }

            let text = rawLine.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, currentRoot != nil else { continue }
            currentLines.append(SyncLinePreview(kind: syncLineKind(text), text: text))
        }

        flushProject()

        let summary = SyncSummaryPreview(projects: projects)
        return SyncPreview(apply: false, mode: "DRY-RUN", summary: summary, projects: projects)
    }

    nonisolated private static func syncLineKind(_ text: String) -> SyncLineKind {
        if text.hasPrefix("warning:") {
            return .warning
        }
        if text.hasPrefix("skipped:") {
            return .skipped
        }
        if text.hasPrefix("would ") || text.hasPrefix("moved ") || text.hasPrefix("wrote ") {
            return .action
        }
        return .info
    }

    nonisolated private static func outputLines(result: ProcessResult) -> [String] {
        let combined = [result.stdout, result.stderr]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
        return combined.lines
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

struct ProcessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

struct ProjectStatus: Identifiable {
    let id: String
    let root: String
    let validSkills: [String]
    let skills: [SkillStatus]

    fileprivate init(project: ScanProject) {
        self.id = project.root
        self.root = project.root
        self.validSkills = project.validSkills
        self.skills = project.skills?.map(SkillStatus.init(skill:)) ?? project.validSkills.map {
            SkillStatus(
                name: $0,
                path: "\(project.skillsDir)/\($0)",
                location: "unknown",
                locationLabel: "scan",
                originKind: "unknown",
                source: nil,
                sourceType: nil,
                sourceURL: nil,
                ref: nil,
                installedAt: nil,
                updatedAt: nil,
                symlinkedContainer: false
            )
        }
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

    fileprivate init(skill: ScanSkill) {
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
        self.folderKind = skill.folderKind ?? Self.fallbackFolderKind(
            location: skill.location,
            originKind: skill.originKind,
            symlinkedContainer: skill.symlinkedContainer,
            path: skill.path
        )
        self.characterCount = skill.characterCount ?? 0
        self.wordCount = skill.wordCount ?? 0
        self.tokenEstimate = skill.tokenEstimate ?? 0
        self.skillFileCharacterCount = skill.skillFileCharacterCount ?? 0
        self.skillFileWordCount = skill.skillFileWordCount ?? 0
        self.skillFileTokenEstimate = skill.skillFileTokenEstimate ?? 0
        self.textFileCount = skill.textFileCount ?? 0
        self.referenceFileCount = skill.referenceFileCount ?? 0
        self.scriptFileCount = skill.scriptFileCount ?? 0
        self.assetFileCount = skill.assetFileCount ?? 0
        self.otherFileCount = skill.otherFileCount ?? 0
        self.otherFolderCount = skill.otherFolderCount ?? 0
        self.hasOpenAIYaml = skill.hasOpenAIYaml ?? false
        self.hasIconSmall = skill.hasIconSmall ?? false
        self.hasIconLarge = skill.hasIconLarge ?? false
        self.hasIconAndLogo = skill.hasIconAndLogo ?? false
        self.iconSmallPath = skill.iconSmallPath
        self.iconLargePath = skill.iconLargePath
    }

    init(
        name: String,
        path: String,
        location: String,
        locationLabel: String,
        originKind: String,
        source: String?,
        sourceType: String?,
        sourceURL: String?,
        ref: String?,
        installedAt: String?,
        updatedAt: String?,
        symlinkedContainer: Bool,
        folderKind: String? = nil,
        characterCount: Int = 0,
        wordCount: Int = 0,
        tokenEstimate: Int = 0,
        skillFileCharacterCount: Int = 0,
        skillFileWordCount: Int = 0,
        skillFileTokenEstimate: Int = 0,
        textFileCount: Int = 0,
        referenceFileCount: Int = 0,
        scriptFileCount: Int = 0,
        assetFileCount: Int = 0,
        otherFileCount: Int = 0,
        otherFolderCount: Int = 0,
        hasOpenAIYaml: Bool = false,
        hasIconSmall: Bool = false,
        hasIconLarge: Bool = false,
        hasIconAndLogo: Bool = false,
        iconSmallPath: String? = nil,
        iconLargePath: String? = nil
    ) {
        self.name = name
        self.path = path
        self.location = location
        self.locationLabel = locationLabel
        self.originKind = originKind
        self.source = source
        self.sourceType = sourceType
        self.sourceURL = sourceURL
        self.ref = ref
        self.installedAt = installedAt
        self.updatedAt = updatedAt
        self.symlinkedContainer = symlinkedContainer
        self.folderKind = folderKind ?? Self.fallbackFolderKind(
            location: location,
            originKind: originKind,
            symlinkedContainer: symlinkedContainer,
            path: path
        )
        self.characterCount = characterCount
        self.wordCount = wordCount
        self.tokenEstimate = tokenEstimate
        self.skillFileCharacterCount = skillFileCharacterCount
        self.skillFileWordCount = skillFileWordCount
        self.skillFileTokenEstimate = skillFileTokenEstimate
        self.textFileCount = textFileCount
        self.referenceFileCount = referenceFileCount
        self.scriptFileCount = scriptFileCount
        self.assetFileCount = assetFileCount
        self.otherFileCount = otherFileCount
        self.otherFolderCount = otherFolderCount
        self.hasOpenAIYaml = hasOpenAIYaml
        self.hasIconSmall = hasIconSmall
        self.hasIconLarge = hasIconLarge
        self.hasIconAndLogo = hasIconAndLogo
        self.iconSmallPath = iconSmallPath
        self.iconLargePath = iconLargePath
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

    private static func fallbackFolderKind(
        location: String,
        originKind: String,
        symlinkedContainer: Bool,
        path: String
    ) -> String {
        if symlinkedContainer {
            return "symlinked"
        }
        if path.split(separator: "/").contains(where: { $0 == ".system" }) {
            return "system"
        }
        if location == "agents" && originKind == "npx-skills" {
            return "npx-installed"
        }
        if location == "agents" && originKind == "native" {
            return "native"
        }
        if location == "codex" {
            return "codex-local"
        }
        if location == "claude" {
            return "claude-local"
        }
        return "unknown"
    }
}

private struct ScanReport: Decodable {
    let projects: [ScanProject]
}

private struct ScanProject: Decodable {
    let root: String
    let skillsDir: String
    let validSkills: [String]
    let skills: [ScanSkill]?

    private enum CodingKeys: String, CodingKey {
        case root
        case skillsDir = "skills_dir"
        case validSkills = "valid_skills"
        case skills
    }
}

private struct ScanSkill: Decodable {
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
    let folderKind: String?
    let characterCount: Int?
    let wordCount: Int?
    let tokenEstimate: Int?
    let skillFileCharacterCount: Int?
    let skillFileWordCount: Int?
    let skillFileTokenEstimate: Int?
    let textFileCount: Int?
    let referenceFileCount: Int?
    let scriptFileCount: Int?
    let assetFileCount: Int?
    let otherFileCount: Int?
    let otherFolderCount: Int?
    let hasOpenAIYaml: Bool?
    let hasIconSmall: Bool?
    let hasIconLarge: Bool?
    let hasIconAndLogo: Bool?
    let iconSmallPath: String?
    let iconLargePath: String?

    private enum CodingKeys: String, CodingKey {
        case name
        case path
        case location
        case locationLabel = "location_label"
        case originKind = "origin_kind"
        case source
        case sourceType = "source_type"
        case sourceURL = "source_url"
        case ref
        case installedAt = "installed_at"
        case updatedAt = "updated_at"
        case symlinkedContainer = "symlinked_container"
        case folderKind = "folder_kind"
        case characterCount = "character_count"
        case wordCount = "word_count"
        case tokenEstimate = "token_estimate"
        case skillFileCharacterCount = "skill_file_character_count"
        case skillFileWordCount = "skill_file_word_count"
        case skillFileTokenEstimate = "skill_file_token_estimate"
        case textFileCount = "text_file_count"
        case referenceFileCount = "reference_file_count"
        case scriptFileCount = "script_file_count"
        case assetFileCount = "asset_file_count"
        case otherFileCount = "other_file_count"
        case otherFolderCount = "other_folder_count"
        case hasOpenAIYaml = "has_openai_yaml"
        case hasIconSmall = "has_icon_small"
        case hasIconLarge = "has_icon_large"
        case hasIconAndLogo = "has_icon_and_logo"
        case iconSmallPath = "icon_small_path"
        case iconLargePath = "icon_large_path"
    }
}

struct SyncPreview: Decodable {
    let apply: Bool
    let mode: String
    let summary: SyncSummaryPreview
    let projects: [SyncProjectPreview]

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

    init(projects: [SyncProjectPreview]) {
        self.projectCount = projects.count
        self.validSkillCount = projects.reduce(0) { $0 + $1.validSkillCount }
        self.warningCount = projects.reduce(0) { $0 + $1.warningCount }
        self.actionCount = projects.reduce(0) { $0 + $1.actionCount }
        self.skippedCount = projects.reduce(0) { $0 + $1.skippedCount }
        self.dotagentsCount = projects.filter(\.usesDotagents).count
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

    init(root: String, lines: [SyncLinePreview]) {
        self.root = root
        self.name = URL(fileURLWithPath: root).lastPathComponent
        self.lines = lines
        self.validSkillCount = Self.validSkillCount(from: lines)
        self.warningCount = lines.filter { $0.kind == .warning }.count
        self.actionCount = lines.filter { $0.kind == .action }.count
        self.skippedCount = lines.filter { $0.kind == .skipped }.count
        self.usesDotagents = lines.contains { $0.text.contains("dotagents") || $0.text.contains("npx @sentry/dotagents") }
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

    private static func validSkillCount(from lines: [SyncLinePreview]) -> Int {
        for line in lines {
            let prefix = "valid local skills: "
            guard let value = line.text.removingPrefix(prefix) else { continue }
            return Int(value.trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return 0
    }
}

struct SyncLinePreview: Decodable, Identifiable {
    let kind: SyncLineKind
    let text: String

    var id: String { "\(kind.rawValue)-\(text)" }
}

enum SyncLineKind: String, Decodable {
    case action
    case warning
    case skipped
    case info
}

private enum RestartError: LocalizedError {
    case missingExecutable

    var errorDescription: String? {
        "Could not resolve the current app executable."
    }
}

private extension String {
    var lines: [String] {
        split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func removingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
