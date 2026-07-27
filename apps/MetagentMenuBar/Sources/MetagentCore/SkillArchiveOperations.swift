import Foundation

/// One projection link moved aside with an archived skill, recorded with its
/// exact original path so restore never has to guess where a link belonged.
public struct SkillArchiveProjection: Codable, Equatable, Sendable {
    public let location: String
    public let originalPath: String
    /// Path inside the archive entry folder, mirroring the removal-recovery
    /// layout: `projections/<index>-<location>/<skillName>`.
    public let archivedSubpath: String

    public init(location: String, originalPath: String, archivedSubpath: String) {
        self.location = location
        self.originalPath = originalPath
        self.archivedSubpath = archivedSubpath
    }
}

/// The manifest written into every archive entry. This is the restore contract:
/// restore replays exactly these paths and nothing else.
public struct ArchivedSkill: Codable, Equatable, Sendable, Identifiable {
    public let formatVersion: Int
    public let skillName: String
    public let projectRoot: String
    /// The canonical bundle path the skill came from and returns to.
    public let skillPath: String
    /// `canonical` or `standalone` — which removal-style path archived it.
    public let method: String
    public let archivedAt: String
    public let projections: [SkillArchiveProjection]
    /// The archive entry folder. Populated when listing; not part of the
    /// manifest on disk (the folder knows where it is).
    public var archivePath: String?

    public var id: String { skillName }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, skillName, projectRoot, skillPath, method, archivedAt, projections
    }

    public init(
        formatVersion: Int = 1,
        skillName: String,
        projectRoot: String,
        skillPath: String,
        method: String,
        archivedAt: String,
        projections: [SkillArchiveProjection],
        archivePath: String? = nil
    ) {
        self.formatVersion = formatVersion
        self.skillName = skillName
        self.projectRoot = projectRoot
        self.skillPath = skillPath
        self.method = method
        self.archivedAt = archivedAt
        self.projections = projections
        self.archivePath = archivePath
    }
}

public struct SkillArchiveOutcome: Codable, Equatable, Sendable, Identifiable {
    public var id: String { target.id }
    public let target: SkillRemovalTarget
    public let succeeded: Bool
    public let lines: [String]
    public let archivePath: String?
    public let failureMessage: String?

    public init(
        target: SkillRemovalTarget,
        succeeded: Bool,
        lines: [String] = [],
        archivePath: String? = nil,
        failureMessage: String? = nil
    ) {
        self.target = target
        self.succeeded = succeeded
        self.lines = lines
        self.archivePath = archivePath
        self.failureMessage = failureMessage
    }
}

public struct SkillArchiveBatchReport: Codable, Equatable, Sendable {
    public let apply: Bool
    public let outcomes: [SkillArchiveOutcome]

    public init(apply: Bool, outcomes: [SkillArchiveOutcome]) {
        self.apply = apply
        self.outcomes = outcomes
    }
}

public struct SkillRestoreReport: Codable, Equatable, Sendable {
    public let skillName: String
    public let projectRoot: String
    public let restoredPath: String
    public let lines: [String]

    public init(skillName: String, projectRoot: String, restoredPath: String, lines: [String]) {
        self.skillName = skillName
        self.projectRoot = projectRoot
        self.restoredPath = restoredPath
        self.lines = lines
    }
}

extension MetagentCore {

    static let skillArchiveManifestName = "ARCHIVE.json"

    /// Where archived skills live. A sibling of `Removed Skills` on purpose:
    /// the history backfill treats that folder as evidence of permanent
    /// removal, and an archived skill is expected back.
    public static func archivedSkillsRoot() -> URL {
        homeURL()
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Metagent")
            .appendingPathComponent("Archived Skills")
    }

    /// Every archive entry with a readable manifest, sorted by name.
    public static func listArchivedSkills() -> [ArchivedSkill] {
        let root = archivedSkillsRoot()
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.sorted().compactMap { name in
            let entry = root.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: entry.appendingPathComponent(skillArchiveManifestName)),
                  var manifest = try? JSONDecoder().decode(ArchivedSkill.self, from: data)
            else { return nil }
            manifest.archivePath = entry.path
            return manifest
        }
    }

    static func archivedSkill(named name: String) -> ArchivedSkill? {
        listArchivedSkills().first { $0.skillName == name }
    }

    /// Original canonical paths of every currently archived skill, in the
    /// history layer's key form. The history capture uses this to tell an
    /// archive apart from a removal.
    static func archivedSkillHistoryKeys() -> Set<String> {
        Set(listArchivedSkills().map { standardizedHistoryPath($0.skillPath) })
    }

    /// The single archive entrance. `apply` defaults to a dry run, mirroring
    /// `removeSkills`. Archiving is a pure file move into the Archived Skills
    /// folder, so only targets whose removal would also be a pure file move are
    /// eligible: canonical local bundles and standalone `.codex`/`.claude`
    /// bundles. Managed skills (skills-cli, dotagents) and Codex plugins are
    /// refused rather than desynced from their manager.
    public static func archiveSkills(
        targets: [SkillRemovalTarget],
        apply: Bool = false
    ) -> SkillArchiveBatchReport {
        var seen = Set<String>()
        let unique = targets.filter { seen.insert($0.id).inserted }
        return SkillArchiveBatchReport(
            apply: apply,
            outcomes: unique.map { archiveSkill(target: $0, apply: apply) }
        )
    }

    private static func archiveSkill(target: SkillRemovalTarget, apply: Bool) -> SkillArchiveOutcome {
        do {
            let plan = try planSkillArchive(target: target)
            guard apply else {
                var lines = [
                    "would archive \(target.displayName) to \(plan.entryDir.path)"
                ]
                if !plan.projections.isEmpty {
                    lines.append("would move \(plan.projections.count) per-skill projection link(s) with it")
                }
                lines.append("restore with: metagent skills restore \(plan.skillName)")
                return SkillArchiveOutcome(
                    target: target,
                    succeeded: true,
                    lines: lines,
                    archivePath: plan.entryDir.path
                )
            }
            return try applySkillArchive(target: target, plan: plan)
        } catch {
            return SkillArchiveOutcome(
                target: target,
                succeeded: false,
                failureMessage: error.localizedDescription
            )
        }
    }

    private struct SkillArchivePlan {
        let skillName: String
        let root: URL
        let skillURL: URL
        let method: String
        let entryDir: URL
        let projections: [SkillInventoryItem]
    }

    private static func planSkillArchive(target: SkillRemovalTarget) throws -> SkillArchivePlan {
        switch target.method {
        case .codexPlugin:
            throw archiveError(1, "\(target.displayName) is a Codex plugin; Metagent archives file-backed skills only. Remove or disable the plugin through Codex instead.")
        case .canonical:
            guard let projectRoot = target.projectRoot, let skillName = target.skillName else {
                throw archiveError(2, "incomplete canonical archive target: \(target.id)")
            }
            let root = URL(fileURLWithPath: projectRoot).resolvingSymlinksInPath().standardizedFileURL
            let project = try readProjectSkills(root: root)
            guard let agentsSkill = project.skills.first(where: {
                $0.location == "agents" && $0.name == skillName && $0.representation == "canonical"
            }) else {
                throw archiveError(3, "\(skillName) is not installed in \(root.path)/.agents/skills")
            }
            guard agentsSkill.manager == "local" else {
                throw archiveError(4, "\(skillName) is managed by \(agentsSkill.manager); archiving would leave its manager state pointing at a missing bundle. Remove it through its manager instead.")
            }
            let skillURL = URL(fileURLWithPath: agentsSkill.path)
            let (projections, _) = partitionSameNameSkills(
                in: project,
                skillName: skillName,
                canonicalSkillURL: skillURL
            )
            return SkillArchivePlan(
                skillName: skillName,
                root: root,
                skillURL: skillURL,
                method: "canonical",
                entryDir: try availableArchiveEntry(for: skillName),
                projections: projections
            )
        case .standalone:
            guard let projectRoot = target.projectRoot,
                  let skillPath = target.skillPath,
                  let skillName = target.skillName
            else {
                throw archiveError(2, "incomplete standalone archive target: \(target.id)")
            }
            guard let (root, skill) = standaloneSkillRemovalTarget(
                projectRoot: projectRoot,
                skillPath: skillPath,
                skillName: skillName
            ) else {
                throw archiveError(5, "Metagent will only archive a canonical standalone skill bundle.")
            }
            let project = try readProjectSkills(root: root)
            let projections = project.skills.filter { candidate in
                guard candidate.name == skillName,
                      candidate.path != skill.path,
                      !candidate.symlinkedContainer
                else { return false }
                let candidateURL = URL(fileURLWithPath: candidate.path)
                return isSymlink(candidateURL) && symlink(candidateURL, resolvesTo: skill)
            }
            return SkillArchivePlan(
                skillName: skillName,
                root: root,
                skillURL: skill,
                method: "standalone",
                entryDir: try availableArchiveEntry(for: skillName),
                projections: projections
            )
        }
    }

    private static func availableArchiveEntry(for skillName: String) throws -> URL {
        let entry = archivedSkillsRoot().appendingPathComponent(skillName)
        guard !fileManager.fileExists(atPath: entry.path), !isSymlink(entry) else {
            throw archiveError(6, "\(skillName) is already archived at \(entry.path); restore or clear it before archiving again.")
        }
        return entry
    }

    private static func applySkillArchive(
        target: SkillRemovalTarget,
        plan: SkillArchivePlan
    ) throws -> SkillArchiveOutcome {
        try fileManager.createDirectory(at: plan.entryDir, withIntermediateDirectories: true)

        // The manifest goes down first so a crash mid-move leaves an entry
        // whose intended contents are on record.
        let manifest = ArchivedSkill(
            skillName: plan.skillName,
            projectRoot: plan.root.path,
            skillPath: plan.skillURL.path,
            method: plan.method,
            archivedAt: iso8601Formatter.string(from: Date()),
            projections: plan.projections.enumerated().map { index, projection in
                SkillArchiveProjection(
                    location: projection.location,
                    originalPath: projection.path,
                    archivedSubpath: "projections/\(index)-\(projection.location)/\(plan.skillName)"
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(manifest)
                .write(to: plan.entryDir.appendingPathComponent(skillArchiveManifestName), options: .atomic)
        } catch {
            try? fileManager.removeItem(at: plan.entryDir)
            throw error
        }

        do {
            try moveSkillAndProjectionsToRecovery(
                skill: plan.skillURL,
                to: plan.entryDir.appendingPathComponent(plan.skillName),
                projections: plan.projections,
                recovery: plan.entryDir,
                skillName: plan.skillName,
                rollbackErrorCode: 20,
                rollbackFailureSummary: "archive failed and rollback was incomplete."
            )
        } catch {
            // Rollback already put the projections back; drop the entry so a
            // failed archive never blocks the next attempt.
            try? fileManager.removeItem(at: plan.entryDir)
            throw error
        }

        guard !fileManager.fileExists(atPath: plan.skillURL.path) else {
            throw archiveError(7, "archive verification failed: \(plan.skillURL.path) still exists")
        }

        var lines = ["archived \(plan.skillName) to \(plan.entryDir.path)"]
        if !plan.projections.isEmpty {
            lines.append("moved \(plan.projections.count) per-skill projection link(s) into the archive")
        }
        lines.append("restore with: metagent skills restore \(plan.skillName)")
        return SkillArchiveOutcome(
            target: target,
            succeeded: true,
            lines: lines,
            archivePath: plan.entryDir.path
        )
    }

    /// Puts an archived skill back exactly where it came from: the bundle to
    /// its recorded canonical path, then every recorded projection link. A
    /// bundle that cannot go back is an error; a projection that cannot is a
    /// warning, because the projection repair path can recreate those.
    public static func restoreArchivedSkill(named skillName: String) throws -> SkillRestoreReport {
        guard let entry = archivedSkill(named: skillName), let archivePath = entry.archivePath else {
            let known = listArchivedSkills().map(\.skillName)
            throw archiveError(8, known.isEmpty
                ? "no archived skill named \(skillName); the archive is empty"
                : "no archived skill named \(skillName); archived: \(known.joined(separator: ", "))")
        }
        let entryDir = URL(fileURLWithPath: archivePath)
        let archivedBundle = entryDir.appendingPathComponent(entry.skillName)
        let destination = URL(fileURLWithPath: entry.skillPath)

        guard fileManager.fileExists(atPath: archivedBundle.path) else {
            throw archiveError(9, "archive entry at \(entryDir.path) has no \(entry.skillName) bundle; restore it by hand")
        }
        guard !fileManager.fileExists(atPath: destination.path), !isSymlink(destination) else {
            throw archiveError(10, "\(destination.path) already exists; resolve it before restoring \(entry.skillName)")
        }

        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.moveItem(at: archivedBundle, to: destination)
        guard isRegularOrSymlinkedFile(destination.appendingPathComponent("SKILL.md")) else {
            throw archiveError(11, "restore verification failed: \(destination.path) has no SKILL.md")
        }

        var lines = ["restored \(entry.skillName) to \(destination.path)"]
        var restoredProjections = 0
        for projection in entry.projections {
            let archived = entryDir.appendingPathComponent(projection.archivedSubpath)
            let original = URL(fileURLWithPath: projection.originalPath)
            guard isSymlink(archived) || fileManager.fileExists(atPath: archived.path) else {
                lines.append("warning: archived projection missing at \(archived.path); run skills repair to recreate it")
                continue
            }
            guard !fileManager.fileExists(atPath: original.path), !isSymlink(original) else {
                lines.append("warning: \(original.path) is already occupied; left the archived projection in place")
                continue
            }
            do {
                try fileManager.createDirectory(
                    at: original.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.moveItem(at: archived, to: original)
                restoredProjections += 1
            } catch {
                lines.append("warning: could not restore projection at \(original.path): \(error.localizedDescription)")
            }
        }
        if restoredProjections > 0 {
            lines.append("restored \(restoredProjections) per-skill projection link(s)")
        }

        // The entry folder only comes down when everything in it went back;
        // otherwise it stays as the record of what still needs a home.
        let leftovers = lines.contains { $0.hasPrefix("warning: ") && $0.contains("left the archived projection") }
        if leftovers {
            lines.append("kept \(entryDir.path) because it still holds unrestored projection link(s)")
        } else {
            do {
                try fileManager.removeItem(at: entryDir)
                lines.append("cleared the archive entry")
            } catch {
                lines.append("warning: restored, but could not clear \(entryDir.path): \(error.localizedDescription)")
            }
        }

        return SkillRestoreReport(
            skillName: entry.skillName,
            projectRoot: entry.projectRoot,
            restoredPath: destination.path,
            lines: lines
        )
    }

    private static func archiveError(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "MetagentSkillArchive", code: code, userInfo: [
            NSLocalizedDescriptionKey: message
        ])
    }
}
