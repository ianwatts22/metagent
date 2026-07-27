import Foundation

public enum SkillOverlapKind: String, Codable, Equatable, Sendable {
    case pluginReplacement = "plugin_replacement"
    case exactDuplicate = "exact_duplicate"
    case globalProject = "global_project"
    case sameName = "same_name"
}

public struct SkillOverlapMember: Codable, Equatable, Identifiable, Sendable {
    public var id: String { canonicalPath }
    public let canonicalPath: String
    public let scope: String
    public let manager: String
    public let authority: String
    public let suggestedRemoval: Bool
}

public struct SkillOverlapGroup: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let skillName: String
    public let kind: SkillOverlapKind
    public let similarity: Double
    public let members: [SkillOverlapMember]
}

extension MetagentCore {
    public static func detectSkillOverlaps(_ skills: [SkillInventoryItem]) -> [SkillOverlapGroup] {
        let canonicalSkills = Dictionary(
            skills
                .filter { $0.representation != "projection" }
                .map { (canonicalExistingPath($0.canonicalPath.isEmpty ? $0.path : $0.canonicalPath), $0) },
            uniquingKeysWith: preferredOverlapItem
        ).values

        return Dictionary(grouping: canonicalSkills, by: { normalizedSkillName($0.name) })
            .values
            .filter { $0.count > 1 }
            .compactMap(makeOverlapGroup)
            .sorted {
                if $0.kind != $1.kind {
                    return overlapPriority($0.kind) < overlapPriority($1.kind)
                }
                return $0.skillName.localizedCaseInsensitiveCompare($1.skillName) == .orderedAscending
            }
    }
}

private struct ComparableSkillDocument {
    let exactText: String
    let comparableText: String
    let words: Set<String>
}

private func makeOverlapGroup(_ unorderedSkills: [SkillInventoryItem]) -> SkillOverlapGroup? {
    let skills = unorderedSkills.sorted {
        if overlapMemberPriority($0) != overlapMemberPriority($1) {
            return overlapMemberPriority($0) < overlapMemberPriority($1)
        }
        return $0.path < $1.path
    }
    guard let first = skills.first else { return nil }

    let documents = Dictionary(uniqueKeysWithValues: skills.map { skill in
        let path = canonicalExistingPath(skill.canonicalPath.isEmpty ? skill.path : skill.canonicalPath)
        return (path, comparableSkillDocument(at: path))
    })
    let pairSimilarities = skills.enumerated().flatMap { index, left in
        skills.dropFirst(index + 1).map { right in
            documentSimilarity(
                documents[canonicalExistingPath(left.canonicalPath.isEmpty ? left.path : left.canonicalPath)] ?? nil,
                documents[canonicalExistingPath(right.canonicalPath.isEmpty ? right.path : right.canonicalPath)] ?? nil
            )
        }
    }
    let hasPlugin = skills.contains { $0.manager == "codex-plugin" }
    let hasStandalone = skills.contains { $0.manager != "codex-plugin" }
    let pluginStandaloneSimilarities = skills
        .filter { $0.manager == "codex-plugin" }
        .flatMap { plugin in
            skills
                .filter { $0.manager != "codex-plugin" }
                .map { standalone in
                    documentSimilarity(
                        documents[canonicalExistingPath(
                            plugin.canonicalPath.isEmpty ? plugin.path : plugin.canonicalPath
                        )] ?? nil,
                        documents[canonicalExistingPath(
                            standalone.canonicalPath.isEmpty ? standalone.path : standalone.canonicalPath
                        )] ?? nil
                    )
                }
        }
    let pluginStandaloneSimilarity = pluginStandaloneSimilarities.max() ?? 0
    let allPairSimilarity = pairSimilarities.max() ?? 0
    let scopes = Set(skills.map(\.scope))
    let allDocumentsMatch = Set(documents.values.compactMap { $0?.exactText }).count == 1
        && documents.values.allSatisfy { $0 != nil }

    let kind: SkillOverlapKind
    if hasPlugin, hasStandalone, pluginStandaloneSimilarity >= 0.55 {
        kind = .pluginReplacement
    } else if scopes.contains("global"), scopes.contains("project") {
        kind = .globalProject
    } else if allDocumentsMatch {
        kind = .exactDuplicate
    } else {
        kind = .sameName
    }
    let similarity = kind == .pluginReplacement ? pluginStandaloneSimilarity : allPairSimilarity

    let normalizedName = normalizedSkillName(first.name)
    return SkillOverlapGroup(
        id: "\(normalizedName):\(kind.rawValue)",
        skillName: first.name,
        kind: kind,
        similarity: similarity,
        members: skills.map { skill in
            let canonicalPath = canonicalExistingPath(skill.canonicalPath.isEmpty ? skill.path : skill.canonicalPath)
            let memberDocument = documents[canonicalPath] ?? nil
            let pluginSimilarity = skills
                .filter { $0.manager == "codex-plugin" }
                .map { plugin in
                    let pluginPath = canonicalExistingPath(
                        plugin.canonicalPath.isEmpty ? plugin.path : plugin.canonicalPath
                    )
                    return documentSimilarity(memberDocument, documents[pluginPath] ?? nil)
                }
                .max() ?? 0
            return SkillOverlapMember(
                canonicalPath: canonicalPath,
                scope: skill.scope,
                manager: skill.manager,
                authority: skill.authority,
                suggestedRemoval: kind == .pluginReplacement
                    && skill.manager != "codex-plugin"
                    && skill.scope == "global"
                    && pluginSimilarity >= 0.55
            )
        }
    )
}

private func comparableSkillDocument(at directoryPath: String) -> ComparableSkillDocument? {
    let path = URL(fileURLWithPath: directoryPath).appendingPathComponent("SKILL.md")
    guard let text = try? String(contentsOf: path, encoding: .utf8) else { return nil }
    let exactText = text
        .replacingOccurrences(
            of: #"\.(agents|claude|codex|cursor|github|gemini|kiro|opencode|pi|qoder|rovodev|trae|trae-cn)/skills/"#,
            with: ".provider/skills/",
            options: .regularExpression
        )
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    let comparableText = exactText.lowercased()
    let words = Set(comparableText.split { !$0.isLetter && !$0.isNumber }.map(String.init))
    return ComparableSkillDocument(exactText: exactText, comparableText: comparableText, words: words)
}

private func documentSimilarity(_ left: ComparableSkillDocument?, _ right: ComparableSkillDocument?) -> Double {
    guard let left, let right else { return 0 }
    if left.comparableText == right.comparableText { return 1 }
    let union = left.words.union(right.words)
    guard !union.isEmpty else { return 0 }
    return Double(left.words.intersection(right.words).count) / Double(union.count)
}

private func normalizedSkillName(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

private func preferredOverlapItem(_ left: SkillInventoryItem, _ right: SkillInventoryItem) -> SkillInventoryItem {
    overlapMemberPriority(left) <= overlapMemberPriority(right) ? left : right
}

private func overlapMemberPriority(_ skill: SkillInventoryItem) -> Int {
    if skill.manager == "codex-plugin" { return 0 }
    if skill.scope == "global" { return 1 }
    if skill.scope == "project" { return 2 }
    return 3
}

private func overlapPriority(_ kind: SkillOverlapKind) -> Int {
    switch kind {
    case .pluginReplacement: 0
    case .exactDuplicate: 1
    case .globalProject: 2
    case .sameName: 3
    }
}
