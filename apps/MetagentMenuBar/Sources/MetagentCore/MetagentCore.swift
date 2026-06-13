import Foundation
import Darwin
import SQLite3

public struct MetagentConfig: Codable, Equatable, Sendable {
    public var roots: [String]
    public var maxDepth: Int
    public var agents: [String]
    public var ignoreProjects: [String]

    public init(
        roots: [String],
        maxDepth: Int = 6,
        agents: [String] = ["claude", "codex", "cursor"],
        ignoreProjects: [String] = []
    ) {
        self.roots = roots
        self.maxDepth = maxDepth
        self.agents = agents
        self.ignoreProjects = ignoreProjects
    }
}

public struct SkillScanOptions: Equatable, Sendable {
    public var roots: [String]
    public var maxDepth: Int?
    public var ignoreProjects: [String]

    public init(roots: [String] = [], maxDepth: Int? = nil, ignoreProjects: [String] = []) {
        self.roots = roots
        self.maxDepth = maxDepth
        self.ignoreProjects = ignoreProjects
    }
}

public struct SkillScanReport: Codable, Equatable, Sendable {
    public var projects: [SkillProject]

    public init(projects: [SkillProject]) {
        self.projects = projects
    }
}

public struct SkillProject: Codable, Equatable, Identifiable, Sendable {
    public var id: String { root }
    public var root: String
    public var skillsDir: String
    public var validSkills: [String]
    public var skills: [SkillInventoryItem]
    public var invalidSkillDirs: [String]
    public var hiddenSkillDirs: [String]

    public init(
        root: String,
        skillsDir: String,
        validSkills: [String],
        skills: [SkillInventoryItem],
        invalidSkillDirs: [String] = [],
        hiddenSkillDirs: [String] = []
    ) {
        self.root = root
        self.skillsDir = skillsDir
        self.validSkills = validSkills
        self.skills = skills
        self.invalidSkillDirs = invalidSkillDirs
        self.hiddenSkillDirs = hiddenSkillDirs
    }

    private enum CodingKeys: String, CodingKey {
        case root
        case skillsDir = "skills_dir"
        case validSkills = "valid_skills"
        case skills
        case invalidSkillDirs = "invalid_skill_dirs"
        case hiddenSkillDirs = "hidden_skill_dirs"
    }
}

public struct SkillInventoryItem: Codable, Equatable, Identifiable, Comparable, Sendable {
    public var id: String { "\(location):\(path)" }
    public var name: String
    public var path: String
    public var location: String
    public var locationLabel: String
    public var originKind: String
    public var source: String?
    public var sourceType: String?
    public var sourceURL: String?
    public var ref: String?
    public var installedAt: String?
    public var updatedAt: String?
    public var symlinkedContainer: Bool
    public var folderKind: String
    public var characterCount: Int
    public var wordCount: Int
    public var tokenEstimate: Int
    public var skillFileCharacterCount: Int
    public var skillFileWordCount: Int
    public var skillFileTokenEstimate: Int
    public var textFileCount: Int
    public var referenceFileCount: Int
    public var scriptFileCount: Int
    public var assetFileCount: Int
    public var otherFileCount: Int
    public var otherFolderCount: Int
    public var hasOpenAIYaml: Bool
    public var hasIconSmall: Bool
    public var hasIconLarge: Bool
    public var hasIconAndLogo: Bool
    public var iconSmallPath: String?
    public var iconLargePath: String?

    public init(
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
        folderKind: String,
        characterCount: Int,
        wordCount: Int,
        tokenEstimate: Int,
        skillFileCharacterCount: Int,
        skillFileWordCount: Int,
        skillFileTokenEstimate: Int,
        textFileCount: Int,
        referenceFileCount: Int,
        scriptFileCount: Int,
        assetFileCount: Int,
        otherFileCount: Int,
        otherFolderCount: Int,
        hasOpenAIYaml: Bool,
        hasIconSmall: Bool,
        hasIconLarge: Bool,
        hasIconAndLogo: Bool,
        iconSmallPath: String?,
        iconLargePath: String?
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
        self.folderKind = folderKind
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

    public static func < (left: SkillInventoryItem, right: SkillInventoryItem) -> Bool {
        if left.location != right.location {
            return left.location < right.location
        }
        if left.name != right.name {
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
        return left.path < right.path
    }

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

public struct DoctorReport: Codable, Equatable, Sendable {
    public var issues: [DoctorIssue]

    public var warningCount: Int {
        issues.filter { $0.severity == .warning }.count
    }

    public var failureCount: Int {
        issues.filter { $0.severity == .failure }.count
    }

    public init(issues: [DoctorIssue]) {
        self.issues = issues
    }
}

public struct DoctorIssue: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(severity.rawValue):\(message)" }
    public var severity: DoctorSeverity
    public var message: String

    public init(severity: DoctorSeverity, message: String) {
        self.severity = severity
        self.message = message
    }
}

public enum DoctorSeverity: String, Codable, Sendable {
    case ok = "OK"
    case warning = "WARN"
    case failure = "FAIL"
}

public struct SkillsSyncOptions: Equatable, Sendable {
    public var apply: Bool
    public var replaceClaudeSkills: Bool
    public var rewriteAgentsToml: Bool
    public var syncOnly: Bool
    public var runDotagents: Bool
    public var agents: [String]
    public var scanOptions: SkillScanOptions

    public init(
        apply: Bool = false,
        replaceClaudeSkills: Bool = false,
        rewriteAgentsToml: Bool = false,
        syncOnly: Bool = false,
        runDotagents: Bool = true,
        agents: [String] = [],
        scanOptions: SkillScanOptions = SkillScanOptions()
    ) {
        self.apply = apply
        self.replaceClaudeSkills = replaceClaudeSkills
        self.rewriteAgentsToml = rewriteAgentsToml
        self.syncOnly = syncOnly
        self.runDotagents = runDotagents
        self.agents = agents
        self.scanOptions = scanOptions
    }
}

public struct SkillsSyncReport: Codable, Equatable, Sendable {
    public var apply: Bool
    public var mode: String
    public var summary: SkillsSyncSummary
    public var projects: [SkillsSyncProject]

    public init(apply: Bool, projects: [SkillsSyncProject]) {
        self.apply = apply
        self.mode = apply ? "APPLY" : "DRY-RUN"
        self.projects = projects
        self.summary = SkillsSyncSummary(projects: projects)
    }
}

public struct SkillsSyncSummary: Codable, Equatable, Sendable {
    public var projectCount: Int
    public var validSkillCount: Int
    public var warningCount: Int
    public var actionCount: Int
    public var skippedCount: Int
    public var dotagentsCount: Int

    public init(projects: [SkillsSyncProject]) {
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

public struct SkillsSyncProject: Codable, Equatable, Identifiable, Sendable {
    public var id: String { root }
    public var root: String
    public var name: String
    public var validSkillCount: Int
    public var warningCount: Int
    public var actionCount: Int
    public var skippedCount: Int
    public var usesDotagents: Bool
    public var lines: [SkillsSyncLine]

    public init(root: String, lines: [SkillsSyncLine]) {
        self.root = root
        self.name = URL(fileURLWithPath: root).lastPathComponent
        self.lines = lines
        self.validSkillCount = Self.validSkillCount(from: lines)
        self.warningCount = lines.filter { $0.kind == .warning }.count
        self.actionCount = lines.filter { $0.kind == .action }.count
        self.skippedCount = lines.filter { $0.kind == .skipped }.count
        self.usesDotagents = lines.contains {
            $0.text.hasPrefix("dotagents:") || $0.text == "would run: npx @sentry/dotagents sync"
        }
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

    private static func validSkillCount(from lines: [SkillsSyncLine]) -> Int {
        for line in lines {
            guard let value = line.text.removingPrefix("valid local skills: ") else { continue }
            return Int(value.trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return 0
    }
}

public struct SkillsSyncLine: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(kind.rawValue):\(text)" }
    public var kind: SkillsSyncLineKind
    public var text: String

    public init(kind: SkillsSyncLineKind, text: String) {
        self.kind = kind
        self.text = text
    }
}

public enum SkillsSyncLineKind: String, Codable, Sendable {
    case action
    case warning
    case skipped
    case info
}

public struct LaunchAgentOptions: Equatable, Sendable {
    public var program: String?
    public var interval: Int

    public init(program: String? = nil, interval: Int = 300) {
        self.program = program
        self.interval = interval
    }
}

public struct LaunchAgentReport: Codable, Equatable, Sendable {
    public var lines: [String]

    public init(lines: [String]) {
        self.lines = lines
    }
}

public enum MetagentCore {
    public static let launchAgentLabel = "com.ianwatts.metagent.skills-sync"
    fileprivate static let legacyLaunchAgentLabel = "com.ianwatts.agent-tools.skills-sync"

    public static func userConfigPath() -> URL {
        homeURL()
            .appendingPathComponent(".config")
            .appendingPathComponent("metagent")
            .appendingPathComponent("config.toml")
    }

    public static func loadUserConfig() throws -> MetagentConfig {
        let path = userConfigPath()
        guard fileManager.fileExists(atPath: path.path) else {
            return MetagentConfig(roots: defaultRootPaths())
        }

        let text: String
        do {
            text = try String(contentsOf: path, encoding: .utf8)
        } catch {
            throw NSError(domain: "MetagentConfig", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "failed reading \(path.path): \(error.localizedDescription)"
            ])
        }

        let configText = uncommentedConfigText(text)
        let roots = try parseStringArray(key: "roots", text: configText) ?? []
        let agents = try parseStringArray(key: "agents", text: configText) ?? []
        let ignoreProjects = try parseStringArray(key: "ignore_projects", text: configText) ?? []
        let maxDepth = try parseInteger(key: "max_depth", text: configText) ?? 6
        return MetagentConfig(
            roots: roots.isEmpty ? defaultRootPaths() : roots,
            maxDepth: maxDepth,
            agents: agents.isEmpty ? defaultAgents() : agents,
            ignoreProjects: ignoreProjects
        )
    }

    public static func scanSkills(options: SkillScanOptions = SkillScanOptions()) throws -> SkillScanReport {
        let config = try loadUserConfig()
        let rootPaths = options.roots.isEmpty ? config.roots : options.roots
        let maxDepth = options.maxDepth ?? config.maxDepth
        let ignoreProjects = Set((config.ignoreProjects + options.ignoreProjects).map { canonicalProjectPath(expandPath($0)) })
        var projectRoots = Set<String>()

        for rootPath in rootPaths {
            let root = expandPath(rootPath)
            discoverProjectRoots(
                root: root,
                maxDepth: maxDepth,
                ignoreProjects: ignoreProjects,
                projectRoots: &projectRoots
            )
        }

        let projects = try projectRoots
            .sorted()
            .map { try readProjectSkills(root: URL(fileURLWithPath: $0)) }
            .filter(hasProjectInventorySurface)

        return SkillScanReport(projects: projects)
    }

    public static func scanHomeSkills(maxDepth: Int = 2) throws -> SkillScanReport {
        let config = try loadUserConfig()
        let home = homeURL()
        let normalizedHome = canonicalProjectPath(home)
        let ignoreProjects = Set(config.ignoreProjects.map { canonicalProjectPath(expandPath($0)) })
        var projectRoots = Set<String>()

        if !ignoreProjects.contains(normalizedHome) {
            for container in [".agents/skills", ".codex/skills", ".claude/skills"] {
                if fileManager.fileExists(atPath: home.appendingPathComponent(container).path) {
                    projectRoots.insert(normalizedHome)
                }
            }
        }

        discoverProjectRoots(
            root: home,
            maxDepth: maxDepth,
            ignoreProjects: ignoreProjects,
            projectRoots: &projectRoots
        )

        let projects = try projectRoots
            .sorted()
            .map { try readProjectSkills(root: URL(fileURLWithPath: $0)) }
            .filter { !ignoreProjects.contains(canonicalProjectPath(URL(fileURLWithPath: $0.root))) }
            .filter(hasProjectInventorySurface)

        return SkillScanReport(projects: projects)
    }

    public static func doctor(options: SkillScanOptions = SkillScanOptions()) throws -> DoctorReport {
        let report = try scanSkills(options: options)
        let config = try loadUserConfig()
        let rootPaths = options.roots.isEmpty ? config.roots : options.roots
        let maxDepth = options.maxDepth ?? config.maxDepth
        let ignoreProjects = Set((config.ignoreProjects + options.ignoreProjects).map { canonicalProjectPath(expandPath($0)) })
        var projectRoots = Set(report.projects.map(\.root))

        for rootPath in rootPaths {
            discoverAgentsTomlProjectRoots(
                root: expandPath(rootPath),
                maxDepth: maxDepth,
                ignoreProjects: ignoreProjects,
                projectRoots: &projectRoots
            )
        }

        let projectsByRoot = Dictionary(uniqueKeysWithValues: report.projects.map { ($0.root, $0) })
        let projects = try projectRoots
            .sorted()
            .map { root in
                if let project = projectsByRoot[root] {
                    return project
                }
                return try readProjectSkills(root: URL(fileURLWithPath: root))
            }
        var issues: [DoctorIssue] = []

        if projects.isEmpty {
            issues.append(.init(severity: .warning, message: "no projects with skills found"))
        }

        for project in projects {
            if project.validSkills.isEmpty {
                issues.append(.init(severity: .warning, message: "\(project.root) has no valid .agents skills"))
            } else {
                issues.append(.init(severity: .ok, message: "\(project.root) has \(project.validSkills.count) valid skills"))
            }

            for path in project.invalidSkillDirs {
                issues.append(.init(severity: .warning, message: "\(path) is not a valid dotagents skill directory"))
            }

            for path in project.hiddenSkillDirs {
                issues.append(.init(severity: .warning, message: "\(path) is hidden and ignored by dotagents"))
            }

            checkAgentsToml(project: project, issues: &issues)

            let claudeSkills = URL(fileURLWithPath: project.root)
                .appendingPathComponent(".claude")
                .appendingPathComponent("skills")
            if isSymlink(claudeSkills) {
                issues.append(.init(severity: .ok, message: "\(claudeSkills.path) is a symlink"))
            } else if fileManager.fileExists(atPath: claudeSkills.path) {
                issues.append(.init(severity: .warning, message: "\(claudeSkills.path) exists but is not a symlink"))
            } else {
                issues.append(.init(severity: .warning, message: "\(claudeSkills.path) missing"))
            }
        }

        return DoctorReport(issues: issues)
    }

    public static func syncSkills(options: SkillsSyncOptions = SkillsSyncOptions()) throws -> SkillsSyncReport {
        let config = try loadUserConfig()
        let agents = options.agents.isEmpty ? config.agents : options.agents
        let scan = try scanSkills(options: options.scanOptions)
        var projects: [SkillsSyncProject] = []

        for project in scan.projects where hasAgentsSyncSurface(project) {
            let lines = try syncProject(project, options: options, agents: agents)
            projects.append(SkillsSyncProject(root: project.root, lines: lines))
        }

        return SkillsSyncReport(apply: options.apply, projects: projects)
    }

    public static func launchAgentStatus(options: LaunchAgentOptions = LaunchAgentOptions()) -> LaunchAgentReport {
        let plist = launchAgentPlistURL()
        let legacyPlist = launchAgentPlistURL(label: legacyLaunchAgentLabel)
        var lines: [String] = []

        if fileManager.fileExists(atPath: plist.path) {
            lines.append("plist exists: \(plist.path)")
        } else {
            lines.append("plist missing: \(plist.path)")
        }
        if fileManager.fileExists(atPath: legacyPlist.path) {
            lines.append("legacy plist present: \(legacyPlist.path)")
        }

        let result = runProcess(launchctlExecutablePath(), arguments: ["print", launchAgentJob(launchAgentLabel)])
        if result.exitCode == 0 {
            lines.append("launchctl status: loaded")
            lines.append(contentsOf: result.stdout.nonEmptyLines)
        } else {
            lines.append("launchctl status: not loaded")
            lines.append(contentsOf: result.stderr.nonEmptyLines)
        }

        return LaunchAgentReport(lines: lines)
    }

    public static func installLaunchAgent(options: LaunchAgentOptions = LaunchAgentOptions()) throws -> LaunchAgentReport {
        let plist = launchAgentPlistURL()
        try fileManager.createDirectory(
            at: plist.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: logsURL(),
            withIntermediateDirectories: true
        )

        let program = try options.program ?? defaultHelperPath()
        let text = renderLaunchAgentPlist(program: program, interval: options.interval)
        try text.write(to: plist, atomically: true, encoding: .utf8)

        var lines = ["wrote \(plist.path)"]
        lines.append(contentsOf: retireLegacyLaunchAgent())
        if bootoutLaunchAgent(label: Self.launchAgentLabel).exitCode == 0 {
            lines.append("unloaded existing LaunchAgent")
        }
        let load = runProcess(launchctlExecutablePath(), arguments: ["bootstrap", launchAgentDomain(), plist.path])
        if load.exitCode == 0 {
            lines.append("loaded LaunchAgent")
        } else {
            lines.append("warning: launchctl load failed")
            lines.append(contentsOf: load.stderr.nonEmptyLines)
        }

        return LaunchAgentReport(lines: lines)
    }

    public static func uninstallLaunchAgent(options: LaunchAgentOptions = LaunchAgentOptions()) -> LaunchAgentReport {
        let plist = launchAgentPlistURL()
        var lines: [String] = []
        if bootoutLaunchAgent(label: Self.launchAgentLabel).exitCode == 0 {
            lines.append("unloaded LaunchAgent")
        }

        do {
            try fileManager.removeItem(at: plist)
            lines.append("removed \(plist.path)")
        } catch CocoaError.fileNoSuchFile {
            lines.append("plist already missing: \(plist.path)")
        } catch {
            lines.append("warning: failed removing \(plist.path): \(error.localizedDescription)")
        }
        lines.append(contentsOf: retireLegacyLaunchAgent())

        return LaunchAgentReport(lines: lines)
    }

    public static func morphMCPStatus() throws -> LaunchAgentReport {
        let result = runProcess(psExecutablePath(), arguments: ["-axo", "pid,ppid,etime,pcpu,command"])
        guard result.exitCode == 0 else {
            let details = result.stderr.nonEmptyLines.joined(separator: "\n")
            throw NSError(domain: "MetagentMorphMCP", code: Int(result.exitCode), userInfo: [
                NSLocalizedDescriptionKey: "failed to inspect processes\(details.isEmpty ? "" : "\n\(details)")"
            ])
        }

        let matches = result.stdout
            .components(separatedBy: .newlines)
            .filter { line in
                let lower = line.lowercased()
                return lower.contains("@morphllm/morphmcp")
                    || lower.contains("/morph-mcp")
                    || lower.hasSuffix(" morph-mcp")
            }

        var lines = ["Morph MCP Processes"]
        if matches.isEmpty {
            lines.append("no morph-mcp processes found")
        } else {
            lines.append("matched morph-mcp processes: \(matches.count)")
            lines.append(contentsOf: matches.map { $0.trimmingCharacters(in: .whitespaces) })
        }

        let plist = homeURL()
            .appendingPathComponent("Library")
            .appendingPathComponent("LaunchAgents")
            .appendingPathComponent("com.ianwatts.metagent.morph-mcp-janitor.plist")
        lines.append("")
        if fileManager.fileExists(atPath: plist.path) {
            lines.append("janitor plist exists: \(plist.path)")
        } else {
            lines.append("janitor plist missing: \(plist.path)")
        }

        return LaunchAgentReport(lines: lines)
    }

    public static func saveInventorySnapshot(_ report: SkillScanReport) {
        try? SkillInventoryCache().save(report)
    }

    public static func loadInventorySnapshot() -> SkillScanReport? {
        try? SkillInventoryCache().load()
    }
}

private struct SkillLock: Decodable {
    var skills: [String: SkillLockEntry]
}

private struct SkillLockEntry: Decodable {
    var source: String?
    var sourceType: String?
    var sourceUrl: String?
    var ref: String?
    var installedAt: String?
    var updatedAt: String?

    private enum CodingKeys: String, CodingKey {
        case source
        case sourceType
        case sourceUrl = "sourceUrl"
        case ref
        case installedAt
        case updatedAt
    }
}

private struct AgentsTomlDeclaration {
    var name: String?
    var source: String?
}

private struct SkillStats {
    var characterCount = 0
    var wordCount = 0
    var tokenEstimate = 0
    var skillFileCharacterCount = 0
    var skillFileWordCount = 0
    var skillFileTokenEstimate = 0
    var textFileCount = 0
    var referenceFileCount = 0
    var scriptFileCount = 0
    var assetFileCount = 0
    var otherFileCount = 0
    var otherFolderCount = 0
    var hasOpenAIYaml = false
    var hasIconSmall = false
    var hasIconLarge = false
    var hasIconAndLogo = false
    var iconSmallPath: String?
    var iconLargePath: String?
}

private struct ProcessOutput {
    var exitCode: Int32
    var stdout: String
    var stderr: String
}

private var fileManager: FileManager {
    FileManager.default
}

private func homeURL() -> URL {
    if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
        return URL(fileURLWithPath: home)
    }
    return fileManager.homeDirectoryForCurrentUser
}

private func defaultRootPaths() -> [String] {
    let home = homeURL()
    return [
        home.appendingPathComponent("code_projects").path,
        home.appendingPathComponent("Library").appendingPathComponent("CloudStorage").path,
        home.appendingPathComponent("Documents").appendingPathComponent("Codex").path
    ]
}

private func defaultAgents() -> [String] {
    ["claude", "codex", "cursor"]
}

private func expandPath(_ path: String) -> URL {
    if path == "~" {
        return homeURL()
    }
    if path.hasPrefix("~/") {
        return homeURL().appendingPathComponent(String(path.dropFirst(2)))
    }
    return URL(fileURLWithPath: path)
}

private func canonicalProjectPath(_ url: URL) -> String {
    url.resolvingSymlinksInPath().standardizedFileURL.path
}

private func discoverProjectRoots(
    root: URL,
    maxDepth: Int,
    ignoreProjects: Set<String>,
    projectRoots: inout Set<String>
) {
    let standardized = root.resolvingSymlinksInPath().standardizedFileURL
    guard fileManager.fileExists(atPath: standardized.path) else { return }

    var queue: [(URL, Int)] = [(standardized, 0)]
    var visited = Set<String>()

    while let (current, depth) = queue.first {
        queue.removeFirst()
        let path = canonicalProjectPath(current)
        guard visited.insert(path).inserted else { continue }

        if let projectRoot = projectRootForSkillContainer(current) {
            if !ignoreProjects.contains(projectRoot) {
                projectRoots.insert(projectRoot)
            }
            continue
        }
        if let projectRoot = projectRootForDotSkillDirectory(current) {
            if !ignoreProjects.contains(projectRoot) {
                projectRoots.insert(projectRoot)
            }
            continue
        }

        if hasKnownSkillContainer(current) {
            if !ignoreProjects.contains(path) {
                projectRoots.insert(path)
            }
        }

        guard depth < maxDepth else { continue }
        guard let entries = try? fileManager.contentsOfDirectory(
            at: current,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else {
            continue
        }

        for entry in entries {
            let name = entry.lastPathComponent
            if let projectRoot = projectRootForSkillContainer(entry) {
                if !ignoreProjects.contains(projectRoot) {
                    projectRoots.insert(projectRoot)
                }
                continue
            }
            if shouldPrune(name: name) {
                continue
            }
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            queue.append((entry, depth + 1))
        }
    }
}

private func projectRootForSkillContainer(_ url: URL) -> String? {
    guard url.lastPathComponent == "skills" else { return nil }
    let dotDirectory = url.deletingLastPathComponent()
    guard [".agents", ".codex", ".claude"].contains(dotDirectory.lastPathComponent) else {
        return nil
    }
    return canonicalProjectPath(dotDirectory.deletingLastPathComponent())
}

private func projectRootForDotSkillDirectory(_ url: URL) -> String? {
    guard [".agents", ".codex", ".claude"].contains(url.lastPathComponent) else {
        return nil
    }
    guard fileManager.fileExists(atPath: url.appendingPathComponent("skills").path) else {
        return nil
    }
    return canonicalProjectPath(url.deletingLastPathComponent())
}

private func discoverAgentsTomlProjectRoots(
    root: URL,
    maxDepth: Int,
    ignoreProjects: Set<String>,
    projectRoots: inout Set<String>
) {
    let standardized = root.resolvingSymlinksInPath().standardizedFileURL
    guard fileManager.fileExists(atPath: standardized.path) else { return }

    var queue: [(URL, Int)] = [(standardized, 0)]
    var visited = Set<String>()

    while let (current, depth) = queue.first {
        queue.removeFirst()
        let path = canonicalProjectPath(current)
        guard visited.insert(path).inserted else { continue }

        if current.lastPathComponent == ".agents" {
            if fileManager.fileExists(atPath: current.appendingPathComponent("agents.toml").path),
               let parent = canonicalProjectPath(current.deletingLastPathComponent()).nonEmpty,
               !ignoreProjects.contains(parent)
            {
                projectRoots.insert(parent)
            }
            continue
        }

        if hasAgentsToml(current), !ignoreProjects.contains(path) {
            projectRoots.insert(path)
        }

        guard depth < maxDepth else { continue }
        guard let entries = try? fileManager.contentsOfDirectory(
            at: current,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else {
            continue
        }

        for entry in entries {
            let name = entry.lastPathComponent
            if isKnownSkillContainerDirectory(entry) || shouldPrune(name: name) {
                continue
            }
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            queue.append((entry, depth + 1))
        }
    }
}

private func hasKnownSkillContainer(_ root: URL) -> Bool {
    [
        ".agents/skills",
        ".codex/skills",
        ".claude/skills"
    ].contains { relative in
        fileManager.fileExists(atPath: root.appendingPathComponent(relative).path)
    }
}

private func hasAgentsToml(_ root: URL) -> Bool {
    fileManager.fileExists(atPath: root.appendingPathComponent("agents.toml").path)
        || fileManager.fileExists(atPath: root.appendingPathComponent(".agents").appendingPathComponent("agents.toml").path)
}

private func readProjectSkills(root: URL) throws -> SkillProject {
    let agentsSkillsDir = root.appendingPathComponent(".agents").appendingPathComponent("skills")
    let skillLock = readSkillLock(root.appendingPathComponent(".agents").appendingPathComponent(".skill-lock.json"))
    var validSkills: [String] = []
    var inventory: [SkillInventoryItem] = []
    var invalidSkillDirs: [String] = []
    var hiddenSkillDirs: [String] = []

    readAgentsSkills(
        skillsDir: agentsSkillsDir,
        skillLock: skillLock,
        validSkills: &validSkills,
        inventory: &inventory,
        invalidSkillDirs: &invalidSkillDirs,
        hiddenSkillDirs: &hiddenSkillDirs
    )

    readInventorySkills(
        skillsDir: root.appendingPathComponent(".codex").appendingPathComponent("skills"),
        location: "codex",
        inventory: &inventory
    )
    readInventorySkills(
        skillsDir: root.appendingPathComponent(".claude").appendingPathComponent("skills"),
        location: "claude",
        inventory: &inventory
    )

    return SkillProject(
        root: root.path,
        skillsDir: agentsSkillsDir.path,
        validSkills: validSkills.sorted(),
        skills: inventory.sorted(),
        invalidSkillDirs: invalidSkillDirs.sorted(),
        hiddenSkillDirs: hiddenSkillDirs.sorted()
    )
}

private func readAgentsSkills(
    skillsDir: URL,
    skillLock: [String: SkillLockEntry],
    validSkills: inout [String],
    inventory: inout [SkillInventoryItem],
    invalidSkillDirs: inout [String],
    hiddenSkillDirs: inout [String]
) {
    guard let entries = skillContainerEntries(at: skillsDir) else {
        return
    }

    let symlinkedContainer = isSymlink(skillsDir)

    for entry in entries.sorted(by: { $0.path < $1.path }) {
        guard isDirectoryOrSymlinkedDirectory(entry) else { continue }
        guard isRegularOrSymlinkedFile(entry.appendingPathComponent("SKILL.md")) else { continue }
        let name = entry.lastPathComponent
        if name.hasPrefix(".") {
            hiddenSkillDirs.append(entry.path)
        }
        guard isValidSkillName(name) else {
            invalidSkillDirs.append(entry.path)
            continue
        }

        validSkills.append(name)
        let lockEntry = skillLock[name]
        inventory.append(makeSkillItem(
            name: name,
            path: entry,
            location: "agents",
            originKind: lockEntry == nil ? "native" : "npx-skills",
            origin: lockEntry,
            symlinkedContainer: symlinkedContainer
        ))
    }
}

private func readInventorySkills(
    skillsDir: URL,
    location: String,
    inventory: inout [SkillInventoryItem]
) {
    guard fileManager.fileExists(atPath: skillsDir.path) else { return }
    collectInventorySkills(
        dir: skillsDir,
        location: location,
        depth: 0,
        maxDepth: 2,
        symlinkedContainer: isSymlink(skillsDir),
        inventory: &inventory
    )
}

private func collectInventorySkills(
    dir: URL,
    location: String,
    depth: Int,
    maxDepth: Int,
    symlinkedContainer: Bool,
    inventory: inout [SkillInventoryItem]
) {
    guard depth <= maxDepth else { return }
    guard let entries = skillContainerEntries(at: dir) else {
        return
    }

    for entry in entries.sorted(by: { $0.path < $1.path }) {
        guard isDirectoryOrSymlinkedDirectory(entry) else { continue }
        if isRegularOrSymlinkedFile(entry.appendingPathComponent("SKILL.md")) {
            let name = entry.lastPathComponent
            guard isValidSkillName(name) else { continue }
            inventory.append(makeSkillItem(
                name: name,
                path: entry,
                location: location,
                originKind: "not-applicable",
                origin: nil,
                symlinkedContainer: symlinkedContainer
            ))
            continue
        }

        guard depth < maxDepth, !shouldPruneSkillContainer(name: entry.lastPathComponent) else {
            continue
        }
        collectInventorySkills(
            dir: entry,
            location: location,
            depth: depth + 1,
            maxDepth: maxDepth,
            symlinkedContainer: symlinkedContainer,
            inventory: &inventory
        )
    }
}

private func makeSkillItem(
    name: String,
    path: URL,
    location: String,
    originKind: String,
    origin: SkillLockEntry?,
    symlinkedContainer: Bool
) -> SkillInventoryItem {
    let stats = skillStats(path)
    return SkillInventoryItem(
        name: name,
        path: path.path,
        location: location,
        locationLabel: ".\(location)",
        originKind: originKind,
        source: origin?.source,
        sourceType: origin?.sourceType,
        sourceURL: origin?.sourceUrl,
        ref: origin?.ref,
        installedAt: origin?.installedAt,
        updatedAt: origin?.updatedAt,
        symlinkedContainer: symlinkedContainer,
        folderKind: folderKind(path: path, location: location, originKind: originKind, symlinkedContainer: symlinkedContainer),
        characterCount: stats.characterCount,
        wordCount: stats.wordCount,
        tokenEstimate: stats.tokenEstimate,
        skillFileCharacterCount: stats.skillFileCharacterCount,
        skillFileWordCount: stats.skillFileWordCount,
        skillFileTokenEstimate: stats.skillFileTokenEstimate,
        textFileCount: stats.textFileCount,
        referenceFileCount: stats.referenceFileCount,
        scriptFileCount: stats.scriptFileCount,
        assetFileCount: stats.assetFileCount,
        otherFileCount: stats.otherFileCount,
        otherFolderCount: stats.otherFolderCount,
        hasOpenAIYaml: stats.hasOpenAIYaml,
        hasIconSmall: stats.hasIconSmall,
        hasIconLarge: stats.hasIconLarge,
        hasIconAndLogo: stats.hasIconAndLogo,
        iconSmallPath: stats.iconSmallPath,
        iconLargePath: stats.iconLargePath
    )
}

private func skillStats(_ skillDir: URL) -> SkillStats {
    var stats = SkillStats()
    var otherFolders = Set<String>()
    readOpenAIYaml(skillDir: skillDir, stats: &stats)
    collectSkillStats(root: skillDir, dir: skillDir, stats: &stats, otherFolders: &otherFolders)
    stats.tokenEstimate = estimateTokens(stats.characterCount)
    stats.skillFileTokenEstimate = estimateTokens(stats.skillFileCharacterCount)
    stats.otherFolderCount = otherFolders.count
    stats.hasIconAndLogo = stats.hasIconSmall && stats.hasIconLarge
    return stats
}

private func collectSkillStats(root: URL, dir: URL, stats: inout SkillStats, otherFolders: inout Set<String>) {
    guard let entries = try? fileManager.contentsOfDirectory(
        at: dir,
        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
        options: [.skipsPackageDescendants]
    ) else {
        return
    }

    for entry in entries {
        if isDirectoryOrSymlinkedDirectory(entry) {
            guard !isSymlink(entry) else { continue }
            guard !shouldPrune(name: entry.lastPathComponent) else { continue }
            collectSkillStats(root: root, dir: entry, stats: &stats, otherFolders: &otherFolders)
            continue
        }

        guard isRegularOrSymlinkedFile(entry) else { continue }
        categorizeSkillFile(root: root, path: entry, stats: &stats, otherFolders: &otherFolders)
        guard isSkillTextFile(entry) else { continue }
        guard let text = try? String(contentsOf: entry, encoding: .utf8) else { continue }
        let characters = text.count
        let words = text.split(whereSeparator: \.isWhitespace).count
        stats.textFileCount += 1
        stats.characterCount += characters
        stats.wordCount += words

        if entry.lastPathComponent == "SKILL.md" {
            stats.skillFileCharacterCount += characters
            stats.skillFileWordCount += words
        }
    }
}

private func categorizeSkillFile(
    root: URL,
    path: URL,
    stats: inout SkillStats,
    otherFolders: inout Set<String>
) {
    guard let topLevel = topLevelComponent(root: root, path: path) else { return }
    switch topLevel {
    case "SKILL.md":
        return
    case "references":
        stats.referenceFileCount += 1
    case "scripts":
        stats.scriptFileCount += 1
    case "assets":
        stats.assetFileCount += 1
    case "agents" where path.lastPathComponent == "openai.yaml":
        return
    default:
        stats.otherFileCount += 1
        if topLevel != "agents", path.deletingLastPathComponent() != root {
            otherFolders.insert(topLevel)
        }
    }
}

private func topLevelComponent(root: URL, path: URL) -> String? {
    let rootComponents = root.standardizedFileURL.pathComponents
    let pathComponents = path.standardizedFileURL.pathComponents
    guard pathComponents.count > rootComponents.count else { return nil }
    return pathComponents[rootComponents.count]
}

private func readOpenAIYaml(skillDir: URL, stats: inout SkillStats) {
    let path = skillDir.appendingPathComponent("agents").appendingPathComponent("openai.yaml")
    guard let text = try? String(contentsOf: path, encoding: .utf8) else { return }
    stats.hasOpenAIYaml = true
    stats.iconSmallPath = yamlValue(key: "icon_small", text: text).map {
        skillDir.appendingPathComponent($0).standardizedFileURL.path
    }
    stats.iconLargePath = yamlValue(key: "icon_large", text: text).map {
        skillDir.appendingPathComponent($0).standardizedFileURL.path
    }
    stats.hasIconSmall = stats.iconSmallPath != nil
    stats.hasIconLarge = stats.iconLargePath != nil
}

private func yamlValue(key: String, text: String) -> String? {
    let prefix = "\(key):"
    for line in text.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(prefix) else { continue }
        let value = String(trimmed.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return value.isEmpty ? nil : value
    }
    return nil
}

private func estimateTokens(_ characterCount: Int) -> Int {
    (characterCount + 3) / 4
}

private func folderKind(path: URL, location: String, originKind: String, symlinkedContainer: Bool) -> String {
    if symlinkedContainer {
        return "symlinked"
    }
    if path.pathComponents.contains(".system") {
        return "system"
    }
    if location == "agents", originKind == "npx-skills" {
        return "npx-installed"
    }
    if location == "agents" {
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

private func readSkillLock(_ path: URL) -> [String: SkillLockEntry] {
    guard let data = try? Data(contentsOf: path) else { return [:] }
    return (try? JSONDecoder().decode(SkillLock.self, from: data).skills) ?? [:]
}

private func hasProjectInventorySurface(_ project: SkillProject) -> Bool {
    !project.validSkills.isEmpty
        || !project.skills.isEmpty
        || !project.invalidSkillDirs.isEmpty
        || !project.hiddenSkillDirs.isEmpty
}

private func hasAgentsSyncSurface(_ project: SkillProject) -> Bool {
    !project.validSkills.isEmpty
        || !project.invalidSkillDirs.isEmpty
        || !project.hiddenSkillDirs.isEmpty
}

private func checkAgentsToml(project: SkillProject, issues: inout [DoctorIssue]) {
    let root = URL(fileURLWithPath: project.root)
    let primary = root.appendingPathComponent("agents.toml")
    let nested = root.appendingPathComponent(".agents").appendingPathComponent("agents.toml")
    let agentsToml = fileManager.fileExists(atPath: primary.path) ? primary
        : (fileManager.fileExists(atPath: nested.path) ? nested : nil)

    guard let agentsToml else {
        issues.append(.init(severity: .warning, message: "\(primary.path) missing"))
        return
    }

    issues.append(.init(severity: .ok, message: "\(agentsToml.path) exists"))

    let lock = agentsToml.path == nested.path
        ? root.appendingPathComponent(".agents").appendingPathComponent("agents.lock")
        : root.appendingPathComponent("agents.lock")
    if !fileManager.fileExists(atPath: lock.path) {
        issues.append(.init(severity: .warning, message: "\(lock.path) missing"))
    }

    guard let text = try? String(contentsOf: agentsToml, encoding: .utf8) else {
        issues.append(.init(severity: .warning, message: "\(agentsToml.path) could not be read"))
        return
    }

    let declarations = parseAgentsTomlDeclarations(text)
    if declarations.isEmpty {
        issues.append(.init(severity: .warning, message: "\(agentsToml.path) declares no skills"))
        return
    }

    let actual = Set(project.validSkills)
    let declared = Set(declarations.compactMap(declaredSkillName))

    for (name, sourceName) in declarationNameSourceMismatches(declarations) {
        issues.append(.init(
            severity: .warning,
            message: "\(agentsToml.path) declares skill \(name) with mismatched path source basename \(sourceName)"
        ))
    }
    for name in actual.subtracting(declared).sorted() {
        issues.append(.init(
            severity: .warning,
            message: "\(project.root)/.agents/skills has on-disk skill not declared in \(agentsToml.path): \(name)"
        ))
    }
    for name in declared.subtracting(actual).sorted() {
        issues.append(.init(
            severity: .warning,
            message: "\(agentsToml.path) declares missing skill folder: \(name)"
        ))
    }
}

private func syncProject(
    _ project: SkillProject,
    options: SkillsSyncOptions,
    agents: [String]
) throws -> [SkillsSyncLine] {
    let root = URL(fileURLWithPath: project.root)
    var lines: [SkillsSyncLine] = [
        .init(kind: .info, text: "valid local skills: \(project.validSkills.count)")
    ]

    if !project.hiddenSkillDirs.isEmpty {
        lines.append(.init(kind: .warning, text: "warning: \(project.hiddenSkillDirs.count) hidden skill dir(s) ignored"))
    }
    for invalid in project.invalidSkillDirs {
        lines.append(.init(kind: .warning, text: "warning: skipped invalid skill name: \(invalid)"))
    }
    if project.validSkills.isEmpty {
        lines.append(.init(kind: .skipped, text: "skipped: no valid SKILL.md folders"))
        return lines
    }

    try retireNestedAgentsToml(root: root, options: options, lines: &lines)
    guard try ensureAgentsToml(project: project, options: options, agents: agents, lines: &lines) else {
        return lines
    }
    try prepareClaudeSkills(root: root, options: options, lines: &lines)

    if options.runDotagents {
        if options.apply {
            let result = runProcess(
                "/usr/bin/env",
                arguments: ["npx", "@sentry/dotagents", "sync"],
                currentDirectory: root,
                environment: ["PATH": augmentedPath()]
            )
            if result.exitCode == 0 {
                lines.append(.init(kind: .action, text: "dotagents: synced"))
                for line in result.stdout.nonEmptyLines {
                    lines.append(.init(kind: .action, text: "dotagents: \(line)"))
                }
                for line in result.stderr.nonEmptyLines {
                    lines.append(.init(kind: .warning, text: "warning: dotagents: \(line)"))
                }
            } else {
                let details = (result.stderr + "\n" + result.stdout).nonEmptyLines.joined(separator: "\n")
                throw NSError(domain: "MetagentDotagents", code: Int(result.exitCode), userInfo: [
                    NSLocalizedDescriptionKey: "dotagents sync failed\(details.isEmpty ? "" : "\n\(details)")"
                ])
            }
        } else {
            lines.append(.init(kind: .action, text: "would run: npx @sentry/dotagents sync"))
        }
    } else {
        lines.append(.init(kind: .skipped, text: "skipped dotagents sync"))
    }

    return lines
}

private func retireNestedAgentsToml(
    root: URL,
    options: SkillsSyncOptions,
    lines: inout [SkillsSyncLine]
) throws {
    let nested = root.appendingPathComponent(".agents").appendingPathComponent("agents.toml")
    guard fileManager.fileExists(atPath: nested.path) else { return }

    let backup = timestampedBackupPath(for: nested)
    if options.apply {
        try fileManager.moveItem(at: nested, to: backup)
        lines.append(.init(kind: .action, text: "moved ignored nested config to \(backup.path)"))
    } else {
        lines.append(.init(kind: .action, text: "would move ignored nested config to \(backup.path)"))
    }
}

private func ensureAgentsToml(
    project: SkillProject,
    options: SkillsSyncOptions,
    agents: [String],
    lines: inout [SkillsSyncLine]
) throws -> Bool {
    let root = URL(fileURLWithPath: project.root)
    let agentsToml = root.appendingPathComponent("agents.toml")

    if fileManager.fileExists(atPath: agentsToml.path), !options.rewriteAgentsToml {
        lines.append(.init(kind: .info, text: "kept existing \(agentsToml.path)"))
        return true
    }

    if options.syncOnly, !fileManager.fileExists(atPath: agentsToml.path) {
        lines.append(.init(kind: .skipped, text: "skipped: \(agentsToml.path) missing and --sync-only is set"))
        return false
    }

    if options.apply {
        if fileManager.fileExists(atPath: agentsToml.path) {
            let backup = timestampedBackupPath(for: agentsToml)
            try fileManager.copyItem(at: agentsToml, to: backup)
            lines.append(.init(kind: .action, text: "backed up existing agents.toml to \(backup.path)"))
        }
        try renderAgentsToml(project, agents: agents).write(to: agentsToml, atomically: true, encoding: .utf8)
        lines.append(.init(kind: .action, text: "wrote \(agentsToml.path)"))
    } else if fileManager.fileExists(atPath: agentsToml.path) {
        lines.append(.init(kind: .action, text: "would rewrite \(agentsToml.path)"))
    } else {
        lines.append(.init(kind: .action, text: "would create \(agentsToml.path)"))
    }

    return true
}

private func renderAgentsToml(_ project: SkillProject, agents: [String]) -> String {
    var out = """
    version = 1
    agents = [\(agents.map(tomlEscape).map { "\"\($0)\"" }.joined(separator: ", "))]

    [trust]
    allow_all = true

    """
    for skill in project.validSkills {
        out += """

        [[skills]]
        name = "\(tomlEscape(skill))"
        source = "path:.agents/skills/\(tomlEscape(skill))"
        """
        out += "\n"
    }
    return out
}

private func prepareClaudeSkills(
    root: URL,
    options: SkillsSyncOptions,
    lines: inout [SkillsSyncLine]
) throws {
    let claudeDir = root.appendingPathComponent(".claude")
    let claudeSkills = claudeDir.appendingPathComponent("skills")

    if isSymlink(claudeSkills) || !fileManager.fileExists(atPath: claudeSkills.path) {
        return
    }

    if fileManager.fileExists(atPath: claudeSkills.path), !options.replaceClaudeSkills {
        lines.append(.init(
            kind: .skipped,
            text: "skipped: \(claudeSkills.path) exists and is not a symlink; pass --replace-claude-skills"
        ))
        return
    }

    if options.apply {
        try fileManager.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let backup = timestampedBackupPath(for: claudeSkills)
        try fileManager.moveItem(at: claudeSkills, to: backup)
        lines.append(.init(kind: .action, text: "moved existing .claude/skills to \(backup.path)"))
    } else {
        lines.append(.init(kind: .action, text: "would move existing .claude/skills to a backup"))
    }
}

private func renderLaunchAgentPlist(program: String, interval: Int) -> String {
    let logs = logsURL().path
    return """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key>
      <string>\(MetagentCore.launchAgentLabel)</string>
      <key>ProgramArguments</key>
      <array>
        <string>\(xmlEscape(program))</string>
        <string>skills</string>
        <string>sync</string>
        <string>--apply</string>
      </array>
      <key>EnvironmentVariables</key>
      <dict>
        <key>PATH</key>
        <string>\(xmlEscape(augmentedPath()))</string>
      </dict>
      <key>StartInterval</key>
      <integer>\(interval)</integer>
      <key>RunAtLoad</key>
      <true/>
      <key>StandardOutPath</key>
      <string>\(xmlEscape(logs))/skills-sync.out.log</string>
      <key>StandardErrorPath</key>
      <string>\(xmlEscape(logs))/skills-sync.err.log</string>
    </dict>
    </plist>
    """
}

private func launchAgentPlistURL(label: String = MetagentCore.launchAgentLabel) -> URL {
    homeURL()
        .appendingPathComponent("Library")
        .appendingPathComponent("LaunchAgents")
        .appendingPathComponent("\(label).plist")
}

private func launchctlExecutablePath() -> String {
    ProcessInfo.processInfo.environment["METAGENT_LAUNCHCTL"] ?? "/bin/launchctl"
}

private func psExecutablePath() -> String {
    ProcessInfo.processInfo.environment["METAGENT_PS"] ?? "/bin/ps"
}

private func launchAgentDomain() -> String {
    "gui/\(getuid())"
}

private func launchAgentJob(_ label: String) -> String {
    "\(launchAgentDomain())/\(label)"
}

private func bootoutLaunchAgent(label: String) -> ProcessOutput {
    runProcess(launchctlExecutablePath(), arguments: ["bootout", launchAgentJob(label)])
}

private func retireLegacyLaunchAgent() -> [String] {
    let plist = launchAgentPlistURL(label: MetagentCore.legacyLaunchAgentLabel)
    var lines: [String] = []

    if bootoutLaunchAgent(label: MetagentCore.legacyLaunchAgentLabel).exitCode == 0 {
        lines.append("unloaded legacy LaunchAgent \(MetagentCore.legacyLaunchAgentLabel)")
    }

    guard fileManager.fileExists(atPath: plist.path) else { return lines }
    do {
        var trashedURL: NSURL?
        try fileManager.trashItem(at: plist, resultingItemURL: &trashedURL)
        lines.append("moved legacy plist to Trash: \(plist.path)")
    } catch {
        do {
            try fileManager.removeItem(at: plist)
            lines.append("removed legacy plist: \(plist.path)")
        } catch {
            lines.append("warning: failed removing legacy plist \(plist.path): \(error.localizedDescription)")
        }
    }

    return lines
}

private func logsURL() -> URL {
    homeURL()
        .appendingPathComponent("Library")
        .appendingPathComponent("Logs")
        .appendingPathComponent("metagent")
}

private func defaultHelperPath() throws -> String {
    let bundledHelper = Bundle.main.bundleURL
        .appendingPathComponent("Contents")
        .appendingPathComponent("Helpers")
        .appendingPathComponent("metagent")
    if fileManager.isExecutableFile(atPath: bundledHelper.path) {
        return bundledHelper.path
    }

    if let currentExecutable = Bundle.main.executableURL,
       currentExecutable.lastPathComponent == "metagent",
       fileManager.isExecutableFile(atPath: currentExecutable.path)
    {
        return currentExecutable.path
    }

    let candidates = [
        "/opt/homebrew/bin/metagent",
        "/usr/local/bin/metagent",
        homeURL().appendingPathComponent(".local/bin/metagent").path
    ]

    for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
        return candidate
    }

    throw NSError(domain: "MetagentLaunchAgent", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "Could not find a metagent helper. Install the CLI or use --program PATH."
    ])
}

private func runProcess(
    _ executable: String,
    arguments: [String],
    currentDirectory: URL? = nil,
    environment: [String: String] = [:]
) -> ProcessOutput {
    let tempDir = fileManager.temporaryDirectory
        .appendingPathComponent("metagent-process-\(UUID().uuidString)")
    let stdoutURL = tempDir.appendingPathComponent("stdout.log")
    let stderrURL = tempDir.appendingPathComponent("stderr.log")

    do {
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        _ = fileManager.createFile(atPath: stdoutURL.path, contents: nil)
        _ = fileManager.createFile(atPath: stderrURL.path, contents: nil)
    } catch {
        return ProcessOutput(exitCode: 127, stdout: "", stderr: error.localizedDescription)
    }
    defer {
        try? fileManager.removeItem(at: tempDir)
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectory
    if !environment.isEmpty {
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
    }

    do {
        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        try process.run()
        process.waitUntilExit()
        try? stdoutHandle.close()
        try? stderrHandle.close()
        let stdout = (try? Data(contentsOf: stdoutURL)) ?? Data()
        let stderr = (try? Data(contentsOf: stderrURL)) ?? Data()
        return ProcessOutput(
            exitCode: process.terminationStatus,
            stdout: String(data: stdout, encoding: .utf8) ?? "",
            stderr: String(data: stderr, encoding: .utf8) ?? ""
        )
    } catch {
        return ProcessOutput(exitCode: 127, stdout: "", stderr: error.localizedDescription)
    }
}

private func augmentedPath() -> String {
    let fallbacks = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin"
    ]
    var parts = ProcessInfo.processInfo.environment["PATH"]?
        .split(separator: ":", omittingEmptySubsequences: false)
        .map(String.init) ?? []

    for fallback in fallbacks where !parts.contains(fallback) {
        parts.append(fallback)
    }

    return parts.joined(separator: ":")
}

private final class SkillInventoryCache {
    private let path: URL

    init(path: URL? = nil) throws {
        self.path = path ?? homeURL()
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Metagent")
            .appendingPathComponent("inventory.sqlite")
        try fileManager.createDirectory(at: self.path.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    func save(_ report: SkillScanReport) throws {
        let data = try JSONEncoder().encode(report)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        var db: OpaquePointer?
        try open(&db)
        defer { sqlite3_close(db) }
        try exec(db, """
        CREATE TABLE IF NOT EXISTS inventory_snapshots (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            updated_at TEXT NOT NULL,
            json TEXT NOT NULL
        );
        """)
        try exec(db, "DELETE FROM inventory_snapshots WHERE id = 1;")
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT INTO inventory_snapshots (id, updated_at, json) VALUES (1, datetime('now'), ?);",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            throw cacheError(db, "prepare insert")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, json, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw cacheError(db, "insert snapshot")
        }
    }

    func load() throws -> SkillScanReport? {
        var db: OpaquePointer?
        try open(&db)
        defer { sqlite3_close(db) }
        try exec(db, """
        CREATE TABLE IF NOT EXISTS inventory_snapshots (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            updated_at TEXT NOT NULL,
            json TEXT NOT NULL
        );
        """)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT json FROM inventory_snapshots WHERE id = 1;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            throw cacheError(db, "prepare select")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let text = sqlite3_column_text(statement, 0) else { return nil }
        let json = String(cString: text)
        return try JSONDecoder().decode(SkillScanReport.self, from: Data(json.utf8))
    }

    private func open(_ db: inout OpaquePointer?) throws {
        guard sqlite3_open(path.path, &db) == SQLITE_OK else {
            throw cacheError(db, "open \(path.path)")
        }
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw cacheError(db, "exec")
        }
    }

    private func cacheError(_ db: OpaquePointer?, _ action: String) -> NSError {
        let message = db.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:)) ?? "unknown sqlite error"
        return NSError(domain: "MetagentSQLite", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "\(action): \(message)"
        ])
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func isDirectoryOrSymlinkedDirectory(_ url: URL) -> Bool {
    var isDirectory = ObjCBool(false)
    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
    return isDirectory.boolValue
}

private func isRegularOrSymlinkedFile(_ url: URL) -> Bool {
    if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
        return true
    }
    var isDirectory = ObjCBool(false)
    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
    return isSymlink(url) && !isDirectory.boolValue
}

private func isSymlink(_ url: URL) -> Bool {
    (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
}

private func skillContainerEntries(at url: URL) -> [URL]? {
    guard let names = try? fileManager.contentsOfDirectory(atPath: url.path) else {
        return nil
    }
    return names.map { url.appendingPathComponent($0) }
}

private func isKnownSkillContainerDirectory(_ url: URL) -> Bool {
    guard url.lastPathComponent == "skills" else {
        return false
    }
    let parent = url.deletingLastPathComponent().lastPathComponent
    return [".agents", ".codex", ".claude"].contains(parent)
}

private func shouldPrune(name: String) -> Bool {
    if [
        ".git",
        ".hg",
        ".svn",
        ".build",
        ".next",
        "node_modules",
        "target",
        "dist",
        "build",
        "vendor",
        "DerivedData"
    ].contains(name) {
        return true
    }
    if name.hasPrefix("."), ![".agents", ".codex", ".claude"].contains(name) {
        return true
    }
    return false
}

private func shouldPruneSkillContainer(name: String) -> Bool {
    [
        ".git",
        ".hg",
        ".svn",
        ".build",
        ".next",
        "node_modules",
        "target",
        "dist",
        "DerivedData",
        "build",
        "vendor"
    ].contains(name)
}

private func isValidSkillName(_ name: String) -> Bool {
    guard let first = name.unicodeScalars.first, isASCIIAlphanumeric(first) else {
        return false
    }
    for scalar in name.unicodeScalars.dropFirst() {
        guard isASCIIAlphanumeric(scalar) || scalar == "." || scalar == "_" || scalar == "-" else {
            return false
        }
    }
    return true
}

private func isASCIIAlphanumeric(_ scalar: UnicodeScalar) -> Bool {
    let value = scalar.value
    return (value >= 48 && value <= 57)
        || (value >= 65 && value <= 90)
        || (value >= 97 && value <= 122)
}

private func isSkillTextFile(_ url: URL) -> Bool {
    switch url.pathExtension.lowercased() {
    case "md", "markdown", "txt", "toml", "yaml", "yml", "json", "sh", "py", "js", "ts", "tsx", "css", "html":
        return true
    default:
        return false
    }
}

private func parseAgentsTomlDeclarations(_ text: String) -> [AgentsTomlDeclaration] {
    var declarations: [AgentsTomlDeclaration] = []
    var current: AgentsTomlDeclaration?

    for rawLine in uncommentedConfigText(text).split(separator: "\n", omittingEmptySubsequences: false) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty {
            continue
        }
        if line.replacingOccurrences(of: " ", with: "") == "[[skills]]" {
            appendDeclaration(current, to: &declarations)
            current = AgentsTomlDeclaration()
            continue
        }
        if line.hasPrefix("[") {
            appendDeclaration(current, to: &declarations)
            current = nil
            continue
        }
        guard current != nil, let (rawKey, rawValue) = line.splitOnce("=") else {
            continue
        }
        let value = quotedStrings(in: String(rawValue)).first
        switch rawKey.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "name":
            current?.name = value
        case "source":
            current?.source = value
        default:
            break
        }
    }

    appendDeclaration(current, to: &declarations)
    return declarations
}

private func appendDeclaration(_ declaration: AgentsTomlDeclaration?, to declarations: inout [AgentsTomlDeclaration]) {
    guard let declaration, declaration.name != nil || declaration.source != nil else {
        return
    }
    declarations.append(declaration)
}

private func declaredSkillName(_ declaration: AgentsTomlDeclaration) -> String? {
    if let name = declaration.name {
        return name
    }
    return skillNameFromSource(declaration.source)
}

private func declarationNameSourceMismatches(_ declarations: [AgentsTomlDeclaration]) -> [(String, String)] {
    declarations.compactMap { declaration in
        guard let name = declaration.name, let sourceName = skillNameFromSource(declaration.source), name != sourceName else {
            return nil
        }
        return (name, sourceName)
    }
}

private func skillNameFromSource(_ source: String?) -> String? {
    guard let source, source.hasPrefix("path:") else {
        return nil
    }
    let name = source
        .dropFirst("path:".count)
        .split(separator: "/")
        .last
        .map(String.init)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return name?.isEmpty == false ? name : nil
}

private func parseStringArray(key: String, text: String) throws -> [String]? {
    guard let body = firstRegexCapture(pattern: "\\b\(key)\\s*=\\s*\\[([\\s\\S]*?)\\]", text: text) else {
        if hasConfigAssignment(key: key, text: text) {
            throw configError("\(key) must be a TOML string array")
        }
        return nil
    }
    return try parseStringArrayBody(body, key: key)
}

private func parseStringArrayBody(_ body: String, key: String) throws -> [String] {
    var values: [String] = []
    var index = body.startIndex

    func skipWhitespace() {
        while index < body.endIndex, body[index].isWhitespace {
            index = body.index(after: index)
        }
    }

    skipWhitespace()
    if index == body.endIndex {
        return values
    }

    while index < body.endIndex {
        skipWhitespace()
        guard index < body.endIndex else { return values }
        let quote = body[index]
        guard quote == "\"" || quote == "'" else {
            throw configError("\(key) must be a TOML string array")
        }
        index = body.index(after: index)

        var value = ""
        var escaped = false
        var closed = false
        while index < body.endIndex {
            let character = body[index]
            index = body.index(after: index)
            if escaped {
                value.append(character)
                escaped = false
                continue
            }
            if quote == "\"", character == "\\" {
                escaped = true
                continue
            }
            if character == quote {
                values.append(value)
                closed = true
                break
            }
            value.append(character)
        }

        guard closed else {
            throw configError("\(key) must be a TOML string array")
        }

        skipWhitespace()
        guard index < body.endIndex else { return values }
        guard body[index] == "," else {
            throw configError("\(key) must be a TOML string array")
        }
        index = body.index(after: index)
        skipWhitespace()
    }

    return values
}

private func uncommentedConfigText(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .map(stripTomlComment)
        .joined(separator: "\n")
}

private func stripTomlComment(_ line: Substring) -> String {
    var output = ""
    var quote: Character?
    var escaped = false

    for character in line {
        if let activeQuote = quote {
            output.append(character)
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == activeQuote {
                quote = nil
            }
            continue
        }

        if character == "#" {
            break
        }
        output.append(character)
        if character == "\"" || character == "'" {
            quote = character
        }
    }

    return output
}

private func parseInteger(key: String, text: String) throws -> Int? {
    guard let value = firstRegexCapture(pattern: "\\b\(key)\\s*=\\s*([^\\n]*)", text: text) else {
        if hasConfigAssignment(key: key, text: text) {
            throw configError("\(key) must be an integer")
        }
        return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil,
          let parsed = Int(trimmed)
    else {
        throw configError("\(key) must be an integer")
    }
    return parsed
}

private func hasConfigAssignment(key: String, text: String) -> Bool {
    let pattern = "\\b\(key)\\s*="
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.firstMatch(in: text, range: range) != nil
}

private func configError(_ message: String) -> NSError {
    NSError(domain: "MetagentConfig", code: 1, userInfo: [
        NSLocalizedDescriptionKey: message
    ])
}

private func firstRegexCapture(pattern: String, text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1 else {
        return nil
    }
    guard let swiftRange = Range(match.range(at: 1), in: text) else { return nil }
    return String(text[swiftRange])
}

private func quotedStrings(in text: String) -> [String] {
    var values: [String] = []
    var current = ""
    var quote: Character?
    var escaped = false

    for character in text {
        if let activeQuote = quote {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == activeQuote {
                values.append(current)
                current = ""
                quote = nil
            } else {
                current.append(character)
            }
        } else if character == "\"" || character == "'" {
            quote = character
        }
    }

    return values
}

private func tomlEscape(_ text: String) -> String {
    text.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

private func xmlEscape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

private func timestampForFilename() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMddHHmmss"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter.string(from: Date())
}

private func timestampedBackupPath(for path: URL) -> URL {
    let baseName = "\(path.lastPathComponent).bak-metagent-\(timestampForFilename())"
    var candidate = path.deletingLastPathComponent().appendingPathComponent(baseName)
    var suffix = 2
    while fileManager.fileExists(atPath: candidate.path) {
        candidate = path.deletingLastPathComponent().appendingPathComponent("\(baseName)-\(suffix)")
        suffix += 1
    }
    return candidate
}

private extension String {
    var nonEmptyLines: [String] {
        split(whereSeparator: \.isNewline)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var nonEmpty: String? {
        isEmpty ? nil : self
    }

    func removingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }

    func splitOnce(_ separator: Character) -> (Substring, Substring)? {
        guard let index = firstIndex(of: separator) else { return nil }
        return (self[..<index], self[self.index(after: index)...])
    }
}
