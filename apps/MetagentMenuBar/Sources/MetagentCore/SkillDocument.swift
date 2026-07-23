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
            description: skillFrontmatterDescription(lines: parsed.frontmatter),
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
        let descriptionLines = cleanDescription
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
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
    guard let value = decodedYAMLScalar(rawValue) else { return nil }
    return value.isEmpty ? nil : value
}

private func skillFrontmatterDescription(lines: [String]) -> String? {
    let prefix = "description:"
    guard let index = lines.firstIndex(where: {
        $0.first?.isWhitespace != true
            && $0.trimmingCharacters(in: .whitespaces).hasPrefix(prefix)
    }) else { return nil }
    let rawValue = String(lines[index].dropFirst(prefix.count))
        .trimmingCharacters(in: .whitespaces)
    guard ["|", "|-", "|+", ">", ">-", ">+"].contains(rawValue) else {
        guard let value = decodedYAMLScalar(rawValue) else { return nil }
        return value.isEmpty ? nil : value
    }
    let continuation = lines.dropFirst(index + 1)
        .prefix { $0.first?.isWhitespace == true || $0.trimmingCharacters(in: .whitespaces).isEmpty }
        .map { $0.trimmingCharacters(in: .whitespaces) }
    let value = continuation.joined(separator: rawValue.hasPrefix(">") ? " " : "\n")
    return value.isEmpty ? nil : value
}

func decodedYAMLScalar(_ rawValue: String) -> String? {
    guard rawValue.count >= 2 else { return rawValue }
    if rawValue.first == "\"", rawValue.last == "\"" {
        if let data = rawValue.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(
               with: data,
               options: .fragmentsAllowed
           ) as? String
        {
            return decoded
        }
        return decodedYAMLDoubleQuoted(String(rawValue.dropFirst().dropLast()))
    }
    if rawValue.first == "'", rawValue.last == "'" {
        return String(rawValue.dropFirst().dropLast())
            .replacingOccurrences(of: "''", with: "'")
    }
    return rawValue
}

private func decodedYAMLDoubleQuoted(_ encoded: String) -> String? {
    let characters = Array(encoded)
    var decoded = ""
    var index = 0
    while index < characters.count {
        let character = characters[index]
        guard character == "\\" else {
            decoded.append(character)
            index += 1
            continue
        }
        index += 1
        guard index < characters.count else { return nil }
        let escape = characters[index]
        index += 1
        switch escape {
        case "0": decoded.append("\0")
        case "a": decoded.append("\u{7}")
        case "b": decoded.append("\u{8}")
        case "t": decoded.append("\t")
        case "n": decoded.append("\n")
        case "v": decoded.append("\u{B}")
        case "f": decoded.append("\u{C}")
        case "r": decoded.append("\r")
        case "e": decoded.append("\u{1B}")
        case " ": decoded.append(" ")
        case "\"": decoded.append("\"")
        case "/": decoded.append("/")
        case "\\": decoded.append("\\")
        case "N": decoded.append("\u{85}")
        case "_": decoded.append("\u{A0}")
        case "L": decoded.append("\u{2028}")
        case "P": decoded.append("\u{2029}")
        case "x", "u", "U":
            let count = escape == "x" ? 2 : (escape == "u" ? 4 : 8)
            guard index + count <= characters.count else { return nil }
            let hex = String(characters[index..<(index + count)])
            guard let value = UInt32(hex, radix: 16) else { return nil }
            index += count
            if escape == "u", (0xD800...0xDBFF).contains(value) {
                guard index + 6 <= characters.count,
                      characters[index] == "\\",
                      characters[index + 1] == "u"
                else { return nil }
                let lowHex = String(characters[(index + 2)..<(index + 6)])
                guard let low = UInt32(lowHex, radix: 16),
                      (0xDC00...0xDFFF).contains(low),
                      let scalar = UnicodeScalar(
                          0x10000 + ((value - 0xD800) << 10) + (low - 0xDC00)
                      )
                else { return nil }
                decoded.unicodeScalars.append(scalar)
                index += 6
            } else {
                guard let scalar = UnicodeScalar(value) else { return nil }
                decoded.unicodeScalars.append(scalar)
            }
        default:
            return nil
        }
    }
    return decoded
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
    var escaped = ""
    for scalar in value.unicodeScalars {
        switch scalar.value {
        case 0x00: escaped += "\\0"
        case 0x07: escaped += "\\a"
        case 0x08: escaped += "\\b"
        case 0x09: escaped += "\\t"
        case 0x0A: escaped += "\\n"
        case 0x0B: escaped += "\\v"
        case 0x0C: escaped += "\\f"
        case 0x0D: escaped += "\\r"
        case 0x1B: escaped += "\\e"
        case 0x22: escaped += "\\\""
        case 0x5C: escaped += "\\\\"
        case 0x85: escaped += "\\N"
        case 0xA0: escaped += "\\_"
        case 0x2028: escaped += "\\L"
        case 0x2029: escaped += "\\P"
        case 0x01...0x1F, 0x7F...0x9F:
            escaped += String(format: "\\u%04X", scalar.value)
        default:
            escaped.unicodeScalars.append(scalar)
        }
    }
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
    var codeFence: (character: Character, length: Int)?

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
        if let activeFence = codeFence {
            if isClosingMarkdownFence(trimmed, matching: activeFence) {
                flushCode()
                codeFence = nil
                continue
            }
            code.append(line)
            continue
        }
        if let openingFence = openingMarkdownFence(trimmed) {
            flushParagraph()
            codeFence = (openingFence.character, openingFence.length)
            codeLanguage = openingFence.info.isEmpty ? nil : openingFence.info
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
    if codeFence != nil {
        flushCode()
    } else {
        flushParagraph()
    }
    return blocks.enumerated().map { index, block in
        SkillMarkdownBlock(id: index, kind: block.0, text: block.1)
    }
}

private func openingMarkdownFence(_ line: String) -> (character: Character, length: Int, info: String)? {
    guard let character = line.first, character == "`" || character == "~" else { return nil }
    let length = line.prefix { $0 == character }.count
    guard length >= 3 else { return nil }
    let info = String(line.dropFirst(length)).trimmingCharacters(in: .whitespaces)
    return (character, length, info)
}

private func isClosingMarkdownFence(
    _ line: String,
    matching opening: (character: Character, length: Int)
) -> Bool {
    guard line.first == opening.character else { return false }
    let length = line.prefix { $0 == opening.character }.count
    return length >= opening.length
        && line.dropFirst(length).trimmingCharacters(in: .whitespaces).isEmpty
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
