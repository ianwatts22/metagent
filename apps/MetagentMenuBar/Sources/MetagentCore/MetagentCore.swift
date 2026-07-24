import Foundation
import Darwin
import ImageIO
import SQLite3

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
    public var respectConfiguredIgnores: Bool

    public init(
        roots: [String] = [],
        maxDepth: Int? = nil,
        ignoreProjects: [String] = [],
        respectConfiguredIgnores: Bool = true
    ) {
        self.roots = roots
        self.maxDepth = maxDepth
        self.ignoreProjects = ignoreProjects
        self.respectConfiguredIgnores = respectConfiguredIgnores
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
    public var description: String?
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
        description: String?,
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
        self.description = description
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
        case description
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
    public var approvedCodexProjectionPaths: [String]?
    public var approvedActionsByProject: [String: [String]]?

    public init(
        apply: Bool = false,
        scanOptions: SkillScanOptions = SkillScanOptions(),
        approvedCodexProjectionPaths: [String]? = nil,
        approvedActionsByProject: [String: [String]]? = nil
    ) {
        self.apply = apply
        self.scanOptions = scanOptions
        self.approvedCodexProjectionPaths = approvedCodexProjectionPaths
        self.approvedActionsByProject = approvedActionsByProject
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

    public var actionsByProject: [String: [String]] {
        Dictionary(uniqueKeysWithValues: projects.map { project in
            (
                project.root,
                project.lines.filter { $0.kind == .action }.map(\.text).sorted()
            )
        })
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
    public var plannedCodexProjectionPaths: [String]

    public init(root: String, lines: [SkillsRepairLine], plannedCodexProjectionPaths: [String] = []) {
        self.root = root
        self.name = URL(fileURLWithPath: root).lastPathComponent
        self.lines = lines
        self.plannedCodexProjectionPaths = plannedCodexProjectionPaths
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
        case plannedCodexProjectionPaths = "planned_codex_projection_paths"
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

public struct SkillUninstallFailure: Codable, Equatable, Sendable {
    public let skillName: String
    public let message: String
}

public struct SkillUninstallBatchReport: Codable, Equatable, Sendable {
    public let reports: [SkillUninstallReport]
    public let failures: [SkillUninstallFailure]
}

public struct SkillIconUpdateReport: Codable, Equatable, Sendable {
    public let skillPath: String
    public let iconPath: String
    public let metadataPath: String
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

private struct SkillsCLIManagedRemoval {
    let skillName: String
    let skillURL: URL
    let recovery: URL
    let projections: [SkillInventoryItem]
    let retainedBackups: [(original: URL, backup: URL)]
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

    public static func updateSkillIcon(skillPath: String, pngData: Data) throws -> SkillIconUpdateReport {
        let skill = URL(fileURLWithPath: skillPath).standardizedFileURL
        guard skill.resolvingSymlinksInPath().standardizedFileURL.path == skill.path,
              isRegularOrSymlinkedFile(skill.appendingPathComponent("SKILL.md"))
        else {
            throw NSError(domain: "MetagentSkillIcon", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Icons can only be changed on a canonical editable skill directory."
            ])
        }
        guard let imageSource = CGImageSourceCreateWithData(pngData as CFData, nil),
              (CGImageSourceGetType(imageSource) as String?) == "public.png",
              CGImageSourceGetCount(imageSource) == 1,
              CGImageSourceCreateImageAtIndex(imageSource, 0, nil) != nil
        else {
            throw NSError(domain: "MetagentSkillIcon", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "The selected icon could not be converted to PNG."
            ])
        }

        let assets = skill.appendingPathComponent("assets")
        let icon = assets.appendingPathComponent("metagent-icon.png")
        let agents = skill.appendingPathComponent("agents")
        let metadata = agents.appendingPathComponent("openai.yaml")
        guard safeSkillIconWriteTargets(
            skill: skill,
            directories: [assets, agents],
            files: [icon, metadata]
        ) else {
            throw NSError(domain: "MetagentSkillIcon", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "The icon or metadata destination is symlinked outside the skill."
            ])
        }
        try fileManager.createDirectory(at: assets, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: agents, withIntermediateDirectories: true)
        try pngData.write(to: icon, options: .atomic)

        let existing = (try? String(contentsOf: metadata, encoding: .utf8)) ?? ""
        let updated = upsertSkillIconMetadata(existing, iconPath: "assets/metagent-icon.png")
        try updated.write(to: metadata, atomically: true, encoding: .utf8)
        return SkillIconUpdateReport(
            skillPath: skill.path,
            iconPath: icon.path,
            metadataPath: metadata.path
        )
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
        return try scanSkills(options: options, config: config)
    }

    static func scanSkills(options: SkillScanOptions, config: MetagentConfig) throws -> SkillScanReport {
        let rootPaths = options.roots.isEmpty ? config.roots : options.roots
        let maxDepth = options.maxDepth ?? config.maxDepth
        let configuredIgnores = options.respectConfiguredIgnores ? config.ignoreProjects : []
        let ignoreProjects = Set((configuredIgnores + options.ignoreProjects).map {
            canonicalProjectPath(expandPath($0))
        })
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

            let obsoleteCodexProjections = obsoleteCodexProjectionURLs(project)
            if !obsoleteCodexProjections.isEmpty {
                let count = obsoleteCodexProjections.count
                issues.append(.init(
                    severity: .warning,
                    message: "\(project.root) has \(count) obsolete .codex skill projection(s)",
                    summary: "Remove \(count) obsolete Codex skill \(count == 1 ? "link" : "links")",
                    projectRoot: project.root,
                    category: .projection,
                    guidance: "Codex now discovers .agents/skills directly. Metagent can remove only these obsolete symlinks after you review the preview.",
                    repairAction: .repairProjection
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
        if options.apply, let approvedActions = options.approvedActionsByProject {
            let currentPreview = try repairSkills(options: SkillsRepairOptions(
                scanOptions: options.scanOptions
            ))
            guard currentPreview.actionsByProject == approvedActions.mapValues({ $0.sorted() }) else {
                throw NSError(domain: "MetagentSkillsRepair", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "cleanup changed after preview; review it again before applying"
                ])
            }
        }

        let scan = try scanSkills(options: options.scanOptions)
        let canonicalHome = canonicalProjectPath(homeURL())
        var inventoryProjects = scan.projects
        if options.scanOptions.roots.isEmpty,
           let homeProject = try scanHomeSkills(maxDepth: 0).projects.first(where: {
               canonicalProjectPath(URL(fileURLWithPath: $0.root)) == canonicalHome
           }),
           !inventoryProjects.contains(where: {
               canonicalProjectPath(URL(fileURLWithPath: $0.root)) == canonicalHome
           })
        {
            inventoryProjects.append(homeProject)
        }
        var repairProjects: [SkillsRepairProject] = []

        for project in inventoryProjects {
            let isHomeProject = canonicalProjectPath(URL(fileURLWithPath: project.root)) == canonicalHome
            let shouldInclude = isHomeProject
                ? hasObsoleteCodexProjections(project)
                : hasCanonicalSkillsSurface(project) || hasObsoleteCodexProjections(project)
            guard shouldInclude else { continue }
            let currentPaths = obsoleteCodexProjectionURLs(project).map(\.path)
            let currentPathSet = Set(currentPaths)
            let approvedPaths = options.approvedCodexProjectionPaths.map { paths in
                Set(paths).intersection(currentPathSet)
            }
            let plannedPaths = approvedPaths.map { approved in
                currentPaths.filter(approved.contains)
            } ?? currentPaths
            let lines = try repairProjectProjection(
                project,
                apply: options.apply,
                approvedCodexProjectionPaths: approvedPaths
            )
            repairProjects.append(SkillsRepairProject(
                root: project.root,
                lines: lines,
                plannedCodexProjectionPaths: plannedPaths
            ))
        }

        return SkillsRepairReport(apply: options.apply, projects: repairProjects)
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

        let command: String?
        switch agentsSkill.manager {
        case "skills-cli":
            command = skillsCLIRemovalCommand(root: root, skillName: skillName)
        case "dotagents":
            command = dotagentsRemovalCommand(root: root, skillName: skillName)
        default:
            command = nil
        }
        return SkillRemovalPlan(
            projectRoot: root.path,
            skillName: skillName,
            manager: agentsSkill.manager,
            mutability: agentsSkill.mutability,
            command: command,
            applySupported: agentsSkill.representation == "canonical"
                && ["local", "dotagents", "skills-cli"].contains(agentsSkill.manager)
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

        if ["skills-cli", "dotagents"].contains(agentsSkill.manager), !allowManagedRemoval {
            throw NSError(domain: "MetagentSkillUninstall", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "\(skillName) is managed by \(agentsSkill.manager). Run `\(plan.command ?? "the owning manager")` from \(root.path), or explicitly apply the Metagent removal plan."
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
        if ["skills-cli", "dotagents"].contains(agentsSkill.manager) {
            let isPathBackedDotagentsSkill = agentsSkill.manager == "dotagents"
                && dotagentsPathSource(
                    agentsSkill.source,
                    projectRoot: root,
                    resolvesTo: skillURL
                )
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
                let output = agentsSkill.manager == "skills-cli"
                    ? try runSkillsCLIRemoval(root: root, skillName: skillName)
                    : try runDotagentsRemoval(root: root, skillName: skillName)
                if !output.isEmpty {
                    lines.append(output)
                }
            } catch {
                throw NSError(domain: "MetagentSkillUninstall", code: 7, userInfo: [
                    NSLocalizedDescriptionKey: "\(agentsSkill.manager) removal failed: \(error.localizedDescription)\nRecovery state: \(recovery.path)"
                ])
            }
            let managerEntryRemains = agentsSkill.manager == "skills-cli"
                ? readProjectSkillLocks(root: root)[skillName] != nil
                : readDotagentsSkills(root: root)[skillName] != nil
            if isPathBackedDotagentsSkill,
               !managerEntryRemains,
               fileManager.fileExists(atPath: skillURL.path)
            {
                let retiredSource = recovery
                    .appendingPathComponent("path-backed-source")
                    .appendingPathComponent(skillName)
                try fileManager.createDirectory(
                    at: retiredSource.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.moveItem(at: skillURL, to: retiredSource)
                lines.append("moved path-backed dotagents source into recovery: \(retiredSource.path)")
            }
            guard !fileManager.fileExists(atPath: skillURL.path), !managerEntryRemains else {
                throw NSError(domain: "MetagentSkillUninstall", code: 8, userInfo: [
                    NSLocalizedDescriptionKey: "\(agentsSkill.manager) reported success but the bundle or manager entry remains. Recovery state: \(recovery.path)"
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
            lines.append("removed managed skill through \(agentsSkill.manager) and verified its manager entry is absent")
            if removedProjectionCount > 0 {
                lines.append("removed \(removedProjectionCount) dangling per-skill projection link(s)")
            }
            lines.append(finalizeRemovalRecovery(
                recovery,
                projectRoot: root,
                skillName: skillName
            ))
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
        lines.append(finalizeRemovalRecovery(
            recovery,
            projectRoot: root,
            skillName: skillName
        ))
        return SkillUninstallReport(
            projectRoot: root.path,
            skillName: skillName,
            backupPath: backupPath,
            lines: lines
        )
    }

    public static func uninstallSkills(
        projectRoot: String,
        skillNames: [String],
        allowManagedRemoval: Bool = false
    ) -> SkillUninstallBatchReport {
        let names = Array(Set(skillNames)).sorted()
        guard !names.isEmpty else {
            return SkillUninstallBatchReport(reports: [], failures: [])
        }
        guard names.count > 1 else {
            do {
                return SkillUninstallBatchReport(reports: [
                    try uninstallSkill(
                        projectRoot: projectRoot,
                        skillName: names[0],
                        allowManagedRemoval: allowManagedRemoval
                    )
                ], failures: [])
            } catch {
                return SkillUninstallBatchReport(reports: [], failures: [
                    SkillUninstallFailure(skillName: names[0], message: error.localizedDescription)
                ])
            }
        }

        var plans: [SkillRemovalPlan] = []
        var failures: [SkillUninstallFailure] = []
        for name in names {
            do {
                plans.append(try planSkillRemoval(projectRoot: projectRoot, skillName: name))
            } catch {
                failures.append(SkillUninstallFailure(skillName: name, message: error.localizedDescription))
            }
        }
        let skillsCLINames = plans.filter { $0.manager == "skills-cli" }.map(\.skillName)
        var reports: [SkillUninstallReport] = []

        if !skillsCLINames.isEmpty, !allowManagedRemoval {
            failures += skillsCLINames.map {
                SkillUninstallFailure(
                    skillName: $0,
                    message: "This skill is managed by skills-cli. Explicitly apply the Metagent removal plan to remove it."
                )
            }
        } else if !skillsCLINames.isEmpty {
            let batch = uninstallSkillsCLIManagedSkills(
                projectRoot: projectRoot,
                skillNames: skillsCLINames
            )
            reports += batch.reports
            failures += batch.failures
        }

        for plan in plans where plan.manager != "skills-cli" {
            do {
                reports.append(try uninstallSkill(
                    projectRoot: projectRoot,
                    skillName: plan.skillName,
                    allowManagedRemoval: allowManagedRemoval
                ))
            } catch {
                failures.append(SkillUninstallFailure(
                    skillName: plan.skillName,
                    message: error.localizedDescription
                ))
            }
        }
        return SkillUninstallBatchReport(
            reports: reports.sorted {
                $0.skillName.localizedCaseInsensitiveCompare($1.skillName) == .orderedAscending
            },
            failures: failures.sorted {
                $0.skillName.localizedCaseInsensitiveCompare($1.skillName) == .orderedAscending
            }
        )
    }

    private static func uninstallSkillsCLIManagedSkills(
        projectRoot: String,
        skillNames: [String]
    ) -> SkillUninstallBatchReport {
        let root = URL(fileURLWithPath: projectRoot).resolvingSymlinksInPath().standardizedFileURL
        let project: SkillProject
        do {
            project = try readProjectSkills(root: root)
        } catch {
            return SkillUninstallBatchReport(reports: [], failures: skillNames.map {
                SkillUninstallFailure(skillName: $0, message: error.localizedDescription)
            })
        }

        var removals: [SkillsCLIManagedRemoval] = []
        var failures: [SkillUninstallFailure] = []
        for skillName in skillNames {
            do {
                guard let skill = project.skills.first(where: {
                    $0.location == "agents"
                        && $0.name == skillName
                        && $0.manager == "skills-cli"
                        && $0.representation == "canonical"
                }) else {
                    throw NSError(domain: "MetagentSkillUninstall", code: 4, userInfo: [
                        NSLocalizedDescriptionKey: "\(skillName) is not a canonical Skills CLI bundle in \(root.path)."
                    ])
                }

                let skillURL = URL(fileURLWithPath: skill.path)
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
                let recovery = try prepareRemovalRecovery(projectRoot: root, skillName: skillName)
                try fileManager.copyItem(at: skillURL, to: recovery.appendingPathComponent(skillName))

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
                removals.append(SkillsCLIManagedRemoval(
                    skillName: skillName,
                    skillURL: skillURL,
                    recovery: recovery,
                    projections: projections,
                    retainedBackups: retainedBackups
                ))
            } catch {
                failures.append(SkillUninstallFailure(
                    skillName: skillName,
                    message: error.localizedDescription
                ))
            }
        }

        guard !removals.isEmpty else {
            return SkillUninstallBatchReport(reports: [], failures: failures)
        }

        let commandError: Error?
        do {
            _ = try runSkillsCLIRemoval(root: root, skillNames: removals.map(\.skillName))
            commandError = nil
        } catch {
            commandError = error
        }

        let remainingLocks = readProjectSkillLocks(root: root)
        var reports: [SkillUninstallReport] = []
        for removal in removals {
            guard !fileManager.fileExists(atPath: removal.skillURL.path),
                  remainingLocks[removal.skillName] == nil
            else {
                failures.append(SkillUninstallFailure(
                    skillName: removal.skillName,
                    message: commandError?.localizedDescription
                        ?? "skills-cli reported success but the bundle or its lock entry remains. Recovery state: \(removal.recovery.path)"
                ))
                continue
            }

            var lines = [
                "saved recovery state to \(removal.recovery.path)",
                "copied managed skill into recovery: \(removal.recovery.appendingPathComponent(removal.skillName).path)"
            ]
            if !removal.retainedBackups.isEmpty {
                lines.append("snapshotted \(removal.retainedBackups.count) independent same-name location(s)")
            }
            var restoredRetainedCount = 0
            for retained in removal.retainedBackups {
                guard !isSymlink(retained.original),
                      !fileManager.fileExists(atPath: retained.original.path)
                else { continue }
                do {
                    try fileManager.createDirectory(
                        at: retained.original.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try fileManager.copyItem(at: retained.backup, to: retained.original)
                    restoredRetainedCount += 1
                } catch {
                    lines.append("warning: managed package was removed, but restoring \(retained.original.path) failed: \(error.localizedDescription)")
                }
            }
            if restoredRetainedCount > 0 {
                lines.append("restored \(restoredRetainedCount) independent same-name location(s)")
            }

            var removedProjectionCount = 0
            for (index, projection) in removal.projections.enumerated() {
                let projectionURL = URL(fileURLWithPath: projection.path)
                guard isSymlink(projectionURL) || fileManager.fileExists(atPath: projectionURL.path) else { continue }
                let projectionRecovery = removal.recovery
                    .appendingPathComponent("projections")
                    .appendingPathComponent("\(index)-\(projection.location)")
                    .appendingPathComponent(removal.skillName)
                do {
                    try fileManager.createDirectory(
                        at: projectionRecovery.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try fileManager.moveItem(at: projectionURL, to: projectionRecovery)
                    removedProjectionCount += 1
                } catch {
                    lines.append("warning: managed skill was removed, but projection cleanup failed at \(projectionURL.path): \(error.localizedDescription)")
                }
            }
            lines.append("removed managed skill through skills-cli and verified its manager entry is absent")
            if removedProjectionCount > 0 {
                lines.append("removed \(removedProjectionCount) dangling per-skill projection link(s)")
            }
            lines.append(finalizeRemovalRecovery(
                removal.recovery,
                projectRoot: root,
                skillName: removal.skillName
            ))
            reports.append(SkillUninstallReport(
                projectRoot: root.path,
                skillName: removal.skillName,
                backupPath: removal.recovery.path,
                lines: lines
            ))
        }
        return SkillUninstallBatchReport(reports: reports, failures: failures)
    }

    public static func uninstallStandaloneSkill(
        projectRoot: String,
        skillPath: String,
        skillName: String
    ) throws -> SkillUninstallReport {
        guard let (root, skill) = standaloneSkillRemovalTarget(
            projectRoot: projectRoot,
            skillPath: skillPath,
            skillName: skillName
        ) else {
            throw NSError(domain: "MetagentSkillUninstall", code: 9, userInfo: [
                NSLocalizedDescriptionKey: "Metagent will only remove a canonical standalone skill bundle."
            ])
        }
        let recovery = try prepareRemovalRecovery(projectRoot: root, skillName: skillName)
        let recoveredSkill = recovery.appendingPathComponent(skillName)
        let project = try readProjectSkills(root: root)
        let projections = project.skills.filter { candidate in
            guard candidate.name == skillName,
                  candidate.path != skill.path,
                  !candidate.symlinkedContainer
            else { return false }
            let candidateURL = URL(fileURLWithPath: candidate.path)
            return isSymlink(candidateURL) && symlink(candidateURL, resolvesTo: skill)
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
            try fileManager.moveItem(at: skill, to: recoveredSkill)
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
                throw NSError(domain: "MetagentSkillUninstall", code: 10, userInfo: [
                    NSLocalizedDescriptionKey: "standalone removal failed and projection rollback was incomplete. Original error: \(error.localizedDescription)\nRollback failures:\n\(rollbackFailures.joined(separator: "\n"))\nRecovery state: \(recovery.path)"
                ])
            }
            throw error
        }
        guard !fileManager.fileExists(atPath: skill.path) else {
            throw NSError(domain: "MetagentSkillUninstall", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "standalone removal verification failed: \(skill.path) still exists"
            ])
        }
        var lines = ["moved standalone skill to recovery: \(recoveredSkill.path)"]
        if !projections.isEmpty {
            lines.append("removed \(projections.count) per-skill projection link(s)")
        }
        lines.append("verified canonical standalone skill is absent")
        lines.append(finalizeRemovalRecovery(
            recovery,
            projectRoot: root,
            skillName: skillName
        ))
        return SkillUninstallReport(
            projectRoot: root.path,
            skillName: skillName,
            backupPath: recovery.path,
            lines: lines
        )
    }

    public static func canUninstallStandaloneSkill(
        projectRoot: String,
        skillPath: String,
        skillName: String
    ) -> Bool {
        standaloneSkillRemovalTarget(
            projectRoot: projectRoot,
            skillPath: skillPath,
            skillName: skillName
        ) != nil
    }

    public static func uninstallCodexPlugin(pluginID: String) throws -> SkillUninstallReport {
        guard pluginID.contains("@") else {
            throw NSError(domain: "MetagentCodexPlugins", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "invalid Codex plugin identifier: \(pluginID)"
            ])
        }
        let result = try runSubprocess(
            executable: try codexExecutable(),
            arguments: ["plugin", "remove", pluginID, "--json"],
            timeout: 120
        )
        let combined = String(data: result.standardOutput + result.standardError, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if result.timedOut {
            throw NSError(domain: "MetagentCodexPlugins", code: 124, userInfo: [
                NSLocalizedDescriptionKey: "Codex plugin removal timed out after 120 seconds"
            ])
        }
        guard result.status == 0 else {
            throw NSError(domain: "MetagentCodexPlugins", code: Int(result.status), userInfo: [
                NSLocalizedDescriptionKey: combined.isEmpty ? "Codex plugin removal failed" : combined
            ])
        }
        guard !(try installedCodexPlugins()).contains(where: { $0.pluginId == pluginID }) else {
            throw NSError(domain: "MetagentCodexPlugins", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "Codex reported success but \(pluginID) remains installed"
            ])
        }
        return SkillUninstallReport(
            projectRoot: "codex-plugin",
            skillName: pluginID,
            backupPath: nil,
            lines: [combined.isEmpty ? "removed Codex plugin \(pluginID)" : combined]
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

private struct DotagentsSkillEntry {
    var source: String
    var isLocked: Bool
}

private struct SkillOriginEvidence {
    var originKind: String
    var manager: String
    var authority: String
    var mutability: String
    var source: String?
    var sourceType: String?
    var sourceURL: String?
    var ref: String?
}

private func canonicalSkillOwnership(
    scope: String,
    skillLock: SkillLockEntry?,
    dotagents: DotagentsSkillEntry?
) -> SkillOriginEvidence {
    if let skillLock {
        return SkillOriginEvidence(
            originKind: "npx-skills",
            manager: "skills-cli",
            authority: skillLock.source ?? "upstream-package",
            mutability: "managed-read-only",
            source: nil,
            sourceType: nil,
            sourceURL: nil,
            ref: nil
        )
    }
    if let dotagents {
        let isLocalPath = dotagents.source.hasPrefix("path:")
        return SkillOriginEvidence(
            originKind: isLocalPath ? "dotagents-local" : "dotagents-managed",
            manager: "dotagents",
            authority: dotagents.source,
            mutability: isLocalPath ? "editable" : "managed-read-only",
            source: dotagents.source,
            sourceType: dotagents.isLocked ? "dotagents-lock" : "dotagents-config",
            sourceURL: isLocalPath
                ? nil
                : (dotagents.source.contains("://") ? dotagents.source : nil),
            ref: nil
        )
    }
    return SkillOriginEvidence(
        originKind: scope == "global" ? "user-local" : "project-local",
        manager: "local",
        authority: "unknown",
        mutability: "editable",
        source: nil,
        sourceType: "local",
        sourceURL: nil,
        ref: nil
    )
}

private struct SkillStats {
    var description: String?
    var latestModifiedAt: Date?
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
        arguments: ["plugin", "list", "--json"],
        timeout: 30
    )
    if result.timedOut {
        let detail = String(data: result.standardError, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        throw NSError(domain: "MetagentCodexPlugins", code: 2, userInfo: [
            NSLocalizedDescriptionKey: detail?.isEmpty == false
                ? "codex plugin list timed out: \(detail!)"
                : "codex plugin list timed out after 30 seconds"
        ])
    }
    guard result.status == 0 else {
        let detail = String(data: result.standardError, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        throw NSError(domain: "MetagentCodexPlugins", code: Int(result.status), userInfo: [
            NSLocalizedDescriptionKey: detail?.isEmpty == false ? detail! : "codex plugin list failed"
        ])
    }
    return try JSONDecoder().decode(CodexPluginList.self, from: result.standardOutput).installed
        .filter { $0.installed && $0.enabled }
}

func codexExecutable() throws -> URL {
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
    let dotagentsSkills = readDotagentsSkills(root: root)
    let scope = canonicalProjectPath(root) == canonicalProjectPath(homeURL()) ? "global" : "project"
    var validSkills: [String] = []
    var inventory: [SkillInventoryItem] = []
    var invalidSkillDirs: [String] = []
    var hiddenSkillDirs: [String] = []

    readAgentsSkills(
        skillsDir: agentsSkillsDir,
        skillLock: skillLock,
        dotagentsSkills: dotagentsSkills,
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
    dotagentsSkills: [String: DotagentsSkillEntry],
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
        let recordedDotagentsEntry = dotagentsSkills[name]
        // dotagents `sync` adopts an existing local skill by recording a path
        // back to its own install directory. That is reconciliation state, not
        // lifecycle ownership. Only a distinct source is manager evidence.
        let dotagentsEntry = recordedDotagentsEntry.flatMap { entryEvidence in
            dotagentsPathSource(entryEvidence.source, projectRoot: projectRoot(for: skillsDir), resolvesTo: entry)
                ? nil
                : entryEvidence
        }
        let projection = symlinkedContainer || isSymlink(entry)
        let ownership = canonicalSkillOwnership(
            scope: scope,
            skillLock: lockEntry,
            dotagents: dotagentsEntry
        )
        inventory.append(makeSkillItem(
            name: name,
            path: entry,
            location: "agents",
            originKind: ownership.originKind,
            scope: scope,
            manager: ownership.manager,
            authority: ownership.authority,
            mutability: projection ? "managed-read-only" : ownership.mutability,
            representation: projection ? "projection" : "canonical",
            canonicalPath: canonicalProjectPath(entry),
            origin: lockEntry,
            evidence: ownership,
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
            let manager = inherited?.manager ?? location
            let authority = inherited?.authority
                ?? (isSystem ? "codex-system" : "\(location)-installed")
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
    evidence: SkillOriginEvidence? = nil,
    symlinkedContainer: Bool,
    inherited: SkillInventoryItem? = nil
) -> SkillInventoryItem {
    let stats = skillStats(path)
    let recognizedEvidence = recognizedExternalSkillEvidence(
        name: name,
        path: path,
        currentManager: evidence?.manager ?? manager
    )
    let resolvedEvidence = recognizedEvidence ?? evidence
    let resolvedOriginKind = resolvedEvidence?.originKind ?? originKind
    return SkillInventoryItem(
        name: name,
        description: stats.description,
        path: path.path,
        location: location,
        locationLabel: ".\(location)",
        originKind: resolvedOriginKind,
        scope: scope,
        manager: resolvedEvidence?.manager ?? manager,
        authority: resolvedEvidence?.authority ?? authority,
        mutability: representation == "projection"
            ? "managed-read-only"
            : (resolvedEvidence?.mutability ?? mutability),
        representation: representation,
        canonicalPath: canonicalPath,
        source: resolvedEvidence?.source ?? origin?.source ?? inherited?.source,
        sourceType: resolvedEvidence?.sourceType ?? origin?.sourceType ?? inherited?.sourceType,
        sourceURL: resolvedEvidence?.sourceURL ?? origin?.sourceUrl ?? inherited?.sourceURL,
        ref: resolvedEvidence?.ref ?? origin?.ref ?? inherited?.ref,
        installedAt: origin?.installedAt ?? inherited?.installedAt,
        updatedAt: origin?.updatedAt
            ?? inherited?.updatedAt
            ?? stats.latestModifiedAt.map { ISO8601DateFormatter().string(from: $0) },
        symlinkedContainer: symlinkedContainer,
        folderKind: folderKind(
            path: path,
            location: location,
            originKind: resolvedOriginKind,
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

private func recognizedExternalSkillEvidence(
    name: String,
    path: URL,
    currentManager: String
) -> SkillOriginEvidence? {
    guard currentManager == "local" else { return nil }
    let skillPath = path.appendingPathComponent("SKILL.md")
    guard name == "impeccable",
          fileManager.fileExists(atPath: path.appendingPathComponent("scripts/context.mjs").path),
          fileManager.fileExists(atPath: path.appendingPathComponent("reference/hooks.md").path),
          let text = try? String(contentsOf: skillPath, encoding: .utf8),
          text.contains(".agents/skills/impeccable/scripts/")
    else {
        return nil
    }
    let version = frontmatterScalar(key: "version", text: text)
    return SkillOriginEvidence(
        originKind: "external-cli",
        manager: "external-cli",
        authority: "Impeccable CLI",
        mutability: "managed-read-only",
        source: "pbakaus/impeccable",
        sourceType: "bundle-signature",
        sourceURL: "https://github.com/pbakaus/impeccable",
        ref: version
    )
}

private func frontmatterScalar(key: String, text: String) -> String? {
    let prefix = "\(key):"
    for line in text.components(separatedBy: .newlines).prefix(40) {
        guard line.first?.isWhitespace != true,
              line.trimmingCharacters(in: .whitespaces).hasPrefix(prefix)
        else { continue }
        let rawValue = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        let value = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return value.isEmpty ? nil : value
    }
    return nil
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
        includingPropertiesForKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
        ],
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
        if let modifiedAt = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           stats.latestModifiedAt == nil || modifiedAt > stats.latestModifiedAt!
        {
            stats.latestModifiedAt = modifiedAt
        }
        categorizeSkillFile(root: root, path: entry, stats: &stats, otherFolders: &otherFolders)
        guard isSkillTextFile(entry) else { continue }
        guard let text = try? String(contentsOf: entry, encoding: .utf8) else { continue }
        let characters = text.count
        let words = text.split(whereSeparator: \.isWhitespace).count
        stats.textFileCount += 1
        stats.characterCount += characters
        stats.wordCount += words

        if entry.standardizedFileURL == root.appendingPathComponent("SKILL.md").standardizedFileURL {
            stats.description = skillDescription(from: text)
            stats.skillFileCharacterCount += characters
            stats.skillFileWordCount += words
        }
    }
}

func skillDescription(from skillText: String) -> String? {
    let lines = skillText.components(separatedBy: .newlines)
    guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else { return nil }
    guard let closingIndex = lines.dropFirst().firstIndex(where: {
        $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---"
    }) else { return nil }

    let frontmatter = Array(lines[1..<closingIndex])
    guard let descriptionIndex = frontmatter.firstIndex(where: {
        $0.trimmingCharacters(in: .whitespaces).hasPrefix("description:")
    }) else { return nil }

    let line = frontmatter[descriptionIndex].trimmingCharacters(in: .whitespaces)
    let rawValue = String(line.dropFirst("description:".count)).trimmingCharacters(in: .whitespaces)
    if !["|", "|-", "|+", ">", ">-", ">+"].contains(rawValue) {
        guard let value = decodedYAMLScalar(rawValue) else { return nil }
        return value.isEmpty ? nil : value
    }

    let continuation = frontmatter.dropFirst(descriptionIndex + 1)
        .prefix { line in
            line.first?.isWhitespace == true || line.trimmingCharacters(in: .whitespaces).isEmpty
        }
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    guard !continuation.isEmpty else { return nil }
    return continuation.joined(separator: rawValue.hasPrefix(">") ? " " : "\n")
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
    stats.iconSmallPath = yamlInterfaceValue(key: "icon_small", text: text).map {
        skillDir.appendingPathComponent($0).standardizedFileURL.path
    }
    stats.iconLargePath = yamlInterfaceValue(key: "icon_large", text: text).map {
        skillDir.appendingPathComponent($0).standardizedFileURL.path
    }
    stats.hasIconSmall = stats.iconSmallPath != nil
    stats.hasIconLarge = stats.iconLargePath != nil
}

private func yamlInterfaceValue(key: String, text: String) -> String? {
    let lines = text.components(separatedBy: .newlines)
    guard let interfaceIndex = lines.firstIndex(where: {
        $0.trimmingCharacters(in: .whitespaces) == "interface:"
    }) else { return nil }
    let range = yamlMappingRange(lines: lines, parentIndex: interfaceIndex)
    let childIndent = range.compactMap { index -> Int? in
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        return yamlIndent(lines[index])
    }.min()
    guard let childIndent else { return nil }
    let prefix = "\(key):"
    for index in range where yamlIndent(lines[index]) == childIndent {
        let line = lines[index]
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(prefix) else { continue }
        let value = String(trimmed.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return value.isEmpty ? nil : value
    }
    return nil
}

private func upsertSkillIconMetadata(_ text: String, iconPath: String) -> String {
    var lines = text.components(separatedBy: .newlines)
    if lines.last == "" { lines.removeLast() }
    var foundSmall = false
    var foundLarge = false
    let interfaceIndex = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "interface:" }
    let interfaceIndent = interfaceIndex.map { yamlIndent(lines[$0]) } ?? 0
    let interfaceRange = interfaceIndex.map { yamlMappingRange(lines: lines, parentIndex: $0) }
    let childIndent = interfaceRange.flatMap { range in
        range.compactMap { index -> Int? in
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            return yamlIndent(lines[index])
        }.min()
    } ?? (interfaceIndent + 2)

    if let interfaceRange {
        for index in interfaceRange where yamlIndent(lines[index]) == childIndent {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            let indent = String(repeating: " ", count: childIndent)
            if trimmed.hasPrefix("icon_small:") {
                lines[index] = "\(indent)icon_small: \(iconPath)"
                foundSmall = true
            } else if trimmed.hasPrefix("icon_large:") {
                lines[index] = "\(indent)icon_large: \(iconPath)"
                foundLarge = true
            }
        }
    }

    if !foundSmall || !foundLarge {
        if let interfaceIndex {
            let indent = String(repeating: " ", count: childIndent)
            var additions: [String] = []
            if !foundSmall { additions.append("\(indent)icon_small: \(iconPath)") }
            if !foundLarge { additions.append("\(indent)icon_large: \(iconPath)") }
            lines.insert(contentsOf: additions, at: interfaceIndex + 1)
        } else {
            if !lines.isEmpty { lines.append("") }
            lines.append("interface:")
            lines.append("  icon_small: \(iconPath)")
            lines.append("  icon_large: \(iconPath)")
        }
    }
    return lines.joined(separator: "\n") + "\n"
}

private func yamlMappingRange(lines: [String], parentIndex: Int) -> Range<Int> {
    let parentIndent = yamlIndent(lines[parentIndex])
    var end = lines.endIndex
    for index in lines.index(after: parentIndex)..<lines.endIndex {
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
        if yamlIndent(lines[index]) <= parentIndent {
            end = index
            break
        }
    }
    return lines.index(after: parentIndex)..<end
}

private func yamlIndent(_ line: String) -> Int {
    line.prefix { $0 == " " }.count
}

private func safeSkillIconWriteTargets(skill: URL, directories: [URL], files: [URL]) -> Bool {
    let root = skill.standardizedFileURL.path
    let descendants = root + "/"
    for directory in directories {
        guard !isSymlink(directory) else { return false }
        let resolvedParent = directory.deletingLastPathComponent()
            .resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedParent == root || resolvedParent.hasPrefix(descendants) else { return false }
    }
    for file in files {
        guard !isSymlink(file) else { return false }
        let resolvedParent = file.deletingLastPathComponent()
            .resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedParent == root || resolvedParent.hasPrefix(descendants) else { return false }
    }
    return true
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
    if location == "agents", originKind.hasPrefix("dotagents") {
        return originKind
    }
    if location == "agents", originKind == "external-cli" {
        return originKind
    }
    if location == "agents", originKind.hasSuffix("-local") {
        return originKind
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

private func readDotagentsSkills(root: URL) -> [String: DotagentsSkillEntry] {
    let base = canonicalProjectPath(root) == canonicalProjectPath(homeURL())
        ? root.appendingPathComponent(".agents")
        : root
    var entries = parseDotagentsConfig(base.appendingPathComponent("agents.toml"))
    for (name, locked) in parseDotagentsLock(base.appendingPathComponent("agents.lock")) {
        entries[name] = locked
    }
    return entries
}

private func parseDotagentsConfig(_ path: URL) -> [String: DotagentsSkillEntry] {
    guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [:] }
    var entries: [String: DotagentsSkillEntry] = [:]
    var name: String?
    var source: String?
    var inSkill = false

    func flush() {
        guard let name, let source else { return }
        entries[name] = DotagentsSkillEntry(source: source, isLocked: false)
    }

    for rawLine in text.components(separatedBy: .newlines) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        let header = tomlHeaderWithoutComment(line)
        if header == "[[skills]]" {
            flush()
            name = nil
            source = nil
            inSkill = true
        } else if header.hasPrefix("[") {
            flush()
            name = nil
            source = nil
            inSkill = false
        } else if inSkill, line.hasPrefix("name"), let value = tomlStringValue(line) {
            name = value
        } else if inSkill, line.hasPrefix("source"), let value = tomlStringValue(line) {
            source = value
        }
    }
    flush()
    return entries
}

private func parseDotagentsLock(_ path: URL) -> [String: DotagentsSkillEntry] {
    guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [:] }
    var entries: [String: DotagentsSkillEntry] = [:]
    var name: String?
    for rawLine in text.components(separatedBy: .newlines) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        let header = tomlHeaderWithoutComment(line)
        if header.hasPrefix("[skills."), header.hasSuffix("]") {
            name = String(header.dropFirst(8).dropLast())
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        } else if header.hasPrefix("[") {
            name = nil
        } else if line.hasPrefix("source"), let name, let source = tomlStringValue(line) {
            entries[name] = DotagentsSkillEntry(source: source, isLocked: true)
        }
    }
    return entries
}

private func tomlHeaderWithoutComment(_ line: String) -> String {
    String(line.prefix { $0 != "#" }).trimmingCharacters(in: .whitespaces)
}

private func tomlStringValue(_ line: String) -> String? {
    guard let equals = line.firstIndex(of: "=") else { return nil }
    let rawValue = line[line.index(after: equals)...]
        .trimmingCharacters(in: .whitespaces)
    guard let quote = rawValue.first, quote == "\"" || quote == "'" else {
        let value = String(rawValue.prefix { $0 != "#" })
            .trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
    var escaped = false
    var closingQuote: String.Index?
    for index in rawValue.indices.dropFirst() {
        let character = rawValue[index]
        if quote == "\"", character == "\\", !escaped {
            escaped = true
            continue
        }
        if character == quote, !escaped {
            closingQuote = index
            break
        }
        escaped = false
    }
    guard let closingQuote else { return nil }
    let value = String(rawValue[rawValue.index(after: rawValue.startIndex)..<closingQuote])
    return value.isEmpty ? nil : value
}

private func dotagentsPathSource(
    _ source: String?,
    projectRoot: URL,
    resolvesTo expectedSkill: URL
) -> Bool {
    guard let source, source.hasPrefix("path:") else { return false }
    let rawPath = String(source.dropFirst("path:".count))
    guard !rawPath.isEmpty else { return false }
    let base = canonicalProjectPath(projectRoot) == canonicalProjectPath(homeURL())
        ? projectRoot.appendingPathComponent(".agents")
        : projectRoot
    let sourceURL = rawPath.hasPrefix("/")
        ? URL(fileURLWithPath: rawPath)
        : base.appendingPathComponent(rawPath)
    return sourceURL.standardizedFileURL.path == expectedSkill.standardizedFileURL.path
}

private func projectRoot(for skillsDirectory: URL) -> URL {
    skillsDirectory
        .deletingLastPathComponent()
        .deletingLastPathComponent()
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
    return "npx --yes skills remove \(skillName) --yes\(globalFlag)"
}

private func dotagentsRemovalCommand(root: URL, skillName: String) -> String {
    let userFlag = canonicalProjectPath(root) == canonicalProjectPath(homeURL()) ? " --user" : ""
    return "npx --yes @sentry/dotagents\(userFlag) remove \(skillName) --yes"
}

private func runSkillsCLIRemoval(root: URL, skillName: String) throws -> String {
    try runSkillsCLIRemoval(root: root, skillNames: [skillName])
}

private func runSkillsCLIRemoval(root: URL, skillNames: [String]) throws -> String {
    let arguments = ["--yes", "skills", "remove"] + skillNames + ["--yes"]
        + (canonicalProjectPath(root) == canonicalProjectPath(homeURL()) ? ["--global"] : [])
    let result = try runSubprocess(
        executable: try npxExecutable(),
        arguments: arguments,
        currentDirectory: root,
        timeout: 120
    )
    let combined = String(data: result.standardOutput + result.standardError, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if result.timedOut {
        throw NSError(domain: "MetagentSkillsCLI", code: 124, userInfo: [
            NSLocalizedDescriptionKey: combined.isEmpty
                ? "npx skills remove timed out after 120 seconds"
                : "npx skills remove timed out after 120 seconds:\n\(combined)"
        ])
    }
    guard result.status == 0 else {
        throw NSError(domain: "MetagentSkillsCLI", code: Int(result.status), userInfo: [
            NSLocalizedDescriptionKey: combined.isEmpty ? "npx skills remove failed" : combined
        ])
    }
    return combined
}

private func runDotagentsRemoval(root: URL, skillName: String) throws -> String {
    let arguments = ["--yes", "@sentry/dotagents"]
        + (canonicalProjectPath(root) == canonicalProjectPath(homeURL()) ? ["--user"] : [])
        + ["remove", skillName, "--yes"]
    let result = try runSubprocess(
        executable: try npxExecutable(),
        arguments: arguments,
        currentDirectory: root,
        timeout: 120
    )
    let combined = String(data: result.standardOutput + result.standardError, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if result.timedOut {
        throw NSError(domain: "MetagentDotagents", code: 124, userInfo: [
            NSLocalizedDescriptionKey: combined.isEmpty
                ? "dotagents remove timed out after 120 seconds"
                : "dotagents remove timed out after 120 seconds:\n\(combined)"
        ])
    }
    guard result.status == 0 else {
        throw NSError(domain: "MetagentDotagents", code: Int(result.status), userInfo: [
            NSLocalizedDescriptionKey: combined.isEmpty ? "dotagents remove failed" : combined
        ])
    }
    return combined
}

private func standaloneSkillRemovalTarget(
    projectRoot: String,
    skillPath: String,
    skillName: String
) -> (root: URL, skill: URL)? {
    let root = URL(fileURLWithPath: projectRoot).standardizedFileURL
    let skill = URL(fileURLWithPath: skillPath).standardizedFileURL
    guard root.resolvingSymlinksInPath().standardizedFileURL.path == root.path,
          !isSymlink(skill),
          !skill.pathComponents.contains(".system"),
          skill.lastPathComponent == skillName,
          isRegularOrSymlinkedFile(skill.appendingPathComponent("SKILL.md"))
    else { return nil }
    let allowedParents = [".codex", ".claude"].map {
        root.appendingPathComponent($0).appendingPathComponent("skills").standardizedFileURL
    }
    guard allowedParents.contains(where: { parent in
        skill.deletingLastPathComponent().path == parent.path
            && !isSymlink(parent)
            && !isSymlink(parent.deletingLastPathComponent())
            && parent.resolvingSymlinksInPath().standardizedFileURL.path == parent.path
    }) else { return nil }
    return (root, skill)
}

struct SubprocessResult {
    var status: Int32
    var standardOutput: Data
    var standardError: Data
    var timedOut: Bool
}

func runSubprocess(
    executable: URL,
    arguments: [String],
    currentDirectory: URL? = nil,
    standardInput: Data? = nil,
    timeout: TimeInterval
) throws -> SubprocessResult {
    let captureDirectory = fileManager.temporaryDirectory
        .appendingPathComponent("metagent-process-\(UUID().uuidString)")
    try fileManager.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: captureDirectory) }
    let outputURL = captureDirectory.appendingPathComponent("stdout")
    let errorURL = captureDirectory.appendingPathComponent("stderr")
    let inputURL = captureDirectory.appendingPathComponent("stdin")
    _ = fileManager.createFile(atPath: outputURL.path, contents: nil)
    _ = fileManager.createFile(atPath: errorURL.path, contents: nil)
    if let standardInput {
        try standardInput.write(to: inputURL, options: .atomic)
    }
    let inputHandle = try FileHandle(
        forReadingFrom: standardInput == nil ? URL(fileURLWithPath: "/dev/null") : inputURL
    )
    let outputHandle = try FileHandle(forWritingTo: outputURL)
    let errorHandle = try FileHandle(forWritingTo: errorURL)

    var fileActions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    try requirePosixSuccess(posix_spawn_file_actions_init(&fileActions), action: "initialize process file actions")
    defer { posix_spawn_file_actions_destroy(&fileActions) }
    try requirePosixSuccess(posix_spawnattr_init(&attributes), action: "initialize process attributes")
    defer { posix_spawnattr_destroy(&attributes) }
    try requirePosixSuccess(
        posix_spawn_file_actions_adddup2(&fileActions, inputHandle.fileDescriptor, STDIN_FILENO),
        action: "redirect process input"
    )
    try requirePosixSuccess(
        posix_spawn_file_actions_adddup2(&fileActions, outputHandle.fileDescriptor, STDOUT_FILENO),
        action: "redirect process output"
    )
    try requirePosixSuccess(
        posix_spawn_file_actions_adddup2(&fileActions, errorHandle.fileDescriptor, STDERR_FILENO),
        action: "redirect process errors"
    )
    if let currentDirectory {
        let result = currentDirectory.path.withCString {
            posix_spawn_file_actions_addchdir_np(&fileActions, $0)
        }
        try requirePosixSuccess(result, action: "set process working directory")
    }
    try requirePosixSuccess(
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)),
        action: "configure process group"
    )
    try requirePosixSuccess(
        posix_spawnattr_setpgroup(&attributes, 0),
        action: "create process group"
    )

    var processID: pid_t = 0
    var argumentPointers = ([executable.path] + arguments).map { strdup($0) as UnsafeMutablePointer<CChar>? }
    argumentPointers.append(nil)
    defer { argumentPointers.dropLast().forEach { free($0) } }
    var environmentPointers = ProcessInfo.processInfo.environment
        .sorted { $0.key < $1.key }
        .map { strdup("\($0.key)=\($0.value)") as UnsafeMutablePointer<CChar>? }
    environmentPointers.append(nil)
    defer { environmentPointers.dropLast().forEach { free($0) } }
    let spawnResult = executable.path.withCString { executablePath in
        argumentPointers.withUnsafeMutableBufferPointer { argumentBuffer in
            environmentPointers.withUnsafeMutableBufferPointer { environmentBuffer in
                posix_spawn(
                    &processID,
                    executablePath,
                    &fileActions,
                    &attributes,
                    argumentBuffer.baseAddress,
                    environmentBuffer.baseAddress
                )
            }
        }
    }
    try requirePosixSuccess(spawnResult, action: "start \(executable.path)")
    try inputHandle.close()
    try outputHandle.close()
    try errorHandle.close()

    let deadline = Date().addingTimeInterval(timeout)
    var waitStatus: Int32 = 0
    var exited = waitpid(processID, &waitStatus, WNOHANG) == processID
    while !exited && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
        exited = waitpid(processID, &waitStatus, WNOHANG) == processID
    }
    let timedOut = !exited
    if timedOut {
        kill(-processID, SIGTERM)
        let terminationDeadline = Date().addingTimeInterval(2)
        var processGroupAlive = isProcessGroupAlive(processID)
        while processGroupAlive && Date() < terminationDeadline {
            Thread.sleep(forTimeInterval: 0.05)
            if !exited {
                exited = waitpid(processID, &waitStatus, WNOHANG) == processID
            }
            processGroupAlive = isProcessGroupAlive(processID)
        }
        if processGroupAlive {
            kill(-processID, SIGKILL)
        }
    }
    while !exited {
        let result = waitpid(processID, &waitStatus, 0)
        if result == processID {
            exited = true
        } else if result == -1, errno != EINTR {
            throw NSError(domain: "MetagentSubprocess", code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "wait for \(executable.path) failed: \(String(cString: strerror(errno)))"
            ])
        }
    }
    return SubprocessResult(
        status: subprocessExitStatus(waitStatus),
        standardOutput: try Data(contentsOf: outputURL),
        standardError: try Data(contentsOf: errorURL),
        timedOut: timedOut
    )
}

private func isProcessGroupAlive(_ processID: pid_t) -> Bool {
    if kill(-processID, 0) == 0 {
        return true
    }
    return errno == EPERM
}

private func requirePosixSuccess(_ status: Int32, action: String) throws {
    guard status == 0 else {
        throw NSError(domain: "MetagentSubprocess", code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: "\(action) failed: \(String(cString: strerror(status)))"
        ])
    }
}

private func subprocessExitStatus(_ waitStatus: Int32) -> Int32 {
    let signal = waitStatus & 0x7f
    return signal == 0 ? (waitStatus >> 8) & 0xff : 128 + signal
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
    let dotagentsRoot = canonicalProjectPath(projectRoot) == canonicalProjectPath(homeURL())
        ? projectRoot.appendingPathComponent(".agents")
        : projectRoot
    let stateFiles: [(URL, String)] = [
        (projectRoot.appendingPathComponent("skills-lock.json"), "project-skills-lock.json"),
        (
            projectRoot.appendingPathComponent(".agents").appendingPathComponent(".skill-lock.json"),
            "agents-skill-lock.json"
        ),
        (globalSkillLockPath(), "global-skill-lock.json"),
        (dotagentsRoot.appendingPathComponent("agents.toml"), "agents.toml"),
        (dotagentsRoot.appendingPathComponent("agents.lock"), "agents.lock")
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
    try writeRemovalInventorySnapshot(
        to: recoveryRoot.appendingPathComponent("before.json"),
        phase: "before",
        projectRoot: projectRoot,
        skillName: skillName
    )
    return recoveryRoot
}

private struct RemovalInventorySnapshot: Codable {
    struct Copy: Codable {
        let path: String
        let location: String
        let manager: String
        let representation: String
    }

    let phase: String
    let capturedAt: String
    let projectRoot: String
    let skillName: String
    let canonicalSkillCount: Int
    let matchingCopies: [Copy]
}

private func writeRemovalInventorySnapshot(
    to destination: URL,
    phase: String,
    projectRoot: URL,
    skillName: String
) throws {
    let project = try readProjectSkills(root: projectRoot)
    let canonicalSkillCount = Set<String>(project.skills.compactMap { skill -> String? in
        guard skill.representation == "canonical" else { return nil }
        return skill.canonicalPath.isEmpty ? skill.path : skill.canonicalPath
    }).count
    let snapshot = RemovalInventorySnapshot(
        phase: phase,
        capturedAt: ISO8601DateFormatter().string(from: Date()),
        projectRoot: projectRoot.path,
        skillName: skillName,
        canonicalSkillCount: canonicalSkillCount,
        matchingCopies: project.skills
            .filter { $0.name == skillName }
            .map {
                RemovalInventorySnapshot.Copy(
                    path: $0.path,
                    location: $0.location,
                    manager: $0.manager,
                    representation: $0.representation
                )
            }
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(snapshot).write(to: destination, options: .atomic)
}

private func finalizeRemovalRecovery(
    _ recovery: URL,
    projectRoot: URL,
    skillName: String
) -> String {
    do {
        try writeRemovalInventorySnapshot(
            to: recovery.appendingPathComponent("after.json"),
            phase: "after",
            projectRoot: projectRoot,
            skillName: skillName
        )
        return "captured before/after inventory snapshots in \(recovery.path)"
    } catch {
        return "warning: the skill archive is intact, but the after snapshot failed: \(error.localizedDescription)"
    }
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

private func hasObsoleteCodexProjections(_ project: SkillProject) -> Bool {
    !obsoleteCodexProjectionURLs(project).isEmpty
}

private func obsoleteCodexProjectionURLs(_ project: SkillProject) -> [URL] {
    let projectRoot = URL(fileURLWithPath: project.root).standardizedFileURL
    let canonicalAgentPaths = Set(project.skills.lazy
        .filter { $0.location == "agents" }
        .map(\.canonicalPath))
    return project.skills.compactMap { skill in
        guard skill.location == "codex",
              skill.representation == "projection",
              !skill.symlinkedContainer,
              canonicalAgentPaths.contains(skill.canonicalPath)
        else { return nil }
        let url = URL(fileURLWithPath: skill.path)
        return isSymlink(url) && !hasSymlinkedAncestor(of: url, below: projectRoot) ? url : nil
    }
}

private func hasSymlinkedAncestor(of url: URL, below root: URL) -> Bool {
    let root = root.standardizedFileURL
    var ancestor = url.standardizedFileURL.deletingLastPathComponent()
    while ancestor.path != root.path {
        guard ancestor.path.hasPrefix(root.path + "/") else { return true }
        if isSymlink(ancestor) { return true }
        ancestor = ancestor.deletingLastPathComponent()
    }
    return false
}

func repairProjectProjection(
    _ project: SkillProject,
    apply: Bool,
    approvedCodexProjectionPaths: Set<String>? = nil
) throws -> [SkillsRepairLine] {
    let root = URL(fileURLWithPath: project.root)
    let canonicalSkills = root.appendingPathComponent(".agents").appendingPathComponent("skills")
    let claudeDirectory = root.appendingPathComponent(".claude")
    let claudeSkills = claudeDirectory.appendingPathComponent("skills")
    var lines: [SkillsRepairLine] = [
        .init(kind: .info, text: "valid local skills: \(project.validSkills.count)")
    ]

    let currentObsoleteCodexProjections = obsoleteCodexProjectionURLs(project)
    let currentPaths = Set(currentObsoleteCodexProjections.map(\.path))
    if let approvedCodexProjectionPaths {
        let missingPaths = approvedCodexProjectionPaths.subtracting(currentPaths)
        guard missingPaths.isEmpty else {
            throw NSError(domain: "MetagentSkillsRepair", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "cleanup changed after preview; review it again before applying"
            ])
        }
    }
    let obsoleteCodexProjections = approvedCodexProjectionPaths.map { approved in
        currentObsoleteCodexProjections.filter { approved.contains($0.path) }
    } ?? currentObsoleteCodexProjections
    func resolveObsoleteCodexProjections() throws {
        guard !obsoleteCodexProjections.isEmpty else { return }
        let projectRoot = URL(fileURLWithPath: project.root).standardizedFileURL
        let canonicalAgentPaths = Set(project.skills.lazy
            .filter { $0.location == "agents" }
            .map(\.canonicalPath))
        if apply {
            for url in obsoleteCodexProjections {
                guard isSymlink(url),
                      !hasSymlinkedAncestor(of: url, below: projectRoot),
                      canonicalAgentPaths.contains(canonicalProjectPath(url))
                else {
                    throw NSError(domain: "MetagentSkillsRepair", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "refusing to remove non-canonical projection at \(url.path)"
                    ])
                }
            }
            for url in obsoleteCodexProjections {
                try fileManager.removeItem(at: url)
            }
            lines.append(contentsOf: obsoleteCodexProjections.map {
                .init(kind: .action, text: "removed obsolete Codex link: \($0.path)")
            })
        } else {
            lines.append(contentsOf: obsoleteCodexProjections.map {
                .init(kind: .action, text: "would remove obsolete Codex link: \($0.path)")
            })
        }
    }

    if !project.hiddenSkillDirs.isEmpty {
        lines.append(.init(kind: .warning, text: "warning: \(project.hiddenSkillDirs.count) hidden skill dir(s) ignored"))
    }
    for invalid in project.invalidSkillDirs {
        lines.append(.init(kind: .warning, text: "warning: skipped invalid skill name: \(invalid)"))
    }
    if project.validSkills.isEmpty {
        lines.append(.init(kind: .info, text: "no valid SKILL.md folders yet"))
    }

    if canonicalProjectPath(root) == canonicalProjectPath(homeURL()) {
        try resolveObsoleteCodexProjections()
        return lines
    }

    if isSymlink(claudeDirectory) {
        lines.append(.init(
            kind: .skipped,
            text: "manual review: .claude is a symlink; refusing to modify its shared target"
        ))
        try resolveObsoleteCodexProjections()
        return lines
    }

    if isSymlink(claudeSkills), symlink(claudeSkills, resolvesTo: canonicalSkills) {
        lines.append(.init(kind: .info, text: "healthy: .claude/skills -> ../.agents/skills"))
        try resolveObsoleteCodexProjections()
        return lines
    }
    if fileManager.fileExists(atPath: claudeSkills.path), !isSymlink(claudeSkills) {
        lines.append(.init(
            kind: .skipped,
            text: "manual review: .claude/skills exists and is not a symlink"
        ))
        try resolveObsoleteCodexProjections()
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

    try resolveObsoleteCodexProjections()
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
