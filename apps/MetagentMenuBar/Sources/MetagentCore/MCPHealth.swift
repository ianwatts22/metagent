import Foundation

public enum MCPClient: String, Codable, CaseIterable, Hashable, Sendable {
    case codex
    case claude

    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }
}

public enum MCPConnectionState: String, Codable, Hashable, Sendable {
    case configured
    case disabled
    case pendingApproval
    case needsSignIn
    case unavailable

    public var needsAttention: Bool {
        self == .pendingApproval || self == .needsSignIn || self == .unavailable
    }
}

public struct MCPProjectState: Codable, Equatable, Sendable {
    public let path: String
    public let state: MCPConnectionState

    public init(path: String, state: MCPConnectionState) {
        self.path = path
        self.state = state
    }
}

public struct MCPServerHealth: Codable, Equatable, Identifiable, Sendable {
    public let client: MCPClient
    public let name: String
    public let state: MCPConnectionState
    public let detail: String
    public let globalState: MCPConnectionState?
    public let projectStates: [MCPProjectState]

    public var projectPaths: [String] {
        projectStates.filter { $0.state == .pendingApproval }.map(\.path)
    }

    public var id: String { "\(client.rawValue):\(name)" }

    public var supportsAuthentication: Bool {
        state == .needsSignIn && client == .codex
    }

    public init(
        client: MCPClient,
        name: String,
        state: MCPConnectionState,
        detail: String,
        globalState: MCPConnectionState? = nil,
        projectStates: [MCPProjectState] = []
    ) {
        self.client = client
        self.name = name
        self.state = state
        self.detail = detail
        self.globalState = globalState ?? (projectStates.isEmpty ? state : nil)
        self.projectStates = projectStates
    }

    public func scoped(to projectPath: String) -> MCPServerHealth? {
        let matchingProjectStates = projectStates.filter { $0.path == projectPath }
        guard globalState != nil || !matchingProjectStates.isEmpty else { return nil }
        let applicableStates = [globalState].compactMap { $0 } + matchingProjectStates.map(\.state)
        let scopedState = aggregateMCPState(applicableStates)
        return MCPServerHealth(
            client: client,
            name: name,
            state: scopedState,
            detail: mcpStateDetail(scopedState, projectStates: matchingProjectStates),
            globalState: globalState,
            projectStates: matchingProjectStates
        )
    }

    public func projectOnly(at projectPath: String) -> MCPServerHealth? {
        let matchingProjectStates = projectStates.filter { $0.path == projectPath }
        guard !matchingProjectStates.isEmpty else { return nil }
        let scopedState = aggregateMCPState(matchingProjectStates.map(\.state))
        return MCPServerHealth(
            client: client,
            name: name,
            state: scopedState,
            detail: mcpStateDetail(scopedState, projectStates: matchingProjectStates),
            globalState: nil,
            projectStates: matchingProjectStates
        )
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

    func disabledCount(for client: MCPClient) -> Int {
        servers.filter { $0.client == client && $0.state == .disabled }.count
    }

    public func scoped(to projectPath: String?) -> MCPHealthSnapshot {
        guard let projectPath else { return self }
        return MCPHealthSnapshot(
            servers: servers.compactMap { $0.scoped(to: projectPath) },
            observedAt: observedAt
        )
    }

    public func projectOnly(at projectPath: String) -> MCPHealthSnapshot {
        MCPHealthSnapshot(
            servers: servers.compactMap { $0.projectOnly(at: projectPath) },
            observedAt: observedAt
        )
    }

    public var inventory: [MCPInventoryEntry] {
        Dictionary(grouping: servers, by: \.name)
            .map { name, matches in
                let states = Dictionary(
                    matches.map { ($0.client, $0.state) },
                    uniquingKeysWith: { current, candidate in
                        aggregateMCPState([current, candidate])
                    }
                )
                return MCPInventoryEntry(
                    name: name,
                    clients: states.keys.sorted { $0.rawValue < $1.rawValue },
                    clientStates: states,
                    globalClients: Array(Set(matches.compactMap { server in
                        server.globalState == nil ? nil : server.client
                    })).sorted { $0.rawValue < $1.rawValue },
                    projectPaths: Array(Set(matches.flatMap { $0.projectStates.map(\.path) })).sorted(),
                    state: aggregateMCPState(Array(states.values))
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

public struct MCPInventoryEntry: Equatable, Identifiable, Sendable {
    public let name: String
    public let clients: [MCPClient]
    public let clientStates: [MCPClient: MCPConnectionState]
    public let globalClients: [MCPClient]
    public let projectPaths: [String]
    public let state: MCPConnectionState

    public var id: String { name }

    func state(for client: MCPClient) -> MCPConnectionState? {
        clientStates[client]
    }
}

public struct MCPAuthenticationResult: Equatable, Sendable {
    public let succeeded: Bool
    public let timedOut: Bool
    public let message: String

    public init(succeeded: Bool, timedOut: Bool, message: String) {
        self.succeeded = succeeded
        self.timedOut = timedOut
        self.message = message
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
    /// Returns the client-owned command for an interactive authentication
    /// flow. The absolute executable path uses the same resolver as inventory,
    /// so Terminal does not need to have Codex on its own PATH.
    static func mcpAuthenticationCommand(
        for server: MCPServerHealth,
        codexExecutableOverride: URL? = nil
    ) throws -> [String]? {
        guard server.supportsAuthentication else { return nil }
        let executable = try codexExecutableOverride ?? codexExecutable()
        return [executable.path, "mcp", "login", server.name]
    }

    /// Returns the configured HTTP endpoint without exposing headers or other
    /// transport configuration. This lets the app recognize loopback MCPs and
    /// give a useful local-app recovery path before starting OAuth.
    static func mcpTransportURL(
        for server: MCPServerHealth,
        codexExecutableOverride: URL? = nil
    ) throws -> URL? {
        guard server.client == .codex else { return nil }
        let executable = try codexExecutableOverride ?? codexExecutable()
        let result = try runSubprocess(
            executable: executable,
            arguments: ["mcp", "get", server.name, "--json"],
            timeout: 15
        )
        guard !result.timedOut, result.status == 0 else { return nil }
        return try parseCodexMCPTransportURL(result.standardOutput)
    }

    /// Runs the client-owned login command without opening a Terminal window.
    /// The caller gets only a redacted failure summary; successful OAuth output
    /// may contain one-time authorization URLs and is intentionally discarded.
    static func authenticateMCPServer(
        _ server: MCPServerHealth,
        codexExecutableOverride: URL? = nil,
        timeout: TimeInterval = 300
    ) throws -> MCPAuthenticationResult {
        guard let command = try mcpAuthenticationCommand(
            for: server,
            codexExecutableOverride: codexExecutableOverride
        ), let executable = command.first
        else {
            return MCPAuthenticationResult(
                succeeded: false,
                timedOut: false,
                message: "This MCP does not support authentication from Metagent."
            )
        }
        let result = try runSubprocess(
            executable: URL(fileURLWithPath: executable),
            arguments: Array(command.dropFirst()),
            timeout: timeout
        )
        if !result.timedOut, result.status == 0 {
            return MCPAuthenticationResult(succeeded: true, timedOut: false, message: "")
        }
        let output = redactMCPAuthenticationOutput(combinedSubprocessOutput(result))
        let message: String
        if result.timedOut {
            message = "Authentication timed out before the MCP client completed sign-in."
        } else if output.isEmpty {
            message = "The MCP client exited with status \(result.status)."
        } else {
            message = output
        }
        return MCPAuthenticationResult(
            succeeded: false,
            timedOut: result.timedOut,
            message: message
        )
    }

    internal static func parseCodexMCPTransportURL(_ data: Data) throws -> URL? {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let transport = root["transport"] as? [String: Any],
              let rawURL = transport["url"] as? String
        else { return nil }
        return URL(string: rawURL)
    }

    /// Builds a passive MCP inventory. This never starts an MCP server, performs OAuth discovery,
    /// or invokes a tool. Codex's supported JSON inventory and Claude's local configuration are
    /// treated as configuration evidence, not proof that a connection currently works.
    static func scanMCPHealth(
        homeDirectory: URL? = nil,
        codexExecutableOverride: URL? = nil,
        additionalProjectPaths: [String] = [],
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

        servers += scanClaudeMCPConfiguration(
            homeDirectory: home,
            additionalProjectPaths: additionalProjectPaths
        )
        return MCPHealthSnapshot(servers: servers.sorted(by: mcpHealthSort), observedAt: observedAt)
    }

    internal static func parseCodexMCPInventory(_ data: Data) throws -> [MCPServerHealth] {
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

    internal static func scanClaudeMCPConfiguration(
        homeDirectory: URL,
        additionalProjectPaths: [String] = []
    ) -> [MCPServerHealth] {
        let claudeRoot = homeDirectory.appendingPathComponent(".claude")
        let configURLs = [
            homeDirectory.appendingPathComponent(".claude.json"),
            claudeRoot.appendingPathComponent("settings.json")
        ]
        var globalNames = Set<String>()
        var globalDisabledNames = Set<String>()
        var userApprovedManifestNames = Set<String>()
        var userRejectedManifestNames = Set<String>()
        var userApprovesAllManifestNames: Bool?
        var projectScopes: [ClaudeProjectMCPScope] = []
        var pluginStates: [String: Bool] = [:]
        var configurationUnavailable = false

        for url in configURLs {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let object = try loadJSONObject(at: url)
                if url == configURLs[0] {
                    globalNames.formUnion(dictionaryKeys(object["mcpServers"]))
                }
                globalDisabledNames.formUnion(disabledServerNames(in: object))
                userApprovedManifestNames.formUnion(stringArray(object["enabledMcpjsonServers"]))
                userRejectedManifestNames.formUnion(rejectedManifestNames(in: object))
                if object["enableAllProjectMcpServers"] as? Bool == true {
                    userApprovesAllManifestNames = true
                }
                if let projects = object["projects"] as? [String: Any] {
                    for (projectPath, projectValue) in projects {
                        guard let project = projectValue as? [String: Any] else { continue }
                        let projectURL = URL(fileURLWithPath: projectPath).resolvingSymlinksInPath()
                        do {
                            let values = try projectURL.resourceValues(forKeys: [.isDirectoryKey])
                            guard values.isDirectory == true else { continue }
                            _ = try FileManager.default.contentsOfDirectory(atPath: projectURL.path)
                        } catch {
                            let error = error as NSError
                            if error.domain == NSCocoaErrorDomain,
                               error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError
                            {
                                continue
                            }
                            configurationUnavailable = true
                            continue
                        }
                        projectScopes.append(claudeProjectMCPScope(
                            projectPath: projectPath,
                            project: project,
                            configurationUnavailable: &configurationUnavailable
                        ))
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

        let knownProjectPaths = Set(projectScopes.map(\.projectPath))
        for projectPath in additionalProjectPaths {
            let canonicalPath = canonicalMCPProjectPath(projectPath)
            guard !knownProjectPaths.contains(canonicalPath) else { continue }
            projectScopes.append(claudeProjectMCPScope(
                projectPath: projectPath,
                project: [:],
                configurationUnavailable: &configurationUnavailable
            ))
        }

        var stateCounts: [String: MCPStateCounts] = [:]
        recordMCPState(
            names: globalNames,
            disabledNames: globalDisabledNames,
            projectPath: nil,
            into: &stateCounts
        )
        for scope in projectScopes {
            recordMCPState(
                names: scope.directNames,
                disabledNames: scope.disabledServerNames,
                projectPath: scope.projectPath,
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
                disabledNames: globalDisabledNames
            ) : nil
        }
        for scope in projectScopes {
            pluginOccurrences += scope.pluginSelections.compactMap { entry in
                entry.value.enabled ? ClaudePluginOccurrence(
                    identifier: entry.key,
                    scope: entry.value.scope,
                    projectPath: entry.value.projectPath,
                    disabledNames: scope.disabledServerNames.union(globalDisabledNames)
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
                    projectPath: occurrence.projectPath.map {
                        URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path
                    },
                    into: &stateCounts
                )
            } catch {
                configurationUnavailable = true
            }
        }

        var servers = stateCounts.keys.sorted().map { name in
            let counts = stateCounts[name, default: MCPStateCounts()]
            let globalState = counts.global.state
            let projectStates = counts.projects.compactMap { path, projectCounts in
                projectCounts.state.map { MCPProjectState(path: path, state: $0) }
            }.sorted { $0.path < $1.path }
            let state = aggregateMCPState(
                [globalState].compactMap { $0 } + projectStates.map(\.state)
            )
            return MCPServerHealth(
                client: .claude,
                name: name,
                state: state,
                detail: mcpStateDetail(state, projectStates: projectStates),
                globalState: globalState,
                projectStates: projectStates
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

private func redactMCPAuthenticationOutput(_ output: String) -> String {
    output.replacingOccurrences(
        of: #"((?:https?)://[^\s?]+)\?[^\s]+"#,
        with: "$1?[redacted]",
        options: .regularExpression
    )
}

private func loadJSONObject(at url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw NSError(domain: "MetagentMCPHealth", code: 2, userInfo: nil)
    }
    return object
}

private func dictionaryKeys(_ value: Any?) -> Set<String> {
    (value as? [String: Any]).map { Set($0.keys) } ?? []
}

private func stringArray(_ value: Any?) -> Set<String> {
    Set(value as? [String] ?? [])
}

private func booleanDictionary(_ value: Any?) -> [String: Bool] {
    (value as? [String: Any])?.compactMapValues { $0 as? Bool } ?? [:]
}

private struct ClaudeProjectMCPScope {
    var projectPath: String
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

private func canonicalMCPProjectPath(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
}

private func claudeProjectMCPScope(
    projectPath: String,
    project: [String: Any],
    configurationUnavailable: inout Bool
) -> ClaudeProjectMCPScope {
    let canonicalPath = canonicalMCPProjectPath(projectPath)
    let projectURL = URL(fileURLWithPath: canonicalPath)
    var scope = ClaudeProjectMCPScope(
        projectPath: canonicalPath,
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
    for manifestURL in ancestorClaudeManifestURLs(from: projectURL) {
        do {
            let manifest = try loadJSONObject(at: manifestURL)
            scope.manifestNames.formUnion(dictionaryKeys(manifest["mcpServers"]))
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
            scope.disabledServerNames.formUnion(disabledServerNames(in: settings))
            if settingsName == "settings.local.json" {
                scope.approvedManifestNames.formUnion(stringArray(settings["enabledMcpjsonServers"]))
                scope.rejectedManifestNames.formUnion(rejectedManifestNames(in: settings))
                if settings["enableAllProjectMcpServers"] as? Bool == true {
                    scope.approvesAllManifestNames = true
                }
            }
            scope.pluginSelections.merge(
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
    return scope
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

private struct ScopedMCPStateCounts {
    var active = 0
    var disabled = 0
    var pending = 0

    var state: MCPConnectionState? {
        guard active + disabled + pending > 0 else { return nil }
        if pending > 0 { return .pendingApproval }
        if active > 0 { return .configured }
        return .disabled
    }
}

private struct MCPStateCounts {
    var global = ScopedMCPStateCounts()
    var projects: [String: ScopedMCPStateCounts] = [:]
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
        var projectCounts = counts.projects[scope.projectPath, default: ScopedMCPStateCounts()]
        if userRejectedNames.contains(where: { claudeMCPSelector($0, matches: name) })
            || scope.rejectedManifestNames.contains(where: { claudeMCPSelector($0, matches: name) }) {
            projectCounts.disabled += 1
        } else if scope.approvesAllManifestNames == true
            || userApprovesAll == true
            || userApprovedNames.contains(where: { claudeMCPSelector($0, matches: name) })
            || scope.approvedManifestNames.contains(where: { claudeMCPSelector($0, matches: name) }) {
            projectCounts.active += 1
        } else {
            projectCounts.pending += 1
        }
        counts.projects[scope.projectPath] = projectCounts
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
    projectPath: String?,
    into stateCounts: inout [String: MCPStateCounts]
) {
    for name in names {
        var counts = stateCounts[name, default: MCPStateCounts()]
        var scopedCounts = projectPath.map {
            counts.projects[$0, default: ScopedMCPStateCounts()]
        } ?? counts.global
        if disabledNames.contains(name) {
            scopedCounts.disabled += 1
        } else {
            scopedCounts.active += 1
        }
        if let projectPath {
            counts.projects[projectPath] = scopedCounts
        } else {
            counts.global = scopedCounts
        }
        stateCounts[name] = counts
    }
}

private func aggregateMCPState(_ states: [MCPConnectionState]) -> MCPConnectionState {
    if states.contains(.unavailable) { return .unavailable }
    if states.contains(.needsSignIn) { return .needsSignIn }
    if states.contains(.pendingApproval) { return .pendingApproval }
    if states.contains(.configured) { return .configured }
    return .disabled
}

private func mcpStateDetail(
    _ state: MCPConnectionState,
    projectStates: [MCPProjectState]
) -> String {
    switch state {
    case .configured:
        return "Configured; live connection not checked"
    case .disabled:
        return "Intentionally disabled"
    case .pendingApproval:
        let paths = projectStates.filter { $0.state == .pendingApproval }.map(\.path)
        if paths.count == 1, let path = paths.first {
            return "Needs approval in \(URL(fileURLWithPath: path).lastPathComponent)"
        }
        return "Needs approval in \(paths.count) projects"
    case .needsSignIn:
        return "Sign-in required"
    case .unavailable:
        return "Static status could not be read"
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
