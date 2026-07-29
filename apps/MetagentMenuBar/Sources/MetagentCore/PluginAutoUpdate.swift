import Foundation

// MARK: - Report

public enum PluginUpdateStatus: String, Codable, Hashable, Sendable {
    case updated
    case upToDate
    case failed
}

public struct PluginUpdateOutcome: Identifiable, Hashable, Sendable {
    public let runtime: PluginRuntime
    public let pluginID: String
    public let scope: String?
    public let fromVersion: String
    public let toVersion: String?
    public let status: PluginUpdateStatus
    public let detail: String?

    public var id: String {
        [runtime.rawValue, pluginID, scope].compactMap { $0 }.joined(separator: ":")
    }
}

public struct PluginUpdateReport: Sendable {
    public var outcomes: [PluginUpdateOutcome]
    public var warnings: [String]
    public var finishedAt: Date

    public var updatedCount: Int { outcomes.filter { $0.status == .updated }.count }
    public var failedCount: Int { outcomes.filter { $0.status == .failed }.count }

    public var summary: String {
        if outcomes.isEmpty {
            return warnings.isEmpty ? "No third-party plugins to update" : warnings[0]
        }
        var parts: [String] = []
        if updatedCount > 0 { parts.append("\(updatedCount) updated") }
        if failedCount > 0 { parts.append("\(failedCount) failed") }
        if parts.isEmpty { parts.append("all up to date") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Update

extension MetagentCore {

    /// Updates every installed plugin that came from a third-party marketplace.
    /// Official runtime plugins update themselves, so those are left alone;
    /// this covers exactly the set the CLIs make you refresh by hand: the
    /// marketplace snapshot is re-fetched first, then any plugin whose
    /// snapshot version moved past the installed one is reinstalled.
    public static func updateThirdPartyPlugins() -> PluginUpdateReport {
        let snapshot = scanPluginInventory()
        var outcomes: [PluginUpdateOutcome] = []
        var warnings = snapshot.warnings

        let manual = snapshot.records.filter { $0.updatePolicy == .manual }
        let codexPlugins = manual.filter { $0.runtime == .codex }
        let claudePlugins = manual.filter { $0.runtime == .claude }

        outcomes += updateCodexPlugins(codexPlugins, warnings: &warnings)
        outcomes += updateClaudePlugins(claudePlugins, warnings: &warnings)

        return PluginUpdateReport(
            outcomes: outcomes.sorted { $0.pluginID < $1.pluginID },
            warnings: warnings,
            finishedAt: Date()
        )
    }

    // MARK: Codex

    private static func updateCodexPlugins(
        _ plugins: [PluginRecord],
        warnings: inout [String]
    ) -> [PluginUpdateOutcome] {
        guard !plugins.isEmpty else { return [] }
        let executable: URL
        do {
            executable = try codexExecutable()
        } catch {
            warnings.append(error.localizedDescription)
            return []
        }

        var refreshedMarketplaces = Set<String>()
        var failedMarketplaces: [String: String] = [:]
        var outcomes: [PluginUpdateOutcome] = []
        for plugin in plugins {
            if let failure = failedMarketplaces[plugin.marketplace] {
                outcomes.append(failedUpdate(plugin, detail: failure))
                continue
            }
            if !refreshedMarketplaces.contains(plugin.marketplace) {
                refreshedMarketplaces.insert(plugin.marketplace)
                if let failure = runPluginCommand(
                    executable: executable,
                    arguments: ["plugin", "marketplace", "upgrade", plugin.marketplace],
                    label: "codex plugin marketplace upgrade \(plugin.marketplace)"
                ) {
                    warnings.append(failure)
                    failedMarketplaces[plugin.marketplace] = failure
                    outcomes.append(failedUpdate(plugin, detail: failure))
                    continue
                }
            }

            guard let available = codexMarketplaceSnapshotVersion(
                marketplace: plugin.marketplace,
                pluginName: plugin.name,
                home: homeURL()
            ) else {
                outcomes.append(failedUpdate(
                    plugin,
                    detail: "Marketplace version unavailable after refresh; no update attempted."
                ))
                continue
            }
            let comparison = available.compare(plugin.version, options: .numeric)
            if comparison == .orderedSame {
                outcomes.append(PluginUpdateOutcome(
                    runtime: .codex,
                    pluginID: plugin.pluginID,
                    scope: plugin.scope,
                    fromVersion: plugin.version,
                    toVersion: plugin.version,
                    status: .upToDate,
                    detail: nil
                ))
                continue
            }
            guard comparison == .orderedDescending else {
                outcomes.append(failedUpdate(
                    plugin,
                    detail: "Marketplace offers older version \(available); refusing to downgrade \(plugin.version)."
                ))
                continue
            }

            // The freshly verified snapshot is newer. `codex plugin add`
            // replaces the existing installation in place.
            if let failure = runPluginCommand(
                executable: executable,
                arguments: ["plugin", "add", plugin.pluginID],
                label: "codex plugin add \(plugin.pluginID)"
            ) {
                outcomes.append(PluginUpdateOutcome(
                    runtime: .codex,
                    pluginID: plugin.pluginID,
                    scope: plugin.scope,
                    fromVersion: plugin.version,
                    toVersion: nil,
                    status: .failed,
                    detail: failure
                ))
                continue
            }
            outcomes.append(PluginUpdateOutcome(
                runtime: .codex,
                pluginID: plugin.pluginID,
                scope: plugin.scope,
                fromVersion: plugin.version,
                toVersion: available,
                status: .updated,
                detail: nil
            ))
        }
        return outcomes
    }

    /// Version the refreshed marketplace snapshot offers for a plugin, read
    /// from the snapshot the CLI keeps under `~/.codex/.tmp/marketplaces`.
    static func codexMarketplaceSnapshotVersion(
        marketplace: String,
        pluginName: String,
        home: URL
    ) -> String? {
        let root = home.appendingPathComponent(".codex/.tmp/marketplaces/\(marketplace)")
        guard let pluginDirectory = codexSnapshotPluginDirectory(
            marketplaceRoot: root,
            pluginName: pluginName
        ) else { return nil }
        for manifest in [".codex-plugin/plugin.json", ".claude-plugin/plugin.json"] {
            let url = pluginDirectory.appendingPathComponent(manifest)
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let root = object as? [String: Any],
                  let version = root["version"] as? String
            else { continue }
            return version
        }
        return nil
    }

    private static func codexSnapshotPluginDirectory(
        marketplaceRoot: URL,
        pluginName: String
    ) -> URL? {
        // The marketplace manifest maps plugin names to relative paths; fall
        // back to the conventional plugins/<name> layout when it is missing.
        for manifest in [".agents/plugins/marketplace.json", ".claude-plugin/marketplace.json"] {
            let url = marketplaceRoot.appendingPathComponent(manifest)
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let root = object as? [String: Any],
                  let plugins = root["plugins"] as? [[String: Any]]
            else { continue }
            for plugin in plugins where plugin["name"] as? String == pluginName {
                if let source = plugin["source"] as? [String: Any],
                   let path = source["path"] as? String
                {
                    return URL(fileURLWithPath: path, relativeTo: marketplaceRoot).standardizedFileURL
                }
                if let path = plugin["source"] as? String {
                    return URL(fileURLWithPath: path, relativeTo: marketplaceRoot).standardizedFileURL
                }
            }
        }
        let conventional = marketplaceRoot.appendingPathComponent("plugins/\(pluginName)")
        return fileManager.fileExists(atPath: conventional.path) ? conventional : nil
    }

    // MARK: Claude

    private static func updateClaudePlugins(
        _ plugins: [PluginRecord],
        warnings: inout [String]
    ) -> [PluginUpdateOutcome] {
        guard !plugins.isEmpty else { return [] }
        let executable: URL
        do {
            executable = try claudeExecutable()
        } catch {
            warnings.append(error.localizedDescription)
            return []
        }

        var refreshedMarketplaces = Set<String>()
        var failedMarketplaces: [String: String] = [:]
        var outcomes: [PluginUpdateOutcome] = []
        for plugin in plugins {
            if let failure = failedMarketplaces[plugin.marketplace] {
                outcomes.append(failedUpdate(plugin, detail: failure))
                continue
            }
            if !refreshedMarketplaces.contains(plugin.marketplace) {
                refreshedMarketplaces.insert(plugin.marketplace)
                if let failure = runPluginCommand(
                    executable: executable,
                    arguments: ["plugin", "marketplace", "update", plugin.marketplace],
                    label: "claude plugin marketplace update \(plugin.marketplace)"
                ) {
                    warnings.append(failure)
                    failedMarketplaces[plugin.marketplace] = failure
                    outcomes.append(failedUpdate(plugin, detail: failure))
                    continue
                }
            }

            guard let available = claudeMarketplaceManifestVersion(
                marketplace: plugin.marketplace,
                pluginName: plugin.name,
                home: homeURL()
            ) else {
                outcomes.append(failedUpdate(
                    plugin,
                    detail: "Marketplace version unavailable after refresh; no update attempted."
                ))
                continue
            }
            let comparison = available.compare(plugin.version, options: .numeric)
            if comparison == .orderedSame {
                outcomes.append(PluginUpdateOutcome(
                    runtime: .claude,
                    pluginID: plugin.pluginID,
                    scope: plugin.scope,
                    fromVersion: plugin.version,
                    toVersion: plugin.version,
                    status: .upToDate,
                    detail: nil
                ))
                continue
            }
            guard comparison == .orderedDescending else {
                outcomes.append(failedUpdate(
                    plugin,
                    detail: "Marketplace offers older version \(available); refusing to downgrade \(plugin.version)."
                ))
                continue
            }
            guard let scope = plugin.scope else {
                outcomes.append(failedUpdate(
                    plugin,
                    detail: "Installation scope is unknown; no update attempted."
                ))
                continue
            }

            if let failure = runPluginCommand(
                executable: executable,
                arguments: ["plugin", "update", "--scope", scope, plugin.pluginID],
                label: "claude plugin update \(plugin.pluginID) --scope \(scope)"
            ) {
                outcomes.append(PluginUpdateOutcome(
                    runtime: .claude,
                    pluginID: plugin.pluginID,
                    scope: plugin.scope,
                    fromVersion: plugin.version,
                    toVersion: nil,
                    status: .failed,
                    detail: failure
                ))
                continue
            }
            let installed = claudePluginRecords(home: homeURL()).records
                .first { $0.pluginID == plugin.pluginID && $0.scope == plugin.scope }?.version
            outcomes.append(PluginUpdateOutcome(
                runtime: .claude,
                pluginID: plugin.pluginID,
                scope: plugin.scope,
                fromVersion: plugin.version,
                toVersion: installed ?? available,
                status: .updated,
                detail: nil
            ))
        }
        return outcomes
    }

    /// Latest version a Claude marketplace advertises for a plugin, read from
    /// the checkout `claude plugin marketplace update` just refreshed.
    static func claudeMarketplaceManifestVersion(
        marketplace: String,
        pluginName: String,
        home: URL
    ) -> String? {
        let manifest = home.appendingPathComponent(
            ".claude/plugins/marketplaces/\(marketplace)/.claude-plugin/marketplace.json"
        )
        guard let data = try? Data(contentsOf: manifest),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let plugins = root["plugins"] as? [[String: Any]]
        else { return nil }
        for plugin in plugins where plugin["name"] as? String == pluginName {
            return plugin["version"] as? String
        }
        return nil
    }

    // MARK: Helpers

    private static func failedUpdate(
        _ plugin: PluginRecord,
        detail: String
    ) -> PluginUpdateOutcome {
        PluginUpdateOutcome(
            runtime: plugin.runtime,
            pluginID: plugin.pluginID,
            scope: plugin.scope,
            fromVersion: plugin.version,
            toVersion: nil,
            status: .failed,
            detail: detail
        )
    }

    /// Runs one plugin CLI command; returns a failure description, or nil on
    /// success. Marketplace refreshes hit the network, so the timeout is long.
    private static func runPluginCommand(
        executable: URL,
        arguments: [String],
        label: String
    ) -> String? {
        do {
            let result = try runSubprocess(
                executable: executable,
                arguments: arguments,
                timeout: 180
            )
            if result.timedOut {
                return "\(label) timed out after 180 seconds"
            }
            guard result.status == 0 else {
                let output = combinedSubprocessOutput(result)
                return output.isEmpty ? "\(label) failed" : "\(label): \(output)"
            }
            return nil
        } catch {
            return "\(label): \(error.localizedDescription)"
        }
    }
}

func claudeExecutable() throws -> URL {
    guard let path = firstExecutableCandidate(
        named: "claude",
        environmentOverride: "METAGENT_CLAUDE",
        extraCandidates: [
            homeURL().appendingPathComponent(".local/bin/claude").path,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]
    ) else {
        throw NSError(domain: "MetagentClaudePlugins", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "claude executable not found; set METAGENT_CLAUDE to enable plugin updates"
        ])
    }
    return URL(fileURLWithPath: path)
}
