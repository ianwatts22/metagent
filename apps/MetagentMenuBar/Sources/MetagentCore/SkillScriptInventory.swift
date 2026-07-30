import CryptoKit
import Darwin
import Foundation

public enum SkillScriptContainment: String, Codable, Equatable, Sendable {
    case bundled
    case bundledSymlink = "bundled_symlink"
    case escapesBundle = "escapes_bundle"
    case brokenSymlink = "broken_symlink"
}

public enum SkillScriptRole: String, Codable, Equatable, Sendable {
    case entryPoint = "entry_point"
    case helper
    case test
    case example
    case generator
    case unknown
}

public struct SkillScriptItem: Codable, Equatable, Identifiable, Sendable {
    public var id: String { relativePath }
    public let relativePath: String
    public let runtime: String
    public let runtimeEvidence: [String]
    public let role: SkillScriptRole
    public let executable: Bool
    public let byteCount: Int
    public let sha256: String?
    public let symlink: Bool
    public let containment: SkillScriptContainment
    public let referencedBy: [String]
    public let warnings: [String]

    private enum CodingKeys: String, CodingKey {
        case relativePath = "relative_path"
        case runtime
        case runtimeEvidence = "runtime_evidence"
        case role
        case executable
        case byteCount = "byte_count"
        case sha256
        case symlink
        case containment
        case referencedBy = "referenced_by"
        case warnings
    }
}

public struct MissingSkillScriptReference: Codable, Equatable, Identifiable, Sendable {
    public var id: String { relativePath }
    public let relativePath: String
    public let referencedBy: [String]

    private enum CodingKeys: String, CodingKey {
        case relativePath = "relative_path"
        case referencedBy = "referenced_by"
    }
}

public struct SkillScriptInventory: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let scripts: [SkillScriptItem]
    public let missingReferences: [MissingSkillScriptReference]
    public let warnings: [String]

    public init(
        scripts: [SkillScriptItem],
        missingReferences: [MissingSkillScriptReference] = [],
        warnings: [String] = []
    ) {
        self.schemaVersion = Self.schemaVersion
        self.scripts = scripts
        self.missingReferences = missingReferences
        self.warnings = warnings
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case scripts
        case missingReferences = "missing_references"
        case warnings
    }
}

public extension MetagentCore {
    /// Inspects files bundled with a skill. It never imports, lints, or executes
    /// script content, and never returns an absolute path from inside a script.
    static func inventorySkillScripts(path: String) throws -> SkillScriptInventory {
        let directory = try resolveSkillDirectory(path)
        return scanSkillScripts(in: directory)
    }
}

private struct SkillScriptCandidate {
    let relativePath: String
    let readableURL: URL?
    let symlink: Bool
    let containment: SkillScriptContainment
}

private struct SkillScriptReferenceIndex {
    var referencedBy: [String: Set<String>] = [:]

    mutating func add(scriptPath: String, sourcePath: String) {
        referencedBy[scriptPath, default: []].insert(sourcePath)
    }
}

func scanSkillScripts(in skillDirectory: URL) -> SkillScriptInventory {
    let root = skillDirectory.standardizedFileURL
    var warnings: [String] = []
    let references = skillScriptReferences(in: root, warnings: &warnings)
    let candidates = skillScriptCandidates(in: root, warnings: &warnings)
    let candidatePaths = Set(candidates.map(\.relativePath))

    let scripts = candidates.map { candidate in
        makeSkillScriptItem(
            candidate,
            root: root,
            references: references.referencedBy[candidate.relativePath] ?? []
        )
    }.sorted { $0.relativePath < $1.relativePath }

    let missing = references.referencedBy.keys
        .filter { !candidatePaths.contains($0) }
        .sorted()
        .map {
            MissingSkillScriptReference(
                relativePath: $0,
                referencedBy: Array(references.referencedBy[$0] ?? []).sorted()
            )
        }

    warnings.append(contentsOf: missing.map {
        "Referenced script is missing: \($0.relativePath)"
    })

    return SkillScriptInventory(
        scripts: scripts,
        missingReferences: missing,
        warnings: Array(Set(warnings)).sorted()
    )
}

private func skillScriptCandidates(
    in root: URL,
    warnings: inout [String]
) -> [SkillScriptCandidate] {
    let scriptsDirectory = root.appendingPathComponent("scripts")
    guard fileManager.fileExists(atPath: scriptsDirectory.path)
        || isFilesystemSymlink(scriptsDirectory)
    else {
        return []
    }
    if isFilesystemSymlink(scriptsDirectory) {
        warnings.append("The scripts directory is a symlink and was not traversed.")
        return []
    }

    var candidates: [SkillScriptCandidate] = []
    collectSkillScriptCandidates(
        directory: scriptsDirectory,
        relativeDirectory: "scripts",
        root: root,
        candidates: &candidates,
        warnings: &warnings
    )
    return candidates
}

private func collectSkillScriptCandidates(
    directory: URL,
    relativeDirectory: String,
    root: URL,
    candidates: inout [SkillScriptCandidate],
    warnings: inout [String]
) {
    guard let entries = try? fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
        options: [.skipsPackageDescendants]
    ) else {
        warnings.append("A scripts directory could not be read.")
        return
    }

    for entry in entries.sorted(by: { $0.path < $1.path }) {
        let relativePath = "\(relativeDirectory)/\(entry.lastPathComponent)"
        if isFilesystemSymlink(entry) {
            let target = resolvedSymlinkTarget(entry)
            let containment: SkillScriptContainment
            let readableURL: URL?
            if let target, fileManager.fileExists(atPath: target.path) {
                if skillBundleContains(root: root, path: target) {
                    containment = .bundledSymlink
                    readableURL = target
                } else {
                    containment = .escapesBundle
                    readableURL = nil
                }
            } else {
                containment = .brokenSymlink
                readableURL = nil
            }

            let targetIsDirectory = target.flatMap {
                try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory
            } ?? false
            if targetIsDirectory {
                warnings.append("\(relativePath): symlinked directories are not traversed.")
                continue
            }
            candidates.append(SkillScriptCandidate(
                relativePath: relativePath,
                readableURL: readableURL,
                symlink: true,
                containment: containment
            ))
            continue
        }

        if isDirectoryOrSymlinkedDirectory(entry) {
            collectSkillScriptCandidates(
                directory: entry,
                relativeDirectory: relativePath,
                root: root,
                candidates: &candidates,
                warnings: &warnings
            )
        } else if isRegularOrSymlinkedFile(entry) {
            candidates.append(SkillScriptCandidate(
                relativePath: relativePath,
                readableURL: entry,
                symlink: false,
                containment: .bundled
            ))
        }
    }
}

private func makeSkillScriptItem(
    _ candidate: SkillScriptCandidate,
    root: URL,
    references: Set<String>
) -> SkillScriptItem {
    let referencePaths = Array(references).sorted()
    guard let readableURL = candidate.readableURL else {
        let warning = candidate.containment == .escapesBundle
            ? "Symlink escapes the skill bundle; content was not read."
            : "Symlink target is missing; content was not read."
        return SkillScriptItem(
            relativePath: candidate.relativePath,
            runtime: "unknown",
            runtimeEvidence: [],
            role: inferSkillScriptRole(path: candidate.relativePath, references: referencePaths),
            executable: false,
            byteCount: 0,
            sha256: nil,
            symlink: candidate.symlink,
            containment: candidate.containment,
            referencedBy: referencePaths,
            warnings: [warning]
        )
    }

    let attributes = try? fileManager.attributesOfItem(atPath: readableURL.path)
    let permissions = (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0
    let executable = permissions & 0o111 != 0
    let byteCount = (attributes?[.size] as? NSNumber)?.intValue ?? 0
    let extensionRuntime = runtimeForExtension(readableURL.pathExtension)
    let firstLine = readFirstLine(readableURL)
    let shebangRuntime = firstLine.flatMap(runtimeForShebang)
    let runtime = shebangRuntime ?? extensionRuntime ?? "unknown"
    var runtimeEvidence: [String] = []
    if let extensionRuntime {
        runtimeEvidence.append("extension:\(extensionRuntime)")
    }
    if let shebangRuntime {
        runtimeEvidence.append("shebang:\(shebangRuntime)")
    }

    var warnings: [String] = []
    if let extensionRuntime, let shebangRuntime, extensionRuntime != shebangRuntime {
        warnings.append("File extension and shebang indicate different runtimes.")
    }
    if executable, firstLine?.hasPrefix("#!") != true {
        warnings.append("Executable file has no shebang.")
    } else if !executable, firstLine?.hasPrefix("#!") == true {
        warnings.append("Shebang is present, but the executable bit is not set.")
    }
    if containsAbsolutePersonalPath(readableURL) {
        warnings.append("Contains an absolute user-home path.")
    }
    if referencePaths.isEmpty {
        warnings.append("No bundled file references this script.")
    }

    return SkillScriptItem(
        relativePath: candidate.relativePath,
        runtime: runtime,
        runtimeEvidence: runtimeEvidence,
        role: inferSkillScriptRole(path: candidate.relativePath, references: referencePaths),
        executable: executable,
        byteCount: byteCount,
        sha256: sha256(readableURL),
        symlink: candidate.symlink,
        containment: candidate.containment,
        referencedBy: referencePaths,
        warnings: warnings
    )
}

private func skillScriptReferences(
    in root: URL,
    warnings: inout [String]
) -> SkillScriptReferenceIndex {
    var index = SkillScriptReferenceIndex()
    var queue: [(directory: URL, relativeDirectory: String)] = [(root, "")]
    while let current = queue.first {
        queue.removeFirst()
        guard let entries = try? fileManager.contentsOfDirectory(
            at: current.directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsPackageDescendants]
        ) else {
            continue
        }

        for entry in entries.sorted(by: { $0.path < $1.path }) {
            if isFilesystemSymlink(entry) {
                continue
            }
            if isDirectoryOrSymlinkedDirectory(entry) {
                guard !shouldPrune(name: entry.lastPathComponent) else { continue }
                let relativeDirectory = current.relativeDirectory.isEmpty
                    ? entry.lastPathComponent
                    : "\(current.relativeDirectory)/\(entry.lastPathComponent)"
                queue.append((entry, relativeDirectory))
                continue
            }
            guard isRegularOrSymlinkedFile(entry), isSkillTextFile(entry) else { continue }
            let size = (try? entry.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= 1_048_576,
                  let text = try? String(contentsOf: entry, encoding: .utf8)
            else {
                continue
            }
            let sourcePath = current.relativeDirectory.isEmpty
                ? entry.lastPathComponent
                : "\(current.relativeDirectory)/\(entry.lastPathComponent)"
            for reference in explicitSkillScriptPaths(in: text) {
                index.add(scriptPath: reference, sourcePath: sourcePath)
            }
        }
    }
    return index
}

private func explicitSkillScriptPaths(in text: String) -> Set<String> {
    let pattern = #"scripts/[A-Za-z0-9._/-]*[A-Za-z0-9._-]"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    var results = Set<String>()
    for match in expression.matches(in: text, range: range) {
        guard let matchRange = Range(match.range, in: text) else { continue }
        let path = String(text[matchRange])
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.first == "scripts",
              components.count > 1,
              !components.contains(".."),
              !components.contains(".")
        else {
            continue
        }
        results.insert(path)
    }
    return results
}

private func inferSkillScriptRole(path: String, references: [String]) -> SkillScriptRole {
    if references.contains("SKILL.md") {
        return .entryPoint
    }
    let lowered = path.lowercased()
    let components = lowered.split(separator: "/").map(String.init)
    if components.contains(where: { $0 == "test" || $0 == "tests" })
        || lowered.contains(".test.")
        || lowered.contains("_test.")
        || lowered.contains("-test.")
    {
        return .test
    }
    if components.contains(where: { $0 == "example" || $0 == "examples" || $0 == "samples" })
        || lowered.contains("example")
        || lowered.contains("demo")
    {
        return .example
    }
    if lowered.contains("generate") || lowered.contains("generator") || lowered.contains("scaffold") {
        return .generator
    }
    if !references.isEmpty
        || lowered.contains("helper")
        || lowered.contains("util")
        || components.contains("lib")
    {
        return .helper
    }
    return .unknown
}

private func runtimeForExtension(_ fileExtension: String) -> String? {
    switch fileExtension.lowercased() {
    case "sh": "shell"
    case "bash": "bash"
    case "zsh": "zsh"
    case "fish": "fish"
    case "py": "python"
    case "js", "mjs", "cjs": "node"
    case "ts", "mts", "cts": "typescript"
    case "rb": "ruby"
    case "swift": "swift"
    case "pl", "pm": "perl"
    case "php": "php"
    case "ps1": "powershell"
    default: nil
    }
}

private func runtimeForShebang(_ line: String) -> String? {
    guard line.hasPrefix("#!") else { return nil }
    let lowered = line.lowercased()
    let runtimes = [
        ("python", "python"),
        ("uv ", "python"),
        ("bash", "bash"),
        ("zsh", "zsh"),
        ("fish", "fish"),
        ("/sh", "shell"),
        ("node", "node"),
        ("deno", "deno"),
        ("bun", "bun"),
        ("ruby", "ruby"),
        ("swift", "swift"),
        ("perl", "perl"),
        ("php", "php"),
        ("pwsh", "powershell"),
        ("powershell", "powershell"),
    ]
    return runtimes.first(where: { lowered.contains($0.0) })?.1
}

private func readFirstLine(_ url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: 4_096),
          let text = String(data: data, encoding: .utf8)
    else {
        return nil
    }
    return text.components(separatedBy: .newlines).first
}

private func containsAbsolutePersonalPath(_ url: URL) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: 1_048_576),
          let text = String(data: data, encoding: .utf8)
    else {
        return false
    }
    let patterns = [
        #"/Users/[A-Za-z0-9._-]+/"#,
        #"/home/[A-Za-z0-9._-]+/"#,
        #"[A-Za-z]:\\Users\\[A-Za-z0-9._-]+\\"#,
    ]
    return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
}

private func sha256(_ url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    var hash = SHA256()
    do {
        while let data = try handle.read(upToCount: 64 * 1_024), !data.isEmpty {
            hash.update(data: data)
        }
    } catch {
        return nil
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

private func resolvedSymlinkTarget(_ url: URL) -> URL? {
    guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else {
        return nil
    }
    let target = destination.hasPrefix("/")
        ? URL(fileURLWithPath: destination)
        : url.deletingLastPathComponent().appendingPathComponent(destination)
    return target.resolvingSymlinksInPath().standardizedFileURL
}

func isFilesystemSymlink(_ url: URL) -> Bool {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return false }
    return info.st_mode & S_IFMT == S_IFLNK
}

private func skillBundleContains(root: URL, path: URL) -> Bool {
    let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
    let resolvedPath = path.resolvingSymlinksInPath().standardizedFileURL.path
    return resolvedPath == resolvedRoot || resolvedPath.hasPrefix(resolvedRoot + "/")
}
