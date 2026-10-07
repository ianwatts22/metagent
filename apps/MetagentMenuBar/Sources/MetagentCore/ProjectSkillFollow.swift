import Foundation

/// One synced skill that did not follow its global source and needs a person.
public struct ProjectSkillFollowIssue: Codable, Equatable, Sendable {
    public let name: String
    public let reason: String
}

public struct ProjectSkillFollowProject: Encodable, Equatable, Sendable {
    public let projectRoot: String
    /// Replaced with the current global source (or, without apply, would be).
    public internal(set) var updatedNames: [String] = []
    /// Left untouched: local edits, credential findings, a removed source, etc.
    public internal(set) var blocked: [ProjectSkillFollowIssue] = []
    /// Another Metagent copy held the project lock. The next refresh retries.
    public internal(set) var deferredNames: [String] = []
    /// The ownership manifest could not be read, so nothing was followed.
    public internal(set) var error: String?
}

public struct ProjectSkillFollowReport: Encodable, Equatable, Sendable {
    public let applied: Bool
    /// Only projects with an ownership manifest appear.
    public let projects: [ProjectSkillFollowProject]
    public var updatedCount: Int { projects.reduce(0) { $0 + $1.updatedNames.count } }
    public var needsAttention: Bool { projects.contains { !$0.blocked.isEmpty || $0.error != nil } }
}

public extension MetagentCore {
    /// Every skill recorded in a project's `.agents/project-skills.json`
    /// follows its global source. Each skill is previewed and applied on its
    /// own through the normal sync path, so one blocked skill never stops the
    /// others and every existing safety check still applies. Project copies
    /// are never deleted or re-created here.
    static func refreshSyncedProjectSkills(projectRoots: [String], apply: Bool = true) -> ProjectSkillFollowReport {
        refreshSyncedProjectSkills(projectRoots: projectRoots, apply: apply) { collection in
            homeURL().appendingPathComponent(collection.relativePath).path
        }
    }
}

extension MetagentCore {
    /// Injectable global roots keep tests away from the real home directory.
    static func refreshSyncedProjectSkills(
        projectRoots: [String],
        apply: Bool = true,
        globalSkillsRoot: (ProjectSkillSyncCollection) -> String
    ) -> ProjectSkillFollowReport {
        let projects = Array(Set(projectRoots)).sorted().compactMap { root -> ProjectSkillFollowProject? in
            // Cheap gate: projects that never synced a skill cost one stat.
            let manifest = URL(fileURLWithPath: root).appendingPathComponent(projectSyncManifestRelativePath)
            guard fileManager.fileExists(atPath: manifest.path) || isFilesystemSymlink(manifest) else { return nil }
            return followSyncedProjectSkills(projectRoot: root, apply: apply, globalSkillsRoot: globalSkillsRoot)
        }
        return ProjectSkillFollowReport(applied: apply, projects: projects)
    }

    private static func followSyncedProjectSkills(
        projectRoot: String,
        apply: Bool,
        globalSkillsRoot: (ProjectSkillSyncCollection) -> String
    ) -> ProjectSkillFollowProject {
        var result = ProjectSkillFollowProject(projectRoot: projectRoot)
        let owned: [(name: String, collection: ProjectSkillSyncCollection)]
        do {
            owned = try projectSyncOwnedSkills(projectRoot: projectRoot)
        } catch {
            result.error = error.localizedDescription
            return result
        }
        for skill in owned {
            let globalRoot = globalSkillsRoot(skill.collection)
            let source = URL(fileURLWithPath: globalRoot).appendingPathComponent(skill.name)
            guard fileManager.fileExists(atPath: source.path) || isFilesystemSymlink(source) else {
                result.blocked.append(ProjectSkillFollowIssue(name: skill.name, reason: """
                    The global skill no longer exists in ~/\(skill.collection.relativePath). The project copy is kept; \
                    remove it and its ownership record yourself if the project no longer needs it.
                    """))
                continue
            }
            do {
                let plan = try previewProjectSkillSync(
                    projectRoot: projectRoot, skillNames: [skill.name],
                    globalSkillsRoot: globalRoot, collection: skill.collection
                )
                guard let item = plan.items.first else { continue }
                switch item.action {
                case .unchanged:
                    continue
                case .update:
                    if apply { _ = try applyProjectSkillSync(plan) }
                    result.updatedNames.append(skill.name)
                case .copy, .blocked:
                    // A recorded skill is only ever updated in place; a missing
                    // project copy is not silently re-created.
                    result.blocked.append(ProjectSkillFollowIssue(name: skill.name, reason: blockedReason(item)))
                }
            } catch where isProjectSyncBusy(error) {
                result.deferredNames.append(skill.name)
            } catch {
                result.blocked.append(ProjectSkillFollowIssue(name: skill.name, reason: error.localizedDescription))
            }
        }
        return result
    }

    private static func blockedReason(_ item: ProjectSkillSyncItem) -> String {
        var seen = Set<String>()
        let messages = item.findings
            .filter { $0.severity == .blocking }
            .map(\.message)
            .filter { seen.insert($0).inserted }
        guard !messages.isEmpty else { return "Review this skill with Sync Global Skills before it can update." }
        return messages.joined(separator: " ")
    }
}
