import Foundation
import Darwin
import ImageIO
import SQLite3

var fileManager: FileManager {
    FileManager.default
}

func homeURL() -> URL {
    if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
        return URL(fileURLWithPath: home)
    }
    return fileManager.homeDirectoryForCurrentUser
}

// ISO8601DateFormatter is documented as thread-safe; these are never mutated
// after creation.
nonisolated(unsafe) let iso8601Formatter = ISO8601DateFormatter()

nonisolated(unsafe) let iso8601FractionalFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

func defaultRootPaths() -> [String] {
    let home = homeURL()
    return [
        home.appendingPathComponent("code_projects").path,
        home.appendingPathComponent("Library").appendingPathComponent("CloudStorage").path,
        home.appendingPathComponent("Documents").appendingPathComponent("Codex").path
    ]
}

func expandPath(_ path: String) -> URL {
    if path == "~" {
        return homeURL()
    }
    if path.hasPrefix("~/") {
        return homeURL().appendingPathComponent(String(path.dropFirst(2)))
    }
    return URL(fileURLWithPath: path)
}

func canonicalProjectPath(_ url: URL) -> String {
    url.resolvingSymlinksInPath().standardizedFileURL.path
}

/// Stable identity for a path that may not exist yet. Existing paths resolve
/// symlinks; missing paths retain their standardized intended location.
func canonicalExistingPath(_ path: String) -> String {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    if fileManager.fileExists(atPath: url.path) {
        return url.resolvingSymlinksInPath().standardizedFileURL.path
    }
    return url.path
}

struct SubprocessResult {
    var status: Int32
    var standardOutput: Data
    var standardError: Data
    var timedOut: Bool
}

func runSubprocess(
    executable: URL,
    arguments: [String],
    currentDirectory: URL? = nil,
    standardInput: Data? = nil,
    timeout: TimeInterval
) throws -> SubprocessResult {
    let captureDirectory = fileManager.temporaryDirectory
        .appendingPathComponent("metagent-process-\(UUID().uuidString)")
    try fileManager.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: captureDirectory) }
    let outputURL = captureDirectory.appendingPathComponent("stdout")
    let errorURL = captureDirectory.appendingPathComponent("stderr")
    let inputURL = captureDirectory.appendingPathComponent("stdin")
    _ = fileManager.createFile(atPath: outputURL.path, contents: nil)
    _ = fileManager.createFile(atPath: errorURL.path, contents: nil)
    if let standardInput {
        try standardInput.write(to: inputURL, options: .atomic)
    }
    let inputHandle = try FileHandle(
        forReadingFrom: standardInput == nil ? URL(fileURLWithPath: "/dev/null") : inputURL
    )
    let outputHandle = try FileHandle(forWritingTo: outputURL)
    let errorHandle = try FileHandle(forWritingTo: errorURL)

    var fileActions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    try requirePosixSuccess(posix_spawn_file_actions_init(&fileActions), action: "initialize process file actions")
    defer { posix_spawn_file_actions_destroy(&fileActions) }
    try requirePosixSuccess(posix_spawnattr_init(&attributes), action: "initialize process attributes")
    defer { posix_spawnattr_destroy(&attributes) }
    try requirePosixSuccess(
        posix_spawn_file_actions_adddup2(&fileActions, inputHandle.fileDescriptor, STDIN_FILENO),
        action: "redirect process input"
    )
    try requirePosixSuccess(
        posix_spawn_file_actions_adddup2(&fileActions, outputHandle.fileDescriptor, STDOUT_FILENO),
        action: "redirect process output"
    )
    try requirePosixSuccess(
        posix_spawn_file_actions_adddup2(&fileActions, errorHandle.fileDescriptor, STDERR_FILENO),
        action: "redirect process errors"
    )
    if let currentDirectory {
        let result = currentDirectory.path.withCString {
            posix_spawn_file_actions_addchdir(&fileActions, $0)
        }
        try requirePosixSuccess(result, action: "set process working directory")
    }
    try requirePosixSuccess(
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)),
        action: "configure process group"
    )
    try requirePosixSuccess(
        posix_spawnattr_setpgroup(&attributes, 0),
        action: "create process group"
    )

    var processID: pid_t = 0
    var argumentPointers = ([executable.path] + arguments).map { strdup($0) as UnsafeMutablePointer<CChar>? }
    argumentPointers.append(nil)
    defer { argumentPointers.dropLast().forEach { free($0) } }
    var environmentPointers = ProcessInfo.processInfo.environment
        .sorted { $0.key < $1.key }
        .map { strdup("\($0.key)=\($0.value)") as UnsafeMutablePointer<CChar>? }
    environmentPointers.append(nil)
    defer { environmentPointers.dropLast().forEach { free($0) } }
    let spawnResult = executable.path.withCString { executablePath in
        argumentPointers.withUnsafeMutableBufferPointer { argumentBuffer in
            environmentPointers.withUnsafeMutableBufferPointer { environmentBuffer in
                posix_spawn(
                    &processID,
                    executablePath,
                    &fileActions,
                    &attributes,
                    argumentBuffer.baseAddress,
                    environmentBuffer.baseAddress
                )
            }
        }
    }
    try requirePosixSuccess(spawnResult, action: "start \(executable.path)")
    try inputHandle.close()
    try outputHandle.close()
    try errorHandle.close()

    let deadline = Date().addingTimeInterval(timeout)
    var waitStatus: Int32 = 0
    var exited = waitpid(processID, &waitStatus, WNOHANG) == processID
    while !exited && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
        exited = waitpid(processID, &waitStatus, WNOHANG) == processID
    }
    let timedOut = !exited
    if timedOut {
        kill(-processID, SIGTERM)
        let terminationDeadline = Date().addingTimeInterval(2)
        var processGroupAlive = isProcessGroupAlive(processID)
        while processGroupAlive && Date() < terminationDeadline {
            Thread.sleep(forTimeInterval: 0.05)
            if !exited {
                exited = waitpid(processID, &waitStatus, WNOHANG) == processID
            }
            processGroupAlive = isProcessGroupAlive(processID)
        }
        if processGroupAlive {
            kill(-processID, SIGKILL)
        }
    }
    while !exited {
        let result = waitpid(processID, &waitStatus, 0)
        if result == processID {
            exited = true
        } else if result == -1, errno != EINTR {
            throw NSError(domain: "MetagentSubprocess", code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "wait for \(executable.path) failed: \(String(cString: strerror(errno)))"
            ])
        }
    }
    return SubprocessResult(
        status: subprocessExitStatus(waitStatus),
        standardOutput: try Data(contentsOf: outputURL),
        standardError: try Data(contentsOf: errorURL),
        timedOut: timedOut
    )
}

func isProcessGroupAlive(_ processID: pid_t) -> Bool {
    if kill(-processID, 0) == 0 {
        return true
    }
    return errno == EPERM
}

func requirePosixSuccess(_ status: Int32, action: String) throws {
    guard status == 0 else {
        throw NSError(domain: "MetagentSubprocess", code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: "\(action) failed: \(String(cString: strerror(status)))"
        ])
    }
}

func subprocessExitStatus(_ waitStatus: Int32) -> Int32 {
    let signal = waitStatus & 0x7f
    return signal == 0 ? (waitStatus >> 8) & 0xff : 128 + signal
}

/// Shared executable lookup: override variable first, then every PATH entry,
/// then caller-provided fallback candidates, preserving that order exactly.
func firstExecutableCandidate(
    named name: String,
    environmentOverride: String?,
    extraCandidates: [String],
    environment: [String: String] = ProcessInfo.processInfo.environment,
    requireAbsolutePaths: Bool = false
) -> String? {
    var candidates: [String] = []
    if let environmentOverride,
       let override = environment[environmentOverride],
       !override.isEmpty,
       !requireAbsolutePaths || (override as NSString).isAbsolutePath
    {
        candidates.append(override)
    }
    if let path = environment["PATH"] {
        candidates += path.split(separator: ":").compactMap {
            let directory = String($0)
            guard !requireAbsolutePaths || (directory as NSString).isAbsolutePath else { return nil }
            return URL(fileURLWithPath: directory).appendingPathComponent(name).path
        }
    }
    candidates += extraCandidates
    return candidates.first { fileManager.isExecutableFile(atPath: $0) }
}

func npxExecutable() throws -> URL {
    var extraCandidates: [String] = []
    let fnmVersions = homeURL().appendingPathComponent(".local/share/fnm/node-versions")
    if let versions = try? fileManager.contentsOfDirectory(at: fnmVersions, includingPropertiesForKeys: nil) {
        extraCandidates += versions.sorted { $0.lastPathComponent > $1.lastPathComponent }.map {
            $0.appendingPathComponent("installation/bin/npx").path
        }
    }
    extraCandidates += ["/opt/homebrew/bin/npx", "/usr/local/bin/npx"]
    guard let path = firstExecutableCandidate(
        named: "npx",
        environmentOverride: "METAGENT_NPX",
        extraCandidates: extraCandidates
    ) else {
        throw NSError(domain: "MetagentSkillsCLI", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "npx executable not found; set METAGENT_NPX to enable managed removal"
        ])
    }
    return URL(fileURLWithPath: path)
}

func combinedSubprocessOutput(_ result: SubprocessResult) -> String {
    String(data: result.standardOutput + result.standardError, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

/// Shared timeout/nonzero-status check for subprocess results. `output` is
/// used verbatim as the failure description when it is non-empty.
func requireSubprocessSuccess(
    _ result: SubprocessResult,
    output: String,
    domain: String,
    timeoutCode: Int,
    timeoutMessage: String,
    failureMessage: String
) throws {
    if result.timedOut {
        throw NSError(domain: domain, code: timeoutCode, userInfo: [
            NSLocalizedDescriptionKey: timeoutMessage
        ])
    }
    guard result.status == 0 else {
        throw NSError(domain: domain, code: Int(result.status), userInfo: [
            NSLocalizedDescriptionKey: output.isEmpty ? failureMessage : output
        ])
    }
}

func hasSymlinkedAncestor(of url: URL, below root: URL) -> Bool {
    let root = root.standardizedFileURL
    var ancestor = url.standardizedFileURL.deletingLastPathComponent()
    while ancestor.path != root.path {
        guard ancestor.path.hasPrefix(root.path + "/") else { return true }
        if isSymlink(ancestor) { return true }
        ancestor = ancestor.deletingLastPathComponent()
    }
    return false
}

func isDirectoryOrSymlinkedDirectory(_ url: URL) -> Bool {
    var isDirectory = ObjCBool(false)
    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
    return isDirectory.boolValue
}

func isRegularOrSymlinkedFile(_ url: URL) -> Bool {
    if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
        return true
    }
    var isDirectory = ObjCBool(false)
    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
    return isSymlink(url) && !isDirectory.boolValue
}

func isSymlink(_ url: URL) -> Bool {
    (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
}

func symlink(_ link: URL, resolvesTo expectedTarget: URL) -> Bool {
    guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: link.path) else {
        return false
    }
    let destinationURL = destination.hasPrefix("/")
        ? URL(fileURLWithPath: destination)
        : link.deletingLastPathComponent().appendingPathComponent(destination)
    return canonicalProjectPath(destinationURL) == canonicalProjectPath(expectedTarget)
}

func skillContainerEntries(at url: URL) -> [URL]? {
    guard let names = try? fileManager.contentsOfDirectory(atPath: url.path) else {
        return nil
    }
    return names.map { url.appendingPathComponent($0) }
}

/// Directories that never contain skills and are skipped by every walk.
let prunedDirectoryNames: Set<String> = [
    ".git",
    ".hg",
    ".svn",
    ".build",
    ".next",
    "node_modules",
    "target",
    "dist",
    "build",
    "vendor",
    "DerivedData"
]

/// Dot-directories that do hold skills, so a walk must descend into them.
let agentDirectoryNames: Set<String> = [".agents", ".codex", ".claude"]

func shouldPrune(name: String) -> Bool {
    if prunedDirectoryNames.contains(name) || name == "_archive" {
        return true
    }
    return name.hasPrefix(".") && !agentDirectoryNames.contains(name)
}

func shouldPruneSkillContainer(name: String) -> Bool {
    prunedDirectoryNames.contains(name)
}

func isValidSkillName(_ name: String) -> Bool {
    guard let first = name.unicodeScalars.first, isASCIIAlphanumeric(first) else {
        return false
    }
    for scalar in name.unicodeScalars.dropFirst() {
        guard isASCIIAlphanumeric(scalar) || scalar == "." || scalar == "_" || scalar == "-" else {
            return false
        }
    }
    return true
}

func isASCIIAlphanumeric(_ scalar: UnicodeScalar) -> Bool {
    let value = scalar.value
    return (value >= 48 && value <= 57)
        || (value >= 65 && value <= 90)
        || (value >= 97 && value <= 122)
}

func isSkillTextFile(_ url: URL) -> Bool {
    switch url.pathExtension.lowercased() {
    case "md", "markdown", "txt", "toml", "yaml", "yml", "json", "sh", "py", "js", "ts", "tsx", "css", "html":
        return true
    default:
        return false
    }
}

func parseStringArray(key: String, text: String) throws -> [String]? {
    guard let body = firstRegexCapture(pattern: "\\b\(key)\\s*=\\s*\\[([\\s\\S]*?)\\]", text: text) else {
        if hasConfigAssignment(key: key, text: text) {
            throw configError("\(key) must be a TOML string array")
        }
        return nil
    }
    return try parseStringArrayBody(body, key: key)
}

func parseStringArrayBody(_ body: String, key: String) throws -> [String] {
    var values: [String] = []
    var index = body.startIndex

    func skipWhitespace() {
        while index < body.endIndex, body[index].isWhitespace {
            index = body.index(after: index)
        }
    }

    skipWhitespace()
    if index == body.endIndex {
        return values
    }

    while index < body.endIndex {
        skipWhitespace()
        guard index < body.endIndex else { return values }
        let quote = body[index]
        guard quote == "\"" || quote == "'" else {
            throw configError("\(key) must be a TOML string array")
        }
        index = body.index(after: index)

        var value = ""
        var escaped = false
        var closed = false
        while index < body.endIndex {
            let character = body[index]
            index = body.index(after: index)
            if escaped {
                value.append(character)
                escaped = false
                continue
            }
            if quote == "\"", character == "\\" {
                escaped = true
                continue
            }
            if character == quote {
                values.append(value)
                closed = true
                break
            }
            value.append(character)
        }

        guard closed else {
            throw configError("\(key) must be a TOML string array")
        }

        skipWhitespace()
        guard index < body.endIndex else { return values }
        guard body[index] == "," else {
            throw configError("\(key) must be a TOML string array")
        }
        index = body.index(after: index)
        skipWhitespace()
    }

    return values
}

func uncommentedConfigText(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .map(stripTomlComment)
        .joined(separator: "\n")
}

func stripTomlComment(_ line: Substring) -> String {
    var output = ""
    var quote: Character?
    var escaped = false

    for character in line {
        if let activeQuote = quote {
            output.append(character)
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == activeQuote {
                quote = nil
            }
            continue
        }

        if character == "#" {
            break
        }
        output.append(character)
        if character == "\"" || character == "'" {
            quote = character
        }
    }

    return output
}

func parseInteger(key: String, text: String) throws -> Int? {
    guard let value = firstRegexCapture(pattern: "\\b\(key)\\s*=\\s*([^\\n]*)", text: text) else {
        if hasConfigAssignment(key: key, text: text) {
            throw configError("\(key) must be an integer")
        }
        return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil,
          let parsed = Int(trimmed)
    else {
        throw configError("\(key) must be an integer")
    }
    return parsed
}

func hasConfigAssignment(key: String, text: String) -> Bool {
    let pattern = "\\b\(key)\\s*="
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.firstMatch(in: text, range: range) != nil
}

func configError(_ message: String) -> NSError {
    NSError(domain: "MetagentConfig", code: 1, userInfo: [
        NSLocalizedDescriptionKey: message
    ])
}

func firstRegexCapture(pattern: String, text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1 else {
        return nil
    }
    guard let swiftRange = Range(match.range(at: 1), in: text) else { return nil }
    return String(text[swiftRange])
}

extension String {
    func removingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
