import Foundation
import Darwin
import SQLite3
import CryptoKit

public struct MetagentConfig: Codable, Equatable, Sendable {
    public var roots: [String]
    public var maxDepth: Int
    public var ignoreProjects: [String]

    public init(
        roots: [String],
        maxDepth: Int = 6,
        ignoreProjects: [String] = []
    ) {
        self.roots = roots
        self.maxDepth = maxDepth
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
    public var warnings: [String]

    public init(projects: [SkillProject], warnings: [String] = []) {
        self.projects = projects
        self.warnings = warnings
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
    public var scope: String
    public var manager: String
    public var authority: String
    public var mutability: String
    public var representation: String
    public var canonicalPath: String
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
        scope: String,
        manager: String,
        authority: String,
        mutability: String,
        representation: String,
        canonicalPath: String,
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
        self.scope = scope
        self.manager = manager
        self.authority = authority
        self.mutability = mutability
        self.representation = representation
        self.canonicalPath = canonicalPath
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
        case scope
        case manager
        case authority
        case mutability
        case representation
        case canonicalPath = "canonical_path"
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

    public var repairableCount: Int {
        issues.filter { $0.severity != .ok && $0.repairAction != nil }.count
    }

    public var reviewCount: Int {
        warningCount + failureCount - repairableCount
    }

    public init(issues: [DoctorIssue]) {
        self.issues = issues
    }
}

public struct DoctorIssue: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(severity.rawValue):\(message)" }
    public var severity: DoctorSeverity
    public var message: String
    public var summary: String?
    public var projectRoot: String?
    public var category: DoctorIssueCategory?
    public var guidance: String?
    public var repairAction: DoctorRepairAction?

    public init(
        severity: DoctorSeverity,
        message: String,
        summary: String? = nil,
        projectRoot: String? = nil,
        category: DoctorIssueCategory? = nil,
        guidance: String? = nil,
        repairAction: DoctorRepairAction? = nil
    ) {
        self.severity = severity
        self.message = message
        self.summary = summary
        self.projectRoot = projectRoot
        self.category = category
        self.guidance = guidance
        self.repairAction = repairAction
    }

    private enum CodingKeys: String, CodingKey {
        case severity
        case message
        case summary
        case projectRoot = "project_root"
        case category
        case guidance
        case repairAction = "repair_action"
    }
}

public enum DoctorIssueCategory: String, Codable, Hashable, Sendable {
    case project
    case skills
    case projection
}

public enum DoctorRepairAction: String, Codable, Hashable, Sendable {
    case repairProjection = "repair_projection"
}

public enum DoctorSeverity: String, Codable, Sendable {
    case ok = "OK"
    case warning = "WARN"
    case failure = "FAIL"
}

public struct SkillsRepairOptions: Equatable, Sendable {
    public var apply: Bool
    public var scanOptions: SkillScanOptions

    public init(
        apply: Bool = false,
        scanOptions: SkillScanOptions = SkillScanOptions()
    ) {
        self.apply = apply
        self.scanOptions = scanOptions
    }
}

public struct SkillsRepairReport: Codable, Equatable, Sendable {
    public var apply: Bool
    public var mode: String
    public var summary: SkillsRepairSummary
    public var projects: [SkillsRepairProject]

    public init(apply: Bool, projects: [SkillsRepairProject]) {
        self.apply = apply
        self.mode = apply ? "APPLY" : "DRY-RUN"
        self.projects = projects
        self.summary = SkillsRepairSummary(projects: projects)
    }
}

public struct SkillsRepairSummary: Codable, Equatable, Sendable {
    public var projectCount: Int
    public var validSkillCount: Int
    public var warningCount: Int
    public var actionCount: Int
    public var skippedCount: Int

    public init(projects: [SkillsRepairProject]) {
        self.projectCount = projects.count
        self.validSkillCount = projects.reduce(0) { $0 + $1.validSkillCount }
        self.warningCount = projects.reduce(0) { $0 + $1.warningCount }
        self.actionCount = projects.reduce(0) { $0 + $1.actionCount }
        self.skippedCount = projects.reduce(0) { $0 + $1.skippedCount }
    }

    private enum CodingKeys: String, CodingKey {
        case projectCount = "project_count"
        case validSkillCount = "valid_skill_count"
        case warningCount = "warning_count"
        case actionCount = "action_count"
        case skippedCount = "skipped_count"
    }
}

public struct SkillsRepairProject: Codable, Equatable, Identifiable, Sendable {
    public var id: String { root }
    public var root: String
    public var name: String
    public var validSkillCount: Int
    public var warningCount: Int
    public var actionCount: Int
    public var skippedCount: Int
    public var lines: [SkillsRepairLine]

    public init(root: String, lines: [SkillsRepairLine]) {
        self.root = root
        self.name = URL(fileURLWithPath: root).lastPathComponent
        self.lines = lines
        self.validSkillCount = Self.validSkillCount(from: lines)
        self.warningCount = lines.filter { $0.kind == .warning }.count
        self.actionCount = lines.filter { $0.kind == .action }.count
        self.skippedCount = lines.filter { $0.kind == .skipped }.count
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

    private static func validSkillCount(from lines: [SkillsRepairLine]) -> Int {
        for line in lines {
            guard let value = line.text.removingPrefix("valid local skills: ") else { continue }
            return Int(value.trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return 0
    }
}

public struct SkillsRepairLine: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(kind.rawValue):\(text)" }
    public var kind: SkillsRepairLineKind
    public var text: String

    public init(kind: SkillsRepairLineKind, text: String) {
        self.kind = kind
        self.text = text
    }
}

public enum SkillsRepairLineKind: String, Codable, Sendable {
    case action
    case warning
    case skipped
    case info
}

public struct SkillUninstallReport: Codable, Equatable, Sendable {
    public var projectRoot: String
    public var skillName: String
    public var backupPath: String?
    public var lines: [String]

    public init(projectRoot: String, skillName: String, backupPath: String?, lines: [String]) {
        self.projectRoot = projectRoot
        self.skillName = skillName
        self.backupPath = backupPath
        self.lines = lines
    }
}

public struct SkillRemovalPlan: Codable, Equatable, Sendable {
    public var projectRoot: String
    public var skillName: String
    public var manager: String
    public var mutability: String
    public var command: String?
    public var applySupported: Bool

    public init(
        projectRoot: String,
        skillName: String,
        manager: String,
        mutability: String,
        command: String?,
        applySupported: Bool
    ) {
        self.projectRoot = projectRoot
        self.skillName = skillName
        self.manager = manager
        self.mutability = mutability
        self.command = command
        self.applySupported = applySupported
    }
}

private struct CodexPluginList: Decodable {
    var installed: [CodexPlugin]
}

private struct CodexPlugin: Decodable {
    struct Source: Decodable {
        var path: String?
    }

    var pluginId: String
    var name: String
    var marketplaceName: String
    var version: String
    var installed: Bool
    var enabled: Bool
    var source: Source
}

public enum MetagentCore {

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
        let ignoreProjects = try parseStringArray(key: "ignore_projects", text: configText) ?? []
        let maxDepth = try parseInteger(key: "max_depth", text: configText) ?? 6
        return MetagentConfig(
            roots: roots.isEmpty ? defaultRootPaths() : roots,
            maxDepth: maxDepth,
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

    public static func scanCodexPlugins() throws -> SkillScanReport {
        let plugins = try installedCodexPlugins()
        let projects = plugins.compactMap(readCodexPluginSkills).sorted { $0.root < $1.root }
        return SkillScanReport(projects: projects)
    }

    public static func scanPortfolio(
        options: SkillScanOptions = SkillScanOptions(),
        homeDepth: Int = 2
    ) throws -> SkillScanReport {
        let configured = try scanSkills(options: options)
        let home = try scanHomeSkills(maxDepth: homeDepth)
        var projects = Dictionary(uniqueKeysWithValues: configured.projects.map { ($0.root, $0) })
        for project in home.projects {
            projects[project.root] = projects[project.root].map { mergeSkillProjects($0, project) } ?? project
        }
        var warnings = configured.warnings + home.warnings
        do {
            for project in try scanCodexPlugins().projects {
                projects[project.root] = projects[project.root].map { mergeSkillProjects($0, project) } ?? project
            }
        } catch {
            warnings.append("Codex plugin inventory unavailable: \(error.localizedDescription)")
        }
        return SkillScanReport(projects: projects.values.sorted { $0.root < $1.root }, warnings: warnings)
    }

    public static func doctor(options: SkillScanOptions = SkillScanOptions()) throws -> DoctorReport {
        let report = try scanSkills(options: options)
        var projects = report.projects
        if options.roots.isEmpty,
           let homeProject = try scanHomeSkills(maxDepth: 0).projects.first(where: {
               canonicalProjectPath(URL(fileURLWithPath: $0.root)) == canonicalProjectPath(homeURL())
           }),
           !projects.contains(where: { canonicalProjectPath(URL(fileURLWithPath: $0.root)) == canonicalProjectPath(homeURL()) })
        {
            projects.append(homeProject)
        }
        var issues: [DoctorIssue] = []

        if projects.isEmpty {
            issues.append(.init(
                severity: .warning,
                message: "no projects with skills found",
                summary: "No skill projects found",
                category: .project,
                guidance: "Review Metagent's configured roots."
            ))
        }

        for project in projects {
            let projectRoot = URL(fileURLWithPath: project.root)
            let isHomeProject = canonicalProjectPath(projectRoot) == canonicalProjectPath(homeURL())

            let unexpectedLock = isHomeProject
                ? projectRoot.appendingPathComponent("skills-lock.json")
                : projectRoot.appendingPathComponent(".agents/.skill-lock.json")
            if fileManager.fileExists(atPath: unexpectedLock.path) {
                issues.append(.init(
                    severity: .warning,
                    message: "\(unexpectedLock.path) is a legacy lock location and is not used for ownership",
                    summary: "Legacy skills lock ignored",
                    projectRoot: project.root,
                    category: .skills,
                    guidance: isHomeProject
                        ? "Global skills-cli ownership comes from .agents/.skill-lock.json. Review and remove the root skills-lock.json."
                        : "Project skills-cli ownership comes from the root skills-lock.json. Review and remove the nested legacy lock."
                ))
            }

            let obsoleteCodexProjections = project.skills.filter {
                $0.location == "codex" && $0.representation == "projection"
            }
            if !obsoleteCodexProjections.isEmpty {
                issues.append(.init(
                    severity: .warning,
                    message: "\(project.root) has \(obsoleteCodexProjections.count) obsolete .codex skill projection(s)",
                    summary: "Obsolete Codex skill projections",
                    projectRoot: project.root,
                    category: .projection,
                    guidance: "Codex now discovers .agents/skills directly. Review these links, then remove only the projections."
                ))
            }

            if project.validSkills.isEmpty {
                issues.append(.init(
                    severity: .warning,
                    message: "\(project.root) has no valid .agents skills",
                    summary: "No valid .agents skills",
                    projectRoot: project.root,
                    category: .skills,
                    guidance: "Remove stale agent configuration or add a valid SKILL.md bundle."
                ))
            } else {
                issues.append(.init(
                    severity: .ok,
                    message: "\(project.root) has \(project.validSkills.count) valid skills",
                    projectRoot: project.root,
                    category: .skills
                ))
            }

            for path in project.invalidSkillDirs {
                issues.append(.init(
                    severity: .warning,
                    message: "\(path) is not a valid skill directory",
                    summary: "Invalid skill directory",
                    projectRoot: project.root,
                    category: .skills,
                    guidance: "Rename or remove the directory so it uses a portable skill name."
                ))
            }

            for path in project.hiddenSkillDirs {
                issues.append(.init(
                    severity: .warning,
                    message: "\(path) is hidden and ignored by Metagent",
                    summary: "Hidden skill directory ignored",
                    projectRoot: project.root,
                    category: .skills,
                    guidance: "Rename or remove the hidden directory if it should be an active skill."
                ))
            }

            let lock = readProjectSkillLocks(root: projectRoot)
            for skill in project.skills where skill.location == "agents" && skill.manager == "skills-cli" {
                guard let lockEntry = lock[skill.name],
                      let expectedHash = lockEntry.computedHash ?? lockEntry.skillFolderHash,
                      !expectedHash.isEmpty,
                      let actualHash = try? computeSkillFolderHash(URL(fileURLWithPath: skill.path)),
                      actualHash != expectedHash
                else { continue }
                issues.append(.init(
                    severity: .warning,
                    message: "\(skill.path) differs from its skills CLI installation hash",
                    summary: "Managed skill modified locally",
                    projectRoot: project.root,
                    category: .skills,
                    guidance: "Avoid editing this managed bundle. Reinstall or update it through the skills CLI, or copy it to a separately named local skill first."
                ))
            }

            // Global agent skill locations are inventory-only. Claude may keep
            // independent global skills there, so project projection rules do
            // not apply to the home directory.
            if isHomeProject {
                continue
            }

            let claudeDirectory = projectRoot.appendingPathComponent(".claude")
            let claudeSkills = claudeDirectory.appendingPathComponent("skills")
            let expectedSkills = projectRoot
                .appendingPathComponent(".agents")
                .appendingPathComponent("skills")
            if isSymlink(claudeDirectory) {
                issues.append(.init(
                    severity: .warning,
                    message: "\(claudeDirectory.path) is a symlink; projection repair is disabled",
                    summary: "Claude project directory is shared",
                    projectRoot: project.root,
                    category: .projection,
                    guidance: "Review the shared .claude directory manually; Metagent will not write through it."
                ))
            } else if isSymlink(claudeSkills), symlink(claudeSkills, resolvesTo: expectedSkills) {
                issues.append(.init(
                    severity: .ok,
                    message: "\(claudeSkills.path) is a symlink to .agents/skills",
                    projectRoot: project.root,
                    category: .projection
                ))
            } else if isSymlink(claudeSkills) {
                issues.append(.init(
                    severity: .warning,
                    message: "\(claudeSkills.path) points somewhere other than .agents/skills",
                    summary: "Claude skills mirror points to the wrong target",
                    projectRoot: project.root,
                    category: .projection,
                    guidance: "Run Repair to point Claude at the canonical .agents/skills directory.",
                    repairAction: .repairProjection
                ))
            } else if fileManager.fileExists(atPath: claudeSkills.path) {
                issues.append(.init(
                    severity: .warning,
                    message: "\(claudeSkills.path) exists but is not a symlink",
                    summary: "Claude skills path is a real directory",
                    projectRoot: project.root,
                    category: .projection,
                    guidance: "Review and explicitly migrate this directory before replacing it with a symlink."
                ))
            } else {
                issues.append(.init(
                    severity: .warning,
                    message: "\(claudeSkills.path) missing",
                    summary: "Claude skills mirror missing",
                    projectRoot: project.root,
                    category: .projection,
                    guidance: "Run Repair to point Claude at the canonical .agents/skills directory.",
                    repairAction: .repairProjection
                ))
            }
        }

        return DoctorReport(issues: issues)
    }

    public static func repairSkills(options: SkillsRepairOptions = SkillsRepairOptions()) throws -> SkillsRepairReport {
        let scan = try scanSkills(options: options.scanOptions)
        let canonicalHome = canonicalProjectPath(homeURL())
        var projects: [SkillsRepairProject] = []

        for project in scan.projects where hasCanonicalSkillsSurface(project)
            && canonicalProjectPath(URL(fileURLWithPath: project.root)) != canonicalHome
        {
            let lines = try repairProjectProjection(project, apply: options.apply)
            projects.append(SkillsRepairProject(root: project.root, lines: lines))
        }

        return SkillsRepairReport(apply: options.apply, projects: projects)
    }

    public static func saveInventorySnapshot(_ report: SkillScanReport) {
        try? SkillInventoryCache().save(report)
    }

    public static func loadInventorySnapshot() -> SkillScanReport? {
        try? SkillInventoryCache().load()
    }

    public static func planSkillRemoval(projectRoot: String, skillName: String) throws -> SkillRemovalPlan {
        guard isValidSkillName(skillName) else {
            throw NSError(domain: "MetagentSkillUninstall", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "invalid skill name: \(skillName)"
            ])
        }

        let root = URL(fileURLWithPath: projectRoot).resolvingSymlinksInPath().standardizedFileURL
        let project = try readProjectSkills(root: root)
        let agentsSkill = project.skills.first { $0.location == "agents" && $0.name == skillName }
        guard let agentsSkill else {
            throw NSError(domain: "MetagentSkillUninstall", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "\(skillName) is not installed in \(root.path)/.agents/skills"
            ])
        }

        let command = agentsSkill.manager == "skills-cli"
            ? skillsCLIRemovalCommand(root: root, skillName: skillName)
            : nil
        return SkillRemovalPlan(
            projectRoot: root.path,
            skillName: skillName,
            manager: agentsSkill.manager,
            mutability: agentsSkill.mutability,
            command: command,
            applySupported: agentsSkill.representation == "canonical"
                && (agentsSkill.manager == "local" || agentsSkill.manager == "skills-cli")
        )
    }

    public static func uninstallSkill(
        projectRoot: String,
        skillName: String,
        allowManagedRemoval: Bool = false
    ) throws -> SkillUninstallReport {
        let plan = try planSkillRemoval(projectRoot: projectRoot, skillName: skillName)
        let root = URL(fileURLWithPath: plan.projectRoot)
        let project = try readProjectSkills(root: root)
        guard let agentsSkill = project.skills.first(where: { $0.location == "agents" && $0.name == skillName }) else {
            throw NSError(domain: "MetagentSkillUninstall", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "\(skillName) is not installed in \(root.path)/.agents/skills"
            ])
        }
        guard plan.applySupported else {
            throw NSError(domain: "MetagentSkillUninstall", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "\(skillName) is not a canonical local or skills CLI bundle; Metagent will not remove \(agentsSkill.representation) content managed by \(agentsSkill.manager)."
            ])
        }

        if agentsSkill.manager == "skills-cli", !allowManagedRemoval {
            throw NSError(domain: "MetagentSkillUninstall", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "\(skillName) is managed by skills CLI. Run `\(plan.command ?? "npx skills remove \(skillName) --yes")` from \(root.path), or explicitly apply the Metagent removal plan."
            ])
        }

        let skillURL = URL(fileURLWithPath: agentsSkill.path)
        var lines: [String] = []
        let projections = project.skills.filter {
            guard $0.name == skillName && $0.location != "agents" && !$0.symlinkedContainer else {
                return false
            }
            let url = URL(fileURLWithPath: $0.path)
            return isSymlink(url) && symlink(url, resolvesTo: skillURL)
        }
        let retained = project.skills.filter {
            guard $0.name == skillName && $0.location != "agents" && !$0.symlinkedContainer else {
                return false
            }
            let url = URL(fileURLWithPath: $0.path)
            return !isSymlink(url) || !symlink(url, resolvesTo: skillURL)
        }
        let recovery = try prepareRemovalRecovery(
            projectRoot: root,
            skillName: skillName
        )
        let backupPath: String? = recovery.path
        lines.append("saved recovery state to \(recovery.path)")

        let recoveredSkill = recovery.appendingPathComponent(skillName)
        if agentsSkill.manager == "skills-cli" {
            try fileManager.copyItem(at: skillURL, to: recoveredSkill)
            lines.append("copied managed skill into recovery: \(recoveredSkill.path)")
            var retainedBackups: [(original: URL, backup: URL)] = []
            for (index, retainedSkill) in retained.enumerated() {
                let original = URL(fileURLWithPath: retainedSkill.path)
                let backup = recovery
                    .appendingPathComponent("retained")
                    .appendingPathComponent("\(index)-\(retainedSkill.location)")
                    .appendingPathComponent(skillName)
                try fileManager.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: original, to: backup)
                retainedBackups.append((original, backup))
            }
            if !retainedBackups.isEmpty {
                lines.append("snapshotted \(retainedBackups.count) independent same-name location(s)")
            }
            do {
                let output = try runSkillsCLIRemoval(root: root, skillName: skillName)
                if !output.isEmpty {
                    lines.append(output)
                }
            } catch {
                throw NSError(domain: "MetagentSkillUninstall", code: 7, userInfo: [
                    NSLocalizedDescriptionKey: "skills CLI removal failed: \(error.localizedDescription)\nRecovery state: \(recovery.path)"
                ])
            }
            guard !fileManager.fileExists(atPath: skillURL.path), readProjectSkillLocks(root: root)[skillName] == nil else {
                throw NSError(domain: "MetagentSkillUninstall", code: 8, userInfo: [
                    NSLocalizedDescriptionKey: "skills CLI reported success but the bundle or lock entry remains. Recovery state: \(recovery.path)"
                ])
            }
            var restoredRetainedCount = 0
            for retainedBackup in retainedBackups {
                guard !isSymlink(retainedBackup.original),
                      !fileManager.fileExists(atPath: retainedBackup.original.path)
                else { continue }
                do {
                    try fileManager.createDirectory(
                        at: retainedBackup.original.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try fileManager.copyItem(at: retainedBackup.backup, to: retainedBackup.original)
                    restoredRetainedCount += 1
                } catch {
                    lines.append("warning: managed package was removed, but restoring \(retainedBackup.original.path) failed: \(error.localizedDescription)")
                }
            }
            if restoredRetainedCount > 0 {
                lines.append("restored \(restoredRetainedCount) independent same-name location(s)")
            }
            var removedProjectionCount = 0
            for (index, projection) in projections.enumerated() {
                let projectionURL = URL(fileURLWithPath: projection.path)
                guard isSymlink(projectionURL) || fileManager.fileExists(atPath: projectionURL.path) else { continue }
                let projectionRecovery = recovery
                    .appendingPathComponent("projections")
                    .appendingPathComponent("\(index)-\(projection.location)")
                    .appendingPathComponent(skillName)
                do {
                    try fileManager.createDirectory(at: projectionRecovery.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fileManager.moveItem(at: projectionURL, to: projectionRecovery)
                    removedProjectionCount += 1
                } catch {
                    lines.append("warning: managed skill was removed, but projection cleanup failed at \(projectionURL.path): \(error.localizedDescription)")
                }
            }
            lines.append("removed managed skill through skills CLI and verified its lock entry is absent")
            if removedProjectionCount > 0 {
                lines.append("removed \(removedProjectionCount) dangling per-skill projection link(s)")
            }
            return SkillUninstallReport(
                projectRoot: root.path,
                skillName: skillName,
                backupPath: backupPath,
                lines: lines
            )
        }

        var movedProjections: [(original: URL, recovery: URL)] = []
        do {
            for (index, projection) in projections.enumerated() {
                let projectionURL = URL(fileURLWithPath: projection.path)
                let projectionRecovery = recovery
                    .appendingPathComponent("projections")
                    .appendingPathComponent("\(index)-\(projection.location)")
                    .appendingPathComponent(skillName)
                try fileManager.createDirectory(
                    at: projectionRecovery.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.moveItem(at: projectionURL, to: projectionRecovery)
                movedProjections.append((projectionURL, projectionRecovery))
            }
            try fileManager.moveItem(at: skillURL, to: recoveredSkill)
        } catch {
            var rollbackFailures: [String] = []
            for moved in movedProjections.reversed() {
                do {
                    try fileManager.moveItem(at: moved.recovery, to: moved.original)
                } catch {
                    rollbackFailures.append("\(moved.original.path): \(error.localizedDescription)")
                }
            }
            if !rollbackFailures.isEmpty {
                throw NSError(domain: "MetagentSkillUninstall", code: 6, userInfo: [
                    NSLocalizedDescriptionKey: "local uninstall failed and rollback was incomplete. Original error: \(error.localizedDescription)\nRollback failures:\n\(rollbackFailures.joined(separator: "\n"))\nRecovery state: \(recovery.path)"
                ])
            }
            throw error
        }
        lines.append("moved local skill to recovery: \(recoveredSkill.path)")
        if !projections.isEmpty {
            lines.append("removed \(projections.count) per-skill projection link(s)")
        }

        guard !fileManager.fileExists(atPath: skillURL.path) else {
            throw NSError(domain: "MetagentSkillUninstall", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "uninstall verification failed: \(skillURL.path) still exists"
            ])
        }

        if !retained.isEmpty {
            lines.append("kept \(retained.count) independent same-name legacy location(s); review them separately")
        }
        lines.append("verified canonical local skill is absent")
        return SkillUninstallReport(
            projectRoot: root.path,
            skillName: skillName,
            backupPath: backupPath,
            lines: lines
        )
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
    var skillPath: String?
    var computedHash: String?
    var skillFolderHash: String?
    var pluginName: String?
    var installedAt: String?
    var updatedAt: String?

    private enum CodingKeys: String, CodingKey {
        case source
        case sourceType
        case sourceUrl = "sourceUrl"
        case ref
        case skillPath
        case computedHash
        case skillFolderHash
        case pluginName
        case installedAt
        case updatedAt
    }
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

private func hasKnownSkillContainer(_ root: URL) -> Bool {
    [
        ".agents/skills",
        ".codex/skills",
        ".claude/skills"
    ].contains { relative in
        fileManager.fileExists(atPath: root.appendingPathComponent(relative).path)
    }
}

private func installedCodexPlugins() throws -> [CodexPlugin] {
    let executable = try codexExecutable()
    let result = try runSubprocess(
        executable: executable,
        arguments: ["plugin", "list", "--json"]
    )
    guard result.status == 0 else {
        let detail = String(data: result.standardError, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        throw NSError(domain: "MetagentCodexPlugins", code: Int(result.status), userInfo: [
            NSLocalizedDescriptionKey: detail?.isEmpty == false ? detail! : "codex plugin list failed"
        ])
    }
    return try JSONDecoder().decode(CodexPluginList.self, from: result.standardOutput).installed
        .filter { $0.installed && $0.enabled }
}

private func codexExecutable() throws -> URL {
    let environment = ProcessInfo.processInfo.environment
    var candidates: [String] = []
    if let override = environment["METAGENT_CODEX"], !override.isEmpty {
        candidates.append(override)
    }
    if let path = environment["PATH"] {
        candidates += path.split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent("codex").path }
    }
    candidates += [
        homeURL().appendingPathComponent(".local/bin/codex").path,
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex"
    ]
    if let path = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
        return URL(fileURLWithPath: path)
    }
    throw NSError(domain: "MetagentCodexPlugins", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "codex executable not found; set METAGENT_CODEX to enable plugin inventory"
    ])
}

private func readCodexPluginSkills(_ plugin: CodexPlugin) -> SkillProject? {
    let home = homeURL()
    let cacheBase = home.appendingPathComponent(".codex/plugins/cache")
    let cacheMarketplaces = plugin.marketplaceName == "openai-curated"
        ? [plugin.marketplaceName, "openai-curated-remote"]
        : [plugin.marketplaceName]
    let cacheRoots = cacheMarketplaces.map {
        cacheBase
            .appendingPathComponent($0)
            .appendingPathComponent(plugin.name)
            .appendingPathComponent(plugin.version)
    }
    let sourceRoot = plugin.source.path.map { URL(fileURLWithPath: $0) }
    let root = cacheRoots.first(where: { fileManager.fileExists(atPath: $0.path) }) ?? sourceRoot
    guard let root else { return nil }
    let representation = root.path.hasPrefix(cacheBase.path + "/") ? "versioned-cache" : "canonical"
    let skillsDir = root.appendingPathComponent("skills")
    guard let entries = skillContainerEntries(at: skillsDir) else { return nil }

    let skills = entries.compactMap { entry -> SkillInventoryItem? in
        guard isDirectoryOrSymlinkedDirectory(entry),
              isRegularOrSymlinkedFile(entry.appendingPathComponent("SKILL.md")),
              isValidSkillName(entry.lastPathComponent)
        else { return nil }
        return makeSkillItem(
            name: entry.lastPathComponent,
            path: entry,
            location: "plugin",
            originKind: "codex-plugin",
            scope: "plugin",
            manager: "codex-plugin",
            authority: plugin.pluginId,
            mutability: "managed-read-only",
            representation: representation,
            canonicalPath: canonicalProjectPath(entry),
            origin: SkillLockEntry(
                source: plugin.pluginId,
                sourceType: "codex-marketplace",
                sourceUrl: nil,
                ref: plugin.version,
                skillPath: nil,
                computedHash: nil,
                skillFolderHash: nil,
                pluginName: plugin.name,
                installedAt: nil,
                updatedAt: nil
            ),
            symlinkedContainer: isSymlink(skillsDir)
        )
    }.sorted()
    guard !skills.isEmpty else { return nil }
    return SkillProject(
        root: canonicalProjectPath(root),
        skillsDir: skillsDir.path,
        validSkills: skills.map(\.name).sorted(),
        skills: skills
    )
}

private func readProjectSkills(root: URL) throws -> SkillProject {
    let agentsSkillsDir = root.appendingPathComponent(".agents").appendingPathComponent("skills")
    let skillLock = readProjectSkillLocks(root: root)
    let scope = canonicalProjectPath(root) == canonicalProjectPath(homeURL()) ? "global" : "project"
    var validSkills: [String] = []
    var inventory: [SkillInventoryItem] = []
    var invalidSkillDirs: [String] = []
    var hiddenSkillDirs: [String] = []

    readAgentsSkills(
        skillsDir: agentsSkillsDir,
        skillLock: skillLock,
        scope: scope,
        validSkills: &validSkills,
        inventory: &inventory,
        invalidSkillDirs: &invalidSkillDirs,
        hiddenSkillDirs: &hiddenSkillDirs
    )

    let canonicalAgents = Dictionary(
        inventory.lazy
            .filter { $0.location == "agents" }
            .map { ($0.canonicalPath, $0) },
        uniquingKeysWith: { first, _ in first }
    )

    readInventorySkills(
        skillsDir: root.appendingPathComponent(".codex").appendingPathComponent("skills"),
        location: "codex",
        scope: scope,
        canonicalAgents: canonicalAgents,
        inventory: &inventory
    )
    readInventorySkills(
        skillsDir: root.appendingPathComponent(".claude").appendingPathComponent("skills"),
        location: "claude",
        scope: scope,
        canonicalAgents: canonicalAgents,
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
    scope: String,
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
        let projection = symlinkedContainer || isSymlink(entry)
        let managed = lockEntry != nil
        inventory.append(makeSkillItem(
            name: name,
            path: entry,
            location: "agents",
            originKind: lockEntry == nil ? "unmanaged" : "npx-skills",
            scope: scope,
            manager: managed ? "skills-cli" : "local",
            authority: managed ? (lockEntry?.source ?? "upstream-package") : "unknown",
            mutability: projection || managed ? "managed-read-only" : "editable",
            representation: projection ? "projection" : "canonical",
            canonicalPath: canonicalProjectPath(entry),
            origin: lockEntry,
            symlinkedContainer: symlinkedContainer
        ))
    }
}

private func readInventorySkills(
    skillsDir: URL,
    location: String,
    scope: String,
    canonicalAgents: [String: SkillInventoryItem],
    inventory: inout [SkillInventoryItem]
) {
    guard fileManager.fileExists(atPath: skillsDir.path) else { return }
    collectInventorySkills(
        dir: skillsDir,
        location: location,
        scope: scope,
        depth: 0,
        maxDepth: 2,
        symlinkedContainer: isSymlink(skillsDir),
        canonicalAgents: canonicalAgents,
        inventory: &inventory
    )
}

private func collectInventorySkills(
    dir: URL,
    location: String,
    scope: String,
    depth: Int,
    maxDepth: Int,
    symlinkedContainer: Bool,
    canonicalAgents: [String: SkillInventoryItem],
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
            let canonicalPath = canonicalProjectPath(entry)
            let projection = symlinkedContainer || isSymlink(entry)
            let inherited = projection ? canonicalAgents[canonicalPath] : nil
            let isSystem = entry.pathComponents.contains(".system")
            let manager = inherited?.manager
                ?? (location == "codex" ? "codex" : "external-manager")
            let authority = inherited?.authority
                ?? (isSystem ? "codex-system" : (location == "codex" ? "codex-installed" : "unknown"))
            let originKind = inherited?.originKind
                ?? (isSystem ? "codex-system" : "\(location)-installed")
            inventory.append(makeSkillItem(
                name: name,
                path: entry,
                location: location,
                originKind: originKind,
                scope: isSystem ? "system" : scope,
                manager: manager,
                authority: authority,
                mutability: "managed-read-only",
                representation: projection ? "projection" : "canonical",
                canonicalPath: canonicalPath,
                origin: nil,
                symlinkedContainer: symlinkedContainer,
                inherited: inherited
            ))
            continue
        }

        guard depth < maxDepth, !shouldPruneSkillContainer(name: entry.lastPathComponent) else {
            continue
        }
        collectInventorySkills(
            dir: entry,
            location: location,
            scope: scope,
            depth: depth + 1,
            maxDepth: maxDepth,
            symlinkedContainer: symlinkedContainer,
            canonicalAgents: canonicalAgents,
            inventory: &inventory
        )
    }
}

private func makeSkillItem(
    name: String,
    path: URL,
    location: String,
    originKind: String,
    scope: String,
    manager: String,
    authority: String,
    mutability: String,
    representation: String,
    canonicalPath: String,
    origin: SkillLockEntry?,
    symlinkedContainer: Bool,
    inherited: SkillInventoryItem? = nil
) -> SkillInventoryItem {
    let stats = skillStats(path)
    return SkillInventoryItem(
        name: name,
        path: path.path,
        location: location,
        locationLabel: ".\(location)",
        originKind: originKind,
        scope: scope,
        manager: manager,
        authority: authority,
        mutability: mutability,
        representation: representation,
        canonicalPath: canonicalPath,
        source: origin?.source ?? inherited?.source,
        sourceType: origin?.sourceType ?? inherited?.sourceType,
        sourceURL: origin?.sourceUrl ?? inherited?.sourceURL,
        ref: origin?.ref ?? inherited?.ref,
        installedAt: origin?.installedAt ?? inherited?.installedAt,
        updatedAt: origin?.updatedAt ?? inherited?.updatedAt,
        symlinkedContainer: symlinkedContainer,
        folderKind: folderKind(
            path: path,
            location: location,
            originKind: originKind,
            representation: representation,
            symlinkedContainer: symlinkedContainer
        ),
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

private func folderKind(
    path: URL,
    location: String,
    originKind: String,
    representation: String,
    symlinkedContainer: Bool
) -> String {
    if symlinkedContainer || isSymlink(path) {
        return "symlinked"
    }
    if path.pathComponents.contains(".system") {
        return "system"
    }
    if location == "agents", originKind == "npx-skills" {
        return "npx-installed"
    }
    if location == "agents" {
        return "unmanaged"
    }
    if location == "codex" {
        return "codex-local"
    }
    if location == "claude" {
        return "claude-local"
    }
    if location == "plugin" {
        return representation
    }
    return "unknown"
}

private func readSkillLock(_ path: URL) -> [String: SkillLockEntry] {
    guard let data = try? Data(contentsOf: path) else { return [:] }
    return (try? JSONDecoder().decode(SkillLock.self, from: data).skills) ?? [:]
}

private func computeSkillFolderHash(_ skillDir: URL) throws -> String {
    let rootComponents = skillDir.standardizedFileURL.pathComponents
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
    guard let enumerator = fileManager.enumerator(
        at: skillDir,
        includingPropertiesForKeys: Array(keys),
        options: []
    ) else {
        throw NSError(domain: "MetagentSkillHash", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "could not enumerate \(skillDir.path)"
        ])
    }

    var files: [(relativePath: String, data: Data)] = []
    for case let path as URL in enumerator {
        let values = try path.resourceValues(forKeys: keys)
        if values.isDirectory == true,
           [".git", "node_modules"].contains(path.lastPathComponent)
        {
            enumerator.skipDescendants()
            continue
        }
        guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
        let components = path.standardizedFileURL.pathComponents
        guard components.count > rootComponents.count else { continue }
        files.append((
            relativePath: components.dropFirst(rootComponents.count).joined(separator: "/"),
            data: try Data(contentsOf: path)
        ))
    }

    files.sort {
        $0.relativePath.localizedCompare($1.relativePath) == .orderedAscending
    }
    var hash = SHA256()
    for file in files {
        hash.update(data: Data(file.relativePath.utf8))
        hash.update(data: file.data)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

private func readProjectSkillLocks(root: URL) -> [String: SkillLockEntry] {
    if canonicalProjectPath(root) == canonicalProjectPath(homeURL()) {
        return readSkillLock(globalSkillLockPath())
    }
    return readSkillLock(root.appendingPathComponent("skills-lock.json"))
}

private func globalSkillLockPath() -> URL {
    if let xdgStateHome = ProcessInfo.processInfo.environment["XDG_STATE_HOME"], !xdgStateHome.isEmpty {
        return URL(fileURLWithPath: xdgStateHome)
            .appendingPathComponent("skills")
            .appendingPathComponent(".skill-lock.json")
    }
    return homeURL().appendingPathComponent(".agents").appendingPathComponent(".skill-lock.json")
}

private func skillsCLIRemovalCommand(root: URL, skillName: String) -> String {
    let globalFlag = canonicalProjectPath(root) == canonicalProjectPath(homeURL()) ? " --global" : ""
    return "npx skills remove \(skillName) --yes\(globalFlag)"
}

private func runSkillsCLIRemoval(root: URL, skillName: String) throws -> String {
    let arguments = ["--yes", "skills", "remove", skillName, "--yes"]
        + (canonicalProjectPath(root) == canonicalProjectPath(homeURL()) ? ["--global"] : [])
    let result = try runSubprocess(
        executable: try npxExecutable(),
        arguments: arguments,
        currentDirectory: root
    )
    let combined = String(data: result.standardOutput + result.standardError, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard result.status == 0 else {
        throw NSError(domain: "MetagentSkillsCLI", code: Int(result.status), userInfo: [
            NSLocalizedDescriptionKey: combined.isEmpty ? "npx skills remove failed" : combined
        ])
    }
    return combined
}

private struct SubprocessResult {
    var status: Int32
    var standardOutput: Data
    var standardError: Data
}

private final class PipeReader: @unchecked Sendable {
    private let handle: FileHandle
    private(set) var data = Data()

    init(handle: FileHandle) {
        self.handle = handle
    }

    func readToEnd() {
        data = handle.readDataToEndOfFile()
    }
}

private func runSubprocess(
    executable: URL,
    arguments: [String],
    currentDirectory: URL? = nil
) throws -> SubprocessResult {
    let process = Process()
    let standardOutput = Pipe()
    let standardError = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectory
    process.standardOutput = standardOutput
    process.standardError = standardError
    try process.run()

    let outputReader = PipeReader(handle: standardOutput.fileHandleForReading)
    let errorReader = PipeReader(handle: standardError.fileHandleForReading)
    let readers = [outputReader, errorReader]
    DispatchQueue.concurrentPerform(iterations: readers.count) { index in
        readers[index].readToEnd()
    }
    process.waitUntilExit()
    return SubprocessResult(
        status: process.terminationStatus,
        standardOutput: outputReader.data,
        standardError: errorReader.data
    )
}

private func npxExecutable() throws -> URL {
    let environment = ProcessInfo.processInfo.environment
    var candidates: [String] = []
    if let override = environment["METAGENT_NPX"], !override.isEmpty {
        candidates.append(override)
    }
    if let path = environment["PATH"] {
        candidates += path.split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent("npx").path }
    }
    let fnmVersions = homeURL().appendingPathComponent(".local/share/fnm/node-versions")
    if let versions = try? fileManager.contentsOfDirectory(at: fnmVersions, includingPropertiesForKeys: nil) {
        candidates += versions.sorted { $0.lastPathComponent > $1.lastPathComponent }.map {
            $0.appendingPathComponent("installation/bin/npx").path
        }
    }
    candidates += ["/opt/homebrew/bin/npx", "/usr/local/bin/npx"]
    if let path = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
        return URL(fileURLWithPath: path)
    }
    throw NSError(domain: "MetagentSkillsCLI", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "npx executable not found; set METAGENT_NPX to enable managed removal"
    ])
}

private func prepareRemovalRecovery(
    projectRoot: URL,
    skillName: String
) throws -> URL {
    let recoveryRoot = homeURL()
        .appendingPathComponent("Library")
        .appendingPathComponent("Application Support")
        .appendingPathComponent("Metagent")
        .appendingPathComponent("Removed Skills")
        .appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)

    let stateRoot = recoveryRoot.appendingPathComponent("state")
    try fileManager.createDirectory(at: stateRoot, withIntermediateDirectories: true)
    let stateFiles: [(URL, String)] = [
        (projectRoot.appendingPathComponent("skills-lock.json"), "project-skills-lock.json"),
        (
            projectRoot.appendingPathComponent(".agents").appendingPathComponent(".skill-lock.json"),
            "agents-skill-lock.json"
        ),
        (globalSkillLockPath(), "global-skill-lock.json")
    ]
    var copiedPaths = Set<String>()
    for (source, backupName) in stateFiles
        where fileManager.fileExists(atPath: source.path) && copiedPaths.insert(source.path).inserted
    {
        try fileManager.copyItem(at: source, to: stateRoot.appendingPathComponent(backupName))
    }

    let metadata = "project=\(projectRoot.path)\nskill=\(skillName)\nremoved_at=\(ISO8601DateFormatter().string(from: Date()))\n"
    try metadata.write(
        to: recoveryRoot.appendingPathComponent("REMOVAL.txt"),
        atomically: true,
        encoding: .utf8
    )
    return recoveryRoot
}

private func hasProjectInventorySurface(_ project: SkillProject) -> Bool {
    !project.validSkills.isEmpty
        || !project.skills.isEmpty
        || !project.invalidSkillDirs.isEmpty
        || !project.hiddenSkillDirs.isEmpty
}

private func mergeSkillProjects(_ existing: SkillProject, _ additional: SkillProject) -> SkillProject {
    var skillsByID = Dictionary(uniqueKeysWithValues: existing.skills.map { ($0.id, $0) })
    for skill in additional.skills {
        skillsByID[skill.id] = skill
    }
    return SkillProject(
        root: existing.root,
        skillsDir: existing.skillsDir,
        validSkills: Array(Set(existing.validSkills + additional.validSkills)).sorted(),
        skills: skillsByID.values.sorted(),
        invalidSkillDirs: Array(Set(existing.invalidSkillDirs + additional.invalidSkillDirs)).sorted(),
        hiddenSkillDirs: Array(Set(existing.hiddenSkillDirs + additional.hiddenSkillDirs)).sorted()
    )
}

private func hasCanonicalSkillsSurface(_ project: SkillProject) -> Bool {
    !project.validSkills.isEmpty
        || !project.invalidSkillDirs.isEmpty
        || !project.hiddenSkillDirs.isEmpty
}

private func repairProjectProjection(
    _ project: SkillProject,
    apply: Bool
) throws -> [SkillsRepairLine] {
    let root = URL(fileURLWithPath: project.root)
    let canonicalSkills = root.appendingPathComponent(".agents").appendingPathComponent("skills")
    let claudeDirectory = root.appendingPathComponent(".claude")
    let claudeSkills = claudeDirectory.appendingPathComponent("skills")
    var lines: [SkillsRepairLine] = [
        .init(kind: .info, text: "valid local skills: \(project.validSkills.count)")
    ]

    if !project.hiddenSkillDirs.isEmpty {
        lines.append(.init(kind: .warning, text: "warning: \(project.hiddenSkillDirs.count) hidden skill dir(s) ignored"))
    }
    for invalid in project.invalidSkillDirs {
        lines.append(.init(kind: .warning, text: "warning: skipped invalid skill name: \(invalid)"))
    }
    if project.validSkills.isEmpty {
        lines.append(.init(kind: .info, text: "no valid SKILL.md folders yet"))
    }

    if isSymlink(claudeDirectory) {
        lines.append(.init(
            kind: .skipped,
            text: "manual review: .claude is a symlink; refusing to modify its shared target"
        ))
        return lines
    }

    if isSymlink(claudeSkills), symlink(claudeSkills, resolvesTo: canonicalSkills) {
        lines.append(.init(kind: .info, text: "healthy: .claude/skills -> ../.agents/skills"))
        return lines
    }
    if fileManager.fileExists(atPath: claudeSkills.path), !isSymlink(claudeSkills) {
        lines.append(.init(
            kind: .skipped,
            text: "manual review: .claude/skills exists and is not a symlink"
        ))
        return lines
    }

    let replacingWrongSymlink = isSymlink(claudeSkills)
    let action = replacingWrongSymlink ? "replace wrong .claude/skills symlink" : "create .claude/skills symlink"
    if apply {
        try fileManager.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        if replacingWrongSymlink {
            try fileManager.removeItem(at: claudeSkills)
        }
        try fileManager.createSymbolicLink(atPath: claudeSkills.path, withDestinationPath: "../.agents/skills")
        guard isSymlink(claudeSkills), symlink(claudeSkills, resolvesTo: canonicalSkills) else {
            throw NSError(domain: "MetagentSkillsRepair", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "repair verification failed for \(claudeSkills.path)"
            ])
        }
        lines.append(.init(kind: .action, text: "repaired: .claude/skills -> ../.agents/skills"))
    } else {
        lines.append(.init(kind: .action, text: "would \(action) -> ../.agents/skills"))
    }

    return lines
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

private func symlink(_ link: URL, resolvesTo expectedTarget: URL) -> Bool {
    guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: link.path) else {
        return false
    }
    let destinationURL = destination.hasPrefix("/")
        ? URL(fileURLWithPath: destination)
        : link.deletingLastPathComponent().appendingPathComponent(destination)
    return canonicalProjectPath(destinationURL) == canonicalProjectPath(expectedTarget)
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
        "DerivedData",
        "_archive"
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
