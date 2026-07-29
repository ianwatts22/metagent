import Foundation

// MARK: - Models

public enum PluginRuntime: String, Codable, CaseIterable, Hashable, Sendable {
    case codex
    case claude

    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }

    public var client: MCPClient {
        switch self {
        case .codex: .codex
        case .claude: .claude
        }
    }
}

/// Who is responsible for keeping a plugin current. Runtime-bundled and
/// app-provided plugins are refreshed by their owner; anything installed from
/// a third-party git marketplace only moves when someone runs the update.
public enum PluginUpdatePolicy: String, Codable, Hashable, Sendable {
    case automatic
    case manual

    public var displayLabel: String {
        switch self {
        case .automatic: "Auto"
        case .manual: "Manual"
        }
    }
}

public struct PluginRecord: Identifiable, Hashable, Sendable {
    public let runtime: PluginRuntime
    /// Stable `name@marketplace` identity used by both CLIs.
    public let pluginID: String
    public let name: String
    public let marketplace: String
    public let version: String
    /// Claude installation scope (`user`, `project`, `local`, or `managed`).
    /// Codex plugins are user-level and leave this nil.
    public let scope: String?
    /// Project root recorded for project/local Claude installations.
    public let projectPath: String?
    public let enabled: Bool
    public let updatePolicy: PluginUpdatePolicy
    /// Where the plugin ultimately comes from: a git URL, GitHub repo, or
    /// local path, depending on the marketplace source.
    public let sourceDetail: String
    public let lastUpdated: Date?

    public var id: String {
        [runtime.rawValue, pluginID, scope, projectPath]
            .compactMap { $0 }
            .joined(separator: ":")
    }

    public init(
        runtime: PluginRuntime,
        pluginID: String,
        name: String,
        marketplace: String,
        version: String,
        scope: String? = nil,
        projectPath: String? = nil,
        enabled: Bool,
        updatePolicy: PluginUpdatePolicy,
        sourceDetail: String,
        lastUpdated: Date?
    ) {
        self.runtime = runtime
        self.pluginID = pluginID
        self.name = name
        self.marketplace = marketplace
        self.version = version
        self.scope = scope
        self.projectPath = projectPath
        self.enabled = enabled
        self.updatePolicy = updatePolicy
        self.sourceDetail = sourceDetail
        self.lastUpdated = lastUpdated
    }
}

public struct PluginInventorySnapshot: Sendable {
    public var records: [PluginRecord]
    public var warnings: [String]
    public var scannedAt: Date?

    public static let empty = PluginInventorySnapshot(records: [], warnings: [], scannedAt: nil)

    public init(records: [PluginRecord], warnings: [String], scannedAt: Date?) {
        self.records = records
        self.warnings = warnings
        self.scannedAt = scannedAt
    }
}

// MARK: - Scan

extension MetagentCore {

    public static func scanPluginInventory() -> PluginInventorySnapshot {
        var records: [PluginRecord] = []
        var warnings: [String] = []

        do {
            records += try allCodexPlugins().map(PluginRecord.init(codexPlugin:))
        } catch {
            warnings.append("Codex plugin inventory unavailable: \(error.localizedDescription)")
        }

        let claude = claudePluginRecords(home: homeURL())
        records += claude.records
        warnings += claude.warnings

        return PluginInventorySnapshot(
            records: records.sorted { ($0.name, $0.runtime.rawValue) < ($1.name, $1.runtime.rawValue) },
            warnings: warnings,
            scannedAt: Date()
        )
    }

    /// Claude Code writes everything the inventory needs to disk, so this scan
    /// never has to launch the (slow) `claude` CLI.
    static func claudePluginRecords(home: URL) -> (records: [PluginRecord], warnings: [String]) {
        let pluginsRoot = home.appendingPathComponent(".claude/plugins")
        let installedURL = pluginsRoot.appendingPathComponent("installed_plugins.json")
        guard fileManager.fileExists(atPath: installedURL.path) else {
            return ([], [])
        }

        var warnings: [String] = []
        let marketplaces: [String: ClaudeMarketplace]
        do {
            marketplaces = try claudeKnownMarketplaces(
                at: pluginsRoot.appendingPathComponent("known_marketplaces.json")
            )
        } catch {
            marketplaces = [:]
            warnings.append("Claude marketplace registry unreadable: \(error.localizedDescription)")
        }
        let userEnabledStates = claudeEnabledPluginStates(
            settingsURL: home.appendingPathComponent(".claude/settings.json")
        )

        do {
            let installed = try claudeInstalledPlugins(at: installedURL)
            let records = installed.map { plugin -> PluginRecord in
                let marketplace = plugin.pluginID.split(separator: "@").last.map(String.init) ?? ""
                let source = marketplaces[marketplace]
                return PluginRecord(
                    runtime: .claude,
                    pluginID: plugin.pluginID,
                    name: plugin.pluginID.split(separator: "@").first.map(String.init) ?? plugin.pluginID,
                    marketplace: marketplace,
                    version: plugin.version,
                    scope: plugin.scope,
                    projectPath: plugin.projectPath,
                    enabled: claudePluginEnabledState(
                        plugin,
                        home: home,
                        userStates: userEnabledStates
                    ),
                    updatePolicy: source.map(\.updatePolicy) ?? .manual,
                    sourceDetail: source?.sourceDetail ?? "",
                    lastUpdated: plugin.lastUpdated
                )
            }
            return (records, warnings)
        } catch {
            warnings.append("Claude plugin inventory unreadable: \(error.localizedDescription)")
            return ([], warnings)
        }
    }
}

private extension PluginRecord {
    init(codexPlugin plugin: CodexPlugin) {
        // Local marketplaces are owned by whatever installed them (the Codex
        // runtime, a bundled snapshot, or a desktop app) and are refreshed by
        // that owner. Git marketplaces only move on an explicit upgrade.
        let isGit = plugin.marketplaceSource?.sourceType == "git"
        self.init(
            runtime: .codex,
            pluginID: plugin.pluginId,
            name: plugin.name,
            marketplace: plugin.marketplaceName,
            version: plugin.version,
            enabled: plugin.enabled,
            updatePolicy: isGit ? .manual : .automatic,
            sourceDetail: plugin.marketplaceSource?.source ?? plugin.source.path ?? "",
            lastUpdated: nil
        )
    }
}

// MARK: - Claude plugin files

struct ClaudeInstalledPlugin {
    var pluginID: String
    var version: String
    var scope: String
    var projectPath: String?
    var installPath: String?
    var lastUpdated: Date?
}

struct ClaudeMarketplace {
    var name: String
    /// `github` sources carry an `owner/repo` slug; `git` sources a URL.
    var sourceKind: String
    var repo: String?
    var url: String?
    var installLocation: String?
    var autoUpdate: Bool?

    var isAnthropicOwned: Bool {
        repo?.hasPrefix("anthropics/") == true
    }

    var sourceDetail: String {
        repo ?? url ?? installLocation ?? ""
    }

    var updatePolicy: PluginUpdatePolicy {
        if let autoUpdate {
            return autoUpdate ? .automatic : .manual
        }
        return isAnthropicOwned ? .automatic : .manual
    }
}

func claudeInstalledPlugins(at url: URL) throws -> [ClaudeInstalledPlugin] {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    guard let root = object as? [String: Any],
          let plugins = root["plugins"] as? [String: Any]
    else {
        throw NSError(domain: "MetagentPluginInventory", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "installed_plugins.json has an unexpected shape"
        ])
    }
    let dateParser = ISO8601DateFormatter()
    dateParser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return plugins.flatMap { pluginID, value -> [ClaudeInstalledPlugin] in
        // Version 2 stores one entry per installation scope. Preserve all of
        // them so an update can target the same scope it inventoried. Version
        // 1 stored one object and used the CLI's default user scope.
        let entries = (value as? [[String: Any]])
            ?? (value as? [String: Any]).map { [$0] }
            ?? []
        return entries.compactMap { entry in
            guard let version = entry["version"] as? String else { return nil }
            return ClaudeInstalledPlugin(
                pluginID: pluginID,
                version: version,
                scope: entry["scope"] as? String ?? "user",
                projectPath: entry["projectPath"] as? String,
                installPath: entry["installPath"] as? String,
                lastUpdated: (entry["lastUpdated"] as? String).flatMap { dateParser.date(from: $0) }
            )
        }
    }.sorted {
        ($0.pluginID, $0.scope, $0.projectPath ?? "")
            < ($1.pluginID, $1.scope, $1.projectPath ?? "")
    }
}

func claudeKnownMarketplaces(at url: URL) throws -> [String: ClaudeMarketplace] {
    guard fileManager.fileExists(atPath: url.path) else { return [:] }
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    guard let root = object as? [String: Any] else {
        throw NSError(domain: "MetagentPluginInventory", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "known_marketplaces.json has an unexpected shape"
        ])
    }
    var marketplaces: [String: ClaudeMarketplace] = [:]
    for (name, value) in root {
        guard let entry = value as? [String: Any] else { continue }
        let source = entry["source"] as? [String: Any] ?? [:]
        marketplaces[name] = ClaudeMarketplace(
            name: name,
            sourceKind: source["source"] as? String ?? "",
            repo: source["repo"] as? String,
            url: source["url"] as? String,
            installLocation: entry["installLocation"] as? String,
            autoUpdate: entry["autoUpdate"] as? Bool
        )
    }
    return marketplaces
}

func claudeEnabledPluginStates(settingsURL: URL) -> [String: Bool] {
    guard let data = try? Data(contentsOf: settingsURL),
          let object = try? JSONSerialization.jsonObject(with: data),
          let root = object as? [String: Any],
          let enabled = root["enabledPlugins"] as? [String: Bool]
    else {
        return [:]
    }
    return enabled
}

func claudePluginEnabledState(
    _ plugin: ClaudeInstalledPlugin,
    home: URL,
    userStates: [String: Bool]
) -> Bool {
    guard let projectPath = plugin.projectPath,
          plugin.scope == "project" || plugin.scope == "local"
    else {
        return userStates[plugin.pluginID] ?? true
    }
    let file = plugin.scope == "local" ? "settings.local.json" : "settings.json"
    let projectStates = claudeEnabledPluginStates(
        settingsURL: URL(fileURLWithPath: projectPath)
            .appendingPathComponent(".claude/\(file)")
    )
    return projectStates[plugin.pluginID] ?? userStates[plugin.pluginID] ?? true
}
