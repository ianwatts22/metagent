import Foundation

// Shared with the store because it is serialized in source checkpoints.
// Record decoding changes only the session fields; byte cursors remain store-owned.
struct UsageSourceState: Sendable {
    var offset: Int64 = 0
    var fileSize: Int64 = 0
    var modifiedAt: Double = 0
    var fileIdentity = ""
    var prefixFingerprint = ""
    var sessionID = ""
    var cwd = ""
    var turnID = ""
    var coverageStartedAt = ""
    var pendingEvents: [String: [ParsedUsageEvent]] = [:]
    var runSessionID = ""
    var runSessionStartedAt = ""
    var runKind = "unknown"
}

struct ParsedSkillIdentity: Codable, Sendable {
    let id: String
    let name: String
    let confirmationName: String
    let canonicalPath: String
    let scope: String
}

struct ParsedUsageEvent: Codable, Sendable {
    let id: String
    let skill: ParsedSkillIdentity
    let occurredAt: String
    let sessionID: String
    let turnID: String
    let cwd: String
    let sourcePath: String
    let callID: String
}

struct ParsedAgentRun: Sendable {
    let id: String
    let sessionID: String
    let turnID: String
    let cwd: String
    let startedAt: String
    let completedAt: String
    let durationMilliseconds: Int64
    let kind: String
    let sourcePath: String
}

private struct ExecutedCommand: Sendable {
    let text: String
    let workdir: String?
}

/// Decodes relevant session records without opening SQLite or advancing a file cursor.
/// Pending reads live in the caller's checkpoint state so calls and outputs can
/// arrive in different refresh slices. Identity resolution reads only skill files.
struct SkillUsageRecordDecoder {
    private let fileManager = FileManager.default

    func parseLine(
        _ data: Data,
        lineOffset: Int64,
        sourcePath: String,
        state: inout UsageSourceState,
        identityCache: inout [String: ParsedSkillIdentity],
        events: inout [ParsedUsageEvent],
        runs: inout [ParsedAgentRun]
    ) {
        guard Self.containsUsageMarker(in: data) else { return }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String,
              let payload = object["payload"] as? [String: Any]
        else { return }

        if type == "session_meta" {
            let sessionID = string(payload["id"] ?? payload["session_id"])
            state.sessionID = sessionID
            state.cwd = string(payload["cwd"])
            let timestamp = string(object["timestamp"] ?? payload["timestamp"])
            if !timestamp.isEmpty,
               state.coverageStartedAt.isEmpty || timestamp < state.coverageStartedAt
            {
                state.coverageStartedAt = timestamp
            }
            let sourceSessionID = rolloutSessionID(sourcePath)
            if state.runSessionID.isEmpty,
               sourceSessionID == nil || sourceSessionID == sessionID
            {
                state.runSessionID = sessionID
                state.runSessionStartedAt = timestamp
                state.runKind = agentRunKind(payload)
            }
            return
        }
        if type == "turn_context" {
            state.turnID = string(payload["turn_id"])
            let cwd = string(payload["cwd"])
            if !cwd.isEmpty { state.cwd = cwd }
            return
        }
        if type == "event_msg" {
            let eventType = string(payload["type"])
            guard eventType == "task_complete" else { return }
            let turnID = string(payload["turn_id"])
            guard !turnID.isEmpty,
                  !state.runSessionID.isEmpty,
                  let startedDate = unixTimestampDate(payload["started_at"]),
                  let completedDate = unixTimestampDate(payload["completed_at"]),
                  completedDate >= startedDate
            else { return }

            // Forked and subagent rollouts contain copied parent history whose
            // JSONL wrapper timestamps are rewritten to the fork time. The
            // payload timestamps retain the real task time. Only events that
            // began in this source session belong to this file; the originals
            // are retained in their own rollout and deduplicate by turn there.
            if let sessionStarted = MetagentCore.parseSkillUsageTimestamp(state.runSessionStartedAt) {
                // Payload epochs are often whole seconds while the session
                // timestamp includes fractions. Keep starts from the same
                // second, but reject everything from an earlier second.
                let sessionStartSecond = Date(
                    timeIntervalSince1970: floor(sessionStarted.timeIntervalSince1970)
                )
                if startedDate < sessionStartSecond { return }
            }

            let recordedDuration = int64(payload["duration_ms"])
            let derivedDuration = Int64((completedDate.timeIntervalSince(startedDate) * 1_000).rounded())
            let duration = recordedDuration ?? derivedDuration
            guard duration >= 0 else { return }
            runs.append(ParsedAgentRun(
                id: "\(state.runSessionID)\u{1F}\(turnID)",
                sessionID: state.runSessionID,
                turnID: turnID,
                cwd: state.cwd,
                startedAt: iso8601Formatter.string(from: startedDate),
                completedAt: iso8601Formatter.string(from: completedDate),
                durationMilliseconds: duration,
                kind: state.runKind,
                sourcePath: sourcePath
            ))
            return
        }
        guard type == "response_item", let itemType = payload["type"] as? String else { return }
        if ["custom_tool_call_output", "function_call_output", "local_shell_call_output"].contains(itemType) {
            let callID = string(payload["call_id"] ?? payload["id"])
            guard !callID.isEmpty, let pending = state.pendingEvents.removeValue(forKey: callID) else {
                return
            }
            let output = collectStrings(payload["output"] ?? payload["result"]).joined(separator: "\n")
            events.append(contentsOf: pending.filter { outputConfirmsRead($0, output: output) })
            return
        }
        guard ["custom_tool_call", "function_call", "local_shell_call"].contains(itemType) else {
            return
        }

        let toolName = string(payload["name"])
        guard isSupportedReadTool(name: toolName, itemType: itemType) else { return }

        let callID = string(payload["call_id"] ?? payload["id"])
        guard !callID.isEmpty else { return }
        if let metadata = payload["internal_chat_message_metadata_passthrough"] as? [String: Any] {
            let turnID = string(metadata["turn_id"])
            if !turnID.isEmpty { state.turnID = turnID }
        }
        var pending: [ParsedUsageEvent] = []
        for (commandIndex, command) in executedCommands(payload: payload, itemType: itemType).enumerated() {
            let executionCWD = commandExecutionCWD(command, sessionCWD: state.cwd)
            for (readIndex, rawPath) in extractExecutedSkillPaths(command.text).enumerated() {
                let resolvedPath = resolve(path: rawPath, cwd: executionCWD)
                let skill = identityCache[resolvedPath] ?? identify(path: resolvedPath)
                identityCache[resolvedPath] = skill
                let sessionID = state.sessionID.isEmpty ? sourcePath : state.sessionID
                let turnID = state.turnID.isEmpty ? "unknown" : state.turnID
                pending.append(ParsedUsageEvent(
                    id: "\(sessionID)\u{1F}\(callID)\u{1F}\(commandIndex)\u{1F}\(readIndex)\u{1F}\(skill.id)",
                    skill: skill,
                    occurredAt: string(object["timestamp"]),
                    sessionID: sessionID,
                    turnID: turnID,
                    cwd: executionCWD,
                    sourcePath: sourcePath,
                    callID: callID
                ))
            }
        }
        if !pending.isEmpty {
            state.pendingEvents[callID] = pending
        }
    }

    /// Most session records cannot affect usage or run timing. Inspect their
    /// UTF-8 bytes before allocating a Swift String or decoding JSON. Large
    /// retained histories contain millions of token and message records, so
    /// this cheap gate is the difference between an incremental index and a
    /// sustained CPU workload.
    private static func containsUsageMarker(in data: Data) -> Bool {
        usageMarkers.contains { data.range(of: $0) != nil }
    }

    private static let usageMarkers = [
        Data("session_meta".utf8),
        Data("turn_context".utf8),
        Data("task_complete".utf8),
        Data("tool_call_output".utf8),
        Data("function_call_output".utf8),
        Data("shell_call_output".utf8),
        Data("SKILL.md".utf8),
    ]

    private func outputConfirmsRead(_ event: ParsedUsageEvent, output: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: event.skill.confirmationName)
        let pattern = #"(?im)^.*\bname:\s*[\"']?"# + escaped + #"[\"']?\s*$"#
        if output.range(of: pattern, options: .regularExpression) != nil { return true }
        if output.range(of: #"(?im)^.*\bname:\s*[\"']?[^\r\n]+$"#, options: .regularExpression) != nil {
            return false
        }
        let substantiveLines = output.components(separatedBy: .newlines).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "Output:" { return false }
            if trimmed.localizedCaseInsensitiveContains("Script completed") { return false }
            if trimmed.localizedCaseInsensitiveContains("Wall time") { return false }
            return true
        }
        guard let first = substantiveLines.first?.trimmingCharacters(in: .whitespaces) else {
            return false
        }
        let leadingFailure = #"(?i)^(?:Script failed|Rejected\(|Process exited with code\s+(?:-[0-9]+|[1-9][0-9]*)\b|(?:cat|sed|head|tail|bat|zsh|bash|sh):.*(?:No such file or directory|Permission denied|Operation not permitted|command not found|cannot open|can't open))"#
        return first.range(of: leadingFailure, options: .regularExpression) == nil
    }

    private func collectStrings(_ value: Any?) -> [String] {
        if let value = value as? String {
            if let data = value.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                let content = ["text", "output", "result", "content", "message"].flatMap {
                    collectStrings(object[$0])
                }
                if let failure = structuredFailureLine(object) { return [failure] + content }
                if !content.isEmpty { return content }
            }
            return [value]
        }
        if let values = value as? [Any] { return values.flatMap(collectStrings) }
        if let values = value as? [String: Any] {
            let content = ["text", "output", "result", "content", "message"].flatMap {
                collectStrings(values[$0])
            }
            if let failure = structuredFailureLine(values) { return [failure] + content }
            return content.isEmpty ? values.values.flatMap(collectStrings) : content
        }
        return []
    }

    private func structuredFailureLine(_ object: [String: Any]) -> String? {
        if let exitCode = (object["exit_code"] as? Int) ?? (object["exitCode"] as? Int),
           exitCode != 0
        {
            return "Process exited with code \(exitCode)"
        }
        if object["success"] as? Bool == false { return "Script failed" }
        guard let status = object["status"] as? String else { return nil }
        switch status.lowercased() {
        case "failed", "failure", "error", "rejected": return "Script failed"
        default: return nil
        }
    }

    private func isSupportedReadTool(name: String, itemType: String) -> Bool {
        if itemType == "local_shell_call" { return true }
        let normalized = name.lowercased()
        return normalized == "exec"
            || normalized.hasSuffix(".exec")
            || normalized == "exec_command"
            || normalized.hasSuffix(".exec_command")
            || normalized == "shell"
            || normalized == "shell_command"
            || normalized.hasSuffix(".shell_command")
    }

    private func executedCommands(payload: [String: Any], itemType: String) -> [ExecutedCommand] {
        if itemType == "local_shell_call" {
            let workdir = string(payload["workdir"] ?? payload["cwd"])
            return commandStrings(payload["command"] ?? payload["cmd"]).map {
                ExecutedCommand(text: $0, workdir: workdir.isEmpty ? nil : workdir)
            }
        }

        if let arguments = payload["arguments"] as? String,
           let data = arguments.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            return executedCommands(from: object)
        }
        if let arguments = payload["arguments"] as? [String: Any] {
            return executedCommands(from: arguments)
        }

        guard let input = payload["input"] as? String else { return [] }
        return extractJavaScriptExecCommands(input)
    }

    private func executedCommands(from object: [String: Any]) -> [ExecutedCommand] {
        let workdir = string(object["workdir"] ?? object["cwd"])
        return commandStrings(object["cmd"] ?? object["command"]).map {
            ExecutedCommand(text: $0, workdir: workdir.isEmpty ? nil : workdir)
        }
    }

    private func commandStrings(_ value: Any?) -> [String] {
        if let value = value as? String { return [value] }
        if let values = value as? [String] { return values }
        if let values = value as? [Any] {
            return values.compactMap { $0 as? String }
        }
        return []
    }

    private func extractJavaScriptValues(_ source: String, property: String) -> [String] {
        let characters = Array(source)
        var commands: [String] = []
        var index = 0
        while index < characters.count {
            if let next = skipJavaScriptNonCode(characters, from: index) {
                index = next
                continue
            }
            guard isIdentifierStart(characters[index]) else {
                index += 1
                continue
            }
            let start = index
            index += 1
            while index < characters.count, isIdentifierPart(characters[index]) { index += 1 }
            guard String(characters[start..<index]) == property else { continue }
            var cursor = index
            while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
            guard cursor < characters.count, characters[cursor] == ":" else { continue }
            cursor += 1
            while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
            guard cursor < characters.count,
                  characters[cursor] == "\"" || characters[cursor] == "'" || characters[cursor] == "`",
                  let parsed = parseJavaScriptString(characters, from: cursor)
            else { continue }
            if !parsed.value.contains("${") {
                commands.append(parsed.value)
            }
            index = parsed.nextIndex
        }
        return commands
    }

    private func extractJavaScriptExecCommands(_ source: String) -> [ExecutedCommand] {
        let characters = Array(source)
        let marker = Array("tools.exec_command")
        var results: [ExecutedCommand] = []
        var index = 0
        while index < characters.count {
            if let next = skipJavaScriptNonCode(characters, from: index) {
                index = next
                continue
            }
            let markerEnd = index + marker.count
            guard markerEnd <= characters.count,
                  Array(characters[index..<markerEnd]) == marker,
                  index == 0 || !isIdentifierPart(characters[index - 1])
            else {
                index += 1
                continue
            }
            var cursor = markerEnd
            while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
            guard cursor < characters.count, characters[cursor] == "(" else {
                index = markerEnd
                continue
            }
            let bodyStart = cursor + 1
            cursor = bodyStart
            var depth = 1
            while cursor < characters.count, depth > 0 {
                if characters[cursor] == "\"" || characters[cursor] == "'" || characters[cursor] == "`" {
                    cursor = skipJavaScriptString(characters, from: cursor)
                    continue
                }
                if characters[cursor] == "(" { depth += 1 }
                if characters[cursor] == ")" { depth -= 1 }
                cursor += 1
            }
            guard depth == 0 else { break }
            let body = String(characters[bodyStart..<(cursor - 1)])
            let workdir = extractJavaScriptValues(body, property: "workdir").first
            for command in extractJavaScriptValues(body, property: "cmd") {
                results.append(ExecutedCommand(text: command, workdir: workdir))
            }
            index = cursor
        }
        return results
    }

    private func commandExecutionCWD(_ command: ExecutedCommand, sessionCWD: String) -> String {
        if let workdir = command.workdir, !workdir.isEmpty {
            return resolve(path: workdir, cwd: sessionCWD)
        }
        let pattern = #"^\s*cd\s+(?:--\s+)?(\"[^\"]+\"|'[^']+'|[^;&|\s]+)\s*&&"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: command.text,
                range: NSRange(command.text.startIndex..<command.text.endIndex, in: command.text)
              ),
              let directoryRange = Range(match.range(at: 1), in: command.text)
        else { return sessionCWD }
        let directory = String(command.text[directoryRange])
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .replacingOccurrences(of: #"\ "#, with: " ")
        return resolve(path: directory, cwd: sessionCWD)
    }

    /// Returns the index just past a comment or string literal starting at
    /// `index`, or nil when that position is ordinary code. Both JavaScript
    /// scanners use this to stay out of quoted and commented text.
    private func skipJavaScriptNonCode(_ characters: [Character], from index: Int) -> Int? {
        if characters[index] == "/", index + 1 < characters.count {
            if characters[index + 1] == "/" {
                var cursor = index + 2
                while cursor < characters.count, characters[cursor] != "\n" { cursor += 1 }
                return cursor
            }
            if characters[index + 1] == "*" {
                var cursor = index + 2
                while cursor + 1 < characters.count,
                      !(characters[cursor] == "*" && characters[cursor + 1] == "/")
                { cursor += 1 }
                return min(characters.count, cursor + 2)
            }
        }
        if characters[index] == "\"" || characters[index] == "'" || characters[index] == "`" {
            return skipJavaScriptString(characters, from: index)
        }
        return nil
    }

    private func skipJavaScriptString(_ characters: [Character], from start: Int) -> Int {
        parseJavaScriptString(characters, from: start)?.nextIndex ?? characters.count
    }

    private func parseJavaScriptString(
        _ characters: [Character],
        from start: Int
    ) -> (value: String, nextIndex: Int)? {
        guard start < characters.count else { return nil }
        let quote = characters[start]
        var index = start + 1
        var value = ""
        while index < characters.count {
            let character = characters[index]
            if character == quote {
                return (value, index + 1)
            }
            if character == "\\" {
                index += 1
                guard index < characters.count else { return nil }
                let escaped = characters[index]
                switch escaped {
                case "n": value.append("\n")
                case "r": value.append("\r")
                case "t": value.append("\t")
                case "\n": break
                default: value.append(escaped)
                }
                index += 1
                continue
            }
            value.append(character)
            index += 1
        }
        return nil
    }

    private func isIdentifierStart(_ character: Character) -> Bool {
        character == "_" || character == "$" || character.isLetter
    }

    private func isIdentifierPart(_ character: Character) -> Bool {
        isIdentifierStart(character) || character.isNumber
    }

    private func extractExecutedSkillPaths(_ command: String) -> [String] {
        let withoutHeredocs = removingHeredocBodies(command)
        guard !containsAmbiguousControlFlow(withoutHeredocs) else { return [] }
        return shellSegments(withoutHeredocs).flatMap { segment in
            guard isSupportedReadSegment(segment) else { return [String]() }
            return extractSkillPaths(removingOutputRedirections(segment))
        }
    }

    private func removingOutputRedirections(_ segment: String) -> String {
        segment.replacingOccurrences(
            of: #"(?:\d+|&)?>>?\s*(?:'[^']*'|\"[^\"]*\"|[^\s;&|]+)"#,
            with: " ",
            options: .regularExpression
        )
    }

    private func containsAmbiguousControlFlow(_ command: String) -> Bool {
        var unquoted = ""
        var quote: Character?
        var escaped = false
        var index = command.startIndex
        while index < command.endIndex {
            let character = command[index]
            let nextIndex = command.index(after: index)
            let next = nextIndex < command.endIndex ? command[nextIndex] : nil
            if escaped {
                unquoted.append(" ")
                escaped = false
            } else if character == "\\", quote != "'" {
                unquoted.append(" ")
                escaped = true
            } else if let activeQuote = quote {
                unquoted.append(character == "\n" ? "\n" : " ")
                if character == activeQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
                unquoted.append(" ")
            } else if character == "|", next == "|" {
                return true
            } else {
                unquoted.append(character)
            }
            index = nextIndex
        }
        let pattern = #"(?i)(?:^|[^A-Za-z0-9_])(?:if|then|elif|else|fi|case|esac|for|while|until|select)\b"#
        return unquoted.range(of: pattern, options: .regularExpression) != nil
    }

    private func isSupportedReadSegment(_ segment: String) -> Bool {
        var value = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        let controlPrefix = #"^(?:(?:then|do|else)\s+)+"#
        value = value.replacingOccurrences(
            of: controlPrefix,
            with: "",
            options: .regularExpression
        )
        let pattern = #"^(?:(?:[A-Za-z_][A-Za-z0-9_]*=(?:'[^']*'|\"[^\"]*\"|[^\s]+))\s+)*(?:(?:command|builtin)\s+)?(?:/usr/bin/|/bin/)?(?:cat|sed|head|tail|bat)\b"#
        return value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func shellSegments(_ command: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var index = command.startIndex

        func finishSegment() {
            let value = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { segments.append(value) }
            current = ""
        }

        while index < command.endIndex {
            let character = command[index]
            let nextIndex = command.index(after: index)
            let next = nextIndex < command.endIndex ? command[nextIndex] : nil
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\", quote != "'" {
                current.append(character)
                escaped = true
            } else if let activeQuote = quote {
                current.append(character)
                if character == activeQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
                current.append(character)
            } else if character == "#", current.isEmpty || current.last?.isWhitespace == true {
                while index < command.endIndex, command[index] != "\n" {
                    index = command.index(after: index)
                }
                finishSegment()
                continue
            } else if character == "\n" || character == ";" || character == "|" || character == "&" {
                finishSegment()
                if (character == "|" || character == "&"), next == character {
                    index = nextIndex
                }
            } else {
                current.append(character)
            }
            index = command.index(after: index)
        }
        finishSegment()
        return segments
    }

    private func removingHeredocBodies(_ command: String) -> String {
        let lines = command.components(separatedBy: .newlines)
        var output: [String] = []
        var delimiters: [(value: String, stripsTabs: Bool)] = []
        for line in lines {
            if let delimiter = delimiters.first {
                let candidate = delimiter.stripsTabs
                    ? String(line.drop(while: { $0 == "\t" }))
                    : line
                if candidate == delimiter.value {
                    delimiters.removeFirst()
                }
                continue
            }
            output.append(line)
            delimiters.append(contentsOf: heredocDelimiters(in: line))
        }
        return output.joined(separator: "\n")
    }

    private func heredocDelimiters(in line: String) -> [(value: String, stripsTabs: Bool)] {
        let pattern = #"<<(-)?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return expression.matches(in: line, range: range).compactMap { match in
            guard let valueRange = Range(match.range(at: 3), in: line) else { return nil }
            return (String(line[valueRange]), match.range(at: 1).location != NSNotFound)
        }
    }

    private func extractSkillPaths(_ text: String) -> [String] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let patterns = [
            #"[\"']((?:file://)?(?:~|/|\.\.?/)[^\"'\r\n]*?/SKILL\.md)[\"']"#,
            #"((?:file://)?(?:~|/|\.\.?/)?(?:[A-Za-z0-9_@.+~:-]|\\ )+(?:/(?:[A-Za-z0-9_@.+~:-]|\\ )+)+/SKILL\.md)(?=$|[\s;&|<>()])"#
        ]
        var matches: [(location: Int, length: Int, path: String)] = []
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in expression.matches(in: text, range: range) {
                guard match.numberOfRanges > 1,
                      let matchRange = Range(match.range(at: 1), in: text)
                else { continue }
                matches.append((
                    location: match.range(at: 1).location,
                    length: match.range(at: 1).length,
                    path: String(text[matchRange])
                        .replacingOccurrences(of: "file://", with: "")
                        .replacingOccurrences(of: #"\ "#, with: " ")
                ))
            }
        }
        matches.sort {
            $0.location == $1.location ? $0.length > $1.length : $0.location < $1.location
        }
        var seenRanges = Set<String>()
        return matches.compactMap { match in
            guard seenRanges.insert("\(match.location):\(match.length)").inserted else { return nil }
            return match.path
        }
    }

    private func resolve(path: String, cwd: String) -> String {
        let expanded: String
        if path.hasPrefix("~/") {
            expanded = homeURL().standardizedFileURL
                .appendingPathComponent(String(path.dropFirst(2))).path
        } else if path.hasPrefix("/") {
            expanded = path
        } else if !cwd.isEmpty {
            expanded = URL(fileURLWithPath: cwd).appendingPathComponent(path).path
        } else {
            expanded = path
        }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        if fileManager.fileExists(atPath: url.path) {
            return url.resolvingSymlinksInPath().standardizedFileURL.path
        }
        return url.path
    }

    private func identify(path: String) -> ParsedSkillIdentity {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        let components = directory.pathComponents
        let folderName = directory.lastPathComponent
        let frontmatterName = readSkillName(url) ?? folderName

        if components.contains(".system") {
            return ParsedSkillIdentity(
                id: "system:\(frontmatterName)",
                name: frontmatterName,
                confirmationName: frontmatterName,
                canonicalPath: directory.path,
                scope: "system"
            )
        }

        if let skillsIndex = components.lastIndex(of: "skills"),
           components.prefix(skillsIndex).contains("plugins"),
           components.prefix(skillsIndex).contains("cache")
        {
            let marketplace = skillsIndex >= 3 ? components[skillsIndex - 3] : "unknown"
            let pluginName = skillsIndex >= 2 ? components[skillsIndex - 2] : "plugin"
            let pluginOwner = "\(MetagentCore.normalizedPluginMarketplace(marketplace))/\(pluginName)"
            return ParsedSkillIdentity(
                id: "plugin:\(pluginOwner):\(folderName)",
                name: "\(pluginName):\(frontmatterName)",
                confirmationName: frontmatterName,
                canonicalPath: directory.path,
                scope: "plugin"
            )
        }

        let codexSkills = skillUsageCodexHomeURL().appendingPathComponent("skills").standardizedFileURL
        if directory.deletingLastPathComponent().standardizedFileURL.path == codexSkills.path {
            return ParsedSkillIdentity(
                id: "global:codex:\(frontmatterName)",
                name: frontmatterName,
                confirmationName: frontmatterName,
                canonicalPath: directory.path,
                scope: "global"
            )
        }

        if let containerIndex = components.lastIndex(where: {
            agentDirectoryNames.contains($0)
        }),
           containerIndex + 1 < components.count,
           components[containerIndex + 1] == "skills"
        {
            let root = NSString.path(withComponents: Array(components[..<containerIndex]))
            let container = components[containerIndex]
            let identityName = container == ".agents"
                ? frontmatterName
                : "\(container.dropFirst()):\(frontmatterName)"
            if URL(fileURLWithPath: root).standardizedFileURL.path
                == homeURL().standardizedFileURL.path
            {
                return ParsedSkillIdentity(
                    id: "global:\(identityName)",
                    name: frontmatterName,
                    confirmationName: frontmatterName,
                    canonicalPath: directory.path,
                    scope: "global"
                )
            }
            return ParsedSkillIdentity(
                id: "project:\(root):\(identityName)",
                name: frontmatterName,
                confirmationName: frontmatterName,
                canonicalPath: directory.path,
                scope: "project"
            )
        }

        return ParsedSkillIdentity(
            id: "path:\(directory.path)",
            name: frontmatterName,
            confirmationName: frontmatterName,
            canonicalPath: directory.path,
            scope: "unknown"
        )
    }

    private func readSkillName(_ file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 8_192)) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(40) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("name:") else { continue }
            return String(trimmed.dropFirst(5))
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
        }
        return nil
    }

    private func string(_ value: Any?) -> String {
        value as? String ?? ""
    }

    private func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber {
            return number.int64Value
        }
        if let value = value as? String {
            return Int64(value)
        }
        return nil
    }

    private func unixTimestampDate(_ value: Any?) -> Date? {
        let seconds: Double?
        if let number = value as? NSNumber {
            seconds = number.doubleValue
        } else if let value = value as? String {
            seconds = Double(value)
        } else {
            seconds = nil
        }
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1_000 : seconds)
    }

    private func rolloutSessionID(_ sourcePath: String) -> String? {
        let filename = URL(fileURLWithPath: sourcePath)
            .deletingPathExtension()
            .lastPathComponent
        guard filename.count >= 36 else { return nil }
        let candidate = String(filename.suffix(36))
        return UUID(uuidString: candidate) == nil ? nil : candidate
    }

    private func agentRunKind(_ session: [String: Any]) -> String {
        func hasJSONValue(_ value: Any?) -> Bool {
            value != nil && !(value is NSNull)
        }

        switch string(session["thread_source"]) {
        case "user":
            return "user"
        case "automation":
            return "automation"
        case "guardian_review":
            return "guardian"
        case "subagent":
            return "subagent"
        default:
            if hasJSONValue(session["agent_path"])
                || hasJSONValue(session["parent_thread_id"])
                || hasJSONValue(session["forked_from_id"])
                || hasJSONValue((session["source"] as? [String: Any])?["subagent"])
            {
                return "subagent"
            }
            return "unknown"
        }
    }
}
