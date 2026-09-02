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
        detectSkillOverlaps(skills, canonicalize: canonicalExistingPath)
    }

    // Resolve filesystem identity once per input, not again for each pair.
    // The resolver seam lets tests guard this independently of machine speed.
    static func detectSkillOverlaps(
        _ skills: [SkillInventoryItem],
        canonicalize: (String) -> String
    ) -> [SkillOverlapGroup] {
        let canonicalSkills = Dictionary(
            skills
                .filter { $0.representation != "projection" }
                .map { (canonicalize($0.canonicalPath.isEmpty ? $0.path : $0.canonicalPath), $0) },
            uniquingKeysWith: preferredOverlapItem
        ).map { CanonicalOverlapSkill(path: $0.key, item: $0.value) }

        return Dictionary(grouping: canonicalSkills, by: { normalizedSkillName($0.item.name) })
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

private struct CanonicalOverlapSkill {
    let path: String
    let item: SkillInventoryItem
}

private struct ComparableSkillDocument {
    let exactText: String
    let comparableText: String
    let words: Set<String>
}

private func makeOverlapGroup(_ unorderedSkills: [CanonicalOverlapSkill]) -> SkillOverlapGroup? {
    let skills = unorderedSkills.sorted {
        if overlapMemberPriority($0.item) != overlapMemberPriority($1.item) {
            return overlapMemberPriority($0.item) < overlapMemberPriority($1.item)
        }
        return $0.item.path < $1.item.path
    }
    guard let first = skills.first else { return nil }

    // Two versions of the same skill can coexist inside one plugin system's
    // managed cache. The plugin manager owns that lifecycle, so asking a user
    // to choose and remove one here is both noisy and unsafe. Mixed groups that
    // include a standalone or a different system remain actionable.
    let managedPluginSystems = skills.compactMap { managedPluginSystem(for: $0.item) }
    if managedPluginSystems.count == skills.count,
       Set(managedPluginSystems).count == 1
    {
        return nil
    }

    // These documents are local to this invocation. A later refresh still
    // rereads them, including same-path edits and formerly missing files.
    let documents = skills.map { comparableSkillDocument(at: $0.path) }
    var allPairSimilarity = 0.0
    var pluginStandaloneSimilarity = 0.0
    var memberPluginSimilarities = Array(repeating: 0.0, count: skills.count)
    for left in skills.indices {
        for right in (left + 1)..<skills.count {
            let similarity = documentSimilarity(documents[left], documents[right])
            allPairSimilarity = max(allPairSimilarity, similarity)
            let leftIsPlugin = skills[left].item.manager == "codex-plugin"
            let rightIsPlugin = skills[right].item.manager == "codex-plugin"
            guard leftIsPlugin != rightIsPlugin else { continue }
            pluginStandaloneSimilarity = max(pluginStandaloneSimilarity, similarity)
            let standalone = leftIsPlugin ? right : left
            memberPluginSimilarities[standalone] = max(memberPluginSimilarities[standalone], similarity)
        }
    }
    let hasPlugin = skills.contains { $0.item.manager == "codex-plugin" }
    let hasStandalone = skills.contains { $0.item.manager != "codex-plugin" }
    let scopes = Set(skills.map(\.item.scope))
    let allDocumentsMatch = Set(documents.compactMap { $0?.exactText }).count == 1
        && documents.allSatisfy { $0 != nil }

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

    let normalizedName = normalizedSkillName(first.item.name)
    return SkillOverlapGroup(
        id: "\(normalizedName):\(kind.rawValue)",
        skillName: first.item.name,
        kind: kind,
        similarity: similarity,
        members: skills.enumerated().map { index, prepared in
            let skill = prepared.item
            return SkillOverlapMember(
                canonicalPath: prepared.path,
                scope: skill.scope,
                manager: skill.manager,
                authority: skill.authority,
                suggestedRemoval: (
                    kind == .pluginReplacement
                        && skill.manager != "codex-plugin"
                        && skill.scope == "global"
                        && memberPluginSimilarities[index] >= 0.55
                ) || (
                    kind == .globalProject
                        && allDocumentsMatch
                        && skill.scope == "project"
                )
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

private func managedPluginSystem(for skill: SkillInventoryItem) -> String? {
    if skill.manager == "codex-plugin" || skill.originKind == "codex-plugin" {
        return "codex"
    }
    if skill.manager == "claude-plugin"
        || skill.originKind == "claude-plugin"
        || skill.path.contains("/.claude/plugins/")
    {
        return "claude"
    }
    return nil
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
