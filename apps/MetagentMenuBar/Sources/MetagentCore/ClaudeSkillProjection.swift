import Foundation

/// The project-local Claude projection is shared with the Skills CLI by name.
///
/// Names recorded in `skills-lock.json` belong to the Skills CLI. Metagent
/// reconciles only the remaining `.agents/skills` names, and only when the
/// corresponding Claude entry is absent.
struct ClaudeSkillProjectionPlan: Equatable {
    var lockedNames: [String]
    var linkedNames: [String]
    var missingNames: [String]
    var overrideNames: [String]
    var collisionNames: [String]
    var orphanedNames: [String]
}

func planClaudeSkillProjection(
    project: SkillProject,
    claudeSkills: URL,
    canonicalSkills: URL
) throws -> ClaudeSkillProjectionPlan {
    let root = URL(fileURLWithPath: project.root)
    let lockedNames = Set(try readProjectSkillLocksValidated(root: root).keys)
    let personalNames = Set(project.validSkills).subtracting(lockedNames)
    var linkedNames: [String] = []
    var missingNames: [String] = []
    var overrideNames: [String] = []
    var collisionNames: [String] = []
    var orphanedNames: [String] = []

    for name in personalNames.sorted() {
        let claudeEntry = claudeSkills.appendingPathComponent(name)
        let canonicalEntry = canonicalSkills.appendingPathComponent(name)
        if isSymlink(claudeEntry) {
            if symlink(claudeEntry, resolvesTo: canonicalEntry) {
                linkedNames.append(name)
            } else {
                collisionNames.append(name)
            }
            continue
        }

        var isDirectory = ObjCBool(false)
        if fileManager.fileExists(atPath: claudeEntry.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                // A real Claude bundle is an intentional provider-specific
                // override. It wins for Claude and remains untouched.
                overrideNames.append(name)
            } else {
                collisionNames.append(name)
            }
        } else {
            missingNames.append(name)
        }
    }

    let validNames = Set(project.validSkills)
    for name in ((try? fileManager.contentsOfDirectory(atPath: claudeSkills.path)) ?? []).sorted() {
        guard !validNames.contains(name), !lockedNames.contains(name) else { continue }
        let claudeEntry = claudeSkills.appendingPathComponent(name)
        let formerCanonicalEntry = canonicalSkills.appendingPathComponent(name)
        if isSymlink(claudeEntry), symlink(claudeEntry, resolvesTo: formerCanonicalEntry) {
            orphanedNames.append(name)
        }
    }

    return ClaudeSkillProjectionPlan(
        lockedNames: lockedNames.intersection(project.validSkills).sorted(),
        linkedNames: linkedNames,
        missingNames: missingNames,
        overrideNames: overrideNames,
        collisionNames: collisionNames,
        orphanedNames: orphanedNames
    )
}

func doctorClaudeSkillProjection(project: SkillProject) -> [DoctorIssue] {
    let root = URL(fileURLWithPath: project.root)
    let claudeDirectory = root.appendingPathComponent(".claude")
    let claudeSkills = claudeDirectory.appendingPathComponent("skills")
    let canonicalSkills = root.appendingPathComponent(".agents/skills")

    if isSymlink(claudeDirectory) {
        return [.init(
            severity: .warning,
            message: "\(claudeDirectory.path) is a symlink; projection repair is disabled",
            summary: "Claude project directory is shared",
            projectRoot: project.root,
            category: .projection,
            guidance: "Review the shared .claude directory manually; Metagent will not write through it."
        )]
    }

    if isSymlink(claudeSkills) {
        if symlink(claudeSkills, resolvesTo: canonicalSkills) {
            return [.init(
                severity: .ok,
                message: "\(claudeSkills.path) uses the legacy whole-folder projection",
                projectRoot: project.root,
                category: .projection,
                guidance: "All project skills are visible to Claude through the existing .agents/skills link."
            )]
        }
        return [.init(
            severity: .warning,
            message: "\(claudeSkills.path) points somewhere other than .agents/skills",
            summary: "Claude skills path is a conflicting symlink",
            projectRoot: project.root,
            category: .projection,
            guidance: "Review this symlink manually. Metagent preserves conflicting paths and will not replace them."
        )]
    }

    var isDirectory = ObjCBool(false)
    if fileManager.fileExists(atPath: claudeSkills.path, isDirectory: &isDirectory),
       !isDirectory.boolValue
    {
        return [.init(
            severity: .warning,
            message: "\(claudeSkills.path) is not a directory",
            summary: "Claude skills path is blocked",
            projectRoot: project.root,
            category: .projection,
            guidance: "Review this path manually. Metagent will not replace files or other non-directory content."
        )]
    }

    let plan: ClaudeSkillProjectionPlan
    do {
        plan = try planClaudeSkillProjection(
            project: project,
            claudeSkills: claudeSkills,
            canonicalSkills: canonicalSkills
        )
    } catch {
        return [.init(
            severity: .warning,
            message: "Could not read \(root.appendingPathComponent("skills-lock.json").path): \(error.localizedDescription)",
            summary: "Skills CLI ownership is unreadable",
            projectRoot: project.root,
            category: .projection,
            guidance: "Repair skills-lock.json before projecting personal skills. Metagent will not guess which names the Skills CLI owns."
        )]
    }

    var issues: [DoctorIssue] = []
    if !plan.missingNames.isEmpty {
        issues.append(.init(
            severity: .warning,
            message: "\(plan.missingNames.count) personal skill(s) are missing from Claude: \(plan.missingNames.joined(separator: ", "))",
            summary: "Claude is missing personal skills",
            projectRoot: project.root,
            category: .projection,
            guidance: "Run Repair to create only the missing Claude child links. Skills CLI names and existing Claude content stay untouched.",
            repairAction: .repairProjection
        ))
    }
    if !plan.collisionNames.isEmpty {
        issues.append(.init(
            severity: .warning,
            message: "\(plan.collisionNames.count) Claude projection collision(s): \(plan.collisionNames.joined(separator: ", "))",
            summary: "Claude skill names collide",
            projectRoot: project.root,
            category: .projection,
            guidance: "Review these names manually. Metagent will not replace files or symlinks that point somewhere else."
        ))
    }
    if !plan.orphanedNames.isEmpty {
        issues.append(.init(
            severity: .warning,
            message: "\(plan.orphanedNames.count) personal Claude link(s) have no .agents skill: \(plan.orphanedNames.joined(separator: ", "))",
            summary: "Claude has stale personal skill links",
            projectRoot: project.root,
            category: .projection,
            guidance: "Run Repair to remove only these dangling child links. Existing Claude content and Skills CLI names stay untouched.",
            repairAction: .repairProjection
        ))
    }
    if !plan.overrideNames.isEmpty {
        issues.append(.init(
            severity: .ok,
            message: "Preserved \(plan.overrideNames.count) Claude-specific override(s): \(plan.overrideNames.joined(separator: ", "))",
            projectRoot: project.root,
            category: .projection
        ))
    }
    if issues.isEmpty {
        issues.append(.init(
            severity: .ok,
            message: plan.lockedNames.count == project.validSkills.count
                ? "Skills CLI owns this project's Claude projections"
                : "\(plan.linkedNames.count) personal skill(s) are linked into Claude",
            projectRoot: project.root,
            category: .projection
        ))
    }
    return issues
}
