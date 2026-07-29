import Foundation
import Darwin
import ImageIO
import SQLite3

extension MetagentCore {

    /// Routes one inventory row to the removal path that owns it. Canonical
    /// `.agents` ownership wins, then Codex plugins, then standalone bundles.
    public static func resolveSkillRemovalTarget(
        projectRoot: String,
        skill: SkillInventoryItem,
        variants: [SkillInventoryItem]
    ) -> SkillRemovalTarget? {
        if let agentsVariant = variants.first(where: { $0.location == "agents" }),
           agentsVariant.representation == "canonical",
           ["local", "dotagents", "skills-cli"].contains(agentsVariant.manager)
        {
            return .canonical(projectRoot: projectRoot, skillName: agentsVariant.name)
        }
        if skill.manager == "codex-plugin", skill.authority.contains("@") {
            return .codexPlugin(pluginID: skill.authority)
        }
        if let standaloneVariant = variants.first(where: { variant in
            ["codex", "claude"].contains(variant.manager)
                && variant.representation == "canonical"
                && canUninstallStandaloneSkill(
                    projectRoot: projectRoot,
                    skillPath: variant.path,
                    skillName: variant.name
                )
        }) {
            return .standalone(
                projectRoot: projectRoot,
                skillPath: standaloneVariant.path,
                skillName: standaloneVariant.name
            )
        }
        return nil
    }

    public static func resolveSkillRemovalTarget(
        in project: SkillProject,
        skillName: String
    ) -> SkillRemovalTarget? {
        let variants = project.skills
            .filter { $0.name == skillName }
            .sorted(by: skillRemovalVariantOrder)
        guard let skill = variants.first else { return nil }
        return resolveSkillRemovalTarget(
            projectRoot: project.root,
            skill: skill,
            variants: variants
        )
    }

    public static func resolveSkillRemovalTarget(
        in scan: SkillScanReport,
        projectRoot: String,
        skillName: String
    ) -> SkillRemovalTarget? {
        let wanted = canonicalProjectPath(URL(fileURLWithPath: projectRoot))
        guard let project = scan.projects.first(where: {
            canonicalProjectPath(URL(fileURLWithPath: $0.root)) == wanted
        }) else { return nil }
        return resolveSkillRemovalTarget(in: project, skillName: skillName)
    }

    /// Resolves a target by scanning `projectRoot` itself, for surfaces that do
    /// not already hold an inventory scan.
    public static func resolveSkillRemovalTarget(
        projectRoot: String,
        skillName: String
    ) throws -> SkillRemovalTarget? {
        let root = URL(fileURLWithPath: projectRoot).resolvingSymlinksInPath().standardizedFileURL
        return resolveSkillRemovalTarget(in: try readProjectSkills(root: root), skillName: skillName)
    }

    /// Read-only plan for a resolved target, including the owning manager and
    /// the package-manager command when one applies.
    static func planSkillRemoval(for target: SkillRemovalTarget) throws -> SkillRemovalPlan {
        switch target.method {
        case .canonical:
            guard let projectRoot = target.projectRoot, let skillName = target.skillName else {
                throw incompleteRemovalTargetError(target)
            }
            var plan = try planSkillRemoval(projectRoot: projectRoot, skillName: skillName)
            plan.method = .canonical
            plan.targetID = target.id
            return plan
        case .standalone:
            guard let projectRoot = target.projectRoot,
                  let skillPath = target.skillPath,
                  let skillName = target.skillName
            else { throw incompleteRemovalTargetError(target) }
            let root = URL(fileURLWithPath: projectRoot).standardizedFileURL
            let item = (try? readProjectSkills(root: root))?.skills.first { $0.path == skillPath }
            return SkillRemovalPlan(
                projectRoot: projectRoot,
                skillName: skillName,
                manager: item?.manager ?? "unknown",
                mutability: item?.mutability ?? "unknown",
                command: nil,
                applySupported: canUninstallStandaloneSkill(
                    projectRoot: projectRoot,
                    skillPath: skillPath,
                    skillName: skillName
                ),
                method: .standalone,
                targetID: target.id
            )
        case .codexPlugin:
            guard let pluginID = target.pluginID else { throw incompleteRemovalTargetError(target) }
            return SkillRemovalPlan(
                projectRoot: "codex-plugin",
                skillName: pluginID,
                manager: "codex-plugin",
                mutability: "managed-read-only",
                command: "codex plugin remove \(pluginID)",
                applySupported: pluginID.contains("@"),
                method: .codexPlugin,
                targetID: target.id
            )
        }
    }

    /// The single removal entrance. `apply` defaults to a dry run: nothing is
    /// mutated and each target reports the plan that would run.
    /// Set `allowManagedRemoval` to false to refuse skills owned by a package
    /// manager instead of removing them through that manager.
    public static func removeSkills(
        targets: [SkillRemovalTarget],
        apply: Bool = false,
        allowManagedRemoval: Bool = true
    ) -> SkillRemovalBatchReport {
        var seen = Set<String>()
        let unique = targets.filter { seen.insert($0.id).inserted }
        guard !unique.isEmpty else {
            return SkillRemovalBatchReport(apply: apply, outcomes: [])
        }
        guard apply else {
            return SkillRemovalBatchReport(
                apply: false,
                outcomes: unique.map(previewSkillRemoval)
            )
        }

        var outcomes: [SkillRemovalTargetOutcome] = []
        let canonicalTargets = unique.filter { $0.method == .canonical }
        let groups = Dictionary(grouping: canonicalTargets) { $0.projectRoot ?? "" }
        for projectRoot in groups.keys.sorted() {
            outcomes += applyCanonicalSkillRemovals(
                projectRoot: projectRoot,
                targets: groups[projectRoot] ?? [],
                allowManagedRemoval: allowManagedRemoval
            )
        }
        for target in unique where target.method != .canonical {
            outcomes.append(applyStandaloneOrPluginRemoval(target))
        }
        return SkillRemovalBatchReport(apply: true, outcomes: outcomes)
    }

    private static func previewSkillRemoval(_ target: SkillRemovalTarget) -> SkillRemovalTargetOutcome {
        do {
            let plan = try planSkillRemoval(for: target)
            var lines = [
                "would remove \(target.displayName) through the \(plan.method.rawValue) path managed by \(plan.manager)"
            ]
            if let command = plan.command {
                lines.append("manager command: \(command)")
            }
            if !plan.applySupported {
                lines.append("Metagent will not apply this removal; remove it through its owner")
            }
            return SkillRemovalTargetOutcome(
                target: target,
                plan: plan,
                succeeded: plan.applySupported,
                lines: lines,
                failureMessage: plan.applySupported
                    ? nil
                    : "\(target.displayName) cannot be removed by Metagent; it is managed by \(plan.manager)."
            )
        } catch {
            return SkillRemovalTargetOutcome(
                target: target,
                succeeded: false,
                failureMessage: error.localizedDescription
            )
        }
    }

    /// Canonical targets in one root go through the batch path so a multi-skill
    /// removal keeps its single `skills` CLI invocation.
    private static func applyCanonicalSkillRemovals(
        projectRoot: String,
        targets: [SkillRemovalTarget],
        allowManagedRemoval: Bool
    ) -> [SkillRemovalTargetOutcome] {
        var outcomes: [SkillRemovalTargetOutcome] = []
        let resolvable = targets.filter { $0.skillName != nil && !projectRoot.isEmpty }
        outcomes += targets.filter { $0.skillName == nil || projectRoot.isEmpty }.map {
            SkillRemovalTargetOutcome(
                target: $0,
                succeeded: false,
                failureMessage: incompleteRemovalTargetError($0).localizedDescription
            )
        }
        guard !resolvable.isEmpty else { return outcomes }

        let batch = uninstallSkills(
            projectRoot: projectRoot,
            skillNames: resolvable.compactMap(\.skillName),
            allowManagedRemoval: allowManagedRemoval
        )
        var handled = Set<String>()
        for report in batch.reports {
            guard let target = resolvable.first(where: { $0.skillName == report.skillName }) else { continue }
            handled.insert(target.id)
            outcomes.append(SkillRemovalTargetOutcome(
                target: target,
                succeeded: true,
                lines: report.lines,
                backupPath: report.backupPath,
                report: report
            ))
        }
        for failure in batch.failures {
            guard let target = resolvable.first(where: { $0.skillName == failure.skillName }),
                  !handled.contains(target.id)
            else { continue }
            handled.insert(target.id)
            outcomes.append(SkillRemovalTargetOutcome(
                target: target,
                succeeded: false,
                needsReconciliation: failure.needsReconciliation,
                failureMessage: failure.message
            ))
        }
        outcomes += resolvable.filter { !handled.contains($0.id) }.map {
            SkillRemovalTargetOutcome(
                target: $0,
                succeeded: false,
                failureMessage: "removal did not report a result for \($0.displayName)"
            )
        }
        return outcomes
    }

    private static func applyStandaloneOrPluginRemoval(
        _ target: SkillRemovalTarget
    ) -> SkillRemovalTargetOutcome {
        do {
            let report: SkillUninstallReport
            switch target.method {
            case .canonical:
                throw incompleteRemovalTargetError(target)
            case .standalone:
                guard let projectRoot = target.projectRoot,
                      let skillPath = target.skillPath,
                      let skillName = target.skillName
                else { throw incompleteRemovalTargetError(target) }
                report = try uninstallStandaloneSkill(
                    projectRoot: projectRoot,
                    skillPath: skillPath,
                    skillName: skillName
                )
            case .codexPlugin:
                guard let pluginID = target.pluginID else { throw incompleteRemovalTargetError(target) }
                report = try uninstallCodexPlugin(pluginID: pluginID)
            }
            return SkillRemovalTargetOutcome(
                target: target,
                succeeded: true,
                lines: report.lines,
                backupPath: report.backupPath,
                report: report
            )
        } catch {
            return SkillRemovalTargetOutcome(
                target: target,
                succeeded: false,
                failureMessage: error.localizedDescription
            )
        }
    }

    private static func incompleteRemovalTargetError(_ target: SkillRemovalTarget) -> NSError {
        NSError(domain: "MetagentSkillUninstall", code: 13, userInfo: [
            NSLocalizedDescriptionKey: "incomplete \(target.method.rawValue) removal target: \(target.id)"
        ])
    }
}

/// Same ordering the inventory table uses to pick the primary variant of a
/// skill: canonical copies first, then `.agents`, `.codex`, `.claude`.
func skillRemovalVariantOrder(_ left: SkillInventoryItem, _ right: SkillInventoryItem) -> Bool {
    let leftRepresentationPriority = left.representation == "canonical" ? 0 : 1
    let rightRepresentationPriority = right.representation == "canonical" ? 0 : 1
    if leftRepresentationPriority != rightRepresentationPriority {
        return leftRepresentationPriority < rightRepresentationPriority
    }
    let priority = ["agents": 0, "codex": 1, "claude": 2]
    let leftPriority = priority[left.location, default: 3]
    let rightPriority = priority[right.location, default: 3]
    if leftPriority != rightPriority {
        return leftPriority < rightPriority
    }
    return left.path < right.path
}

func projectRoot(for skillsDirectory: URL) -> URL {
    skillsDirectory
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

func readProjectSkillLocks(root: URL) -> [String: SkillLockEntry] {
    readSkillLock(projectSkillLockPath(root))
}

func readProjectSkillLocksValidated(root: URL) throws -> [String: SkillLockEntry] {
    let path = projectSkillLockPath(root)
    guard fileManager.fileExists(atPath: path.path) else { return [:] }
    do {
        let data = try Data(contentsOf: path)
        return try JSONDecoder().decode(SkillLock.self, from: data).skills
    } catch {
        throw NSError(domain: "MetagentSkillsCLI", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Could not verify Skills CLI lock state at \(path.path): \(error.localizedDescription)"
        ])
    }
}

func projectSkillLockPath(_ root: URL) -> URL {
    if canonicalProjectPath(root) == canonicalProjectPath(homeURL()) {
        return globalSkillLockPath()
    }
    return root.appendingPathComponent("skills-lock.json")
}

func removeProjectSkillLockEntries(
    root: URL,
    skillNames: [String]
) throws -> Set<String> {
    let path = projectSkillLockPath(root)
    let data = try Data(contentsOf: path)
    guard var document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          var skills = document["skills"] as? [String: Any]
    else {
        throw NSError(domain: "MetagentSkillsCLI", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "Unexpected Skills CLI lock structure at \(path.path)"
        ])
    }

    var removedNames = Set<String>()
    for skillName in skillNames where skills.removeValue(forKey: skillName) != nil {
        removedNames.insert(skillName)
    }
    guard !removedNames.isEmpty else { return [] }

    document["skills"] = skills
    var output = try JSONSerialization.data(
        withJSONObject: document,
        options: [.prettyPrinted, .sortedKeys]
    )
    output.append(0x0A)
    try output.write(to: path, options: .atomic)
    return removedNames
}

func moveDanglingSkillProjections(
    projectRoot: URL,
    skillURL: URL,
    skillName: String,
    recovery: URL
) throws -> [(original: URL, recovery: URL)] {
    let candidates = [
        ("codex", projectRoot.appendingPathComponent(".codex").appendingPathComponent("skills")),
        ("claude", projectRoot.appendingPathComponent(".claude").appendingPathComponent("skills")),
    ]
    var moved: [(original: URL, recovery: URL)] = []
    do {
        for (index, candidate) in candidates.enumerated() {
            let (location, container) = candidate
            guard !isSymlink(container),
                  !isSymlink(container.deletingLastPathComponent()),
                  container.resolvingSymlinksInPath().standardizedFileURL.path == container.standardizedFileURL.path
            else { continue }
            let projectionURL = container.appendingPathComponent(skillName)
            guard isSymlink(projectionURL),
                  symlink(projectionURL, resolvesTo: skillURL)
            else { continue }
            let destination = recovery
                .appendingPathComponent("projections")
                .appendingPathComponent("\(index)-\(location)")
                .appendingPathComponent(skillName)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: projectionURL, to: destination)
            moved.append((projectionURL, destination))
        }
    } catch {
        let rollbackFailures = rollbackMovedSkillProjections(moved)
        guard rollbackFailures.isEmpty else {
            throw NSError(domain: "MetagentSkillUninstall", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "Projection cleanup failed and rollback was incomplete. Original error: \(error.localizedDescription)\nRollback failures:\n\(rollbackFailures.joined(separator: "\n"))\nRecovery state: \(recovery.path)"
            ])
        }
        throw NSError(domain: "MetagentSkillUninstall", code: 6, userInfo: [
            NSLocalizedDescriptionKey: "Projection cleanup failed: \(error.localizedDescription)\nRecovery state: \(recovery.path)"
        ])
    }
    return moved
}

func rollbackMovedSkillProjections(
    _ moved: [(original: URL, recovery: URL)]
) -> [String] {
    var failures: [String] = []
    for projection in moved.reversed() {
        do {
            try fileManager.createDirectory(
                at: projection.original.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: projection.recovery, to: projection.original)
        } catch {
            failures.append("\(projection.original.path): \(error.localizedDescription)")
        }
    }
    return failures
}

func globalSkillLockPath() -> URL {
    if let xdgStateHome = ProcessInfo.processInfo.environment["XDG_STATE_HOME"], !xdgStateHome.isEmpty {
        return URL(fileURLWithPath: xdgStateHome)
            .appendingPathComponent("skills")
            .appendingPathComponent(".skill-lock.json")
    }
    return homeURL().appendingPathComponent(".agents").appendingPathComponent(".skill-lock.json")
}

func skillsCLIRemovalCommand(root: URL, skillName: String) -> String {
    let globalFlag = canonicalProjectPath(root) == canonicalProjectPath(homeURL()) ? " --global" : ""
    return "npx --yes skills remove \(skillName) --yes\(globalFlag)"
}

func dotagentsRemovalCommand(root: URL, skillName: String) -> String {
    let userFlag = canonicalProjectPath(root) == canonicalProjectPath(homeURL()) ? " --user" : ""
    return "npx --yes @sentry/dotagents\(userFlag) remove \(skillName) --yes"
}

func runSkillsCLIRemoval(root: URL, skillName: String) throws -> String {
    try runSkillsCLIRemoval(root: root, skillNames: [skillName])
}

func runSkillsCLIRemoval(root: URL, skillNames: [String]) throws -> String {
    let arguments = ["--yes", "skills", "remove"] + skillNames + ["--yes"]
        + (canonicalProjectPath(root) == canonicalProjectPath(homeURL()) ? ["--global"] : [])
    let result = try runSubprocess(
        executable: try npxExecutable(),
        arguments: arguments,
        currentDirectory: root,
        timeout: 120
    )
    let combined = combinedSubprocessOutput(result)
    try requireSubprocessSuccess(
        result,
        output: combined,
        domain: "MetagentSkillsCLI",
        timeoutCode: 124,
        timeoutMessage: combined.isEmpty
            ? "npx skills remove timed out after 120 seconds"
            : "npx skills remove timed out after 120 seconds:\n\(combined)",
        failureMessage: "npx skills remove failed"
    )
    return combined
}

func runDotagentsRemoval(root: URL, skillName: String) throws -> String {
    let arguments = ["--yes", "@sentry/dotagents"]
        + (canonicalProjectPath(root) == canonicalProjectPath(homeURL()) ? ["--user"] : [])
        + ["remove", skillName, "--yes"]
    let result = try runSubprocess(
        executable: try npxExecutable(),
        arguments: arguments,
        currentDirectory: root,
        timeout: 120
    )
    let combined = combinedSubprocessOutput(result)
    try requireSubprocessSuccess(
        result,
        output: combined,
        domain: "MetagentDotagents",
        timeoutCode: 124,
        timeoutMessage: combined.isEmpty
            ? "dotagents remove timed out after 120 seconds"
            : "dotagents remove timed out after 120 seconds:\n\(combined)",
        failureMessage: "dotagents remove failed"
    )
    return combined
}

func standaloneSkillRemovalTarget(
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

/// Splits the non-canonical same-name inventory copies into per-skill
/// projection links that resolve to the canonical bundle and independent
/// retained locations that do not.
func partitionSameNameSkills(
    in project: SkillProject,
    skillName: String,
    canonicalSkillURL skillURL: URL
) -> (projections: [SkillInventoryItem], retained: [SkillInventoryItem]) {
    var projections: [SkillInventoryItem] = []
    var retained: [SkillInventoryItem] = []
    for candidate in project.skills {
        guard candidate.name == skillName,
              candidate.location != "agents",
              !candidate.symlinkedContainer
        else { continue }
        let url = URL(fileURLWithPath: candidate.path)
        if isSymlink(url), symlink(url, resolvesTo: skillURL) {
            projections.append(candidate)
        } else {
            retained.append(candidate)
        }
    }
    return (projections, retained)
}

/// Opening report lines shared by every managed (skills-cli/dotagents) removal.
func managedRemovalIntroLines(
    recovery: URL,
    skillName: String,
    retainedBackupCount: Int
) -> [String] {
    var lines = [
        "saved recovery state to \(recovery.path)",
        "copied managed skill into recovery: \(recovery.appendingPathComponent(skillName).path)"
    ]
    if retainedBackupCount > 0 {
        lines.append("snapshotted \(retainedBackupCount) independent same-name location(s)")
    }
    return lines
}

/// Puts back independent same-name copies that a manager removal deleted
/// alongside the canonical bundle, reporting per-location failures as
/// warnings rather than errors.
func restoreRetainedSkillBackups(
    _ retainedBackups: [(original: URL, backup: URL)],
    lines: inout [String]
) {
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
}

/// Moves the dangling per-skill projection links of a verified managed removal
/// into recovery and appends the shared completion report lines.
func finishManagedSkillRemoval(
    manager: String,
    projections: [SkillInventoryItem],
    recovery: URL,
    projectRoot: URL,
    skillName: String,
    lines: inout [String]
) {
    var removedProjectionCount = 0
    for (index, projection) in projections.enumerated() {
        let projectionURL = URL(fileURLWithPath: projection.path)
        guard isSymlink(projectionURL) || fileManager.fileExists(atPath: projectionURL.path) else { continue }
        let projectionRecovery = recovery
            .appendingPathComponent("projections")
            .appendingPathComponent("\(index)-\(projection.location)")
            .appendingPathComponent(skillName)
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
    lines.append("removed managed skill through \(manager) and verified its manager entry is absent")
    if removedProjectionCount > 0 {
        lines.append("removed \(removedProjectionCount) dangling per-skill projection link(s)")
    }
    lines.append(finalizeRemovalRecovery(
        recovery,
        projectRoot: projectRoot,
        skillName: skillName
    ))
}

/// Copies every independent same-name skill location into the recovery folder
/// so a manager-driven removal can be reversed even where Metagent did not own
/// the copy it deleted.
func snapshotRetainedSkills(
    _ retained: [SkillInventoryItem],
    into recovery: URL,
    skillName: String
) throws -> [(original: URL, backup: URL)] {
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
    return retainedBackups
}

/// Moves each per-skill projection link, then the skill bundle itself, into the
/// recovery folder. If any move fails, every projection already moved is put
/// back before the error propagates, so a partial removal never survives.
func moveSkillAndProjectionsToRecovery(
    skill: URL,
    to recoveredSkill: URL,
    projections: [SkillInventoryItem],
    recovery: URL,
    skillName: String,
    rollbackErrorCode: Int,
    rollbackFailureSummary: String
) throws {
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
            throw NSError(domain: "MetagentSkillUninstall", code: rollbackErrorCode, userInfo: [
                NSLocalizedDescriptionKey: "\(rollbackFailureSummary) Original error: \(error.localizedDescription)\nRollback failures:\n\(rollbackFailures.joined(separator: "\n"))\nRecovery state: \(recovery.path)"
            ])
        }
        throw error
    }
}

func prepareRemovalRecovery(
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

    let metadata = "project=\(projectRoot.path)\nskill=\(skillName)\nremoved_at=\(iso8601Formatter.string(from: Date()))\n"
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

struct RemovalInventorySnapshot: Codable {
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

func writeRemovalInventorySnapshot(
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
        capturedAt: iso8601Formatter.string(from: Date()),
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

func finalizeRemovalRecovery(
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

    if isSymlink(claudeSkills) {
        if symlink(claudeSkills, resolvesTo: canonicalSkills) {
            lines.append(.init(kind: .info, text: "healthy: legacy .claude/skills -> ../.agents/skills"))
        } else {
            lines.append(.init(
                kind: .skipped,
                text: "manual review: .claude/skills is a conflicting symlink; left untouched"
            ))
        }
        try resolveObsoleteCodexProjections()
        return lines
    }

    var isClaudeSkillsDirectory = ObjCBool(false)
    if fileManager.fileExists(atPath: claudeSkills.path, isDirectory: &isClaudeSkillsDirectory),
       !isClaudeSkillsDirectory.boolValue
    {
        lines.append(.init(
            kind: .skipped,
            text: "manual review: .claude/skills is not a directory; left untouched"
        ))
        try resolveObsoleteCodexProjections()
        return lines
    }

    let plan: ClaudeSkillProjectionPlan
    do {
        plan = try planClaudeSkillProjection(
            project: project,
            claudeSkills: claudeSkills,
            canonicalSkills: canonicalSkills
        )
    } catch {
        lines.append(.init(
            kind: .skipped,
            text: "manual review: skills-lock.json is unreadable; left Claude projections untouched"
        ))
        try resolveObsoleteCodexProjections()
        return lines
    }

    for name in plan.orphanedNames {
        let action = apply
            ? "removed orphaned personal Claude link: \(name)"
            : "would remove orphaned personal Claude link: \(name)"
        guard apply else {
            lines.append(.init(kind: .action, text: action))
            continue
        }

        let claudeEntry = claudeSkills.appendingPathComponent(name)
        let formerCanonicalEntry = canonicalSkills.appendingPathComponent(name)
        guard isSymlink(claudeEntry),
              symlink(claudeEntry, resolvesTo: formerCanonicalEntry),
              !fileManager.fileExists(atPath: formerCanonicalEntry.path),
              !isSymlink(formerCanonicalEntry)
        else {
            throw NSError(domain: "MetagentSkillsRepair", code: 4, userInfo: [
                NSLocalizedDescriptionKey:
                    "\(claudeEntry.path) changed after preview; review it before applying"
            ])
        }
        try fileManager.removeItem(at: claudeEntry)
        lines.append(.init(kind: .action, text: action))
    }

    for name in plan.missingNames {
        let action = apply ? "linked personal Claude skill: \(name)" : "would link personal Claude skill: \(name)"
        guard apply else {
            lines.append(.init(kind: .action, text: action))
            continue
        }

        try fileManager.createDirectory(at: claudeSkills, withIntermediateDirectories: true)
        let claudeEntry = claudeSkills.appendingPathComponent(name)
        let canonicalEntry = canonicalSkills.appendingPathComponent(name)
        guard !fileManager.fileExists(atPath: claudeEntry.path), !isSymlink(claudeEntry) else {
            throw NSError(domain: "MetagentSkillsRepair", code: 4, userInfo: [
                NSLocalizedDescriptionKey:
                    "\(claudeEntry.path) appeared after preview; review it before applying"
            ])
        }
        try fileManager.createSymbolicLink(
            atPath: claudeEntry.path,
            withDestinationPath: "../../.agents/skills/\(name)"
        )
        guard symlink(claudeEntry, resolvesTo: canonicalEntry) else {
            throw NSError(domain: "MetagentSkillsRepair", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "repair verification failed for \(claudeEntry.path)"
            ])
        }
        lines.append(.init(kind: .action, text: action))
    }
    if !plan.overrideNames.isEmpty {
        lines.append(.init(
            kind: .info,
            text: "preserved Claude-specific override(s): \(plan.overrideNames.joined(separator: ", "))"
        ))
    }
    if !plan.collisionNames.isEmpty {
        lines.append(.init(
            kind: .skipped,
            text: "manual review: Claude projection collision(s) left untouched: "
                + plan.collisionNames.joined(separator: ", ")
        ))
    }
    if plan.missingNames.isEmpty, plan.collisionNames.isEmpty, plan.orphanedNames.isEmpty {
        lines.append(.init(kind: .info, text: "healthy: personal Claude skill links are current"))
    }

    try resolveObsoleteCodexProjections()
    return lines
}
