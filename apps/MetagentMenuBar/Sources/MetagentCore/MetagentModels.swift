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
    public var scriptInventory: SkillScriptInventory?

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
        iconLargePath: String?,
        scriptInventory: SkillScriptInventory? = nil
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
        self.scriptInventory = scriptInventory
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
        case scriptInventory = "script_inventory"
    }
}

public struct DoctorReport: Codable, Equatable, Sendable {
    public var issues: [DoctorIssue]
    /// Logical skill bundles, deduplicated by canonical path.
    public var canonicalSkillCount: Int
    /// Every discovered copy, including projections.
    public var representationCount: Int
    public var projectionCount: Int

    public var warningCount: Int {
        issues.filter { $0.severity == .warning }.count
    }

    public var failureCount: Int {
        issues.filter { $0.severity == .failure }.count
    }

    public init(
        issues: [DoctorIssue],
        canonicalSkillCount: Int = 0,
        representationCount: Int = 0,
        projectionCount: Int = 0
    ) {
        self.issues = issues
        self.canonicalSkillCount = canonicalSkillCount
        self.representationCount = representationCount
        self.projectionCount = projectionCount
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
    public let needsReconciliation: Bool

    public init(skillName: String, message: String, needsReconciliation: Bool = false) {
        self.skillName = skillName
        self.message = message
        self.needsReconciliation = needsReconciliation
    }
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
    public var method: SkillRemovalTarget.Method
    public var targetID: String?

    public init(
        projectRoot: String,
        skillName: String,
        manager: String,
        mutability: String,
        command: String?,
        applySupported: Bool,
        method: SkillRemovalTarget.Method = .canonical,
        targetID: String? = nil
    ) {
        self.projectRoot = projectRoot
        self.skillName = skillName
        self.manager = manager
        self.mutability = mutability
        self.command = command
        self.applySupported = applySupported
        self.method = method
        self.targetID = targetID
    }
}

/// A single removable unit of skill inventory, resolved once in core so every
/// surface routes removal through the same decision.
public struct SkillRemovalTarget: Sendable, Codable, Identifiable, Hashable {
    public enum Method: String, Sendable, Codable {
        case canonical
        case standalone
        case codexPlugin
    }

    public let id: String
    public let displayName: String
    public let method: Method
    public let projectRoot: String?
    public let skillName: String?
    public let skillPath: String?
    public let pluginID: String?

    public init(
        id: String,
        displayName: String,
        method: Method,
        projectRoot: String? = nil,
        skillName: String? = nil,
        skillPath: String? = nil,
        pluginID: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.method = method
        self.projectRoot = projectRoot
        self.skillName = skillName
        self.skillPath = skillPath
        self.pluginID = pluginID
    }

    public static func canonical(projectRoot: String, skillName: String) -> SkillRemovalTarget {
        SkillRemovalTarget(
            id: "canonical:\(projectRoot):\(skillName)",
            displayName: skillName,
            method: .canonical,
            projectRoot: projectRoot,
            skillName: skillName
        )
    }

    public static func standalone(
        projectRoot: String,
        skillPath: String,
        skillName: String
    ) -> SkillRemovalTarget {
        SkillRemovalTarget(
            id: "standalone:\(skillPath)",
            displayName: skillName,
            method: .standalone,
            projectRoot: projectRoot,
            skillName: skillName,
            skillPath: skillPath
        )
    }

    public static func codexPlugin(pluginID: String) -> SkillRemovalTarget {
        SkillRemovalTarget(
            id: "plugin:\(pluginID)",
            displayName: "\(pluginID) plugin",
            method: .codexPlugin,
            pluginID: pluginID
        )
    }
}

public struct SkillRemovalTargetOutcome: Codable, Equatable, Sendable, Identifiable {
    public var id: String { target.id }
    public let target: SkillRemovalTarget
    public let plan: SkillRemovalPlan?
    public let succeeded: Bool
    public let needsReconciliation: Bool
    public let lines: [String]
    public let backupPath: String?
    public let failureMessage: String?
    public let report: SkillUninstallReport?

    public init(
        target: SkillRemovalTarget,
        plan: SkillRemovalPlan? = nil,
        succeeded: Bool,
        needsReconciliation: Bool = false,
        lines: [String] = [],
        backupPath: String? = nil,
        failureMessage: String? = nil,
        report: SkillUninstallReport? = nil
    ) {
        self.target = target
        self.plan = plan
        self.succeeded = succeeded
        self.needsReconciliation = needsReconciliation
        self.lines = lines
        self.backupPath = backupPath
        self.failureMessage = failureMessage
        self.report = report
    }
}

public struct SkillRemovalBatchReport: Codable, Equatable, Sendable {
    public let apply: Bool
    public let outcomes: [SkillRemovalTargetOutcome]

    public init(apply: Bool, outcomes: [SkillRemovalTargetOutcome]) {
        self.apply = apply
        self.outcomes = outcomes
    }

    public var succeededIDs: Set<String> {
        Set(outcomes.filter(\.succeeded).map(\.id))
    }

    public var failedIDs: Set<String> {
        Set(outcomes.filter { !$0.succeeded }.map(\.id))
    }

    public var reconciliationIDs: Set<String> {
        Set(outcomes.filter(\.needsReconciliation).map(\.id))
    }

    public var reports: [SkillUninstallReport] {
        outcomes.compactMap(\.report)
    }

    public var failures: [SkillUninstallFailure] {
        outcomes.compactMap { outcome in
            guard !outcome.succeeded else { return nil }
            return SkillUninstallFailure(
                skillName: outcome.target.skillName ?? outcome.target.displayName,
                message: outcome.failureMessage ?? "removal did not report a result",
                needsReconciliation: outcome.needsReconciliation
            )
        }
    }

    public var uninstallBatchReport: SkillUninstallBatchReport {
        SkillUninstallBatchReport(reports: reports, failures: failures)
    }

    /// Report text in the order the removals were performed.
    public var lines: [String] {
        outcomes.flatMap { outcome -> [String] in
            guard outcome.succeeded else {
                return [
                    "\(outcome.target.displayName): failed",
                    "  \(outcome.failureMessage ?? "removal did not report a result")",
                ]
            }
            return ["\(outcome.target.displayName):"] + outcome.lines.map { "  \($0)" }
        }
    }
}
