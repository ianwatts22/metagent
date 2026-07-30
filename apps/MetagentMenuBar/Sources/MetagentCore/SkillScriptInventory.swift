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
    let readWarning: String?
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
            let readWarning: String?
            if let target, fileManager.fileExists(atPath: target.path) {
                if skillBundleContains(root: root, path: target) {
                    containment = .bundledSymlink
                    if isRegularFile(target) {
                        readableURL = target
                        readWarning = nil
                    } else {
                        readableURL = nil
                        readWarning = "Symlink target is not a regular file; content was not read."
                    }
                } else {
                    containment = .escapesBundle
                    readableURL = nil
                    readWarning = nil
                }
            } else {
                containment = .brokenSymlink
                readableURL = nil
                readWarning = nil
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
                containment: containment,
                readWarning: readWarning
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
                containment: .bundled,
                readWarning: nil
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
        let warning = candidate.readWarning
            ?? (candidate.containment == .escapesBundle
                ? "Symlink escapes the skill bundle; content was not read."
                : "Symlink target is missing; content was not read.")
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
            guard isRegularOrSymlinkedFile(entry),
                  isSkillScriptReferenceSource(entry)
            else {
                continue
            }
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
    // A final period is normally prose punctuation, not part of the filename.
    // Requiring an alphanumeric, underscore, or hyphen terminator still permits
    // dotted extensions and hidden files without inventing `script.py.`.
    let pattern = #"scripts/[A-Za-z0-9._/-]*[A-Za-z0-9_-]"#
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

private func isSkillScriptReferenceSource(_ url: URL) -> Bool {
    isSkillTextFile(url) || runtimeForExtension(url.pathExtension) != nil
}

private func runtimeForShebang(_ line: String) -> String? {
    guard line.hasPrefix("#!") else { return nil }
    let plainTokens = line.dropFirst(2)
        .split(whereSeparator: \.isWhitespace)
        .map(String.init)
    let usesEnvSplitString = plainTokens.first.map {
        URL(fileURLWithPath: $0).lastPathComponent.lowercased() == "env"
    } == true && envUsesSplitString(Array(plainTokens.dropFirst()))
    let parsedTokens = usesEnvSplitString ? shebangTokens(in: line) : plainTokens
    guard var tokens = parsedTokens else { return nil }
    guard !tokens.isEmpty else { return nil }

    var interpreter = URL(fileURLWithPath: tokens.removeFirst())
        .lastPathComponent
        .lowercased()
    if interpreter == "env" {
        guard let command = envCommand(in: tokens) else { return nil }
        interpreter = URL(fileURLWithPath: command)
            .lastPathComponent
            .lowercased()
    }

    if interpreter.hasPrefix("python") || interpreter == "uv" {
        return "python"
    }
    return switch interpreter {
    case "sh": "shell"
    case "bash": "bash"
    case "zsh": "zsh"
    case "fish": "fish"
    case "node": "node"
    case "deno": "deno"
    case "bun": "bun"
    case "ruby": "ruby"
    case "swift": "swift"
    case "perl": "perl"
    case "php": "php"
    case "pwsh", "powershell": "powershell"
    default: nil
    }
}

private func envUsesSplitString(_ tokens: [String]) -> Bool {
    for token in tokens {
        if token.hasPrefix("--split-string=") {
            return true
        }
        if token == "--" || isEnvironmentAssignment(token) {
            return false
        }
        guard token.hasPrefix("-"), !token.hasPrefix("--") else {
            return false
        }
        if token == "-S" || envShortSplitIndex(in: token) != nil {
            return true
        }
    }
    return false
}

private func shebangTokens(in line: String) -> [String]? {
    var tokens: [String] = []
    var current = ""
    var quote: Character?
    var escaped = false

    for character in line.dropFirst(2) {
        if escaped {
            current.append(character)
            escaped = false
        } else if character == "\\" {
            escaped = true
        } else if let activeQuote = quote {
            if character == activeQuote {
                quote = nil
                current.append(character)
            } else {
                current.append(character)
            }
        } else if character == "'" || character == "\"" {
            quote = character
            current.append(character)
        } else if character.isWhitespace {
            if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        } else {
            current.append(character)
        }
    }
    if escaped {
        current.append("\\")
    }
    guard quote == nil else { return nil }
    if !current.isEmpty {
        tokens.append(current)
    }
    return tokens
}

private func envCommand(in tokens: [String]) -> String? {
    var index = tokens.startIndex
    var optionsEnded = false
    while index < tokens.endIndex {
        let token = tokens[index]
        if !optionsEnded, token.hasPrefix("--split-string=") {
            let payload = String(token.dropFirst("--split-string=".count))
            let remaining = Array(tokens[tokens.index(after: index)...])
            guard let payloadTokens = splitStringTokens(payload) else { return nil }
            return envCommand(in: payloadTokens + remaining)
        }
        if !optionsEnded, let splitPayload = attachedEnvSplitPayload(token) {
            let remaining = Array(tokens[tokens.index(after: index)...])
            guard let payloadTokens = splitStringTokens(splitPayload) else { return nil }
            return envCommand(in: payloadTokens + remaining)
        }
        if !optionsEnded, token == "--" {
            optionsEnded = true
            index = tokens.index(after: index)
            continue
        }
        if !optionsEnded, envOptionConsumesNextToken(token) {
            index = tokens.index(index, offsetBy: 2, limitedBy: tokens.endIndex)
                ?? tokens.endIndex
            continue
        }
        if isEnvironmentAssignment(token) {
            optionsEnded = true
            index = tokens.index(after: index)
            continue
        }
        if !optionsEnded, token.hasPrefix("-") {
            index = tokens.index(after: index)
            continue
        }
        return token
    }
    return nil
}

private func attachedEnvSplitPayload(_ token: String) -> String? {
    guard let splitIndex = envShortSplitIndex(in: token) else { return nil }
    let payload = token[token.index(after: splitIndex)...]
    return payload.isEmpty ? nil : String(payload)
}

private func envShortSplitIndex(in token: String) -> String.Index? {
    guard token.hasPrefix("-"), !token.hasPrefix("--") else { return nil }
    var index = token.index(after: token.startIndex)
    while index < token.endIndex {
        let option = token[index]
        if option == "S" {
            return index
        }
        if option == "a" || option == "u" || option == "C" || option == "P" {
            return nil
        }
        index = token.index(after: index)
    }
    return nil
}

private func splitStringTokens(_ value: String) -> [String]? {
    let normalized: String
    if value.count >= 2,
       let first = value.first,
       first == value.last,
       first == "'" || first == "\""
    {
        normalized = String(value.dropFirst().dropLast())
    } else {
        normalized = value
    }
    guard let tokens = shebangTokens(in: "#!\(normalized)") else { return nil }
    return tokens.map(unquotedEnvToken)
}

private func unquotedEnvToken(_ token: String) -> String {
    guard token.count >= 2,
          let first = token.first,
          first == token.last,
          first == "'" || first == "\""
    else {
        return token.replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
    }
    return String(token.dropFirst().dropLast())
}

private func envOptionConsumesNextToken(_ token: String) -> Bool {
    switch token {
    case "-a", "-u", "-C", "-P", "--argv0", "--unset", "--chdir":
        return true
    default:
        break
    }

    var shortOptions = token[...]
    if shortOptions.hasPrefix("-S"), shortOptions.count > 2 {
        shortOptions = shortOptions.dropFirst(2)
        if shortOptions.hasPrefix("-") {
            shortOptions = shortOptions.dropFirst()
        }
    } else if shortOptions.hasPrefix("-"), !shortOptions.hasPrefix("--") {
        shortOptions = shortOptions.dropFirst()
    } else {
        return false
    }

    for index in shortOptions.indices
        where shortOptions[index] == "u"
            || shortOptions[index] == "a"
            || shortOptions[index] == "C"
            || shortOptions[index] == "P"
    {
        return shortOptions.index(after: index) == shortOptions.endIndex
    }
    return false
}

private func isEnvironmentAssignment(_ token: String) -> Bool {
    token.firstIndex(of: "=").map { $0 != token.startIndex } ?? false
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
        #"/Users/[A-Za-z0-9._-]+(?:/|(?=[^A-Za-z0-9._-]|$))"#,
        #"/home/[A-Za-z0-9._-]+(?:/|(?=[^A-Za-z0-9._-]|$))"#,
        #"[A-Za-z]:\\Users\\[A-Za-z0-9._-]+(?:\\|(?=[^A-Za-z0-9._-]|$))"#,
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

private func isRegularFile(_ url: URL) -> Bool {
    var info = stat()
    guard stat(url.path, &info) == 0 else { return false }
    return info.st_mode & S_IFMT == S_IFREG
}

private func skillBundleContains(root: URL, path: URL) -> Bool {
    let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
    let resolvedPath = path.resolvingSymlinksInPath().standardizedFileURL.path
    return resolvedPath == resolvedRoot || resolvedPath.hasPrefix(resolvedRoot + "/")
}
