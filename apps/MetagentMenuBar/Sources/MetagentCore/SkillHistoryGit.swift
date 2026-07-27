import Foundation

/// One skill's lifetime as git recorded it.
///
/// Where a skills directory is tracked, git is the strongest evidence available:
/// it dates the commit that introduced a skill rather than the moment its folder
/// happened to be written, and it keeps every later edit and the deletion too.
/// `st_birthtime` only ever reports when these bytes arrived on this disk, which
/// a restore, a clone, or a plugin-cache extraction all reset.
struct GitSkillLifetime: Sendable, Equatable {
    let skillKey: String
    let name: String
    let installedOn: String?
    let removedOn: String?
    /// Days on which any file in the bundle changed, one entry per day.
    let changedOn: [String]
}

/// A tracked skills directory and the repository that tracks it.
private struct TrackedSkillsDirectory: Hashable {
    let repositoryRoot: URL
    /// The skills directory relative to the repository root, as git names it.
    let relativePath: String
    /// The same directory as an absolute path, for rebuilding skill keys.
    let absolutePath: String
}

/// Reads git history for every tracked skills directory behind `projects`.
///
/// One `git log` per repository covers every skill in it, so this stays a
/// handful of subprocesses rather than one per skill. Repositories that are not
/// tracked, or that git cannot read, simply contribute nothing; the caller falls
/// back to filesystem evidence for those skills.
func gitSkillLifetimes(
    projects: [SkillProject],
    timeout: TimeInterval = 20
) -> [String: GitSkillLifetime] {
    var lifetimes: [String: GitSkillLifetime] = [:]
    for directory in trackedSkillsDirectories(projects: projects) {
        guard let entries = gitSkillLogEntries(directory: directory, timeout: timeout) else { continue }
        for (skillKey, lifetime) in skillLifetimes(from: entries, directory: directory) {
            lifetimes[skillKey] = lifetime
        }
    }
    return lifetimes
}

/// One parsed change to one file, as `git log --name-status` reports it.
struct GitChange: Equatable {
    let day: String
    let status: Character
    let path: String
}

private func trackedSkillsDirectories(projects: [SkillProject]) -> [TrackedSkillsDirectory] {
    var directories: Set<TrackedSkillsDirectory> = []
    for project in projects where !project.skillsDir.isEmpty {
        let skillsDir = URL(fileURLWithPath: project.skillsDir).standardizedFileURL
        guard fileManager.fileExists(atPath: skillsDir.path),
              let repositoryRoot = enclosingRepository(of: skillsDir)
        else { continue }
        let rootPath = repositoryRoot.path
        guard skillsDir.path.hasPrefix(rootPath) else { continue }
        let relative = String(skillsDir.path.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relative.isEmpty else { continue }
        directories.insert(TrackedSkillsDirectory(
            repositoryRoot: repositoryRoot,
            relativePath: relative,
            absolutePath: skillsDir.path
        ))
    }
    return directories.sorted { $0.absolutePath < $1.absolutePath }
}

/// Walks up from `directory` to the repository that contains it. Stops at the
/// filesystem root so a directory outside any repository returns nothing.
private func enclosingRepository(of directory: URL) -> URL? {
    var candidate = directory.standardizedFileURL
    while candidate.path != "/" {
        if isGitRepository(candidate) { return candidate }
        let parent = candidate.deletingLastPathComponent().standardizedFileURL
        guard parent.path != candidate.path else { return nil }
        candidate = parent
    }
    return nil
}

private func gitSkillLogEntries(
    directory: TrackedSkillsDirectory,
    timeout: TimeInterval
) -> [GitChange]? {
    guard let executable = try? gitExecutable() else { return nil }
    // `-M` reports a moved bundle as a rename rather than an unrelated delete
    // and add, which keeps a renamed skill's history in one piece.
    let result = try? runSubprocess(
        executable: executable,
        arguments: [
            "log",
            "--format=C|%H|%ad",
            "--date=short",
            "--name-status",
            "--diff-filter=ADMR",
            "-M",
            "--",
            directory.relativePath,
        ],
        currentDirectory: directory.repositoryRoot,
        timeout: timeout
    )
    guard let result, !result.timedOut, result.status == 0 else { return nil }
    return parseGitSkillLog(String(decoding: result.standardOutput, as: UTF8.self))
}

/// Parses `--name-status` output into flat per-file changes.
///
/// A rename is recorded as a deletion of the old path and an addition of the
/// new one, which is what it means at skill granularity: one bundle stopped
/// existing under its old name and started existing under the new one.
func parseGitSkillLog(_ output: String) -> [GitChange] {
    var changes: [GitChange] = []
    var day = ""
    for line in output.split(whereSeparator: \.isNewline) {
        if line.hasPrefix("C|") {
            let parts = line.split(separator: "|", maxSplits: 2).map(String.init)
            if parts.count == 3 { day = parts[2] }
            continue
        }
        guard !day.isEmpty else { continue }
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 2, let status = fields[0].first else { continue }
        if status == "R", fields.count >= 3 {
            changes.append(GitChange(day: day, status: "D", path: fields[1]))
            changes.append(GitChange(day: day, status: "A", path: fields[2]))
            continue
        }
        changes.append(GitChange(day: day, status: status, path: fields[1]))
    }
    return changes
}

private func skillLifetimes(
    from changes: [GitChange],
    directory: TrackedSkillsDirectory
) -> [String: GitSkillLifetime] {
    let prefix = directory.relativePath + "/"
    var bySkill: [String: [GitChange]] = [:]
    for change in changes {
        guard change.path.hasPrefix(prefix) else { continue }
        let remainder = change.path.dropFirst(prefix.count)
        guard let name = remainder.split(separator: "/").first.map(String.init),
              // A file sitting directly in the skills directory is not a skill.
              remainder.contains("/")
        else { continue }
        bySkill[name, default: []].append(change)
    }

    var lifetimes: [String: GitSkillLifetime] = [:]
    for (name, skillChanges) in bySkill {
        let sorted = skillChanges.sorted { $0.day < $1.day }
        let manifest = "\(prefix)\(name)/SKILL.md"
        let manifestChanges = sorted.filter { $0.path == manifest }
        // The manifest defines the skill, so its first appearance is the
        // install. Bundles whose manifest predates the tracked history fall back
        // to the earliest change of any kind.
        let installedOn = manifestChanges.first { $0.status == "A" }?.day
            ?? sorted.first?.day
        let lastManifestDelete = manifestChanges.last { $0.status == "D" }?.day
        let lastManifestAdd = manifestChanges.last { $0.status == "A" }?.day
        let removedOn: String? = {
            guard let lastManifestDelete else { return nil }
            // Re-added after the deletion means it is present again, not gone.
            if let lastManifestAdd, lastManifestAdd >= lastManifestDelete { return nil }
            return lastManifestDelete
        }()
        // One content-change entry per day, whatever moved inside the bundle.
        // Reference and script edits are real changes to a skill, but a day is
        // as fine as this evidence usefully gets.
        let changedOn = Set(
            sorted
                .filter { $0.status == "M" || ($0.status == "A" && $0.day != installedOn) }
                .map(\.day)
        )
        .sorted()

        let skillKey = standardizedHistoryPath("\(directory.absolutePath)/\(name)")
        lifetimes[skillKey] = GitSkillLifetime(
            skillKey: skillKey,
            name: name,
            installedOn: installedOn,
            removedOn: removedOn,
            changedOn: changedOn
        )
    }
    return lifetimes
}
