import Foundation
import Darwin
import ImageIO
import SQLite3

struct SkillLock: Decodable {
    var skills: [String: SkillLockEntry]
}

struct SkillLockEntry: Decodable {
    var source: String?
    var sourceType: String?
    var sourceUrl: String?
    var ref: String?
    var skillPath: String?
    var computedHash: String?
    var skillFolderHash: String?
    var pluginName: String?
    var installedAt: String?
    var updatedAt: String?

    private enum CodingKeys: String, CodingKey {
        case source
        case sourceType
        case sourceUrl = "sourceUrl"
        case ref
        case skillPath
        case computedHash
        case skillFolderHash
        case pluginName
        case installedAt
        case updatedAt
    }
}

struct DotagentsSkillEntry {
    var source: String
    var isLocked: Bool
}

struct SkillOriginEvidence {
    var originKind: String
    var manager: String
    var authority: String
    var mutability: String
    var source: String?
    var sourceType: String?
    var sourceURL: String?
    var ref: String?
}

func canonicalSkillOwnership(
    scope: String,
    skillLock: SkillLockEntry?,
    dotagents: DotagentsSkillEntry?
) -> SkillOriginEvidence {
    if let skillLock {
        return SkillOriginEvidence(
            originKind: "npx-skills",
            manager: "skills-cli",
            authority: skillLock.source ?? "upstream-package",
            mutability: "managed-read-only",
            source: nil,
            sourceType: nil,
            sourceURL: nil,
            ref: nil
        )
    }
    if let dotagents {
        let isLocalPath = dotagents.source.hasPrefix("path:")
        return SkillOriginEvidence(
            originKind: isLocalPath ? "dotagents-local" : "dotagents-managed",
            manager: "dotagents",
            authority: dotagents.source,
            mutability: isLocalPath ? "editable" : "managed-read-only",
            source: dotagents.source,
            sourceType: dotagents.isLocked ? "dotagents-lock" : "dotagents-config",
            sourceURL: isLocalPath
                ? nil
                : (dotagents.source.contains("://") ? dotagents.source : nil),
            ref: nil
        )
    }
    return SkillOriginEvidence(
        originKind: scope == "global" ? "user-local" : "project-local",
        manager: "local",
        authority: "unknown",
        mutability: "editable",
        source: nil,
        sourceType: "local",
        sourceURL: nil,
        ref: nil
    )
}

struct SkillStats {
    var description: String?
    var latestModifiedAt: Date?
    var characterCount = 0
    var wordCount = 0
    var tokenEstimate = 0
    var skillFileCharacterCount = 0
    var skillFileWordCount = 0
    var skillFileTokenEstimate = 0
    var textFileCount = 0
    var referenceFileCount = 0
    var scriptFileCount = 0
    var assetFileCount = 0
    var otherFileCount = 0
    var otherFolderCount = 0
    var hasOpenAIYaml = false
    var hasIconSmall = false
    var hasIconLarge = false
    var hasIconAndLogo = false
    var iconSmallPath: String?
    var iconLargePath: String?
    var scriptInventory: SkillScriptInventory?
}

func discoverProjectRoots(
    root: URL,
    maxDepth: Int,
    ignoreProjects: Set<String>,
    traversalPruneRoots: Set<String>,
    configuredProjectPaths: Set<String> = [],
    allowExplicitWorktree: Bool = false,
    projectRoots: inout Set<String>
) {
    let standardized = root.resolvingSymlinksInPath().standardizedFileURL
    guard fileManager.fileExists(atPath: standardized.path) else { return }
    if !allowExplicitWorktree, isInsideGitLinkedWorktree(standardized) { return }

    var queue: [(URL, Int)] = [(standardized, 0)]
    var visited = Set<String>()

    while let (current, depth) = queue.first {
        queue.removeFirst()
        let path = canonicalProjectPath(current)
        guard visited.insert(path).inserted else { continue }
        guard !traversalPruneRoots.contains(path) else { continue }

        // A linked Git worktree repeats its repository's project-local skills.
        // Treat it as generated workspace state, not as another project. The
        // `.git` file identifies worktrees without running Git for every folder.
        if depth > 0, isGitLinkedWorktree(current) {
            continue
        }

        if let projectRoot = projectRootForSkillContainer(current) {
            if !ignoreProjects.contains(projectRoot) {
                projectRoots.insert(projectRoot)
            }
            continue
        }
        if let projectRoot = projectRootForDotSkillDirectory(current) {
            if !ignoreProjects.contains(projectRoot) {
                projectRoots.insert(projectRoot)
            }
            continue
        }

        if hasKnownSkillContainer(current) || hasProjectMCPConfiguration(current)
            || configuredProjectPaths.contains(path) {
            if !ignoreProjects.contains(path) {
                projectRoots.insert(path)
            }
        }

        guard depth < maxDepth else { continue }
        guard let entries = try? fileManager.contentsOfDirectory(
            at: current,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else {
            continue
        }

        for entry in entries {
            let name = entry.lastPathComponent
            if let projectRoot = projectRootForSkillContainer(entry) {
                if !ignoreProjects.contains(projectRoot) {
                    projectRoots.insert(projectRoot)
                }
                continue
            }
            if shouldPrune(name: name) {
                continue
            }
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            queue.append((entry, depth + 1))
        }
    }
}

// Git metadata works across arbitrary worktree names and locations. Walk the
// ancestors as configured roots can point inside a linked checkout.
func isInsideGitLinkedWorktree(_ root: URL) -> Bool {
    var current = root.resolvingSymlinksInPath().standardizedFileURL
    while current.path != "/" {
        if isGitLinkedWorktree(current) { return true }
        current.deleteLastPathComponent()
    }
    return false
}

func configuredClaudeProjectPaths(home: URL) -> Set<String> {
    let urls = [home.appendingPathComponent(".claude.json"),
                home.appendingPathComponent(".claude/settings.json")]
    return Set(urls.flatMap { url -> [String] in
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = object["projects"] as? [String: Any]
        else { return [] }
        return projects.keys.map { canonicalProjectPath(URL(fileURLWithPath: $0)) }
    })
}

func hasProjectMCPConfiguration(_ root: URL) -> Bool {
    // Plugin distributions also carry .mcp.json, but their installation and
    // project association belong to the plugin inventory.
    if [".claude-plugin/plugin.json", ".codex-plugin/plugin.json"].contains(where: {
        isRegularOrSymlinkedFile(root.appendingPathComponent($0))
    }) { return false }
    return [".mcp.json", ".claude/settings.json", ".claude/settings.local.json", ".codex/config.toml"]
        .contains { isRegularOrSymlinkedFile(root.appendingPathComponent($0)) }
}

func isGitLinkedWorktree(_ root: URL) -> Bool {
    let marker = root.appendingPathComponent(".git")
    guard isRegularOrSymlinkedFile(marker),
          let text = try? String(contentsOf: marker, encoding: .utf8)
    else { return false }

    let prefix = "gitdir:"
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.lowercased().hasPrefix(prefix) else { return false }
    let value = trimmed.dropFirst(prefix.count)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return false }

    let gitDirectory = resolveGitMetadataPath(String(value), relativeTo: root)
    let commonDirectoryMarker = gitDirectory.appendingPathComponent("commondir")
    let backlinkMarker = gitDirectory.appendingPathComponent("gitdir")
    guard isRegularOrSymlinkedFile(commonDirectoryMarker),
          isRegularOrSymlinkedFile(backlinkMarker),
          let backlink = try? String(contentsOf: backlinkMarker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
          !backlink.isEmpty
    else { return false }

    return resolveGitMetadataPath(backlink, relativeTo: gitDirectory)
        .resolvingSymlinksInPath().standardizedFileURL
        == marker.resolvingSymlinksInPath().standardizedFileURL
}

private func resolveGitMetadataPath(_ path: String, relativeTo base: URL) -> URL {
    if path.hasPrefix("/") {
        return URL(fileURLWithPath: path).standardizedFileURL
    }
    return base.appendingPathComponent(path).standardizedFileURL
}

func projectRootForSkillContainer(_ url: URL) -> String? {
    guard url.lastPathComponent == "skills" else { return nil }
    let dotDirectory = url.deletingLastPathComponent()
    guard agentDirectoryNames.contains(dotDirectory.lastPathComponent) else {
        return nil
    }
    return canonicalProjectPath(dotDirectory.deletingLastPathComponent())
}

func projectRootForDotSkillDirectory(_ url: URL) -> String? {
    guard agentDirectoryNames.contains(url.lastPathComponent) else {
        return nil
    }
    guard fileManager.fileExists(atPath: url.appendingPathComponent("skills").path) else {
        return nil
    }
    return canonicalProjectPath(url.deletingLastPathComponent())
}

func hasKnownSkillContainer(_ root: URL) -> Bool {
    [
        ".agents/skills",
        ".codex/skills",
        ".claude/skills"
    ].contains { relative in
        fileManager.fileExists(atPath: root.appendingPathComponent(relative).path)
    }
}

func installedCodexPlugins() throws -> [CodexPlugin] {
    try allCodexPlugins().filter { $0.installed && $0.enabled }
}

/// Every plugin `codex plugin list` reports, including disabled ones. The
/// skills scan wants only active plugins; the plugin inventory wants all.
func allCodexPlugins() throws -> [CodexPlugin] {
    let executable = try codexExecutable()
    let result = try runSubprocess(
        executable: executable,
        arguments: ["plugin", "list", "--json"],
        timeout: 30
    )
    let detail = String(data: result.standardError, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    try requireSubprocessSuccess(
        result,
        output: detail,
        domain: "MetagentCodexPlugins",
        timeoutCode: 2,
        timeoutMessage: detail.isEmpty
            ? "codex plugin list timed out after 30 seconds"
            : "codex plugin list timed out: \(detail)",
        failureMessage: "codex plugin list failed"
    )
    return try JSONDecoder().decode(CodexPluginList.self, from: result.standardOutput).installed
        .filter { $0.installed }
}

func codexExecutable() throws -> URL {
    guard let path = firstExecutableCandidate(
        named: "codex",
        environmentOverride: "METAGENT_CODEX",
        extraCandidates: [
            homeURL().appendingPathComponent(".local/bin/codex").path,
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
    ) else {
        throw NSError(domain: "MetagentCodexPlugins", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "codex executable not found; set METAGENT_CODEX to enable plugin inventory"
        ])
    }
    return URL(fileURLWithPath: path)
}

func readCodexPluginSkills(_ plugin: CodexPlugin) -> SkillProject? {
    let home = homeURL()
    let cacheBase = home.appendingPathComponent(".codex/plugins/cache")
    let cacheMarketplaces = plugin.marketplaceName == "openai-curated"
        ? [plugin.marketplaceName, "openai-curated-remote"]
        : [plugin.marketplaceName]
    let cacheRoots = cacheMarketplaces.map {
        cacheBase
            .appendingPathComponent($0)
            .appendingPathComponent(plugin.name)
            .appendingPathComponent(plugin.version)
    }
    let sourceRoot = plugin.source.path.map { URL(fileURLWithPath: $0) }
    let root = cacheRoots.first(where: { fileManager.fileExists(atPath: $0.path) }) ?? sourceRoot
    guard let root else { return nil }
    let representation = root.path.hasPrefix(cacheBase.path + "/") ? "versioned-cache" : "canonical"
    let skillsDir = root.appendingPathComponent("skills")
    guard let entries = skillContainerEntries(at: skillsDir) else { return nil }

    let skills = entries.compactMap { entry -> SkillInventoryItem? in
        guard isDirectoryOrSymlinkedDirectory(entry),
              isRegularOrSymlinkedFile(entry.appendingPathComponent("SKILL.md")),
              isValidSkillName(entry.lastPathComponent)
        else { return nil }
        return makeSkillItem(
            name: entry.lastPathComponent,
            path: entry,
            location: "plugin",
            originKind: "codex-plugin",
            scope: "plugin",
            manager: "codex-plugin",
            authority: plugin.pluginId,
            mutability: "managed-read-only",
            representation: representation,
            canonicalPath: canonicalProjectPath(entry),
            origin: SkillLockEntry(
                source: plugin.pluginId,
                sourceType: "codex-marketplace",
                sourceUrl: nil,
                ref: plugin.version,
                skillPath: nil,
                computedHash: nil,
                skillFolderHash: nil,
                pluginName: plugin.name,
                installedAt: nil,
                updatedAt: nil
            ),
            symlinkedContainer: isSymlink(skillsDir)
        )
    }.sorted()
    guard !skills.isEmpty else { return nil }
    return SkillProject(
        root: canonicalProjectPath(root),
        skillsDir: skillsDir.path,
        validSkills: skills.map(\.name).sorted(),
        skills: skills
    )
}

func readProjectSkills(root: URL) throws -> SkillProject {
    let agentsSkillsDir = root.appendingPathComponent(".agents").appendingPathComponent("skills")
    let skillLock = readProjectSkillLocks(root: root)
    let dotagentsSkills = readDotagentsSkills(root: root)
    let scope = canonicalProjectPath(root) == canonicalProjectPath(homeURL()) ? "global" : "project"
    var validSkills: [String] = []
    var inventory: [SkillInventoryItem] = []
    var invalidSkillDirs: [String] = []
    var hiddenSkillDirs: [String] = []

    readAgentsSkills(
        skillsDir: agentsSkillsDir,
        skillLock: skillLock,
        dotagentsSkills: dotagentsSkills,
        scope: scope,
        validSkills: &validSkills,
        inventory: &inventory,
        invalidSkillDirs: &invalidSkillDirs,
        hiddenSkillDirs: &hiddenSkillDirs
    )

    let canonicalAgents = Dictionary(
        inventory.lazy
            .filter { $0.location == "agents" }
            .map { ($0.canonicalPath, $0) },
        uniquingKeysWith: { first, _ in first }
    )

    readInventorySkills(
        skillsDir: root.appendingPathComponent(".codex").appendingPathComponent("skills"),
        location: "codex",
        scope: scope,
        canonicalAgents: canonicalAgents,
        inventory: &inventory
    )
    readInventorySkills(
        skillsDir: root.appendingPathComponent(".claude").appendingPathComponent("skills"),
        location: "claude",
        scope: scope,
        canonicalAgents: canonicalAgents,
        inventory: &inventory
    )

    return SkillProject(
        root: root.path,
        skillsDir: agentsSkillsDir.path,
        validSkills: validSkills.sorted(),
        skills: inventory.sorted(),
        invalidSkillDirs: invalidSkillDirs.sorted(),
        hiddenSkillDirs: hiddenSkillDirs.sorted()
    )
}

func readAgentsSkills(
    skillsDir: URL,
    skillLock: [String: SkillLockEntry],
    dotagentsSkills: [String: DotagentsSkillEntry],
    scope: String,
    validSkills: inout [String],
    inventory: inout [SkillInventoryItem],
    invalidSkillDirs: inout [String],
    hiddenSkillDirs: inout [String]
) {
    guard let entries = skillContainerEntries(at: skillsDir) else {
        return
    }

    let symlinkedContainer = isSymlink(skillsDir)

    for entry in entries.sorted(by: { $0.path < $1.path }) {
        guard isDirectoryOrSymlinkedDirectory(entry) else { continue }
        guard isRegularOrSymlinkedFile(entry.appendingPathComponent("SKILL.md")) else { continue }
        let name = entry.lastPathComponent
        if name.hasPrefix(".") {
            hiddenSkillDirs.append(entry.path)
        }
        guard isValidSkillName(name) else {
            invalidSkillDirs.append(entry.path)
            continue
        }

        validSkills.append(name)
        let lockEntry = skillLock[name]
        let recordedDotagentsEntry = dotagentsSkills[name]
        // dotagents `sync` adopts an existing local skill by recording a path
        // back to its own install directory. That is reconciliation state, not
        // lifecycle ownership. Only a distinct source is manager evidence.
        let dotagentsEntry = recordedDotagentsEntry.flatMap { entryEvidence in
            dotagentsPathSource(entryEvidence.source, projectRoot: projectRoot(for: skillsDir), resolvesTo: entry)
                ? nil
                : entryEvidence
        }
        let projection = symlinkedContainer || isSymlink(entry)
        let ownership = canonicalSkillOwnership(
            scope: scope,
            skillLock: lockEntry,
            dotagents: dotagentsEntry
        )
        inventory.append(makeSkillItem(
            name: name,
            path: entry,
            location: "agents",
            originKind: ownership.originKind,
            scope: scope,
            manager: ownership.manager,
            authority: ownership.authority,
            mutability: projection ? "managed-read-only" : ownership.mutability,
            representation: projection ? "projection" : "canonical",
            canonicalPath: canonicalProjectPath(entry),
            origin: lockEntry,
            evidence: ownership,
            symlinkedContainer: symlinkedContainer
        ))
    }
}

func readInventorySkills(
    skillsDir: URL,
    location: String,
    scope: String,
    canonicalAgents: [String: SkillInventoryItem],
    inventory: inout [SkillInventoryItem]
) {
    guard fileManager.fileExists(atPath: skillsDir.path) else { return }
    collectInventorySkills(
        dir: skillsDir,
        location: location,
        scope: scope,
        depth: 0,
        maxDepth: 2,
        symlinkedContainer: isSymlink(skillsDir),
        canonicalAgents: canonicalAgents,
        inventory: &inventory
    )
}

func collectInventorySkills(
    dir: URL,
    location: String,
    scope: String,
    depth: Int,
    maxDepth: Int,
    symlinkedContainer: Bool,
    canonicalAgents: [String: SkillInventoryItem],
    inventory: inout [SkillInventoryItem]
) {
    guard depth <= maxDepth else { return }
    guard let entries = skillContainerEntries(at: dir) else {
        return
    }

    for entry in entries.sorted(by: { $0.path < $1.path }) {
        guard isDirectoryOrSymlinkedDirectory(entry) else { continue }
        if isRegularOrSymlinkedFile(entry.appendingPathComponent("SKILL.md")) {
            let name = entry.lastPathComponent
            guard isValidSkillName(name) else { continue }
            let canonicalPath = canonicalProjectPath(entry)
            let projection = symlinkedContainer || isSymlink(entry)
            let inherited = projection ? canonicalAgents[canonicalPath] : nil
            let isSystem = entry.pathComponents.contains(".system")
            let manager = inherited?.manager ?? location
            let authority = inherited?.authority
                ?? (isSystem ? "codex-system" : "\(location)-installed")
            let originKind = inherited?.originKind
                ?? (isSystem ? "codex-system" : "\(location)-installed")
            inventory.append(makeSkillItem(
                name: name,
                path: entry,
                location: location,
                originKind: originKind,
                scope: isSystem ? "system" : scope,
                manager: manager,
                authority: authority,
                mutability: "managed-read-only",
                representation: projection ? "projection" : "canonical",
                canonicalPath: canonicalPath,
                origin: nil,
                symlinkedContainer: symlinkedContainer,
                inherited: inherited
            ))
            continue
        }

        guard depth < maxDepth, !shouldPruneSkillContainer(name: entry.lastPathComponent) else {
            continue
        }
        collectInventorySkills(
            dir: entry,
            location: location,
            scope: scope,
            depth: depth + 1,
            maxDepth: maxDepth,
            symlinkedContainer: symlinkedContainer,
            canonicalAgents: canonicalAgents,
            inventory: &inventory
        )
    }
}

func makeSkillItem(
    name: String,
    path: URL,
    location: String,
    originKind: String,
    scope: String,
    manager: String,
    authority: String,
    mutability: String,
    representation: String,
    canonicalPath: String,
    origin: SkillLockEntry?,
    evidence: SkillOriginEvidence? = nil,
    symlinkedContainer: Bool,
    inherited: SkillInventoryItem? = nil
) -> SkillInventoryItem {
    let stats = skillStats(path)
    let recognizedEvidence = recognizedExternalSkillEvidence(
        name: name,
        path: path,
        currentManager: evidence?.manager ?? manager
    )
    let resolvedEvidence = recognizedEvidence ?? evidence
    let resolvedOriginKind = resolvedEvidence?.originKind ?? originKind
    return SkillInventoryItem(
        name: name,
        description: stats.description,
        path: path.path,
        location: location,
        locationLabel: ".\(location)",
        originKind: resolvedOriginKind,
        scope: scope,
        manager: resolvedEvidence?.manager ?? manager,
        authority: resolvedEvidence?.authority ?? authority,
        mutability: representation == "projection"
            ? "managed-read-only"
            : (resolvedEvidence?.mutability ?? mutability),
        representation: representation,
        canonicalPath: canonicalPath,
        source: resolvedEvidence?.source ?? origin?.source ?? inherited?.source,
        sourceType: resolvedEvidence?.sourceType ?? origin?.sourceType ?? inherited?.sourceType,
        sourceURL: resolvedEvidence?.sourceURL ?? origin?.sourceUrl ?? inherited?.sourceURL,
        ref: resolvedEvidence?.ref ?? origin?.ref ?? inherited?.ref,
        installedAt: origin?.installedAt ?? inherited?.installedAt,
        updatedAt: origin?.updatedAt
            ?? inherited?.updatedAt
            ?? stats.latestModifiedAt.map { iso8601Formatter.string(from: $0) },
        symlinkedContainer: symlinkedContainer,
        folderKind: folderKind(
            path: path,
            location: location,
            originKind: resolvedOriginKind,
            representation: representation,
            symlinkedContainer: symlinkedContainer
        ),
        characterCount: stats.characterCount,
        wordCount: stats.wordCount,
        tokenEstimate: stats.tokenEstimate,
        skillFileCharacterCount: stats.skillFileCharacterCount,
        skillFileWordCount: stats.skillFileWordCount,
        skillFileTokenEstimate: stats.skillFileTokenEstimate,
        textFileCount: stats.textFileCount,
        referenceFileCount: stats.referenceFileCount,
        scriptFileCount: stats.scriptFileCount,
        assetFileCount: stats.assetFileCount,
        otherFileCount: stats.otherFileCount,
        otherFolderCount: stats.otherFolderCount,
        hasOpenAIYaml: stats.hasOpenAIYaml,
        hasIconSmall: stats.hasIconSmall,
        hasIconLarge: stats.hasIconLarge,
        hasIconAndLogo: stats.hasIconAndLogo,
        iconSmallPath: stats.iconSmallPath,
        iconLargePath: stats.iconLargePath,
        scriptInventory: stats.scriptInventory
    )
}

func recognizedExternalSkillEvidence(
    name: String,
    path: URL,
    currentManager: String
) -> SkillOriginEvidence? {
    guard currentManager == "local" else { return nil }
    let skillPath = path.appendingPathComponent("SKILL.md")
    guard name == "impeccable",
          fileManager.fileExists(atPath: path.appendingPathComponent("scripts/context.mjs").path),
          fileManager.fileExists(atPath: path.appendingPathComponent("reference/hooks.md").path),
          let text = try? String(contentsOf: skillPath, encoding: .utf8),
          text.contains(".agents/skills/impeccable/scripts/")
    else {
        return nil
    }
    let version = frontmatterScalar(key: "version", text: text)
    return SkillOriginEvidence(
        originKind: "external-cli",
        manager: "external-cli",
        authority: "Impeccable CLI",
        mutability: "managed-read-only",
        source: "pbakaus/impeccable",
        sourceType: "bundle-signature",
        sourceURL: "https://github.com/pbakaus/impeccable",
        ref: version
    )
}

func frontmatterScalar(key: String, text: String) -> String? {
    let prefix = "\(key):"
    for line in text.components(separatedBy: .newlines).prefix(40) {
        guard line.first?.isWhitespace != true,
              line.trimmingCharacters(in: .whitespaces).hasPrefix(prefix)
        else { continue }
        let rawValue = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        let value = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return value.isEmpty ? nil : value
    }
    return nil
}

func skillStats(_ skillDir: URL) -> SkillStats {
    var stats = SkillStats()
    var otherFolders = Set<String>()
    readOpenAIYaml(skillDir: skillDir, stats: &stats)
    collectSkillStats(root: skillDir, dir: skillDir, stats: &stats, otherFolders: &otherFolders)
    stats.scriptInventory = scanSkillScripts(in: skillDir)
    stats.scriptFileCount = stats.scriptInventory?.scripts.count ?? stats.scriptFileCount
    stats.tokenEstimate = estimateTokens(stats.characterCount)
    stats.skillFileTokenEstimate = estimateTokens(stats.skillFileCharacterCount)
    stats.otherFolderCount = otherFolders.count
    stats.hasIconAndLogo = stats.hasIconSmall && stats.hasIconLarge
    return stats
}

func collectSkillStats(root: URL, dir: URL, stats: inout SkillStats, otherFolders: inout Set<String>) {
    guard let entries = try? fileManager.contentsOfDirectory(
        at: dir,
        includingPropertiesForKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
        ],
        options: [.skipsPackageDescendants]
    ) else {
        return
    }

    for entry in entries {
        if isDirectoryOrSymlinkedDirectory(entry) {
            guard !isSymlink(entry) else { continue }
            guard !shouldPrune(name: entry.lastPathComponent) else { continue }
            collectSkillStats(root: root, dir: entry, stats: &stats, otherFolders: &otherFolders)
            continue
        }

        guard isRegularOrSymlinkedFile(entry) else { continue }
        if isFilesystemSymlink(entry) {
            categorizeSkillFile(root: root, path: entry, stats: &stats, otherFolders: &otherFolders)
            continue
        }
        if let modifiedAt = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           stats.latestModifiedAt == nil || modifiedAt > stats.latestModifiedAt!
        {
            stats.latestModifiedAt = modifiedAt
        }
        categorizeSkillFile(root: root, path: entry, stats: &stats, otherFolders: &otherFolders)
        guard isSkillTextFile(entry) else { continue }
        guard let text = try? String(contentsOf: entry, encoding: .utf8) else { continue }
        let characters = text.count
        let words = text.split(whereSeparator: \.isWhitespace).count
        stats.textFileCount += 1
        stats.characterCount += characters
        stats.wordCount += words

        if entry.standardizedFileURL == root.appendingPathComponent("SKILL.md").standardizedFileURL {
            stats.description = skillDescription(from: text)
            stats.skillFileCharacterCount += characters
            stats.skillFileWordCount += words
        }
    }
}

func skillDescription(from skillText: String) -> String? {
    let lines = skillText.components(separatedBy: .newlines)
    guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else { return nil }
    guard let closingIndex = lines.dropFirst().firstIndex(where: {
        $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---"
    }) else { return nil }

    let frontmatter = Array(lines[1..<closingIndex])
    guard let descriptionIndex = frontmatter.firstIndex(where: {
        $0.trimmingCharacters(in: .whitespaces).hasPrefix("description:")
    }) else { return nil }

    let line = frontmatter[descriptionIndex].trimmingCharacters(in: .whitespaces)
    let rawValue = String(line.dropFirst("description:".count)).trimmingCharacters(in: .whitespaces)
    if !["|", "|-", "|+", ">", ">-", ">+"].contains(rawValue) {
        guard let value = decodedYAMLScalar(rawValue) else { return nil }
        return value.isEmpty ? nil : value
    }

    let continuation = frontmatter.dropFirst(descriptionIndex + 1)
        .prefix { line in
            line.first?.isWhitespace == true || line.trimmingCharacters(in: .whitespaces).isEmpty
        }
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    guard !continuation.isEmpty else { return nil }
    return continuation.joined(separator: rawValue.hasPrefix(">") ? " " : "\n")
}

func categorizeSkillFile(
    root: URL,
    path: URL,
    stats: inout SkillStats,
    otherFolders: inout Set<String>
) {
    guard let topLevel = topLevelComponent(root: root, path: path) else { return }
    switch topLevel {
    case "SKILL.md":
        return
    case "references":
        stats.referenceFileCount += 1
    case "scripts":
        stats.scriptFileCount += 1
    case "assets":
        stats.assetFileCount += 1
    case "agents" where path.lastPathComponent == "openai.yaml":
        return
    default:
        stats.otherFileCount += 1
        if topLevel != "agents", path.deletingLastPathComponent() != root {
            otherFolders.insert(topLevel)
        }
    }
}

func topLevelComponent(root: URL, path: URL) -> String? {
    let rootComponents = root.standardizedFileURL.pathComponents
    let pathComponents = path.standardizedFileURL.pathComponents
    guard pathComponents.count > rootComponents.count else { return nil }
    return pathComponents[rootComponents.count]
}

func readOpenAIYaml(skillDir: URL, stats: inout SkillStats) {
    let path = skillDir.appendingPathComponent("agents").appendingPathComponent("openai.yaml")
    guard let text = try? String(contentsOf: path, encoding: .utf8) else { return }
    stats.hasOpenAIYaml = true
    stats.iconSmallPath = yamlInterfaceValue(key: "icon_small", text: text).map {
        skillDir.appendingPathComponent($0).standardizedFileURL.path
    }
    stats.iconLargePath = yamlInterfaceValue(key: "icon_large", text: text).map {
        skillDir.appendingPathComponent($0).standardizedFileURL.path
    }
    stats.hasIconSmall = stats.iconSmallPath != nil
    stats.hasIconLarge = stats.iconLargePath != nil
}

func yamlInterfaceValue(key: String, text: String) -> String? {
    let lines = text.components(separatedBy: .newlines)
    guard let interfaceIndex = lines.firstIndex(where: {
        $0.trimmingCharacters(in: .whitespaces) == "interface:"
    }) else { return nil }
    let range = yamlMappingRange(lines: lines, parentIndex: interfaceIndex)
    let childIndent = range.compactMap { index -> Int? in
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        return yamlIndent(lines[index])
    }.min()
    guard let childIndent else { return nil }
    let prefix = "\(key):"
    for index in range where yamlIndent(lines[index]) == childIndent {
        let line = lines[index]
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(prefix) else { continue }
        let value = String(trimmed.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return value.isEmpty ? nil : value
    }
    return nil
}

func upsertSkillIconMetadata(_ text: String, iconPath: String) -> String {
    var lines = text.components(separatedBy: .newlines)
    if lines.last == "" { lines.removeLast() }
    var foundSmall = false
    var foundLarge = false
    let interfaceIndex = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "interface:" }
    let interfaceIndent = interfaceIndex.map { yamlIndent(lines[$0]) } ?? 0
    let interfaceRange = interfaceIndex.map { yamlMappingRange(lines: lines, parentIndex: $0) }
    let childIndent = interfaceRange.flatMap { range in
        range.compactMap { index -> Int? in
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            return yamlIndent(lines[index])
        }.min()
    } ?? (interfaceIndent + 2)

    if let interfaceRange {
        for index in interfaceRange where yamlIndent(lines[index]) == childIndent {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            let indent = String(repeating: " ", count: childIndent)
            if trimmed.hasPrefix("icon_small:") {
                lines[index] = "\(indent)icon_small: \(iconPath)"
                foundSmall = true
            } else if trimmed.hasPrefix("icon_large:") {
                lines[index] = "\(indent)icon_large: \(iconPath)"
                foundLarge = true
            }
        }
    }

    if !foundSmall || !foundLarge {
        if let interfaceIndex {
            let indent = String(repeating: " ", count: childIndent)
            var additions: [String] = []
            if !foundSmall { additions.append("\(indent)icon_small: \(iconPath)") }
            if !foundLarge { additions.append("\(indent)icon_large: \(iconPath)") }
            lines.insert(contentsOf: additions, at: interfaceIndex + 1)
        } else {
            if !lines.isEmpty { lines.append("") }
            lines.append("interface:")
            lines.append("  icon_small: \(iconPath)")
            lines.append("  icon_large: \(iconPath)")
        }
    }
    return lines.joined(separator: "\n") + "\n"
}

func yamlMappingRange(lines: [String], parentIndex: Int) -> Range<Int> {
    let parentIndent = yamlIndent(lines[parentIndex])
    var end = lines.endIndex
    for index in lines.index(after: parentIndex)..<lines.endIndex {
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
        if yamlIndent(lines[index]) <= parentIndent {
            end = index
            break
        }
    }
    return lines.index(after: parentIndex)..<end
}

func yamlIndent(_ line: String) -> Int {
    line.prefix { $0 == " " }.count
}

func safeSkillIconWriteTargets(skill: URL, directories: [URL], files: [URL]) -> Bool {
    let root = skill.standardizedFileURL.path
    let descendants = root + "/"
    for directory in directories {
        guard !isSymlink(directory) else { return false }
        let resolvedParent = directory.deletingLastPathComponent()
            .resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedParent == root || resolvedParent.hasPrefix(descendants) else { return false }
    }
    for file in files {
        guard !isSymlink(file) else { return false }
        let resolvedParent = file.deletingLastPathComponent()
            .resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedParent == root || resolvedParent.hasPrefix(descendants) else { return false }
    }
    return true
}

func estimateTokens(_ characterCount: Int) -> Int {
    (characterCount + 3) / 4
}

func folderKind(
    path: URL,
    location: String,
    originKind: String,
    representation: String,
    symlinkedContainer: Bool
) -> String {
    if symlinkedContainer || isSymlink(path) {
        return "symlinked"
    }
    if path.pathComponents.contains(".system") {
        return "system"
    }
    if location == "agents", originKind == "npx-skills" {
        return "npx-installed"
    }
    if location == "agents", originKind.hasPrefix("dotagents") {
        return originKind
    }
    if location == "agents", originKind == "external-cli" {
        return originKind
    }
    if location == "agents", originKind.hasSuffix("-local") {
        return originKind
    }
    if location == "agents" {
        return "unmanaged"
    }
    if location == "codex" {
        return "codex-local"
    }
    if location == "claude" {
        return "claude-local"
    }
    if location == "plugin" {
        return representation
    }
    return "unknown"
}

func readSkillLock(_ path: URL) -> [String: SkillLockEntry] {
    guard let data = try? Data(contentsOf: path) else { return [:] }
    return (try? JSONDecoder().decode(SkillLock.self, from: data).skills) ?? [:]
}

func readDotagentsSkills(root: URL) -> [String: DotagentsSkillEntry] {
    let base = canonicalProjectPath(root) == canonicalProjectPath(homeURL())
        ? root.appendingPathComponent(".agents")
        : root
    var entries = parseDotagentsConfig(base.appendingPathComponent("agents.toml"))
    for (name, locked) in parseDotagentsLock(base.appendingPathComponent("agents.lock")) {
        entries[name] = locked
    }
    return entries
}

func parseDotagentsConfig(_ path: URL) -> [String: DotagentsSkillEntry] {
    guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [:] }
    var entries: [String: DotagentsSkillEntry] = [:]
    var name: String?
    var source: String?
    var inSkill = false

    func flush() {
        guard let name, let source else { return }
        entries[name] = DotagentsSkillEntry(source: source, isLocked: false)
    }

    for rawLine in text.components(separatedBy: .newlines) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        let header = tomlHeaderWithoutComment(line)
        if header == "[[skills]]" {
            flush()
            name = nil
            source = nil
            inSkill = true
        } else if header.hasPrefix("[") {
            flush()
            name = nil
            source = nil
            inSkill = false
        } else if inSkill, line.hasPrefix("name"), let value = tomlStringValue(line) {
            name = value
        } else if inSkill, line.hasPrefix("source"), let value = tomlStringValue(line) {
            source = value
        }
    }
    flush()
    return entries
}

func parseDotagentsLock(_ path: URL) -> [String: DotagentsSkillEntry] {
    guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [:] }
    var entries: [String: DotagentsSkillEntry] = [:]
    var name: String?
    for rawLine in text.components(separatedBy: .newlines) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        let header = tomlHeaderWithoutComment(line)
        if header.hasPrefix("[skills."), header.hasSuffix("]") {
            name = String(header.dropFirst(8).dropLast())
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        } else if header.hasPrefix("[") {
            name = nil
        } else if line.hasPrefix("source"), let name, let source = tomlStringValue(line) {
            entries[name] = DotagentsSkillEntry(source: source, isLocked: true)
        }
    }
    return entries
}

func tomlHeaderWithoutComment(_ line: String) -> String {
    String(line.prefix { $0 != "#" }).trimmingCharacters(in: .whitespaces)
}

func tomlStringValue(_ line: String) -> String? {
    guard let equals = line.firstIndex(of: "=") else { return nil }
    let rawValue = line[line.index(after: equals)...]
        .trimmingCharacters(in: .whitespaces)
    guard let quote = rawValue.first, quote == "\"" || quote == "'" else {
        let value = String(rawValue.prefix { $0 != "#" })
            .trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
    var escaped = false
    var closingQuote: String.Index?
    for index in rawValue.indices.dropFirst() {
        let character = rawValue[index]
        if quote == "\"", character == "\\", !escaped {
            escaped = true
            continue
        }
        if character == quote, !escaped {
            closingQuote = index
            break
        }
        escaped = false
    }
    guard let closingQuote else { return nil }
    let value = String(rawValue[rawValue.index(after: rawValue.startIndex)..<closingQuote])
    return value.isEmpty ? nil : value
}

func dotagentsPathSource(
    _ source: String?,
    projectRoot: URL,
    resolvesTo expectedSkill: URL
) -> Bool {
    guard let source, source.hasPrefix("path:") else { return false }
    let rawPath = String(source.dropFirst("path:".count))
    guard !rawPath.isEmpty else { return false }
    let base = canonicalProjectPath(projectRoot) == canonicalProjectPath(homeURL())
        ? projectRoot.appendingPathComponent(".agents")
        : projectRoot
    let sourceURL = rawPath.hasPrefix("/")
        ? URL(fileURLWithPath: rawPath)
        : base.appendingPathComponent(rawPath)
    return sourceURL.standardizedFileURL.path == expectedSkill.standardizedFileURL.path
}

func hasProjectInventorySurface(_ project: SkillProject) -> Bool {
    !project.validSkills.isEmpty
        || !project.skills.isEmpty
        || !project.invalidSkillDirs.isEmpty
        || !project.hiddenSkillDirs.isEmpty
}

func mergeSkillProjects(_ existing: SkillProject, _ additional: SkillProject) -> SkillProject {
    var skillsByID = Dictionary(uniqueKeysWithValues: existing.skills.map { ($0.id, $0) })
    for skill in additional.skills {
        skillsByID[skill.id] = skill
    }
    return SkillProject(
        root: existing.root,
        skillsDir: existing.skillsDir,
        validSkills: Array(Set(existing.validSkills + additional.validSkills)).sorted(),
        skills: skillsByID.values.sorted(),
        invalidSkillDirs: Array(Set(existing.invalidSkillDirs + additional.invalidSkillDirs)).sorted(),
        hiddenSkillDirs: Array(Set(existing.hiddenSkillDirs + additional.hiddenSkillDirs)).sorted()
    )
}

func hasCanonicalSkillsSurface(_ project: SkillProject) -> Bool {
    !project.validSkills.isEmpty
        || !project.invalidSkillDirs.isEmpty
        || !project.hiddenSkillDirs.isEmpty
}

func hasObsoleteCodexProjections(_ project: SkillProject) -> Bool {
    !obsoleteCodexProjectionURLs(project).isEmpty
}

func obsoleteCodexProjectionURLs(_ project: SkillProject) -> [URL] {
    let projectRoot = URL(fileURLWithPath: project.root).standardizedFileURL
    let canonicalAgentPaths = Set(project.skills.lazy
        .filter { $0.location == "agents" }
        .map(\.canonicalPath))
    return project.skills.compactMap { skill in
        guard skill.location == "codex",
              skill.representation == "projection",
              !skill.symlinkedContainer,
              canonicalAgentPaths.contains(skill.canonicalPath)
        else { return nil }
        let url = URL(fileURLWithPath: skill.path)
        return isSymlink(url) && !hasSymlinkedAncestor(of: url, below: projectRoot) ? url : nil
    }
}

final class SkillInventoryCache {
    private let path: URL

    init(path: URL? = nil) throws {
        self.path = path ?? homeURL()
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Metagent")
            .appendingPathComponent("inventory.sqlite")
        try fileManager.createDirectory(at: self.path.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    func save(_ report: SkillScanReport) throws {
        let data = try JSONEncoder().encode(report)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        try withPreparedDatabase { db in
            try exec(db, "DELETE FROM inventory_snapshots WHERE id = 1;")
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                "INSERT INTO inventory_snapshots (id, updated_at, json) VALUES (1, datetime('now'), ?);",
                -1,
                &statement,
                nil
            ) == SQLITE_OK else {
                throw cacheError(db, "prepare insert")
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, json, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw cacheError(db, "insert snapshot")
            }
        }
    }

    func load() throws -> SkillScanReport? {
        try withPreparedDatabase { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                "SELECT json FROM inventory_snapshots WHERE id = 1;",
                -1,
                &statement,
                nil
            ) == SQLITE_OK else {
                throw cacheError(db, "prepare select")
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            guard let text = sqlite3_column_text(statement, 0) else { return nil }
            let json = String(cString: text)
            return try JSONDecoder().decode(SkillScanReport.self, from: Data(json.utf8))
        }
    }

    /// Opens the cache, ensures the snapshot table exists, and closes it again
    /// once `work` returns.
    private func withPreparedDatabase<T>(_ work: (OpaquePointer?) throws -> T) throws -> T {
        var db: OpaquePointer?
        try open(&db)
        defer { sqlite3_close(db) }
        try exec(db, """
        CREATE TABLE IF NOT EXISTS inventory_snapshots (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            updated_at TEXT NOT NULL,
            json TEXT NOT NULL
        );
        """)
        return try work(db)
    }

    private func open(_ db: inout OpaquePointer?) throws {
        guard sqlite3_open(path.path, &db) == SQLITE_OK else {
            throw cacheError(db, "open \(path.path)")
        }
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw cacheError(db, "exec")
        }
    }

    private func cacheError(_ db: OpaquePointer?, _ action: String) -> NSError {
        let message = db.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:)) ?? "unknown sqlite error"
        return NSError(domain: "MetagentSQLite", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "\(action): \(message)"
        ])
    }
}

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
