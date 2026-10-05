import CryptoKit
import Darwin
import Foundation

public enum ProjectSkillSyncCollection: String, Codable, CaseIterable, Sendable {
    case agents, codex, claude
    public var relativePath: String { ".\(rawValue)/skills" }
}

public struct ProjectSkillSyncFile: Codable, Equatable, Sendable {
    public let relativePath: String
    public let byteCount: Int
}

public struct ProjectSkillSyncItem: Codable, Equatable, Sendable, Identifiable {
    public enum Action: String, Codable, Sendable { case copy, update, unchanged, blocked }
    public var id: String { name }
    public let name: String
    public let destinationPath: String
    public let action: Action
    public let sourceHash: String?
    public let destinationHash: String?
    public let files: [ProjectSkillSyncFile]
    public let removedFiles: [String]
    public let findings: [SkillPublishFinding]
}

/// A preview is a snapshot, not ongoing permission to mirror. Apply rechecks
/// every selected bundle and ownership record before it changes the project.
public struct ProjectSkillSyncPlan: Encodable, Equatable, Sendable {
    public let projectRoot: String
    public let globalSkillsRoot: String
    public let projectIdentity: ProjectSkillSyncDirectoryIdentity
    public let globalIdentity: ProjectSkillSyncDirectoryIdentity
    public let collection: ProjectSkillSyncCollection
    public let manifestHash: String?
    public let items: [ProjectSkillSyncItem]
    public var canApply: Bool { !items.isEmpty && items.allSatisfy { $0.action != .blocked } }
    public var changeCount: Int { items.filter { [.copy, .update].contains($0.action) }.count }
}

/// Ephemeral preview identity, never written into the portable ownership file.
public struct ProjectSkillSyncDirectoryIdentity: Encodable, Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
}

public struct ProjectSkillSyncReport: Encodable, Equatable, Sendable {
    public let applied: Bool
    public let plan: ProjectSkillSyncPlan
    public let copiedNames: [String]
    public let updatedNames: [String]
    public init(applied: Bool, plan: ProjectSkillSyncPlan, copiedNames: [String], updatedNames: [String]) {
        self.applied = applied
        self.plan = plan
        self.copiedNames = copiedNames
        self.updatedNames = updatedNames
    }
}

/// Portable project ownership only. Never persist absolute source/home paths,
/// accounts, lockfile contents or the user's other selected projects here.
private struct ProjectSkillSyncManifest: Codable {
    struct Entry: Codable {
        let collection: ProjectSkillSyncCollection
        let contentHash: String
    }
    var version = 1
    var skills: [String: Entry] = [:]
}

private struct ProjectSkillSyncBundle {
    struct File {
        let path: String
        let data: Data
        let permissions: Int
    }
    let files: [File]
    let hash: String
    let findings: [SkillPublishFinding]
}

public extension MetagentCore {
    static func globalProjectSyncSkillNames(collection: ProjectSkillSyncCollection = .agents) throws -> [String] {
        let root = homeURL().appendingPathComponent(collection.relativePath)
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        return try projectSyncSkillNames(in: root)
    }

    static func previewProjectSkillSync(
        projectRoot: String,
        skillNames: [String],
        collection: ProjectSkillSyncCollection = .agents
    ) throws -> ProjectSkillSyncPlan {
        try previewProjectSkillSync(
            projectRoot: projectRoot,
            skillNames: skillNames,
            globalSkillsRoot: homeURL().appendingPathComponent(collection.relativePath).path,
            collection: collection
        )
    }

    /// Copies locally only; never stages, commits, pushes, installs projections,
    /// changes a Git index, or deletes skills omitted from this preview.
    static func applyProjectSkillSync(_ preview: ProjectSkillSyncPlan) throws -> ProjectSkillSyncReport {
        guard preview.canApply else { throw projectSyncError("Resolve blocked skills before copying.") }
        return try withProjectSkillSyncDirectoryLock(projectRoot: preview.projectRoot, expectedIdentity: preview.projectIdentity) { directory in
            let current = try previewProjectSkillSync(
                projectRoot: preview.projectRoot,
                skillNames: preview.items.map(\.name),
                globalSkillsRoot: preview.globalSkillsRoot,
                collection: preview.collection
            )
            guard current == preview else {
                throw projectSyncError("The source or project changed after preview. Preview again; nothing was copied.")
            }
            guard preview.changeCount > 0 else {
                return ProjectSkillSyncReport(applied: true, plan: preview, copiedNames: [], updatedNames: [])
            }
            return try applyProjectSkillSyncTransaction(preview, in: directory)
        }
    }
}

extension MetagentCore {
    /// Injectable roots are internal: production selection always reads the
    /// canonical global collection; tests never need a real home directory.
    static func projectSyncSkillNames(in root: URL) throws -> [String] {
        let root = try projectSyncRoot(root.path)
        let entries = try projectSyncDirectoryNames(root, limit: projectSyncMaximumEntries)
        return entries.sorted().filter { name in
            let skill = root.appendingPathComponent(name)
            return projectSyncValidName(name)
                && isUnsymlinkedDescendant(skill, of: root)
                && (try? skill.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && (try? skill.appendingPathComponent("SKILL.md").resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    static func previewProjectSkillSync(
        projectRoot: String,
        skillNames: [String],
        globalSkillsRoot: String,
        collection: ProjectSkillSyncCollection = .agents
    ) throws -> ProjectSkillSyncPlan {
        let names = Array(Set(skillNames)).sorted()
        guard !names.isEmpty, names.count <= 32, names.allSatisfy(projectSyncValidName) else {
            throw projectSyncError("Select between 1 and 32 skill folder names (lowercase letters, numbers, hyphens or underscores).")
        }
        let project = try projectSyncRoot(projectRoot)
        let global = try projectSyncRoot(globalSkillsRoot)
        let projectIdentity = try projectSyncIdentity(project)
        let globalIdentity = try projectSyncIdentity(global)
        guard project != global, !global.path.hasPrefix(project.path + "/"),
              !project.path.hasPrefix(global.path + "/") else {
            throw projectSyncError("The project and global skills collection must be separate folders.")
        }
        let agents = project.appendingPathComponent(".agents")
        let skills = agents.appendingPathComponent("skills")
        for path in [agents, skills] {
            try projectSyncDirectoryDestination(path, under: project)
        }
        let manifestURL = agents.appendingPathComponent(projectSyncManifestName)
        let (manifest, manifestHash) = try projectSyncManifest(at: manifestURL, under: project)
        guard Set(manifest.skills.keys).union(names).count <= projectSyncMaximumEntries else {
            throw projectSyncError("The selection would exceed the 4,096 project ownership record limit. Nothing was copied.")
        }
        let lockedNames = try projectSyncManagedNames(in: project)
        var projectedManifest = manifest
        var totalBytes = 0
        let items = names.map { name -> ProjectSkillSyncItem in
            let source = global.appendingPathComponent(name)
            let destination = skills.appendingPathComponent(name)
            var findings: [SkillPublishFinding] = []
            var sourceBundle: ProjectSkillSyncBundle?
            var destinationBundle: ProjectSkillSyncBundle?
            var action = ProjectSkillSyncItem.Action.copy
            do {
                guard totalBytes < projectSyncMaximumTotalBytes else {
                    throw projectSyncError("The selection exceeds the 100 MiB total copy limit.")
                }
                guard isUnsymlinkedDescendant(source, of: global) else {
                    throw projectSyncError("The selected source is linked outside the global collection.")
                }
                let bundle = try projectSyncBundle(at: source, screening: true,
                    maximumBytes: min(publicationMaximumBundleBytes, projectSyncMaximumTotalBytes - totalBytes))
                sourceBundle = bundle
                findings += bundle.findings
                totalBytes += bundle.files.reduce(0) { $0 + $1.data.count }
                if totalBytes > projectSyncMaximumTotalBytes {
                    throw projectSyncError("The selection exceeds the 100 MiB total copy limit.")
                }
                guard isUnsymlinkedDescendant(destination, of: project) else {
                    throw projectSyncError("The destination crosses a symlink. Metagent will not write through it.")
                }
                guard !lockedNames.contains(name) else {
                    throw projectSyncError("This project skill belongs to another manager. Update it through that manager.")
                }
                if fileManager.fileExists(atPath: destination.path) {
                    let existing = try projectSyncBundle(at: destination, screening: false)
                    destinationBundle = existing
                    guard let owned = manifest.skills[name], owned.collection == collection,
                          owned.contentHash == existing.hash else {
                        throw projectSyncError("The project skill is not an unchanged Metagent copy. Existing project content stays untouched.")
                    }
                    action = existing.hash == bundle.hash ? .unchanged : .update
                } else if manifest.skills[name] != nil {
                    throw projectSyncError("The previously copied project skill is missing. Review its removal before restoring it manually.")
                }
                if findings.contains(where: { $0.severity == .blocking }) { action = .blocked }
            } catch {
                action = .blocked
                findings.append(projectSyncFinding("blocked", message: error.localizedDescription))
            }
            if [.copy, .update].contains(action), let hash = sourceBundle?.hash {
                projectedManifest.skills[name] = .init(collection: collection, contentHash: hash)
            }
            let sourcePaths = Set(sourceBundle?.files.map(\.path) ?? [])
            return ProjectSkillSyncItem(
                name: name, destinationPath: destination.path, action: action,
                sourceHash: sourceBundle?.hash, destinationHash: destinationBundle?.hash,
                files: sourceBundle?.files.map { ProjectSkillSyncFile(relativePath: $0.path, byteCount: $0.data.count) } ?? [],
                removedFiles: destinationBundle?.files.map(\.path).filter { !sourcePaths.contains($0) } ?? [],
                findings: findings
            )
        }
        _ = try projectSyncEncodedManifest(projectedManifest)
        return ProjectSkillSyncPlan(
            projectRoot: project.path, globalSkillsRoot: global.path,
            projectIdentity: projectIdentity, globalIdentity: globalIdentity, collection: collection,
            manifestHash: manifestHash, items: items
        )
    }
}

private let projectSyncManifestName = "project-skills.json"
private let projectSyncMaximumEntries = 4_096
private let projectSyncMaximumTotalBytes = 100 * 1_024 * 1_024

private func projectSyncRoot(_ path: String) throws -> URL {
    guard NSString(string: path).isAbsolutePath else {
        throw projectSyncError("Choose an absolute folder path.")
    }
    let url = URL(fileURLWithPath: path).standardizedFileURL
    // Aliases above a selected checkout are supported; the returned canonical
    // root is pinned in the preview and cannot be reselected by a later link.
    let canonical = url.resolvingSymlinksInPath().standardizedFileURL
    guard !isFilesystemSymlink(url),
          (try? canonical.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
        throw projectSyncError("The selected folder must be an existing physical directory.")
    }
    guard canonical.path != "/" else { throw projectSyncError("A filesystem root is not a project destination.") }
    return canonical
}

private func projectSyncValidName(_ name: String) -> Bool {
    name.range(of: #"^[a-z0-9][a-z0-9_-]{0,63}$"#, options: .regularExpression) != nil
}

private func projectSyncDirectoryDestination(_ path: URL, under root: URL) throws {
    guard isUnsymlinkedDescendant(path, of: root),
          !fileManager.fileExists(atPath: path.path)
            || (try? path.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
        throw projectSyncError("The project skills path is linked or is not a directory. Nothing was copied.")
    }
}

private func projectSyncManifest(at path: URL, under root: URL) throws -> (ProjectSkillSyncManifest, String?) {
    guard isUnsymlinkedDescendant(path, of: root) else {
        throw projectSyncError("The project ownership manifest is linked. Nothing was copied.")
    }
    guard fileManager.fileExists(atPath: path.path) else { return (ProjectSkillSyncManifest(), nil) }
    let data = try projectSyncReadFile(path, limit: 1_024 * 1_024).data
    return try projectSyncDecodedManifest(data)
}

private func projectSyncDecodedManifest(_ data: Data) throws -> (ProjectSkillSyncManifest, String?) {
    guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          Set(document.keys) == ["version", "skills"],
          let records = document["skills"] as? [String: [String: Any]],
          records.values.allSatisfy({ Set($0.keys) == ["collection", "contentHash"] }) else {
        throw projectSyncError("The ownership manifest has unknown fields. Preserve and reconcile it manually before syncing.")
    }
    let manifest = try JSONDecoder().decode(ProjectSkillSyncManifest.self, from: data)
    guard manifest.version == 1, manifest.skills.count <= projectSyncMaximumEntries,
          manifest.skills.allSatisfy({ projectSyncValidName($0.key) && $0.value.contentHash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil }) else {
        throw projectSyncError("The project ownership manifest is invalid or uses an unsupported version.")
    }
    return (manifest, projectSyncHash(data))
}

private func projectSyncManifest(in directory: ProjectSkillSyncDirectory) throws -> (ProjectSkillSyncManifest, String?) {
    guard try directory.metadata(projectSyncManifestName) != nil else { return (ProjectSkillSyncManifest(), nil) }
    return try projectSyncDecodedManifest(directory.read(projectSyncManifestName, limit: 1_024 * 1_024).data)
}

private func projectSyncEncodedManifest(_ manifest: ProjectSkillSyncManifest) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(manifest)
    guard manifest.skills.count <= projectSyncMaximumEntries, data.count <= 1_024 * 1_024 else {
        throw projectSyncError("The resulting project ownership manifest exceeds its bounded limits.")
    }
    return data
}

private func projectSyncManagedNames(in root: URL) throws -> Set<String> {
    // Preserve all external-manager state. Fail closed for legacy dotagents
    // declarations rather than relying on permissive TOML ownership parsing.
    for name in ["agents.toml", "agents.lock", ".agents/.skill-lock.json"] {
        let path = root.appendingPathComponent(name)
        if fileManager.fileExists(atPath: path.path) || isFilesystemSymlink(path) {
            throw projectSyncError("This project has legacy or external skill-manager declarations (\(name)). Reconcile ownership before syncing.")
        }
    }
    let lock = root.appendingPathComponent("skills-lock.json")
    guard isUnsymlinkedDescendant(lock, of: root) else {
        throw projectSyncError("The project's Skills CLI lock is linked.")
    }
    guard fileManager.fileExists(atPath: lock.path) else { return [] }
    let data = try projectSyncReadFile(lock, limit: 1_024 * 1_024).data
    return try projectSyncManagedNames(data: data)
}

private func projectSyncManagedNames(in project: ProjectSkillSyncDirectory, agents: ProjectSkillSyncDirectory) throws -> Set<String> {
    for name in ["agents.toml", "agents.lock"] {
        guard try project.metadata(name) == nil else {
            throw projectSyncError("This project has external skill-manager declarations (\(name)). Reconcile ownership before syncing.")
        }
    }
    guard try agents.metadata(".skill-lock.json") == nil else {
        throw projectSyncError("This project has external skill-manager declarations (.agents/.skill-lock.json). Reconcile ownership before syncing.")
    }
    guard try project.metadata("skills-lock.json") != nil else { return [] }
    return try projectSyncManagedNames(data: project.read("skills-lock.json", limit: 1_024 * 1_024).data)
}

private func projectSyncManagedNames(data: Data) throws -> Set<String> {
    guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let version = document["version"] as? Int, version == 1 else {
        throw projectSyncError("The project Skills CLI lock must use the supported version 1 format.")
    }
    return Set(try JSONDecoder().decode(SkillLock.self, from: data).skills.keys)
}

private func projectSyncBundle(
    at root: URL, screening: Bool,
    maximumBytes: Int = publicationMaximumBundleBytes
) throws -> ProjectSkillSyncBundle {
    guard !isFilesystemSymlink(root),
          (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
        throw projectSyncError("A physical skill bundle directory is required.")
    }
    return try projectSyncBundle(in: ProjectSkillSyncDirectory(root), screening: screening, maximumBytes: maximumBytes)
}

private func projectSyncBundle(
    in root: ProjectSkillSyncDirectory, screening: Bool,
    maximumBytes: Int = publicationMaximumBundleBytes
) throws -> ProjectSkillSyncBundle {
    var files: [ProjectSkillSyncBundle.File] = []
    var findings: [SkillPublishFinding] = []
    var entriesVisited = 0
    var bytes = 0
    func walk(_ directory: ProjectSkillSyncDirectory, prefix: String, depth: Int) throws {
        guard depth <= 32 else { throw projectSyncError("The skill bundle exceeds the directory depth limit.") }
        let names = try directory.names(limit: projectSyncMaximumEntries - entriesVisited)
        entriesVisited += names.count
        guard entriesVisited <= projectSyncMaximumEntries else {
            throw projectSyncError("The skill bundle exceeds the 4,096 entry limit.")
        }
        for name in names {
            let relative = prefix.isEmpty ? name : "\(prefix)/\(name)"
            // Finder metadata is not bundle content. Other added files,
            // including generated project notes, still block replacement.
            if !screening && name == ".DS_Store" { continue }
            if screening && publicationPathIsExcluded(relative) {
                findings.append(projectSyncFinding("excluded:\(relative)", path: relative,
                    message: "Generated or repository-local content is not copied.", severity: .warning))
                continue
            }
            guard let metadata = try directory.metadata(name) else {
                throw projectSyncError("A bundled entry disappeared while copying.")
            }
            if (metadata.st_mode & S_IFMT) == S_IFDIR {
                try walk(directory.child(name), prefix: relative, depth: depth + 1)
                continue
            }
            let file = try directory.read(name, limit: min(publicationMaximumFileBytes, maximumBytes - bytes))
            bytes += file.data.count
            guard bytes <= maximumBytes else {
                throw projectSyncError("The skill bundle exceeds the 50 MiB limit.")
            }
            files.append(.init(path: relative, data: file.data, permissions: file.permissions))
            if screening {
                inspectPublicationFileName(relative, findings: &findings)
                var contentFindings: [SkillPublishFinding] = []
                inspectPublicationContent(file.data, relativePath: relative, findings: &contentFindings)
                findings += contentFindings.map { finding in
                    guard finding.id.hasPrefix("personal-path:") else { return finding }
                    return projectSyncFinding(finding.id, path: relative,
                        message: "A machine-specific home path may not work in a cloud checkout. Instructions are copied without rewriting.", severity: .warning)
                }
                let text = String(decoding: file.data, as: UTF8.self)
                if text.range(of: #"(?:~|\$HOME|\$\{HOME\})/(?:\.agents|\.codex|\.claude)/skills(?:/|\b)"#, options: .regularExpression) != nil {
                    findings.append(projectSyncFinding("outside-skill-reference:\(relative)", path: relative,
                        message: "This file references global skills outside the copied bundle. Include its dependencies or adapt the instructions yourself.", severity: .warning))
                }
            }
        }
    }
    try walk(root, prefix: "", depth: 0)
    files.sort { $0.path < $1.path }
    guard let skill = files.first(where: { $0.path == "SKILL.md" }),
          let text = String(data: skill.data, encoding: .utf8), hasPublishableSkillFrontmatter(text) else {
        throw projectSyncError("A regular UTF-8 SKILL.md with name and description is required.")
    }
    if screening {
        let included = Set(files.map(\.path))
        for file in files where file.data.count <= 1_048_576 {
            guard let text = String(data: file.data, encoding: .utf8) else { continue }
            for reference in explicitSkillScriptPaths(in: text).sorted() where !included.contains(reference) {
                findings.append(projectSyncFinding("missing-script:\(file.path):\(reference)", path: file.path,
                    message: "Referenced script \(reference) is not in the copied bundle. It may be an outside dependency; include or adapt it before cloud use.", severity: .warning))
            }
        }
    }
    var hash = SHA256()
    for file in files {
        // Git preserves the owner executable bit, not full POSIX modes.
        // Ownership must survive e.g. a 0600 source becoming 0644 in a clone.
        let executable = (file.permissions & 0o100) == 0 ? 0 : 1
        hash.update(data: Data("\(file.path.utf8.count):\(file.path):\(file.data.count):\(executable):".utf8))
        hash.update(data: file.data)
    }
    return ProjectSkillSyncBundle(files: files, hash: hash.finalize().map { String(format: "%02x", $0) }.joined(), findings: findings)
}

/// O_NOFOLLOW and a bounded read prevent linked leafs and a file growing after
/// stat from bypassing the copy limit. No FIFOs, devices, or sockets are read.
private func projectSyncReadFile(_ path: URL, limit: Int) throws -> (data: Data, permissions: Int) {
    let descriptor = Darwin.open(path.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else { throw projectSyncError("A bundled file could not be opened safely.") }
    return try projectSyncReadFile(descriptor: descriptor, limit: limit)
}

func projectSyncReadFile(descriptor: CInt, limit: Int) throws -> (data: Data, permissions: Int) {
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG,
          metadata.st_size >= 0, metadata.st_size <= limit else {
        throw projectSyncError("Only regular files within the remaining byte budget can be copied (10 MiB maximum per file).")
    }
    var data = Data()
    while let chunk = try handle.read(upToCount: min(64 * 1_024, limit + 1 - data.count)), !chunk.isEmpty {
        data.append(chunk)
        guard data.count <= limit else { throw projectSyncError("A file grew beyond the copy limit.") }
    }
    guard (metadata.st_mode & 0o7000) == 0 else { throw projectSyncError("Special file permission bits are not copied.") }
    return (data, Int(metadata.st_mode & 0o777))
}

/// Advisory cross-process exclusion on the existing directory: no sidecar
/// files or Git state are created, and a busy project fails without waiting.
func withProjectSkillSyncLock<Result>(projectRoot: String,
    expectedIdentity: ProjectSkillSyncDirectoryIdentity? = nil,
    _ operation: () throws -> Result
) throws -> Result {
    try withProjectSkillSyncDirectoryLock(projectRoot: projectRoot, expectedIdentity: expectedIdentity) { _ in
        try operation()
    }
}

private func withProjectSkillSyncDirectoryLock<Result>(projectRoot: String,
    expectedIdentity: ProjectSkillSyncDirectoryIdentity?,
    _ operation: (ProjectSkillSyncDirectory) throws -> Result
) throws -> Result {
    let root = try projectSyncRoot(projectRoot)
    guard root.path == projectRoot else { throw projectSyncError("The project root changed after preview.") }
    let directory = try ProjectSkillSyncDirectory(root)
    if let expectedIdentity, try directory.identity != expectedIdentity {
        throw projectSyncError("The project directory changed after preview. Preview again; nothing was copied.")
    }
    guard flock(directory.descriptor, LOCK_EX | LOCK_NB) == 0 else {
        guard errno == EWOULDBLOCK || errno == EAGAIN else {
            throw projectSyncError("The project does not support a safe sync lock. Nothing was copied.")
        }
        throw projectSyncError("Another Metagent sync is active in this project. Try again after it finishes.")
    }
    defer { flock(directory.descriptor, LOCK_UN) }
    return try operation(directory)
}

func applyProjectSkillSyncTransaction(
    _ plan: ProjectSkillSyncPlan,
    beforeManifestCommit: (() throws -> Void)? = nil
) throws -> ProjectSkillSyncReport {
    try applyProjectSkillSyncTransaction(plan,
        in: ProjectSkillSyncDirectory(URL(fileURLWithPath: plan.projectRoot)), beforeManifestCommit: beforeManifestCommit)
}

private func applyProjectSkillSyncTransaction(
    _ plan: ProjectSkillSyncPlan,
    in projectDirectory: ProjectSkillSyncDirectory,
    beforeManifestCommit: (() throws -> Void)? = nil
) throws -> ProjectSkillSyncReport {
    let project = URL(fileURLWithPath: plan.projectRoot)
    guard try projectDirectory.identity == plan.projectIdentity,
          try projectSyncIdentity(project) == plan.projectIdentity else {
        throw projectSyncError("The project directory changed after preview. Preview again; nothing was copied.")
    }
    let agents = try projectDirectory.child(".agents", create: true)
    let skills = try agents.child("skills", create: true)
    let stageName = ".metagent-project-skills-\(UUID().uuidString)"
    let stage = try agents.child(stageName, create: true, mode: 0o700)
    let stageIdentity = try stage.identity
    var installed: [String] = []
    var backedUp: [String] = []
    var manifestCommitted = false
    var cleanup = true
    defer { if cleanup { try? agents.removeTree(stageName, expectedIdentity: stageIdentity) } }
    let staged = try stage.child("new", create: true)
    let backups = try stage.child("backup", create: true)
    func validateScope() throws {
        guard try projectSyncIdentity(project) == plan.projectIdentity,
              try agents.isNamed(".agents", in: projectDirectory), try skills.isNamed("skills", in: agents),
              try stage.isNamed(stageName, in: agents) else {
            throw projectSyncError("The project directories changed during copying. Preview again; replacement directories were not modified.")
        }
    }
    do {
        try validateScope()
        var (manifest, _) = try projectSyncManifest(in: agents)
        let global = try ProjectSkillSyncDirectory(URL(fileURLWithPath: plan.globalSkillsRoot))
        guard try global.identity == plan.globalIdentity else { throw projectSyncError("The source collection changed after preview.") }
        for item in plan.items where [.copy, .update].contains(item.action) {
            let bundle = try projectSyncBundle(in: global.child(item.name), screening: true)
            guard bundle.hash == item.sourceHash, !bundle.findings.contains(where: { $0.severity == .blocking }) else {
                throw projectSyncError("The source changed while preparing the copy. Preview again.")
            }
            let target = try staged.child(item.name, create: true)
            for file in bundle.files {
                try target.write(file.path, data: file.data, permissions: file.permissions)
            }
            manifest.skills[item.name] = .init(collection: plan.collection, contentHash: bundle.hash)
        }
        let rechecked = try MetagentCore.previewProjectSkillSync(
            projectRoot: plan.projectRoot, skillNames: plan.items.map(\.name), globalSkillsRoot: plan.globalSkillsRoot,
            collection: plan.collection
        )
        guard rechecked == plan else { throw projectSyncError("The source or project changed while preparing the copy. Preview again.") }
        try validateScope()
        for item in plan.items where [.copy, .update].contains(item.action) {
            try validateScope()
            if item.action == .update {
                guard try projectSyncBundle(in: skills.child(item.name), screening: false).hash == item.destinationHash else {
                    throw projectSyncError("A project skill changed before replacement.")
                }
                try skills.move(item.name, to: backups, as: item.name)
                backedUp.append(item.name)
                guard try projectSyncBundle(in: backups.child(item.name), screening: false).hash == item.destinationHash else {
                    throw projectSyncError("A project skill changed while moving it to recovery. Its changed content will be restored.")
                }
            }
            try staged.move(item.name, to: skills, as: item.name)
            installed.append(item.name)
        }
        guard try projectSyncManifest(in: agents).1 == plan.manifestHash else {
            throw projectSyncError("The ownership manifest changed during copying.")
        }
        try beforeManifestCommit?()
        try validateScope()
        guard try projectSyncManifest(in: agents).1 == plan.manifestHash else {
            throw projectSyncError("The ownership manifest changed before commit.")
        }
        let managedNames = try projectSyncManagedNames(in: projectDirectory, agents: agents)
        guard plan.items.allSatisfy({ !managedNames.contains($0.name) }) else {
            throw projectSyncError("A selected project skill became manager-owned during copying.")
        }
        let manifestData = try projectSyncEncodedManifest(manifest)
        try validateScope()
        try agents.writeAtomically(projectSyncManifestName, data: manifestData)
        manifestCommitted = true
        try validateScope()
        return ProjectSkillSyncReport(
            applied: true, plan: plan,
            copiedNames: plan.items.filter { $0.action == .copy }.map(\.name),
            updatedNames: plan.items.filter { $0.action == .update }.map(\.name)
        )
    } catch {
        if manifestCommitted {
            let location = agents.currentPath() ?? projectDirectory.currentPath() ?? plan.projectRoot
            throw projectSyncError("The copy committed to the original project directories, but their locations changed. Review \(location) before retrying.")
        }
        // No data is hard-deleted during rollback: our just-installed copies
        // return to staging before the original project bundles are restored.
        if !manifestCommitted {
            do {
                for name in installed.reversed() {
                    guard try projectSyncBundle(in: skills.child(name), screening: false).hash == plan.items.first(where: { $0.name == name })?.sourceHash else {
                        throw projectSyncError("A rollback path changed; retaining recovery content.")
                    }
                    try skills.move(name, to: staged, as: name)
                }
                for name in backedUp.reversed() {
                    try backups.move(name, to: skills, as: name)
                }
            } catch {
                cleanup = false
                let recovery = stage.currentPath() ?? "the retained project directory descriptor (\(stageName))"
                throw projectSyncError("Copying stopped; recovery bundles remain at \(recovery). Review the project before retrying.")
            }
        }
        throw error
    }
}

private func projectSyncHash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func projectSyncIdentity(_ directory: URL) throws -> ProjectSkillSyncDirectoryIdentity {
    let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw projectSyncError("A preview directory could not be opened safely.") }
    defer { Darwin.close(descriptor) }
    return try projectSyncIdentity(descriptor: descriptor)
}

func projectSyncIdentity(descriptor: CInt) throws -> ProjectSkillSyncDirectoryIdentity {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFDIR else {
        throw projectSyncError("A preview directory identity could not be read safely.")
    }
    return ProjectSkillSyncDirectoryIdentity(device: UInt64(truncatingIfNeeded: metadata.st_dev), inode: UInt64(metadata.st_ino))
}

private func projectSyncDirectoryNames(_ directory: URL, limit: Int) throws -> [String] {
    guard let handle = opendir(directory.path) else { throw projectSyncError("A bundle directory could not be read.") }
    defer { closedir(handle) }
    var names: [String] = []
    errno = 0
    while let entry = readdir(handle) {
        let name = withUnsafePointer(to: &entry.pointee.d_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
        }
        if name == "." || name == ".." { continue }
        guard names.count < limit else { throw projectSyncError("The directory exceeds the bounded entry limit.") }
        names.append(name)
        errno = 0
    }
    guard errno == 0 else { throw projectSyncError("A directory changed or could not be read completely.") }
    return names.sorted()
}

private func projectSyncFinding(_ id: String, path: String? = nil, message: String,
                                severity: SkillPublishFindingSeverity = .blocking) -> SkillPublishFinding {
    SkillPublishFinding(id: id, severity: severity, relativePath: path,
                        message: message, remediation: "Review the selected bundle and project before copying.")
}

func projectSyncError(_ message: String) -> NSError {
    NSError(domain: "MetagentProjectSkillSync", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}
