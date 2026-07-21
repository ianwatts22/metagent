import Foundation

public enum MCPClient: String, Codable, CaseIterable, Sendable {
    case codex
    case claude

    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }
}

public enum MCPConnectionState: String, Codable, Sendable {
    case configured
    case disabled
    case pendingApproval
    case needsSignIn
    case unavailable

    public var needsAttention: Bool {
        self == .pendingApproval || self == .needsSignIn || self == .unavailable
    }
}

public struct MCPServerHealth: Codable, Equatable, Identifiable, Sendable {
    public let client: MCPClient
    public let name: String
    public let state: MCPConnectionState
    public let detail: String

    public var id: String { "\(client.rawValue):\(name)" }

    public init(client: MCPClient, name: String, state: MCPConnectionState, detail: String) {
        self.client = client
        self.name = name
        self.state = state
        self.detail = detail
    }
}

public struct MCPHealthSnapshot: Codable, Equatable, Sendable {
    public let servers: [MCPServerHealth]
    public let observedAt: Date

    public init(servers: [MCPServerHealth] = [], observedAt: Date = .distantPast) {
        self.servers = servers
        self.observedAt = observedAt
    }

    public var configuredCount: Int {
        servers.filter { $0.state == .configured || $0.state == .needsSignIn }.count
    }

    public var attention: [MCPServerHealth] {
        servers.filter { $0.state.needsAttention }
    }

    public func count(for client: MCPClient) -> Int {
        servers.filter {
            $0.client == client && ($0.state == .configured || $0.state == .needsSignIn)
        }.count
    }

    public func disabledCount(for client: MCPClient) -> Int {
        servers.filter { $0.client == client && $0.state == .disabled }.count
    }
}

private struct CodexMCPEntry: Decodable {
    let name: String
    let enabled: Bool
    let disabledReason: String?
    let authStatus: String?

    enum CodingKeys: String, CodingKey {
        case name
        case enabled
        case disabledReason = "disabled_reason"
        case authStatus = "auth_status"
    }
}

public extension MetagentCore {
    /// Builds a passive MCP inventory. This never starts an MCP server, performs OAuth discovery,
    /// or invokes a tool. Codex's supported JSON inventory and Claude's local configuration are
    /// treated as configuration evidence, not proof that a connection currently works.
    static func scanMCPHealth(
        homeDirectory: URL? = nil,
        codexExecutableOverride: URL? = nil,
        observedAt: Date = Date()
    ) -> MCPHealthSnapshot {
        let home = homeDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        var servers: [MCPServerHealth] = []

        do {
            let executable = try codexExecutableOverride ?? codexExecutable()
            let result = try runSubprocess(
                executable: executable,
                arguments: ["mcp", "list", "--json"],
                timeout: 20
            )
            guard !result.timedOut, result.status == 0 else {
                throw NSError(domain: "MetagentMCPHealth", code: Int(result.status), userInfo: nil)
            }
            servers += try parseCodexMCPInventory(result.standardOutput)
        } catch {
            servers.append(MCPServerHealth(
                client: .codex,
                name: "Codex inventory",
                state: .unavailable,
                detail: "Static status could not be read"
            ))
        }

        servers += scanClaudeMCPConfiguration(homeDirectory: home)
        return MCPHealthSnapshot(servers: servers.sorted(by: mcpHealthSort), observedAt: observedAt)
    }

    static func parseCodexMCPInventory(_ data: Data) throws -> [MCPServerHealth] {
        try JSONDecoder().decode([CodexMCPEntry].self, from: data).map { entry in
            if !entry.enabled {
                return MCPServerHealth(
                    client: .codex,
                    name: entry.name,
                    state: .disabled,
                    detail: entry.disabledReason?.isEmpty == false ? "Intentionally disabled" : "Disabled"
                )
            }
            if entry.authStatus == "not_logged_in" {
                return MCPServerHealth(
                    client: .codex,
                    name: entry.name,
                    state: .needsSignIn,
                    detail: "Sign-in required"
                )
            }
            return MCPServerHealth(
                client: .codex,
                name: entry.name,
                state: .configured,
                detail: "Configured; live connection not checked"
            )
        }
    }

    static func scanClaudeMCPConfiguration(homeDirectory: URL) -> [MCPServerHealth] {
        let claudeRoot = homeDirectory.appendingPathComponent(".claude")
        let configURLs = [
            homeDirectory.appendingPathComponent(".claude.json"),
            claudeRoot.appendingPathComponent("settings.json")
        ]
        let legacyConfigURL = homeDirectory.appendingPathComponent(".claude.json")
        var globalNames = Set<String>()
        var globalDisabledNames = Set<String>()
        var userApprovedManifestNames = Set<String>()
        var userRejectedManifestNames = Set<String>()
        var userApprovesAllManifestNames: Bool?
        var projectScopes: [ClaudeProjectMCPScope] = []
        var pluginStates: [String: Bool] = [:]
        var disabledPluginSelectors = Set<String>()
        var configurationUnavailable = false

        for url in configURLs {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let object = try loadJSONObject(at: url)
                if url == legacyConfigURL {
                    globalNames.formUnion(dictionaryKeys(object["mcpServers"]))
                }
                globalDisabledNames.formUnion(disabledServerNames(in: object))
                disabledPluginSelectors.formUnion(disabledServerNames(in: object))
                userApprovedManifestNames.formUnion(stringArray(object["enabledMcpjsonServers"]))
                userRejectedManifestNames.formUnion(rejectedManifestNames(in: object))
                if object["enableAllProjectMcpServers"] as? Bool == true {
                    userApprovesAllManifestNames = true
                }
                if let projects = object["projects"] as? [String: Any] {
                    for (projectPath, projectValue) in projects {
                        guard let project = projectValue as? [String: Any] else { continue }
                        var projectScope = ClaudeProjectMCPScope(
                            directNames: dictionaryKeys(project["mcpServers"]),
                            manifestNames: [],
                            approvedManifestNames: stringArray(project["enabledMcpjsonServers"]),
                            disabledServerNames: disabledServerNames(in: project),
                            rejectedManifestNames: rejectedManifestNames(in: project),
                            approvesAllManifestNames: project["enableAllProjectMcpServers"] as? Bool,
                            pluginSelections: pluginSelections(
                                booleanDictionary(project["enabledPlugins"]),
                                scope: "local",
                                projectPath: projectPath
                            )
                        )
                        let projectURL = URL(fileURLWithPath: projectPath)
                        for manifestURL in ancestorClaudeManifestURLs(from: projectURL) {
                            do {
                                let manifest = try loadJSONObject(at: manifestURL)
                                projectScope.manifestNames.formUnion(dictionaryKeys(manifest["mcpServers"]))
                            } catch {
                                configurationUnavailable = true
                            }
                        }
                        for settingsName in ["settings.json", "settings.local.json"] {
                            let settingsURL = projectURL
                                .appendingPathComponent(".claude")
                                .appendingPathComponent(settingsName)
                            guard FileManager.default.fileExists(atPath: settingsURL.path) else { continue }
                            do {
                                let settings = try loadJSONObject(at: settingsURL)
                                projectScope.disabledServerNames.formUnion(disabledServerNames(in: settings))
                                if settingsName == "settings.local.json" {
                                    projectScope.approvedManifestNames.formUnion(
                                        stringArray(settings["enabledMcpjsonServers"])
                                    )
                                    projectScope.rejectedManifestNames.formUnion(
                                        rejectedManifestNames(in: settings)
                                    )
                                    if settings["enableAllProjectMcpServers"] as? Bool == true {
                                        projectScope.approvesAllManifestNames = true
                                    }
                                }
                                projectScope.pluginSelections.merge(
                                    pluginSelections(
                                        booleanDictionary(settings["enabledPlugins"]),
                                        scope: settingsName == "settings.local.json" ? "local" : "project",
                                        projectPath: projectPath
                                    ),
                                    uniquingKeysWith: { _, newer in newer }
                                )
                            } catch {
                                configurationUnavailable = true
                            }
                        }
                        projectScopes.append(projectScope)
                    }
                }
                if let plugins = object["enabledPlugins"] as? [String: Any] {
                    for (key, value) in plugins {
                        if let enabled = value as? Bool {
                            pluginStates[key] = enabled
                        }
                    }
                }
            } catch {
                configurationUnavailable = true
            }
        }

        var stateCounts: [String: MCPStateCounts] = [:]
        recordMCPState(names: globalNames, disabledNames: globalDisabledNames, into: &stateCounts)
        for scope in projectScopes {
            recordMCPState(
                names: scope.directNames,
                disabledNames: scope.disabledServerNames,
                into: &stateCounts
            )
            recordManifestMCPState(
                scope,
                userApprovedNames: userApprovedManifestNames,
                userRejectedNames: userRejectedManifestNames,
                userApprovesAll: userApprovesAllManifestNames,
                into: &stateCounts
            )
        }

        var pluginOccurrences = pluginStates.compactMap { entry in
            entry.value ? ClaudePluginOccurrence(
                identifier: entry.key,
                scope: "user",
                projectPath: nil,
                disabledNames: disabledPluginSelectors
            ) : nil
        }
        for scope in projectScopes {
            pluginOccurrences += scope.pluginSelections.compactMap { entry in
                entry.value.enabled ? ClaudePluginOccurrence(
                    identifier: entry.key,
                    scope: entry.value.scope,
                    projectPath: entry.value.projectPath,
                    disabledNames: scope.disabledServerNames.union(disabledPluginSelectors)
                ) : nil
            }
        }
        for occurrence in pluginOccurrences {
            do {
                let pluginNames = try claudePluginMCPNames(
                    identifier: occurrence.identifier,
                    scope: occurrence.scope,
                    projectPath: occurrence.projectPath,
                    claudeRoot: claudeRoot
                )
                recordMCPState(
                    names: pluginNames,
                    disabledNames: pluginNames.intersection(occurrence.disabledNames),
                    into: &stateCounts
                )
            } catch {
                configurationUnavailable = true
            }
        }

        var servers = stateCounts.keys.sorted().map { name in
            let counts = stateCounts[name, default: MCPStateCounts()]
            let state: MCPConnectionState = if counts.pending > 0 {
                .pendingApproval
            } else if counts.active > 0 {
                .configured
            } else {
                .disabled
            }
            let detail: String = switch state {
            case .configured: "Configured; live connection not checked"
            case .disabled: "Intentionally disabled"
            case .pendingApproval: "Project server needs approval"
            case .needsSignIn, .unavailable: ""
            }
            return MCPServerHealth(
                client: .claude,
                name: name,
                state: state,
                detail: detail
            )
        }
        if configurationUnavailable {
            servers.append(MCPServerHealth(
                client: .claude,
                name: "Claude configuration",
                state: .unavailable,
                detail: "One or more configuration sources could not be read"
            ))
        }
        return servers
    }
}

private func loadJSONObject(at url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw NSError(domain: "MetagentMCPHealth", code: 2, userInfo: nil)
    }
    return object
}

private func dictionaryKeys(_ value: Any?) -> Set<String> {
    Set((value as? [String: Any])?.keys ?? Dictionary<String, Any>().keys)
}

private func stringArray(_ value: Any?) -> Set<String> {
    Set(value as? [String] ?? [])
}

private func booleanDictionary(_ value: Any?) -> [String: Bool] {
    (value as? [String: Any])?.compactMapValues { $0 as? Bool } ?? [:]
}

private struct ClaudeProjectMCPScope {
    var directNames: Set<String>
    var manifestNames: Set<String>
    var approvedManifestNames: Set<String>
    var disabledServerNames: Set<String>
    var rejectedManifestNames: Set<String>
    var approvesAllManifestNames: Bool?
    var pluginSelections: [String: ClaudePluginSelection]
}

private struct ClaudePluginSelection {
    let enabled: Bool
    let scope: String
    let projectPath: String?
}

private struct ClaudePluginOccurrence {
    let identifier: String
    let scope: String
    let projectPath: String?
    let disabledNames: Set<String>
}

private func pluginSelections(
    _ states: [String: Bool],
    scope: String,
    projectPath: String?
) -> [String: ClaudePluginSelection] {
    states.mapValues {
        ClaudePluginSelection(enabled: $0, scope: scope, projectPath: projectPath)
    }
}

private struct MCPStateCounts {
    var active = 0
    var disabled = 0
    var pending = 0
}

private func recordManifestMCPState(
    _ scope: ClaudeProjectMCPScope,
    userApprovedNames: Set<String>,
    userRejectedNames: Set<String>,
    userApprovesAll: Bool?,
    into stateCounts: inout [String: MCPStateCounts]
) {
    for name in scope.manifestNames {
        var counts = stateCounts[name, default: MCPStateCounts()]
        if userRejectedNames.contains(where: { claudeMCPSelector($0, matches: name) })
            || scope.rejectedManifestNames.contains(where: { claudeMCPSelector($0, matches: name) }) {
            counts.disabled += 1
        } else if scope.approvesAllManifestNames == true
            || userApprovesAll == true
            || userApprovedNames.contains(where: { claudeMCPSelector($0, matches: name) })
            || scope.approvedManifestNames.contains(where: { claudeMCPSelector($0, matches: name) }) {
            counts.active += 1
        } else {
            counts.pending += 1
        }
        stateCounts[name] = counts
    }
}

private func claudeMCPSelector(_ selector: String, matches name: String) -> Bool {
    if selector.hasPrefix("plugin:") || name.hasPrefix("plugin:") {
        return selector == name
    }
    return normalizeClaudeMCPName(selector) == normalizeClaudeMCPName(name)
}

private func normalizeClaudeMCPName(_ name: String) -> String {
    String(name.unicodeScalars.map { scalar in
        CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-"
            ? Character(scalar)
            : "_"
    })
}

private func disabledServerNames(in object: [String: Any]) -> Set<String> {
    stringArray(object["disabledMcpServers"])
}

private func rejectedManifestNames(in object: [String: Any]) -> Set<String> {
    stringArray(object["disabledMcpjsonServers"])
}

private func ancestorClaudeManifestURLs(from projectURL: URL) -> [URL] {
    var manifests: [URL] = []
    var directory = projectURL.standardizedFileURL
    while true {
        let manifest = directory.appendingPathComponent(".mcp.json")
        if FileManager.default.fileExists(atPath: manifest.path) {
            manifests.append(manifest)
        }
        let parent = directory.deletingLastPathComponent()
        guard parent.path != directory.path else { break }
        directory = parent
    }
    return manifests
}

private func recordMCPState(
    names: Set<String>,
    disabledNames: Set<String>,
    into stateCounts: inout [String: MCPStateCounts]
) {
    for name in names {
        var counts = stateCounts[name, default: MCPStateCounts()]
        if disabledNames.contains(name) {
            counts.disabled += 1
        } else {
            counts.active += 1
        }
        stateCounts[name] = counts
    }
}

private func claudePluginMCPNames(
    identifier: String,
    scope: String,
    projectPath: String?,
    claudeRoot: URL
) throws -> Set<String> {
    let pluginsRoot = claudeRoot.appendingPathComponent("plugins").standardizedFileURL
    let registryURL = pluginsRoot.appendingPathComponent("installed_plugins.json")
    let registry = try loadJSONObject(at: registryURL)
    guard let plugins = registry["plugins"] as? [String: Any],
          let installations = plugins[identifier] as? [[String: Any]],
          !installations.isEmpty
    else {
        throw NSError(domain: "MetagentMCPHealth", code: 3, userInfo: nil)
    }

    let scopedInstallation = installations.first(where: {
        ($0["scope"] as? String ?? "user") == scope
            && pluginInstallation($0, matchesProjectPath: projectPath)
    })
    let inheritedUserInstallation = installations.first(where: {
        ($0["scope"] as? String ?? "user") == "user"
            && pluginInstallation($0, matchesProjectPath: nil)
    })
    guard let installation = scopedInstallation ?? inheritedUserInstallation,
          let installPath = installation["installPath"] as? String else {
        throw NSError(domain: "MetagentMCPHealth", code: 4, userInfo: nil)
    }
    let installRoot = URL(fileURLWithPath: installPath).standardizedFileURL
    guard installRoot.path.hasPrefix(pluginsRoot.path + "/") else {
        throw NSError(domain: "MetagentMCPHealth", code: 5, userInfo: nil)
    }
    let pluginManifestURL = installRoot
        .appendingPathComponent(".claude-plugin")
        .appendingPathComponent("plugin.json")
    let pluginManifest = FileManager.default.fileExists(atPath: pluginManifestURL.path)
        ? try loadJSONObject(at: pluginManifestURL)
        : [:]
    let pluginName = try claudePluginName(identifier: identifier, manifest: pluginManifest)
    let serverNames = try claudePluginServerNames(
        manifest: pluginManifest,
        installRoot: installRoot
    )
    return Set(serverNames.map {
        "plugin:\(pluginName):\($0)"
    })
}

private func pluginInstallation(_ installation: [String: Any], matchesProjectPath projectPath: String?) -> Bool {
    guard let projectPath else {
        return installation["projectPath"] == nil || installation["projectPath"] is NSNull
    }
    guard let installedProjectPath = installation["projectPath"] as? String else { return false }
    let project = URL(fileURLWithPath: projectPath).standardizedFileURL.path
    let installedProject = URL(fileURLWithPath: installedProjectPath).standardizedFileURL.path
    return project == installedProject || project.hasPrefix(installedProject + "/")
}

private func claudePluginName(identifier: String, manifest: [String: Any]) throws -> String {
    if let name = manifest["name"] as? String, !name.isEmpty {
        return name
    }
    guard let fallback = identifier.split(separator: "@", maxSplits: 1).first,
          !fallback.isEmpty else {
        throw NSError(domain: "MetagentMCPHealth", code: 6, userInfo: nil)
    }
    return String(fallback)
}

private func claudePluginServerNames(
    manifest: [String: Any],
    installRoot: URL
) throws -> Set<String> {
    if let inlineServers = manifest["mcpServers"] as? [String: Any] {
        return Set(inlineServers.keys)
    }
    let configurationURL: URL
    if let relativePath = manifest["mcpServers"] as? String {
        configurationURL = installRoot.appendingPathComponent(relativePath).standardizedFileURL
        guard configurationURL.path.hasPrefix(installRoot.path + "/") else {
            throw NSError(domain: "MetagentMCPHealth", code: 7, userInfo: nil)
        }
    } else {
        configurationURL = installRoot.appendingPathComponent(".mcp.json")
    }
    guard FileManager.default.fileExists(atPath: configurationURL.path) else { return [] }
    let object = try loadJSONObject(at: configurationURL)
    if let wrappedServers = object["mcpServers"] as? [String: Any] {
        return Set(wrappedServers.keys)
    }
    return Set(object.keys.filter { !$0.hasPrefix("$") })
}

private func mcpHealthSort(_ lhs: MCPServerHealth, _ rhs: MCPServerHealth) -> Bool {
    if lhs.state.needsAttention != rhs.state.needsAttention {
        return lhs.state.needsAttention
    }
    if lhs.client != rhs.client {
        return lhs.client.rawValue < rhs.client.rawValue
    }
    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
}
