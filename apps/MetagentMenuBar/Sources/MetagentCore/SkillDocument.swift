import Foundation

public struct SkillDocumentMetadata: Equatable, Identifiable, Sendable {
    public var id: String { key }
    public let key: String
    public let value: String
}

public struct SkillDocument: Equatable, Sendable {
    public let name: String
    public let description: String?
    public let metadata: [SkillDocumentMetadata]
    public let bodyMarkdown: String
    public let rawFrontmatter: String?
}

extension MetagentCore {
    public static func loadSkillDocument(at skillDirectoryPath: String) throws -> SkillDocument {
        let directory = URL(fileURLWithPath: skillDirectoryPath).standardizedFileURL
        let path = directory.appendingPathComponent("SKILL.md")
        let text = try String(contentsOf: path, encoding: .utf8)
        let parsed = splitSkillDocument(text)
        let name = skillFrontmatterValue(key: "name", lines: parsed.frontmatter)
            ?? directory.lastPathComponent
        let metadata = topLevelSkillMetadata(lines: parsed.frontmatter)
            .filter { !["Name", "Description"].contains($0.key) }
        return SkillDocument(
            name: name,
            description: skillDescription(from: text),
            metadata: metadata,
            bodyMarkdown: parsed.body.trimmingCharacters(in: .whitespacesAndNewlines),
            rawFrontmatter: parsed.frontmatter.isEmpty ? nil : parsed.frontmatter.joined(separator: "\n")
        )
    }
}

private func splitSkillDocument(_ text: String) -> (frontmatter: [String], body: String) {
    let lines = text.components(separatedBy: .newlines)
    guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
          let closingIndex = lines.dropFirst().firstIndex(where: {
              $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---"
          })
    else {
        return ([], text)
    }
    return (
        Array(lines[1..<closingIndex]),
        lines.dropFirst(closingIndex + 1).joined(separator: "\n")
    )
}

private func skillFrontmatterValue(key: String, lines: [String]) -> String? {
    let prefix = "\(key):"
    guard let line = lines.first(where: {
        $0.first?.isWhitespace != true
            && $0.trimmingCharacters(in: .whitespaces).hasPrefix(prefix)
    }) else { return nil }
    let rawValue = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    let value = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    return value.isEmpty ? nil : value
}

private func topLevelSkillMetadata(lines: [String]) -> [SkillDocumentMetadata] {
    lines.compactMap { line in
        guard line.first.map({ !$0.isWhitespace }) ?? false,
              let separator = line.firstIndex(of: ":")
        else { return nil }
        let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
        let rawValue = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !rawValue.isEmpty, !["|", "|-", "|+", ">", ">-", ">+"].contains(rawValue) else {
            return nil
        }
        return SkillDocumentMetadata(
            key: key.replacingOccurrences(of: "-", with: " ").capitalized,
            value: rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        )
    }
}
