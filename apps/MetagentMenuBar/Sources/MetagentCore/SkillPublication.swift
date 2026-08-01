import CryptoKit
import Foundation

public enum SkillPublishReadinessStatus: String, Codable, Sendable {
    case ready
    case blocked
    case incomplete
}

public enum SkillPublishFindingSeverity: String, Codable, Sendable {
    case warning
    case blocking
}

public struct SkillPublishFinding: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let severity: SkillPublishFindingSeverity
    public let relativePath: String?
    public let message: String
    public let remediation: String

    public init(
        id: String,
        severity: SkillPublishFindingSeverity,
        relativePath: String?,
        message: String,
        remediation: String
    ) {
        self.id = id
        self.severity = severity
        self.relativePath = relativePath
        self.message = message
        self.remediation = remediation
    }
}

public struct SkillPublishReadiness: Codable, Equatable, Sendable {
    public let status: SkillPublishReadinessStatus
    public let sourceHash: String?
    public let findings: [SkillPublishFinding]

    public init(
        status: SkillPublishReadinessStatus,
        sourceHash: String?,
        findings: [SkillPublishFinding]
    ) {
        self.status = status
        self.sourceHash = sourceHash
        self.findings = findings
    }
}

public enum SkillPublicationState: String, Codable, Sendable {
    case mirrored
    case updateBlocked = "update_blocked"
    case sourceMissing = "source_missing"
    case repositoryMissing = "repository_missing"
    case disabled
}

public struct SkillPublicationCatalog: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let localRepositoryPath: String
    public let skillsRelativePath: String
    public let remoteURL: String?

    public init(
        id: String,
        localRepositoryPath: String,
        skillsRelativePath: String = "skills",
        remoteURL: String? = nil
    ) {
        self.id = id
        self.localRepositoryPath = localRepositoryPath
        self.skillsRelativePath = skillsRelativePath
        self.remoteURL = remoteURL
    }
}

public struct SkillPublicationRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let sourceCanonicalPath: String
    public let skillName: String
    public let catalogID: String
    public let destinationName: String
    public var automaticMirroringEnabled: Bool
    public var state: SkillPublicationState
    public var lastMirroredHash: String?
    public var lastMirroredAt: Date?
    public var lastError: String?
    public var findings: [SkillPublishFinding]

    public init(
        id: String,
        sourceCanonicalPath: String,
        skillName: String,
        catalogID: String,
        destinationName: String,
        automaticMirroringEnabled: Bool = true,
        state: SkillPublicationState = .disabled,
        lastMirroredHash: String? = nil,
        lastMirroredAt: Date? = nil,
        lastError: String? = nil,
        findings: [SkillPublishFinding] = []
    ) {
        self.id = id
        self.sourceCanonicalPath = sourceCanonicalPath
        self.skillName = skillName
        self.catalogID = catalogID
        self.destinationName = destinationName
        self.automaticMirroringEnabled = automaticMirroringEnabled
        self.state = state
        self.lastMirroredHash = lastMirroredHash
        self.lastMirroredAt = lastMirroredAt
        self.lastError = lastError
        self.findings = findings
    }
}

public struct SkillPublicationSnapshot: Codable, Equatable, Sendable {
    public static let version = 1

    public let version: Int
    public var catalogs: [SkillPublicationCatalog]
    public var records: [SkillPublicationRecord]

    public init(
        catalogs: [SkillPublicationCatalog] = [],
        records: [SkillPublicationRecord] = []
    ) {
        self.version = Self.version
        self.catalogs = catalogs
        self.records = records
    }

    public static let empty = SkillPublicationSnapshot()
}

public struct SkillPublicationReconcileReport: Equatable, Sendable {
    public let snapshot: SkillPublicationSnapshot
    public let mirroredRecordIDs: [String]
    public let blockedRecordIDs: [String]

    public init(
        snapshot: SkillPublicationSnapshot,
        mirroredRecordIDs: [String],
        blockedRecordIDs: [String]
    ) {
        self.snapshot = snapshot
        self.mirroredRecordIDs = mirroredRecordIDs
        self.blockedRecordIDs = blockedRecordIDs
    }
}

private struct SkillPublicationFile {
    let relativePath: String
    let sourceURL: URL
    let permissions: NSNumber?
    let byteCount: Int64
}

public extension MetagentCore {
    static func loadSkillPublicationSnapshot(path: URL? = nil) -> SkillPublicationSnapshot {
        let url = path ?? skillPublicationStorePath()
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? skillPublicationDecoder().decode(
                SkillPublicationSnapshot.self,
                from: data
              ),
              snapshot.version == SkillPublicationSnapshot.version
        else {
            return .empty
        }
        return snapshot
    }

    private static func loadSkillPublicationSnapshotForMutation(
        path: URL? = nil
    ) throws -> SkillPublicationSnapshot {
        let url = path ?? skillPublicationStorePath()
        guard fileManager.fileExists(atPath: url.path) else { return .empty }

        do {
            let data = try Data(contentsOf: url)
            let snapshot = try skillPublicationDecoder().decode(
                SkillPublicationSnapshot.self,
                from: data
            )
            guard snapshot.version == SkillPublicationSnapshot.version else {
                throw publicationError(
                    "Publication settings use an unsupported version (\(snapshot.version))."
                )
            }
            return snapshot
        } catch {
            let recoveryURL = url.appendingPathExtension("unreadable")
            if !fileManager.fileExists(atPath: recoveryURL.path) {
                try? fileManager.copyItem(at: url, to: recoveryURL)
            }
            throw publicationError(
                "Publication settings could not be read, so Metagent left them unchanged. "
                    + "A recovery copy is at \(recoveryURL.path). \(error.localizedDescription)"
            )
        }
    }

    static func saveSkillPublicationSnapshot(
        _ snapshot: SkillPublicationSnapshot,
        path: URL? = nil
    ) throws {
        let url = path ?? skillPublicationStorePath()
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try skillPublicationEncoder().encode(snapshot).write(to: url, options: .atomic)
    }

    /// Enables continuous one-way local mirroring for one canonical skill.
    /// This never commits, pushes, changes repository visibility, or contacts GitHub.
    static func enableSkillPublication(
        sourcePath: String,
        skillName: String,
        repositoryPath: String,
        destinationName: String? = nil,
        remoteURL: String? = nil,
        storePath: URL? = nil,
        now: Date = Date()
    ) throws -> SkillPublicationReconcileReport {
        let source = URL(fileURLWithPath: sourcePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let repository = URL(fileURLWithPath: repositoryPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let destination = destinationName ?? source.lastPathComponent
        guard isValidPublicationName(destination) else {
            throw publicationError(
                "Use a lowercase skill destination containing only letters, numbers, and hyphens."
            )
        }

        var snapshot = try loadSkillPublicationSnapshotForMutation(path: storePath)
        let catalogID = publicationCatalogID(repository.path)
        if let index = snapshot.catalogs.firstIndex(where: { $0.id == catalogID }) {
            let existing = snapshot.catalogs[index]
            snapshot.catalogs[index] = SkillPublicationCatalog(
                id: existing.id,
                localRepositoryPath: existing.localRepositoryPath,
                skillsRelativePath: existing.skillsRelativePath,
                remoteURL: remoteURL ?? existing.remoteURL
            )
        } else {
            snapshot.catalogs.append(SkillPublicationCatalog(
                id: catalogID,
                localRepositoryPath: repository.path,
                remoteURL: remoteURL
            ))
        }

        let recordID = publicationRecordID(
            sourcePath: source.path,
            catalogID: catalogID,
            destinationName: destination
        )
        let previous = snapshot.records.first { $0.id == recordID }
        let record = SkillPublicationRecord(
            id: recordID,
            sourceCanonicalPath: source.path,
            skillName: skillName,
            catalogID: catalogID,
            destinationName: destination,
            automaticMirroringEnabled: true,
            state: previous?.state ?? .disabled,
            lastMirroredHash: previous?.lastMirroredHash,
            lastMirroredAt: previous?.lastMirroredAt,
            lastError: previous?.lastError,
            findings: previous?.findings ?? []
        )
        if let index = snapshot.records.firstIndex(where: { $0.id == recordID }) {
            snapshot.records[index] = record
        } else {
            snapshot.records.append(record)
        }
        try saveSkillPublicationSnapshot(snapshot, path: storePath)
        return try reconcileSkillPublications(storePath: storePath, now: now)
    }

    /// Stops watching without deleting the public copy. Removing a public
    /// bundle is an explicit unpublish operation, not a mirroring side effect.
    static func disableSkillPublication(
        recordID: String,
        storePath: URL? = nil
    ) throws -> SkillPublicationSnapshot {
        var snapshot = try loadSkillPublicationSnapshotForMutation(path: storePath)
        guard let index = snapshot.records.firstIndex(where: { $0.id == recordID }) else {
            return snapshot
        }
        snapshot.records[index].automaticMirroringEnabled = false
        snapshot.records[index].state = .disabled
        snapshot.records[index].lastError = nil
        try saveSkillPublicationSnapshot(snapshot, path: storePath)
        return snapshot
    }

    /// Reconciles all selected skills after launch, manual refresh, or one
    /// coalesced filesystem event. A blocked candidate never replaces the last
    /// safe public copy.
    static func reconcileSkillPublications(
        storePath: URL? = nil,
        now: Date = Date()
    ) throws -> SkillPublicationReconcileReport {
        var snapshot = try loadSkillPublicationSnapshotForMutation(path: storePath)
        var mirrored: [String] = []
        var blocked: [String] = []
        let destinationCounts = Dictionary(
            grouping: snapshot.records.filter(\.automaticMirroringEnabled),
            by: { "\($0.catalogID)\u{1f}\($0.destinationName)" }
        ).mapValues(\.count)

        for index in snapshot.records.indices {
            guard snapshot.records[index].automaticMirroringEnabled else { continue }
            let record = snapshot.records[index]
            let destinationKey = "\(record.catalogID)\u{1f}\(record.destinationName)"
            if destinationCounts[destinationKey, default: 0] > 1 {
                let finding = publicationFinding(
                    id: "destination-collision",
                    message: "More than one canonical skill targets this public destination.",
                    remediation: "Choose a unique destination name for each selected skill."
                )
                snapshot.records[index].state = .updateBlocked
                snapshot.records[index].findings = [finding]
                snapshot.records[index].lastError = finding.message
                blocked.append(record.id)
                continue
            }
            guard let catalog = snapshot.catalogs.first(where: { $0.id == record.catalogID }) else {
                snapshot.records[index].state = .repositoryMissing
                snapshot.records[index].lastError = "The configured publication catalog is missing."
                blocked.append(record.id)
                continue
            }
            let source = URL(fileURLWithPath: record.sourceCanonicalPath)
            guard fileManager.fileExists(atPath: source.path) else {
                snapshot.records[index].state = .sourceMissing
                snapshot.records[index].lastError = "The canonical skill is missing; the public copy was retained."
                blocked.append(record.id)
                continue
            }

            let repository = URL(fileURLWithPath: catalog.localRepositoryPath)
            let readiness = assessSkillPublicationReadiness(
                sourcePath: source.path,
                repositoryPath: repository.path,
                skillsRelativePath: catalog.skillsRelativePath,
                destinationName: record.destinationName
            )
            snapshot.records[index].findings = readiness.findings
            guard readiness.status == .ready, let sourceHash = readiness.sourceHash else {
                snapshot.records[index].state = .updateBlocked
                snapshot.records[index].lastError = readiness.findings.first {
                    $0.severity == .blocking
                }?.message ?? "Publication readiness is incomplete."
                blocked.append(record.id)
                continue
            }

            let destination = repository
                .appendingPathComponent(catalog.skillsRelativePath, isDirectory: true)
                .appendingPathComponent(record.destinationName, isDirectory: true)
            let destinationHash = publicationDirectoryHash(destination)
            if snapshot.records[index].lastMirroredHash != sourceHash
                || destinationHash != sourceHash
            {
                do {
                    try mirrorSkillPublication(
                        source: source,
                        repository: repository,
                        skillsRelativePath: catalog.skillsRelativePath,
                        destinationName: record.destinationName
                    )
                    snapshot.records[index].lastMirroredHash = sourceHash
                    snapshot.records[index].lastMirroredAt = now
                    mirrored.append(record.id)
                } catch {
                    snapshot.records[index].state = .updateBlocked
                    snapshot.records[index].lastError = error.localizedDescription
                    blocked.append(record.id)
                    continue
                }
            }
            snapshot.records[index].state = .mirrored
            snapshot.records[index].lastError = nil
        }

        snapshot.catalogs.sort { $0.localRepositoryPath < $1.localRepositoryPath }
        snapshot.records.sort {
            if $0.skillName != $1.skillName { return $0.skillName < $1.skillName }
            return $0.sourceCanonicalPath < $1.sourceCanonicalPath
        }
        try saveSkillPublicationSnapshot(snapshot, path: storePath)
        return SkillPublicationReconcileReport(
            snapshot: snapshot,
            mirroredRecordIDs: mirrored.sorted(),
            blockedRecordIDs: blocked.sorted()
        )
    }

    static func assessSkillPublicationReadiness(
        sourcePath: String,
        repositoryPath: String,
        skillsRelativePath: String = "skills",
        destinationName: String
    ) -> SkillPublishReadiness {
        let source = URL(fileURLWithPath: sourcePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let repository = URL(fileURLWithPath: repositoryPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        var findings: [SkillPublishFinding] = []

        guard fileManager.fileExists(atPath: source.path) else {
            return SkillPublishReadiness(
                status: .incomplete,
                sourceHash: nil,
                findings: [publicationFinding(
                    id: "source-missing",
                    message: "The canonical skill folder is missing.",
                    remediation: "Restore the canonical skill before publishing."
                )]
            )
        }
        guard isValidPublicationName(destinationName),
              isSafeRelativePublicationPath(skillsRelativePath)
        else {
            return SkillPublishReadiness(
                status: .blocked,
                sourceHash: nil,
                findings: [publicationFinding(
                    id: "unsafe-destination",
                    message: "The publication destination is not a safe relative skill path.",
                    remediation: "Use a lowercase skill name and a repository-relative skills directory."
                )]
            )
        }

        if pathsOverlap(source, repository) {
            findings.append(publicationFinding(
                id: "overlapping-roots",
                message: "The canonical skill and public repository must not contain one another.",
                remediation: "Choose a separate public repository checkout."
            ))
        }
        if !fileManager.fileExists(atPath: repository.path)
            || !fileManager.fileExists(atPath: repository.appendingPathComponent(".git").path)
        {
            findings.append(publicationFinding(
                id: "repository-missing",
                message: "The publication destination is not a Git checkout.",
                remediation: "Choose an existing public repository checkout."
            ))
        }

        let skillFile = source.appendingPathComponent("SKILL.md")
        if !isRegularPublicationFile(skillFile) {
            findings.append(publicationFinding(
                id: "skill-file-missing",
                relativePath: "SKILL.md",
                message: "A regular SKILL.md file is required.",
                remediation: "Add a valid SKILL.md file to the canonical skill."
            ))
        } else if let text = try? String(contentsOf: skillFile, encoding: .utf8),
                  !hasPublishableSkillFrontmatter(text)
        {
            findings.append(publicationFinding(
                id: "invalid-frontmatter",
                relativePath: "SKILL.md",
                message: "SKILL.md needs YAML frontmatter with name and description.",
                remediation: "Add name and description fields inside the opening frontmatter block."
            ))
        }

        let files: [SkillPublicationFile]
        do {
            files = try publicationFiles(in: source, findings: &findings)
        } catch {
            findings.append(publicationFinding(
                id: "bundle-unreadable",
                message: "The skill bundle could not be read safely.",
                remediation: "Fix unreadable files and retry."
            ))
            return SkillPublishReadiness(status: .incomplete, sourceHash: nil, findings: findings)
        }
        if let scriptInventory = try? inventorySkillScripts(path: source.path) {
            for missing in scriptInventory.missingReferences {
                findings.append(publicationFinding(
                    id: "missing-script:\(missing.relativePath)",
                    relativePath: missing.relativePath,
                    message: "A referenced bundled script is missing.",
                    remediation: "Bundle the script or remove the stale reference."
                ))
            }
        }
        let sourceHash = publicationContentHash(files)
        let status: SkillPublishReadinessStatus = findings.contains {
            $0.severity == .blocking
        } ? .blocked : .ready
        return SkillPublishReadiness(
            status: status,
            sourceHash: status == .ready ? sourceHash : nil,
            findings: findings.sorted {
                ($0.relativePath ?? "", $0.id) < ($1.relativePath ?? "", $1.id)
            }
        )
    }
}

private func mirrorSkillPublication(
    source: URL,
    repository: URL,
    skillsRelativePath: String,
    destinationName: String
) throws {
    var findings: [SkillPublishFinding] = []
    let files = try publicationFiles(in: source, findings: &findings)
    guard !findings.contains(where: { $0.severity == .blocking }) else {
        throw publicationError("The candidate changed after readiness validation.")
    }

    let skillsRoot = repository.appendingPathComponent(skillsRelativePath, isDirectory: true)
    try fileManager.createDirectory(at: skillsRoot, withIntermediateDirectories: true)
    let stage = skillsRoot.appendingPathComponent(".metagent-stage-\(UUID().uuidString)")
    let backup = skillsRoot.appendingPathComponent(".metagent-backup-\(UUID().uuidString)")
    let destination = skillsRoot.appendingPathComponent(destinationName, isDirectory: true)
    try fileManager.createDirectory(at: stage, withIntermediateDirectories: true)
    var movedDestinationToBackup = false
    defer {
        try? fileManager.removeItem(at: stage)
        if movedDestinationToBackup, fileManager.fileExists(atPath: backup.path) {
            try? fileManager.removeItem(at: backup)
        }
    }

    for file in files {
        let target = stage.appendingPathComponent(file.relativePath)
        try fileManager.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.copyItem(at: file.sourceURL, to: target)
        if let permissions = file.permissions {
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
        }
    }

    do {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.moveItem(at: destination, to: backup)
            movedDestinationToBackup = true
        }
        try fileManager.moveItem(at: stage, to: destination)
        if movedDestinationToBackup {
            if (try? fileManager.removeItem(at: backup)) != nil {
                movedDestinationToBackup = false
            }
        }
    } catch {
        if movedDestinationToBackup,
           !fileManager.fileExists(atPath: destination.path),
           fileManager.fileExists(atPath: backup.path)
        {
            try? fileManager.moveItem(at: backup, to: destination)
            movedDestinationToBackup = false
        }
        throw publicationError("Could not update the public checkout safely: \(error.localizedDescription)")
    }
}

private func publicationFiles(
    in root: URL,
    findings: inout [SkillPublishFinding]
) throws -> [SkillPublicationFile] {
    var files: [SkillPublicationFile] = []
    var totalBytes: Int64 = 0
    try collectPublicationFiles(
        directory: root,
        relativeDirectory: "",
        files: &files,
        totalBytes: &totalBytes,
        findings: &findings
    )
    if totalBytes > 50 * 1_024 * 1_024 {
        findings.append(publicationFinding(
            id: "bundle-too-large",
            message: "The skill bundle is larger than 50 MB.",
            remediation: "Remove generated or unnecessary large files before publishing."
        ))
    }
    return files.sorted { $0.relativePath < $1.relativePath }
}

private func collectPublicationFiles(
    directory: URL,
    relativeDirectory: String,
    files: inout [SkillPublicationFile],
    totalBytes: inout Int64,
    findings: inout [SkillPublishFinding]
) throws {
    let entries = try fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ],
        options: []
    ).sorted { $0.lastPathComponent < $1.lastPathComponent }

    for entry in entries {
        let name = entry.lastPathComponent
        let relativePath = relativeDirectory.isEmpty
            ? name
            : "\(relativeDirectory)/\(name)"
        if publicationSkippedNames.contains(name) {
            findings.append(SkillPublishFinding(
                id: "excluded-generated-content:\(relativePath)",
                severity: .warning,
                relativePath: relativePath,
                message: "Generated or repository-local content is excluded from publication.",
                remediation: "No action is needed unless this file is part of the skill."
            ))
            continue
        }
        if isFilesystemSymlink(entry) {
            findings.append(publicationFinding(
                id: "symlink:\(relativePath)",
                relativePath: relativePath,
                message: "Symlinks are not safe publication inputs.",
                remediation: "Replace the link with a bundled regular file or directory."
            ))
            continue
        }
        let values = try entry.resourceValues(forKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .fileSizeKey,
        ])
        if values.isDirectory == true {
            try collectPublicationFiles(
                directory: entry,
                relativeDirectory: relativePath,
                files: &files,
                totalBytes: &totalBytes,
                findings: &findings
            )
            continue
        }
        guard values.isRegularFile == true else {
            findings.append(publicationFinding(
                id: "special-file:\(relativePath)",
                relativePath: relativePath,
                message: "Only regular files can be published.",
                remediation: "Remove the special file from the skill bundle."
            ))
            continue
        }
        if publicationSecretFileNames.contains(name.lowercased())
            || publicationSecretExtensions.contains(entry.pathExtension.lowercased())
        {
            findings.append(publicationFinding(
                id: "secret-file:\(relativePath)",
                relativePath: relativePath,
                message: "This file name commonly contains credentials.",
                remediation: "Remove the file and rotate any credential it contained."
            ))
        }

        let byteCount = Int64(values.fileSize ?? 0)
        totalBytes += byteCount
        if byteCount > 10 * 1_024 * 1_024 {
            findings.append(publicationFinding(
                id: "large-file:\(relativePath)",
                relativePath: relativePath,
                message: "A bundled file is larger than 10 MB.",
                remediation: "Remove or replace the large file before publishing."
            ))
        }
        let attributes = try? fileManager.attributesOfItem(atPath: entry.path)
        let permissions = attributes?[.posixPermissions] as? NSNumber
        files.append(SkillPublicationFile(
            relativePath: relativePath,
            sourceURL: entry,
            permissions: permissions,
            byteCount: byteCount
        ))
        inspectPublicationTextFile(entry, relativePath: relativePath, findings: &findings)
    }
}

private func inspectPublicationTextFile(
    _ file: URL,
    relativePath: String,
    findings: inout [SkillPublishFinding]
) {
    guard let handle = try? FileHandle(forReadingFrom: file) else { return }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: 1_048_576) else { return }
    let text = String(decoding: data, as: UTF8.self)

    if containsPublicationPersonalPath(text) {
        findings.append(publicationFinding(
            id: "personal-path:\(relativePath)",
            relativePath: relativePath,
            message: "The file contains a user-home path.",
            remediation: "Use ~ in prose, $HOME in scripts, or a native home-directory API."
        ))
    }
    if publicationSecretPatterns.contains(where: {
        text.range(of: $0, options: .regularExpression) != nil
    }) {
        findings.append(publicationFinding(
            id: "secret-literal:\(relativePath)",
            relativePath: relativePath,
            message: "The file appears to contain a credential or private key.",
            remediation: "Remove and rotate the credential; document an environment variable instead."
        ))
    }
}

private func publicationContentHash(_ files: [SkillPublicationFile]) -> String {
    var hash = SHA256()
    for file in files {
        let data = (try? Data(contentsOf: file.sourceURL)) ?? Data()
        var pathLength = UInt64(file.relativePath.utf8.count).bigEndian
        var dataLength = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &pathLength) { hash.update(data: Data($0)) }
        hash.update(data: Data(file.relativePath.utf8))
        withUnsafeBytes(of: &dataLength) { hash.update(data: Data($0)) }
        hash.update(data: data)
        var permissions = UInt64(file.permissions?.uint64Value ?? 0).bigEndian
        withUnsafeBytes(of: &permissions) { hash.update(data: Data($0)) }
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

private func publicationDirectoryHash(_ directory: URL) -> String? {
    guard fileManager.fileExists(atPath: directory.path) else { return nil }
    var findings: [SkillPublishFinding] = []
    guard let files = try? publicationFiles(in: directory, findings: &findings),
          !findings.contains(where: { $0.severity == .blocking })
    else {
        return nil
    }
    return publicationContentHash(files)
}

private func hasPublishableSkillFrontmatter(_ text: String) -> Bool {
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
    let lines = normalized.components(separatedBy: "\n")
    guard lines.first == "---",
          let end = lines.dropFirst().firstIndex(of: "---")
    else { return false }
    let frontmatter = lines[1..<end]
    return frontmatter.contains { $0.range(of: #"^name\s*:"#, options: .regularExpression) != nil }
        && frontmatter.contains {
            $0.range(of: #"^description\s*:"#, options: .regularExpression) != nil
        }
}

private func containsPublicationPersonalPath(_ text: String) -> Bool {
    let home = homeURL().standardizedFileURL.path
    if !home.isEmpty, text.contains(home) { return true }
    let patterns = [
        #"/Users/[A-Za-z0-9._-]+(?:/|(?=[^A-Za-z0-9._-]|$))"#,
        #"/home/[A-Za-z0-9._-]+(?:/|(?=[^A-Za-z0-9._-]|$))"#,
        #"[A-Za-z]:\\Users\\[A-Za-z0-9._-]+(?:\\|(?=[^A-Za-z0-9._-]|$))"#,
    ]
    return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
}

private func pathsOverlap(_ left: URL, _ right: URL) -> Bool {
    let leftPath = left.standardizedFileURL.path
    let rightPath = right.standardizedFileURL.path
    return leftPath == rightPath
        || leftPath.hasPrefix(rightPath + "/")
        || rightPath.hasPrefix(leftPath + "/")
}

private func isRegularPublicationFile(_ url: URL) -> Bool {
    guard !isFilesystemSymlink(url) else { return false }
    return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
}

private func isValidPublicationName(_ value: String) -> Bool {
    value.range(of: #"^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$"#, options: .regularExpression) != nil
}

private func isSafeRelativePublicationPath(_ value: String) -> Bool {
    guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\") else { return false }
    let components = value.split(separator: "/", omittingEmptySubsequences: false)
    return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
}

private func publicationCatalogID(_ repositoryPath: String) -> String {
    Data(SHA256.hash(data: Data(repositoryPath.utf8))).base64EncodedString()
}

private func publicationRecordID(
    sourcePath: String,
    catalogID: String,
    destinationName: String
) -> String {
    let identity = "\(sourcePath)\u{1f}\(catalogID)\u{1f}\(destinationName)"
    return Data(SHA256.hash(data: Data(identity.utf8))).base64EncodedString()
}

private func publicationFinding(
    id: String,
    relativePath: String? = nil,
    message: String,
    remediation: String
) -> SkillPublishFinding {
    SkillPublishFinding(
        id: id,
        severity: .blocking,
        relativePath: relativePath,
        message: message,
        remediation: remediation
    )
}

private func skillPublicationStorePath() -> URL {
    homeURL().appendingPathComponent(
        "Library/Application Support/Metagent/skill-publications-v1.json"
    )
}

private func skillPublicationEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}

private func skillPublicationDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}

private func publicationError(_ message: String) -> NSError {
    NSError(
        domain: "MetagentSkillPublication",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: message]
    )
}

private let publicationSkippedNames: Set<String> = [
    ".DS_Store",
    ".git",
    ".build",
    ".cache",
    "__pycache__",
    "node_modules",
]

private let publicationSecretFileNames: Set<String> = [
    ".env",
    ".env.local",
    ".netrc",
    "id_dsa",
    "id_ed25519",
    "id_rsa",
]

private let publicationSecretExtensions: Set<String> = ["key", "p12", "pfx", "pem"]

private let publicationSecretPatterns = [
    #"-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----"#,
    #"\b(?:AKIA[0-9A-Z]{16}|github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9_-]{20,})\b"#,
    #"(?i)\b(?:password|secret|token|api[_-]?key)\s*[:=]\s*[\"']?[A-Za-z0-9+/=_-]{20,}"#,
    #"[A-Za-z][A-Za-z0-9+.-]*://[^/\s:@]+:[^@\s/]+@"#,
]
