import Foundation

public struct SkillDocumentMetadata: Equatable, Identifiable, Sendable {
    public var id: String { key }
    public let key: String
    public let value: String
}

public struct SkillDocument: Equatable, Sendable {
    public let directoryPath: String
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

public struct SkillPortablePathFinding: Equatable, Identifiable, Sendable {
    public var id: String { relativePath }
    public let relativePath: String
    public let occurrenceCount: Int
    public let canReplaceAutomatically: Bool
}

public struct SkillPortablePathScan: Equatable, Sendable {
    public let homePath: String
    public let findings: [SkillPortablePathFinding]

    public var replaceableOccurrenceCount: Int {
        findings.filter(\.canReplaceAutomatically).reduce(0) { $0 + $1.occurrenceCount }
    }

    public var reviewOccurrenceCount: Int {
        findings.filter { !$0.canReplaceAutomatically }.reduce(0) { $0 + $1.occurrenceCount }
    }
}

public struct SkillPortablePathUpdateReport: Equatable, Sendable {
    public let updatedFiles: [String]
    public let replacedOccurrenceCount: Int
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
            directoryPath: directory.path,
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
        guard isValidEditableSkillName(cleanName) else {
            throw skillDocumentError(
                code: 5,
                message: "Use letters, numbers, periods, underscores, or hyphens; the name must start with a letter or number."
            )
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
            || cleanDescription.unicodeScalars.contains(where: isYAMLForbiddenControl)
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
        let targetDirectory = directory
            .deletingLastPathComponent()
            .appendingPathComponent(cleanName, isDirectory: true)
            .standardizedFileURL
        guard targetDirectory.path != directory.path else {
            try (updated + "\n").write(to: path, atomically: true, encoding: .utf8)
            return try loadSkillDocument(at: directory.path)
        }
        let targetExists = FileManager.default.fileExists(atPath: targetDirectory.path)
        guard !targetExists || urlsReferToSameFile(directory, targetDirectory) else {
            throw skillDocumentError(
                code: 6,
                message: "A skill folder named \(cleanName) already exists."
            )
        }

        let projections = skillProjectionLinks(resolvingTo: directory)
        var renamedProjections: [(old: URL, new: URL, destination: String)] = []
        do {
            try moveItemAllowingCaseOnlyRename(from: directory, to: targetDirectory)
            for projection in projections {
                let renamed = projection.url
                    .deletingLastPathComponent()
                    .appendingPathComponent(cleanName)
                try FileManager.default.removeItem(at: projection.url)
                do {
                    try FileManager.default.createSymbolicLink(
                        atPath: renamed.path,
                        withDestinationPath: renamedSymlinkDestination(
                            projection.destination,
                            newName: cleanName
                        )
                    )
                    renamedProjections.append((
                        old: projection.url,
                        new: renamed,
                        destination: projection.destination
                    ))
                } catch {
                    try? FileManager.default.createSymbolicLink(
                        atPath: projection.url.path,
                        withDestinationPath: projection.destination
                    )
                    throw error
                }
            }
            try (updated + "\n").write(
                to: targetDirectory.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )
        } catch {
            for projection in renamedProjections.reversed() {
                try? FileManager.default.removeItem(at: projection.new)
                try? FileManager.default.createSymbolicLink(
                    atPath: projection.old.path,
                    withDestinationPath: projection.destination
                )
            }
            if FileManager.default.fileExists(atPath: targetDirectory.path) {
                try? moveItemAllowingCaseOnlyRename(from: targetDirectory, to: directory)
            }
            throw skillDocumentError(
                code: 7,
                message: "Couldn’t rename the skill folder safely: \(error.localizedDescription)"
            )
        }
        return try loadSkillDocument(at: targetDirectory.path)
    }

    public static func skillMarkdownBlocks(_ markdown: String) -> [SkillMarkdownBlock] {
        parseSkillMarkdownBlocks(markdown)
    }

    public static func scanSkillForPersonalPaths(
        at skillDirectoryPath: String
    ) throws -> SkillPortablePathScan {
        let directory = try editableCanonicalSkillDirectory(at: skillDirectoryPath)
        return SkillPortablePathScan(
            homePath: FileManager.default.homeDirectoryForCurrentUser.path,
            findings: portablePathFiles(in: directory).map(\.finding)
        )
    }

    public static func replacePersonalPathsWithTilde(
        at skillDirectoryPath: String
    ) throws -> SkillPortablePathUpdateReport {
        let directory = try editableCanonicalSkillDirectory(at: skillDirectoryPath)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = portablePathFiles(in: directory).filter {
            $0.finding.canReplaceAutomatically
        }
        var originals: [(url: URL, text: String)] = []
        do {
            for candidate in candidates {
                let text = try String(contentsOf: candidate.url, encoding: .utf8)
                originals.append((candidate.url, text))
                try replacingHomePath(in: text, home: home, replacement: "~").text
                    .write(to: candidate.url, atomically: true, encoding: .utf8)
            }
        } catch {
            for original in originals {
                try? original.text.write(to: original.url, atomically: true, encoding: .utf8)
            }
            throw skillDocumentError(
                code: 9,
                message: "Couldn’t make the skill portable; edited files were restored. \(error.localizedDescription)"
            )
        }
        return SkillPortablePathUpdateReport(
            updatedFiles: candidates.map(\.finding.relativePath),
            replacedOccurrenceCount: candidates.reduce(0) {
                $0 + $1.finding.occurrenceCount
            }
        )
    }
}

private func editableCanonicalSkillDirectory(at path: String) throws -> URL {
    let directory = URL(fileURLWithPath: path).standardizedFileURL
    let skillFile = directory.appendingPathComponent("SKILL.md")
    let values = try skillFile.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard directory.resolvingSymlinksInPath().standardizedFileURL.path == directory.path,
          values.isRegularFile == true,
          values.isSymbolicLink != true
    else {
        throw skillDocumentError(
            code: 8,
            message: "Only a canonical, non-symlinked skill can be scanned or changed."
        )
    }
    return directory
}

private func portablePathFiles(
    in directory: URL
) -> [(url: URL, finding: SkillPortablePathFinding)] {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
    guard let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else { return [] }
    return enumerator.compactMap { item in
        guard let url = item as? URL,
              let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? 0) <= 2_000_000,
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        let count = replacingHomePath(in: text, home: home, replacement: "~").count
        guard count > 0 else { return nil }
        let resolvedDirectoryComponents = directory.resolvingSymlinksInPath().pathComponents
        let resolvedFileComponents = url.resolvingSymlinksInPath().pathComponents
        let componentCount = max(
            1,
            resolvedFileComponents.count - resolvedDirectoryComponents.count
        )
        let relativeComponents = Array(resolvedFileComponents.suffix(componentCount))
        let relative = relativeComponents.joined(separator: "/")
        let isDocumentation = url.lastPathComponent.lowercased() == "skill.md"
            || (
                relativeComponents.first?.lowercased() == "references"
                    && ["md", "mdx", "txt"].contains(url.pathExtension.lowercased())
            )
        return (
            url,
            SkillPortablePathFinding(
                relativePath: relative,
                occurrenceCount: count,
                canReplaceAutomatically: isDocumentation
            )
        )
    }
    .sorted { $0.finding.relativePath < $1.finding.relativePath }
}

private func replacingHomePath(
    in text: String,
    home: String,
    replacement: String
) -> (text: String, count: Int) {
    guard !home.isEmpty else { return (text, 0) }
    var result = text
    var ranges: [Range<String.Index>] = []
    var searchStart = text.startIndex
    while searchStart < text.endIndex,
          let range = text.range(of: home, range: searchStart..<text.endIndex)
    {
        let hasLeadingBoundary = range.lowerBound == text.startIndex
            || text[text.index(before: range.lowerBound)].isWhitespace
            || "\"'`([{<=:".contains(text[text.index(before: range.lowerBound)])
        let hasTrailingBoundary = range.upperBound == text.endIndex
            || text[range.upperBound] == "/"
            || text[range.upperBound].isWhitespace
            || "\"'`)]}>,.:;!?".contains(text[range.upperBound])
        if hasLeadingBoundary, hasTrailingBoundary {
            ranges.append(range)
        }
        searchStart = range.upperBound
    }
    for range in ranges.reversed() {
        result.replaceSubrange(range, with: replacement)
    }
    return (result, ranges.count)
}

private func urlsReferToSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
    let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
    guard let lhsIdentifier = try? lhs.resourceValues(forKeys: keys).fileResourceIdentifier as? NSObject,
          let rhsIdentifier = try? rhs.resourceValues(forKeys: keys).fileResourceIdentifier as? NSObject
    else { return false }
    return lhsIdentifier.isEqual(rhsIdentifier)
}

private func moveItemAllowingCaseOnlyRename(from source: URL, to destination: URL) throws {
    let fileManager = FileManager.default
    let destinationExists = fileManager.fileExists(atPath: destination.path)
    guard destinationExists, urlsReferToSameFile(source, destination) else {
        try fileManager.moveItem(at: source, to: destination)
        return
    }

    let temporary = source
        .deletingLastPathComponent()
        .appendingPathComponent(".metagent-rename-\(UUID().uuidString)", isDirectory: true)
    try fileManager.moveItem(at: source, to: temporary)
    do {
        try fileManager.moveItem(at: temporary, to: destination)
    } catch {
        try? fileManager.moveItem(at: temporary, to: source)
        throw error
    }
}

private struct SkillProjectionLink {
    let url: URL
    let destination: String
}

private func skillProjectionLinks(resolvingTo directory: URL) -> [SkillProjectionLink] {
    let skillsDirectory = directory.deletingLastPathComponent()
    let agentDirectory = skillsDirectory.deletingLastPathComponent()
    guard skillsDirectory.lastPathComponent == "skills",
          [".agents", ".claude", ".codex"].contains(agentDirectory.lastPathComponent)
    else { return [] }
    let projectRoot = agentDirectory.deletingLastPathComponent()
    return [".agents", ".claude", ".codex"].compactMap { container in
        let candidate = projectRoot
            .appendingPathComponent(container)
            .appendingPathComponent("skills")
            .appendingPathComponent(directory.lastPathComponent)
        guard candidate.path != directory.path,
              (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true,
              candidate.resolvingSymlinksInPath().standardizedFileURL.path == directory.path,
              let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path)
        else { return nil }
        return SkillProjectionLink(url: candidate, destination: destination)
    }
}

private func renamedSymlinkDestination(_ destination: String, newName: String) -> String {
    let parent = (destination as NSString).deletingLastPathComponent
    return (parent as NSString).appendingPathComponent(newName)
}

private func isValidEditableSkillName(_ name: String) -> Bool {
    guard let first = name.unicodeScalars.first, isASCIIAlphanumeric(first) else {
        return false
    }
    return name.unicodeScalars.dropFirst().allSatisfy {
        isASCIIAlphanumeric($0) || $0 == "." || $0 == "_" || $0 == "-"
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

private func isYAMLForbiddenControl(_ scalar: UnicodeScalar) -> Bool {
    switch scalar.value {
    case 0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F...0x84, 0x86...0x9F:
        true
    default:
        false
    }
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
