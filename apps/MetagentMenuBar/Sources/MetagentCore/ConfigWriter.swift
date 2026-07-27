import Foundation

/// The three keys the settings surface owns. Anything else in the file belongs
/// to the user and is carried through a save untouched.
private let managedConfigKeys = ["roots", "max_depth", "ignore_projects"]

public extension MetagentCore {
    /// Rewrites the managed keys in `config.toml` while preserving comments,
    /// commented-out experiments, and any keys this app does not know about.
    static func saveUserConfig(_ config: MetagentConfig) throws {
        try saveUserConfig(config, at: userConfigPath())
    }
}

extension MetagentCore {
    static func saveUserConfig(_ config: MetagentConfig, at path: URL) throws {
        let existing: String
        if fileManager.fileExists(atPath: path.path) {
            do {
                existing = try String(contentsOf: path, encoding: .utf8)
            } catch {
                throw configError("failed reading \(path.path): \(error.localizedDescription)")
            }
        } else {
            existing = ""
        }
        var text = renderedManagedConfig(config)
        let preserved = configTextDroppingManagedKeys(existing)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !preserved.isEmpty {
            text += "\n\(preserved)\n"
        }

        do {
            try fileManager.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try text.write(to: path, atomically: true, encoding: .utf8)
        } catch {
            throw configError("failed writing \(path.path): \(error.localizedDescription)")
        }
    }
}

private func renderedManagedConfig(_ config: MetagentConfig) -> String {
    """
    \(renderedStringArray(key: "roots", values: config.roots))
    max_depth = \(config.maxDepth)
    \(renderedStringArray(key: "ignore_projects", values: config.ignoreProjects))
    """
}

private func renderedStringArray(key: String, values: [String]) -> String {
    guard !values.isEmpty else { return "\(key) = []" }
    let body = values
        .map { "  \"\(escapedTomlString($0))\"" }
        .joined(separator: ",\n")
    return "\(key) = [\n\(body)\n]"
}

private func escapedTomlString(_ value: String) -> String {
    var escaped = ""
    for scalar in value.unicodeScalars {
        switch scalar.value {
        case 0x08: escaped += "\\b"
        case 0x09: escaped += "\\t"
        case 0x0A: escaped += "\\n"
        case 0x0C: escaped += "\\f"
        case 0x0D: escaped += "\\r"
        case 0x22: escaped += "\\\""
        case 0x5C: escaped += "\\\\"
        case 0x00...0x1F, 0x7F:
            escaped += String(format: "\\u%04X", scalar.value)
        default:
            escaped.unicodeScalars.append(scalar)
        }
    }
    return escaped
}

/// Drops each managed assignment, including the continuation lines of an array
/// that spans several lines, and leaves every other line exactly as written.
private func configTextDroppingManagedKeys(_ text: String) -> String {
    var kept: [String] = []
    var openArrayDepth = 0
    var isTopLevel = true
    var userValueContext = TOMLValueContext()

    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        if userValueContext.isContinuing {
            kept.append(String(line))
            userValueContext.consume(line)
            continue
        }
        let code = stripTomlComment(line)
        if openArrayDepth > 0 {
            openArrayDepth += bracketDelta(code)
            continue
        }
        if isTomlTableHeader(code) {
            isTopLevel = false
            kept.append(String(line))
            continue
        }
        guard isTopLevel,
              managedConfigKeys.contains(where: { assignsKey($0, in: code) })
        else {
            kept.append(String(line))
            userValueContext.consume(line)
            continue
        }
        openArrayDepth = max(0, bracketDelta(code))
    }

    return kept.joined(separator: "\n")
}

private func isTomlTableHeader(_ code: String) -> Bool {
    let trimmed = code.trimmingCharacters(in: .whitespaces)
    return trimmed.hasPrefix("[") && trimmed.hasSuffix("]")
}

/// Tracks multiline user-owned values so content that merely looks like a table
/// header cannot change the scope of later managed assignments.
private struct TOMLValueContext {
    private var arrayDepth = 0
    private var multilineQuote: Character?

    var isContinuing: Bool {
        arrayDepth > 0 || multilineQuote != nil
    }

    mutating func consume(_ line: Substring) {
        let characters = Array(line)
        var quote: Character?
        var escaped = false
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if let activeMultilineQuote = multilineQuote {
                if character == activeMultilineQuote,
                   hasTripleQuote(at: index, in: characters),
                   activeMultilineQuote == "'" || !isEscaped(at: index, in: characters)
                {
                    self.multilineQuote = nil
                    index += 3
                } else {
                    index += 1
                }
                continue
            }
            if let activeQuote = quote {
                if activeQuote == "\"", escaped {
                    escaped = false
                } else if activeQuote == "\"", character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
                index += 1
                continue
            }
            if character == "#" {
                break
            }
            if character == "\"" || character == "'" {
                if hasTripleQuote(at: index, in: characters) {
                    multilineQuote = character
                    index += 3
                } else {
                    quote = character
                    index += 1
                }
                continue
            }
            if character == "[" {
                arrayDepth += 1
            } else if character == "]" {
                arrayDepth = max(0, arrayDepth - 1)
            }
            index += 1
        }
    }
}

private func hasTripleQuote(at index: Int, in characters: [Character]) -> Bool {
    index + 2 < characters.count
        && characters[index] == characters[index + 1]
        && characters[index] == characters[index + 2]
}

private func isEscaped(at index: Int, in characters: [Character]) -> Bool {
    guard index > 0 else { return false }
    var backslashCount = 0
    var cursor = index - 1
    while characters[cursor] == "\\" {
        backslashCount += 1
        guard cursor > 0 else { break }
        cursor -= 1
    }
    return backslashCount % 2 == 1
}

private func assignsKey(_ key: String, in code: String) -> Bool {
    let trimmed = code.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix(key) else { return false }
    return trimmed
        .dropFirst(key.count)
        .trimmingCharacters(in: .whitespaces)
        .hasPrefix("=")
}

private func bracketDelta(_ code: String) -> Int {
    var depth = 0
    var quote: Character?
    var escaped = false

    for character in code {
        if let activeQuote = quote {
            if activeQuote == "\"", escaped {
                escaped = false
            } else if activeQuote == "\"", character == "\\" {
                escaped = true
            } else if character == activeQuote {
                quote = nil
            }
            continue
        }

        if character == "\"" || character == "'" {
            quote = character
            continue
        }

        switch character {
        case "[": depth += 1
        case "]": depth -= 1
        default: break
        }
    }
    return depth
}
