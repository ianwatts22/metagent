import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
#if canImport(ImageIO)
import ImageIO
#endif
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

/// Where Metagent keeps its databases, caches, and recovery archives.
/// `METAGENT_DATA_DIR` overrides it everywhere (for example a persistent
/// volume in a cloud container). Otherwise macOS uses Application Support and
/// Linux follows the XDG base-directory convention.
func metagentDataDirectory() -> URL {
    let environment = ProcessInfo.processInfo.environment
    if let override = environment["METAGENT_DATA_DIR"], !override.isEmpty {
        return URL(fileURLWithPath: override).standardizedFileURL
    }
    #if os(macOS)
    return homeURL().standardizedFileURL
        .appendingPathComponent("Library")
        .appendingPathComponent("Application Support")
        .appendingPathComponent("Metagent")
    #else
    if let dataHome = environment["XDG_DATA_HOME"], dataHome.hasPrefix("/") {
        return URL(fileURLWithPath: dataHome).standardizedFileURL.appendingPathComponent("metagent")
    }
    return homeURL().standardizedFileURL
        .appendingPathComponent(".local")
        .appendingPathComponent("share")
        .appendingPathComponent("metagent")
    #endif
}

// ISO8601DateFormatter is documented as thread-safe; these are never mutated
// after creation.
nonisolated(unsafe) let iso8601Formatter = ISO8601DateFormatter()

nonisolated(unsafe) let iso8601FractionalFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

func defaultRootPaths(home: URL = homeURL()) -> [String] {
    return [
        home.appendingPathComponent("code_projects").path,
        home.appendingPathComponent("Library").appendingPathComponent("CloudStorage").path,
        home.appendingPathComponent("Documents").appendingPathComponent("Codex").path
    ]
}

func expandPath(_ path: String, home: URL = homeURL()) -> URL {
    if path == "~" {
        return home
    }
    if path.hasPrefix("~/") {
        return home.appendingPathComponent(String(path.dropFirst(2)))
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

/// Owns only the login process group created for this authentication attempt.
public final class MCPAuthenticationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var processID: pid_t?
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        // Shutdown cannot wait for a grace period: terminate the whole owned
        // group now so an OAuth listener cannot survive the app that opened it.
        if let processID { kill(-processID, SIGKILL) }
    }

    fileprivate func register(_ processID: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        self.processID = processID
        if cancelled { kill(-processID, SIGKILL) }
    }

    fileprivate func unregister() {
        lock.lock()
        defer { lock.unlock() }
        processID = nil
    }

    fileprivate func waitForExit(_ pid: pid_t, status: inout Int32, options: Int32) -> pid_t {
        lock.lock()
        defer { lock.unlock() }
        let result = waitpid(pid, &status, options)
        // Clear ownership atomically with reaping; a later cancellation must
        // never signal a process group whose identifier has been reused.
        if result == pid { processID = nil }
        return result
    }
}

#if canImport(Darwin)
/// Short-lived commands should complete when the kernel reports their exit,
/// not at the next polling tick. Registration can lose a race with an already
/// exited child, or fail on a restricted host; those cases retain polling.
final class SubprocessExitWaiter {
    private let processID: pid_t
    private let timerFlags: UInt32
    private var queue: Int32 = -1

    var usesEventWaiting: Bool { queue >= 0 }

    init(
        processID: pid_t,
        queueFactory: () -> Int32 = kqueue,
        timerFlags: UInt32 = UInt32(NOTE_NSECONDS | NOTE_MACH_CONTINUOUS_TIME)
    ) {
        self.processID = processID
        self.timerFlags = timerFlags
        let descriptor = queueFactory()
        guard descriptor >= 0 else { return }
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            close(descriptor)
            return
        }
        var change = kevent(
            ident: UInt(processID), filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_ADD | EV_ONESHOT), fflags: UInt32(NOTE_EXIT),
            data: 0, udata: nil
        )
        guard kevent(descriptor, &change, 1, nil, 0, nil) == 0 else {
            close(descriptor)
            return
        }
        queue = descriptor
    }

    deinit {
        if queue >= 0 { close(queue) }
    }

    /// True means NOTE_EXIT was received for this exact owned child. The
    /// caller may then reap it with waitpid, including the tiny exit/reap race.
    func wait(upTo interval: TimeInterval) -> Bool {
        guard interval > 0 else { return false }
        guard queue >= 0 else {
            Thread.sleep(forTimeInterval: min(interval, 0.05))
            return false
        }
        // TimeInterval permits infinity and very large values. Bound only an
        // individual kernel wait, not the caller's timeout policy or deadline.
        let boundedInterval = min(interval, 86_400)
        let nanoseconds = Int(max(1, (boundedInterval * 1_000_000_000).rounded(.up)))
        // kevent's relative syscall timeout excludes system sleep. A one-shot
        // continuous timer on this same queue preserves elapsed-time deadlines
        // without adding periodic polling wakeups.
        var timer = kevent(
            ident: 0, filter: Int16(EVFILT_TIMER),
            flags: UInt16(EV_ADD | EV_ONESHOT), fflags: timerFlags,
            data: nanoseconds, udata: nil
        )
        var event = kevent()
        let count = kevent(queue, &timer, 1, &event, 1, nil)
        if count == 0 || (count < 0 && errno == EINTR) { return false }
        guard count == 1, event.flags & UInt16(EV_ERROR) == 0 else {
            close(queue)
            queue = -1
            return false
        }
        if event.ident == 0, event.filter == Int16(EVFILT_TIMER) { return false }
        guard event.ident == UInt(processID), event.filter == Int16(EVFILT_PROC),
              event.fflags & UInt32(NOTE_EXIT) != 0
        else {
            close(queue)
            queue = -1
            return false
        }
        return true
    }
}
#else
/// Linux waits on a pidfd for the owned child's exit. Kernels without
/// pidfd_open, or sandboxes that deny it, retain the polling fallback.
final class SubprocessExitWaiter {
    private var descriptor: Int32 = -1

    var usesEventWaiting: Bool { descriptor >= 0 }

    init(processID: pid_t, queueFactory: (() -> Int32)? = nil) {
        let created = queueFactory?() ?? openProcessDescriptor(processID)
        guard created >= 0 else { return }
        guard fcntl(created, F_SETFD, FD_CLOEXEC) == 0 else {
            close(created)
            return
        }
        descriptor = created
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }

    /// True means the pidfd became readable, so the child has exited and the
    /// caller may reap it with waitpid.
    func wait(upTo interval: TimeInterval) -> Bool {
        guard interval > 0 else { return false }
        guard descriptor >= 0 else {
            Thread.sleep(forTimeInterval: min(interval, 0.05))
            return false
        }
        let boundedInterval = min(interval, 86_400)
        let milliseconds = Int32(max(1, (boundedInterval * 1_000).rounded(.up)))
        var target = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let count = poll(&target, 1, milliseconds)
        if count == 0 || (count < 0 && errno == EINTR) { return false }
        guard count == 1, target.revents & Int16(POLLIN) != 0 else {
            close(descriptor)
            descriptor = -1
            return false
        }
        return true
    }
}
#endif

private func continuousSubprocessTime() -> TimeInterval {
    // Unlike uptime, this monotonic clock advances during system sleep.
    continuousClockSeconds()
}

func runSubprocess(
    executable: URL,
    arguments: [String],
    currentDirectory: URL? = nil,
    standardInput: Data? = nil,
    outputObserver: ((Data, Data) -> Void)? = nil,
    cancellation: MCPAuthenticationCancellation? = nil,
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

    var fileActions = makeSpawnFileActions()
    var attributes = makeSpawnAttributes()
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
        let result = spawnFileActionsAddChdir(&fileActions, currentDirectory.path)
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
                    argumentBuffer.baseAddress!,
                    environmentBuffer.baseAddress!
                )
            }
        }
    }
    try requirePosixSuccess(spawnResult, action: "start \(executable.path)")
    cancellation?.register(processID)
    defer { cancellation?.unregister() }
    try inputHandle.close()
    try outputHandle.close()
    try errorHandle.close()

    let exitWaiter = SubprocessExitWaiter(processID: processID)
    let deadline = continuousSubprocessTime() + timeout
    var nextOutputObservation = continuousSubprocessTime() + 0.05
    var waitStatus: Int32 = 0
    func waitForExit(_ options: Int32) -> pid_t {
        var result: pid_t
        repeat {
            if let cancellation {
                result = cancellation.waitForExit(processID, status: &waitStatus, options: options)
            } else {
                result = waitpid(processID, &waitStatus, options)
            }
        } while options == 0 && result == -1 && errno == EINTR
        return result
    }
    var exited = waitForExit(WNOHANG) == processID
    while !exited && continuousSubprocessTime() < deadline {
        let now = continuousSubprocessTime()
        let observationDeadline = outputObserver == nil ? deadline : nextOutputObservation
        let reportedExit = exitWaiter.wait(upTo: min(deadline, observationDeadline) - now)
        if let outputObserver, continuousSubprocessTime() >= nextOutputObservation {
            outputObserver(
                (try? Data(contentsOf: outputURL)) ?? Data(),
                (try? Data(contentsOf: errorURL)) ?? Data()
            )
            nextOutputObservation = continuousSubprocessTime() + 0.25
        }
        exited = waitForExit(reportedExit ? 0 : WNOHANG) == processID
    }
    let timedOut = !exited
    if timedOut {
        kill(-processID, SIGTERM)
        let terminationDeadline = continuousSubprocessTime() + 2
        var processGroupAlive = isProcessGroupAlive(processID)
        while processGroupAlive && continuousSubprocessTime() < terminationDeadline {
            Thread.sleep(forTimeInterval: 0.05)
            if !exited {
                exited = waitForExit(WNOHANG) == processID
            }
            processGroupAlive = isProcessGroupAlive(processID)
        }
        if processGroupAlive {
            kill(-processID, SIGKILL)
        }
    }
    while !exited {
        let result = waitForExit(0)
        if result == processID {
            exited = true
        } else if result == -1, errno != EINTR {
            throw NSError(domain: "MetagentSubprocess", code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "wait for \(executable.path) failed: \(String(cString: strerror(errno)))"
            ])
        }
    }
    let standardOutput = try Data(contentsOf: outputURL)
    let standardError = try Data(contentsOf: errorURL)
    outputObserver?(standardOutput, standardError)
    return SubprocessResult(
        status: subprocessExitStatus(waitStatus),
        standardOutput: standardOutput,
        standardError: standardError,
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

/// The caller resolves the selected root once; aliases above it stay supported.
/// Missing ordinary descendants are safe, but even dangling links are rejected.
func isUnsymlinkedDescendant(_ url: URL, of root: URL) -> Bool {
    let root = root.standardizedFileURL
    let path = url.standardizedFileURL
    return path.path.hasPrefix(root.path + "/")
        && root.resolvingSymlinksInPath().standardizedFileURL.path == root.path
        && !isSymlink(path)
        && !hasSymlinkedAncestor(of: path, below: root)
        && path.resolvingSymlinksInPath().standardizedFileURL.path == path.path
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
                switch character {
                case "b": value.append("\u{08}")
                case "t": value.append("\t")
                case "n": value.append("\n")
                case "f": value.append("\u{0C}")
                case "r": value.append("\r")
                case "\"": value.append("\"")
                case "\\": value.append("\\")
                case "u", "U":
                    let count = character == "u" ? 4 : 8
                    var digits = ""
                    for _ in 0 ..< count {
                        guard index < body.endIndex else {
                            throw configError("\(key) must be a TOML string array")
                        }
                        digits.append(body[index])
                        index = body.index(after: index)
                    }
                    guard let scalarValue = UInt32(digits, radix: 16),
                          let scalar = UnicodeScalar(scalarValue)
                    else {
                        throw configError("\(key) must be a TOML string array")
                    }
                    value.unicodeScalars.append(scalar)
                default:
                    throw configError("\(key) must be a TOML string array")
                }
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
