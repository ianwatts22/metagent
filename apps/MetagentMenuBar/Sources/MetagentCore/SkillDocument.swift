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
    public let rawText: String
}

public enum SkillMarkdownBlockKind: Equatable, Sendable {
    case heading(level: Int)
    case paragraph
    case unorderedListItem
    case orderedListItem(marker: String)
    case quote
    case code(language: String?)
    case divider
}

public struct SkillMarkdownBlock: Equatable, Identifiable, Sendable {
    public let id: Int
    public let kind: SkillMarkdownBlockKind
    public let text: String
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
            rawFrontmatter: parsed.frontmatter.isEmpty ? nil : parsed.frontmatter.joined(separator: "\n"),
            rawText: text
        )
    }

    public static func updateSkillDocument(
        at skillDirectoryPath: String,
        expectedRawText: String,
        name: String,
        description: String,
        bodyMarkdown: String
    ) throws -> SkillDocument {
        let directory = URL(fileURLWithPath: skillDirectoryPath).standardizedFileURL
        let path = directory.appendingPathComponent("SKILL.md")
        let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        let pathValues = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard resolvedDirectory.path == directory.path,
              pathValues.isRegularFile == true,
              pathValues.isSymbolicLink != true
        else {
            throw skillDocumentError(
                code: 1,
                message: "Only a canonical, non-symlinked SKILL.md can be edited."
            )
        }

        let currentText = try String(contentsOf: path, encoding: .utf8)
        guard currentText == expectedRawText else {
            throw skillDocumentError(
                code: 2,
                message: "SKILL.md changed on disk. Reload it before saving your edits."
            )
        }

        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, !cleanDescription.isEmpty else {
            throw skillDocumentError(code: 3, message: "Name and description are required.")
        }
        guard !cleanName.contains(where: \.isNewline) else {
            throw skillDocumentError(code: 4, message: "The skill name must fit on one line.")
        }

        let parsed = splitSkillDocument(currentText)
        var frontmatter = parsed.frontmatter
        replaceFrontmatterField(
            key: "name",
            replacement: ["name: \(yamlQuoted(cleanName))"],
            lines: &frontmatter
        )
        let descriptionLines = cleanDescription.components(separatedBy: .newlines)
        let descriptionReplacement = descriptionLines.count == 1
            ? ["description: \(yamlQuoted(cleanDescription))"]
            : ["description: |-"] + descriptionLines.map { "  \($0)" }
        replaceFrontmatterField(
            key: "description",
            replacement: descriptionReplacement,
            lines: &frontmatter
        )

        let cleanBody = bodyMarkdown.trimmingCharacters(in: .newlines)
        let updated = """
        ---
        \(frontmatter.joined(separator: "\n"))
        ---

        \(cleanBody)
        """
        try (updated + "\n").write(to: path, atomically: true, encoding: .utf8)
        return try loadSkillDocument(at: directory.path)
    }

    public static func skillMarkdownBlocks(_ markdown: String) -> [SkillMarkdownBlock] {
        parseSkillMarkdownBlocks(markdown)
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

private func replaceFrontmatterField(
    key: String,
    replacement: [String],
    lines: inout [String]
) {
    let prefix = "\(key):"
    guard let start = lines.firstIndex(where: {
        $0.first?.isWhitespace != true
            && $0.trimmingCharacters(in: .whitespaces).hasPrefix(prefix)
    }) else {
        let insertionIndex = key == "name" ? 0 : min(1, lines.count)
        lines.insert(contentsOf: replacement, at: insertionIndex)
        return
    }
    var end = start + 1
    while end < lines.count {
        let line = lines[end]
        if line.first?.isWhitespace != true, !line.trimmingCharacters(in: .whitespaces).isEmpty {
            break
        }
        end += 1
    }
    lines.replaceSubrange(start..<end, with: replacement)
}

private func yamlQuoted(_ value: String) -> String {
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    return "\"\(escaped)\""
}

private func skillDocumentError(code: Int, message: String) -> NSError {
    NSError(
        domain: "MetagentSkillDocument",
        code: code,
        userInfo: [NSLocalizedDescriptionKey: message]
    )
}

private func parseSkillMarkdownBlocks(_ markdown: String) -> [SkillMarkdownBlock] {
    let lines = markdown.components(separatedBy: .newlines)
    var blocks: [(SkillMarkdownBlockKind, String)] = []
    var paragraph: [String] = []
    var code: [String] = []
    var codeLanguage: String?
    var isInCodeBlock = false

    func flushParagraph() {
        guard !paragraph.isEmpty else { return }
        blocks.append((.paragraph, paragraph.joined(separator: " ")))
        paragraph.removeAll(keepingCapacity: true)
    }

    func flushCode() {
        blocks.append((.code(language: codeLanguage), code.joined(separator: "\n")))
        code.removeAll(keepingCapacity: true)
        codeLanguage = nil
    }

    for rawLine in lines {
        let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") {
            if isInCodeBlock {
                flushCode()
                isInCodeBlock = false
            } else {
                flushParagraph()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                codeLanguage = language.isEmpty ? nil : language
                isInCodeBlock = true
            }
            continue
        }
        if isInCodeBlock {
            code.append(line)
            continue
        }
        if trimmed.isEmpty {
            flushParagraph()
            continue
        }
        if ["---", "***", "___"].contains(trimmed) {
            flushParagraph()
            blocks.append((.divider, ""))
            continue
        }
        let headingLevel = trimmed.prefix { $0 == "#" }.count
        if (1...6).contains(headingLevel),
           trimmed.dropFirst(headingLevel).first == " "
        {
            flushParagraph()
            blocks.append((
                .heading(level: headingLevel),
                String(trimmed.dropFirst(headingLevel + 1))
            ))
            continue
        }
        if let prefix = ["- ", "* ", "+ "].first(where: { trimmed.hasPrefix($0) }) {
            flushParagraph()
            blocks.append((.unorderedListItem, String(trimmed.dropFirst(prefix.count))))
            continue
        }
        if let ordered = orderedListParts(trimmed) {
            flushParagraph()
            blocks.append((.orderedListItem(marker: ordered.marker), ordered.text))
            continue
        }
        if trimmed.hasPrefix("> ") {
            flushParagraph()
            blocks.append((.quote, String(trimmed.dropFirst(2))))
            continue
        }
        paragraph.append(trimmed)
    }
    if isInCodeBlock {
        flushCode()
    } else {
        flushParagraph()
    }
    return blocks.enumerated().map { index, block in
        SkillMarkdownBlock(id: index, kind: block.0, text: block.1)
    }
}

private func orderedListParts(_ line: String) -> (marker: String, text: String)? {
    guard let separator = line.firstIndex(where: { $0 == "." || $0 == ")" }) else { return nil }
    let marker = String(line[...separator])
    guard !marker.dropLast().isEmpty,
          marker.dropLast().allSatisfy(\.isNumber)
    else { return nil }
    let contentStart = line.index(after: separator)
    guard contentStart < line.endIndex, line[contentStart] == " " else { return nil }
    return (marker, String(line[line.index(after: contentStart)...]))
}
