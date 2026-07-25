import Foundation
import Darwin
import ImageIO
import SQLite3

struct SkillsCLIManagedRemoval {
    let skillName: String
    let skillURL: URL
    let recovery: URL
    let projections: [SkillInventoryItem]
    let retainedBackups: [(original: URL, backup: URL)]
}

struct CodexPluginList: Decodable {
    var installed: [CodexPlugin]
}

struct CodexPlugin: Decodable {
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
        if options.roots.isEmpty {
            try appendHomeProjectIfMissing(&projects)
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
        if options.scanOptions.roots.isEmpty {
            try appendHomeProjectIfMissing(&inventoryProjects)
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

    /// Adds the home inventory project when a default-roots scan did not
    /// already discover it.
    private static func appendHomeProjectIfMissing(_ projects: inout [SkillProject]) throws {
        let canonicalHome = canonicalProjectPath(homeURL())
        if let homeProject = try scanHomeSkills(maxDepth: 0).projects.first(where: {
               canonicalProjectPath(URL(fileURLWithPath: $0.root)) == canonicalHome
           }),
           !projects.contains(where: {
               canonicalProjectPath(URL(fileURLWithPath: $0.root)) == canonicalHome
           })
        {
            projects.append(homeProject)
        }
    }

    public static func saveInventorySnapshot(_ report: SkillScanReport) {
        try? SkillInventoryCache().save(report)
    }

    public static func loadInventorySnapshot() -> SkillScanReport? {
        try? SkillInventoryCache().load()
    }

    static func planSkillRemoval(projectRoot: String, skillName: String) throws -> SkillRemovalPlan {
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

    /// Removal mechanism: one canonical `.agents` bundle, through its owning
    /// package manager when it has one. Reached through `removeSkills`.
    static func uninstallSkill(
        projectRoot: String,
        skillName: String,
        allowManagedRemoval: Bool = false
    ) throws -> SkillUninstallReport {
        guard isValidSkillName(skillName) else {
            throw NSError(domain: "MetagentSkillUninstall", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "invalid skill name: \(skillName)"
            ])
        }
        let requestedRoot = URL(fileURLWithPath: projectRoot)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let expectedSkillURL = requestedRoot
            .appendingPathComponent(".agents")
            .appendingPathComponent("skills")
            .appendingPathComponent(skillName)
        if allowManagedRemoval,
           canonicalProjectPath(requestedRoot) != canonicalProjectPath(homeURL()),
           !fileManager.fileExists(atPath: expectedSkillURL.path),
           try readProjectSkillLocksValidated(root: requestedRoot)[skillName] != nil
        {
            let recovery = try prepareRemovalRecovery(
                projectRoot: requestedRoot,
                skillName: skillName
            )
            let movedProjections = try moveDanglingSkillProjections(
                projectRoot: requestedRoot,
                skillURL: expectedSkillURL,
                skillName: skillName,
                recovery: recovery
            )
            do {
                let removedNames = try removeProjectSkillLockEntries(
                    root: requestedRoot,
                    skillNames: [skillName]
                )
                guard removedNames.contains(skillName),
                      try readProjectSkillLocksValidated(root: requestedRoot)[skillName] == nil
                else {
                    throw NSError(domain: "MetagentSkillUninstall", code: 8, userInfo: [
                        NSLocalizedDescriptionKey: "Could not reconcile the stale Skills CLI lock entry for \(skillName). Recovery state: \(recovery.path)"
                    ])
                }
            } catch {
                let rollbackFailures = rollbackMovedSkillProjections(movedProjections)
                let rollbackSuffix = rollbackFailures.isEmpty
                    ? ""
                    : "\nProjection rollback failures:\n\(rollbackFailures.joined(separator: "\n"))"
                throw NSError(domain: "MetagentSkillUninstall", code: 8, userInfo: [
                    NSLocalizedDescriptionKey: "\(error.localizedDescription)\(rollbackSuffix)"
                ])
            }
            var lines = [
                "saved recovery state to \(recovery.path)",
                "removed a stale project lock entry for an already-absent Skills CLI bundle",
            ]
            if !movedProjections.isEmpty {
                lines.append("removed \(movedProjections.count) dangling per-skill projection link(s)")
            }
            lines.append(finalizeRemovalRecovery(
                recovery,
                projectRoot: requestedRoot,
                skillName: skillName
            ))
            return SkillUninstallReport(
                projectRoot: requestedRoot.path,
                skillName: skillName,
                backupPath: recovery.path,
                lines: lines
            )
        }

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
        let (projections, retained) = partitionSameNameSkills(
            in: project,
            skillName: skillName,
            canonicalSkillURL: skillURL
        )
        let recovery = try prepareRemovalRecovery(
            projectRoot: root,
            skillName: skillName
        )
        let backupPath: String? = recovery.path

        let recoveredSkill = recovery.appendingPathComponent(skillName)
        if ["skills-cli", "dotagents"].contains(agentsSkill.manager) {
            let isPathBackedDotagentsSkill = agentsSkill.manager == "dotagents"
                && dotagentsPathSource(
                    agentsSkill.source,
                    projectRoot: root,
                    resolvesTo: skillURL
                )
            try fileManager.copyItem(at: skillURL, to: recoveredSkill)
            let retainedBackups = try snapshotRetainedSkills(
                retained,
                into: recovery,
                skillName: skillName
            )
            lines = managedRemovalIntroLines(
                recovery: recovery,
                skillName: skillName,
                retainedBackupCount: retainedBackups.count
            )
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
            var managerEntryRemains = agentsSkill.manager == "skills-cli"
                ? readProjectSkillLocks(root: root)[skillName] != nil
                : readDotagentsSkills(root: root)[skillName] != nil
            if agentsSkill.manager == "skills-cli",
               canonicalProjectPath(root) != canonicalProjectPath(homeURL()),
               !fileManager.fileExists(atPath: skillURL.path),
               managerEntryRemains
            {
                do {
                    let removedNames = try removeProjectSkillLockEntries(
                        root: root,
                        skillNames: [skillName]
                    )
                    if removedNames.contains(skillName) {
                        lines.append("removed a stale project lock entry left by skills-cli")
                    }
                    managerEntryRemains = try readProjectSkillLocksValidated(root: root)[skillName] != nil
                } catch {
                    throw NSError(domain: "MetagentSkillUninstall", code: 8, userInfo: [
                        NSLocalizedDescriptionKey: "Skills CLI removed the bundle, but Metagent could not reconcile its stale project lock entry: \(error.localizedDescription)\nRecovery state: \(recovery.path)"
                    ])
                }
            }
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
            restoreRetainedSkillBackups(retainedBackups, lines: &lines)
            finishManagedSkillRemoval(
                manager: agentsSkill.manager,
                projections: projections,
                recovery: recovery,
                projectRoot: root,
                skillName: skillName,
                lines: &lines
            )
            return SkillUninstallReport(
                projectRoot: root.path,
                skillName: skillName,
                backupPath: backupPath,
                lines: lines
            )
        }

        lines.append("saved recovery state to \(recovery.path)")
        try moveSkillAndProjectionsToRecovery(
            skill: skillURL,
            to: recoveredSkill,
            projections: projections,
            recovery: recovery,
            skillName: skillName,
            rollbackErrorCode: 6,
            rollbackFailureSummary: "local uninstall failed and rollback was incomplete."
        )
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

    /// Removal mechanism: several canonical bundles in one root, keeping a
    /// single `skills` CLI invocation for the managed ones.
    static func uninstallSkills(
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
                return SkillUninstallFailure(
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
                let (projections, retained) = partitionSameNameSkills(
                    in: project,
                    skillName: skillName,
                    canonicalSkillURL: skillURL
                )
                let recovery = try prepareRemovalRecovery(projectRoot: root, skillName: skillName)
                try fileManager.copyItem(at: skillURL, to: recovery.appendingPathComponent(skillName))

                let retainedBackups = try snapshotRetainedSkills(
                    retained,
                    into: recovery,
                    skillName: skillName
                )
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

        var reconciledProjectLockNames = Set<String>()
        if commandError == nil,
           canonicalProjectPath(root) != canonicalProjectPath(homeURL())
        {
            do {
                let locks = try readProjectSkillLocksValidated(root: root)
                let staleNames: [String] = removals.compactMap { removal in
                    guard !fileManager.fileExists(atPath: removal.skillURL.path),
                          locks[removal.skillName] != nil
                    else { return nil }
                    return removal.skillName
                }
                if !staleNames.isEmpty {
                    reconciledProjectLockNames = try removeProjectSkillLockEntries(
                        root: root,
                        skillNames: staleNames
                    )
                }
            } catch {
                failures += removals.map { removal in
                    let changedOnDisk = !fileManager.fileExists(atPath: removal.skillURL.path)
                    return SkillUninstallFailure(
                        skillName: removal.skillName,
                        message: [
                            changedOnDisk
                                ? "Skills CLI removed the bundle, but Metagent could not reconcile its stale project lock entry: \(error.localizedDescription)"
                                : "Skills CLI returned success, but Metagent could not verify its lock state and the bundle remains: \(error.localizedDescription)",
                            "Recovery state: \(removal.recovery.path)",
                            changedOnDisk
                                ? finalizeRemovalRecovery(
                                    removal.recovery,
                                    projectRoot: root,
                                    skillName: removal.skillName
                                )
                                : nil,
                        ].compactMap { $0 }.joined(separator: "\n"),
                        needsReconciliation: changedOnDisk
                    )
                }
                return SkillUninstallBatchReport(reports: [], failures: failures)
            }
        }

        let remainingLocks: [String: SkillLockEntry]
        do {
            remainingLocks = try readProjectSkillLocksValidated(root: root)
        } catch {
            failures += removals.map { removal in
                let changedOnDisk = !fileManager.fileExists(atPath: removal.skillURL.path)
                let snapshotLine = changedOnDisk
                    ? finalizeRemovalRecovery(
                        removal.recovery,
                        projectRoot: root,
                        skillName: removal.skillName
                    )
                    : nil
                return SkillUninstallFailure(
                    skillName: removal.skillName,
                    message: [
                        error.localizedDescription,
                        "Recovery state: \(removal.recovery.path)",
                        snapshotLine,
                    ].compactMap { $0 }.joined(separator: "\n"),
                    needsReconciliation: changedOnDisk
                )
            }
            return SkillUninstallBatchReport(reports: [], failures: failures)
        }
        var reports: [SkillUninstallReport] = []
        for removal in removals {
            guard !fileManager.fileExists(atPath: removal.skillURL.path),
                  remainingLocks[removal.skillName] == nil
            else {
                let reason = commandError?.localizedDescription
                    ?? "skills-cli reported success but the bundle or its lock entry remains."
                failures.append(SkillUninstallFailure(
                    skillName: removal.skillName,
                    message: "\(reason)\nRecovery state: \(removal.recovery.path)"
                ))
                continue
            }

            var lines = managedRemovalIntroLines(
                recovery: removal.recovery,
                skillName: removal.skillName,
                retainedBackupCount: removal.retainedBackups.count
            )
            restoreRetainedSkillBackups(removal.retainedBackups, lines: &lines)
            if reconciledProjectLockNames.contains(removal.skillName) {
                lines.append("removed a stale project lock entry left by skills-cli")
            }

            finishManagedSkillRemoval(
                manager: "skills-cli",
                projections: removal.projections,
                recovery: removal.recovery,
                projectRoot: root,
                skillName: removal.skillName,
                lines: &lines
            )
            reports.append(SkillUninstallReport(
                projectRoot: root.path,
                skillName: removal.skillName,
                backupPath: removal.recovery.path,
                lines: lines
            ))
        }
        return SkillUninstallBatchReport(reports: reports, failures: failures)
    }

    /// Removal mechanism: a standalone `.codex`/`.claude` bundle moved into the
    /// recovery folder.
    static func uninstallStandaloneSkill(
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
        try moveSkillAndProjectionsToRecovery(
            skill: skill,
            to: recoveredSkill,
            projections: projections,
            recovery: recovery,
            skillName: skillName,
            rollbackErrorCode: 10,
            rollbackFailureSummary: "standalone removal failed and projection rollback was incomplete."
        )
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

    static func canUninstallStandaloneSkill(
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

    /// Removal mechanism: `codex plugin remove`, verified against the installed
    /// plugin list.
    static func uninstallCodexPlugin(pluginID: String) throws -> SkillUninstallReport {
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
        let combined = combinedSubprocessOutput(result)
        try requireSubprocessSuccess(
            result,
            output: combined,
            domain: "MetagentCodexPlugins",
            timeoutCode: 124,
            timeoutMessage: "Codex plugin removal timed out after 120 seconds",
            failureMessage: "Codex plugin removal failed"
        )
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
