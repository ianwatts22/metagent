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
        let existing = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
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
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

/// Drops each managed assignment, including the continuation lines of an array
/// that spans several lines, and leaves every other line exactly as written.
private func configTextDroppingManagedKeys(_ text: String) -> String {
    var kept: [String] = []
    var openArrayDepth = 0

    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let code = stripTomlComment(line)
        if openArrayDepth > 0 {
            openArrayDepth += bracketDelta(code)
            continue
        }
        guard managedConfigKeys.contains(where: { assignsKey($0, in: code) }) else {
            kept.append(String(line))
            continue
        }
        openArrayDepth = max(0, bracketDelta(code))
    }

    return kept.joined(separator: "\n")
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
    code.reduce(0) { depth, character in
        switch character {
        case "[": depth + 1
        case "]": depth - 1
        default: depth
        }
    }
}
