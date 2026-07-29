import Foundation
import XCTest
@testable import MetagentCore

final class PluginInventoryTests: XCTestCase {

    // MARK: - Claude inventory files

    func testClaudeInstalledPluginsParsesVersionTwoScopeArrays() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-plugin-tests")
        let url = root.appendingPathComponent("installed_plugins.json")
        try Data("""
        {
          "version": 2,
          "plugins": {
            "demo@vendor": [
              {
                "scope": "user",
                "installPath": "/tmp/cache/vendor/demo/1.2.0",
                "version": "1.2.0",
                "installedAt": "2026-06-01T19:13:27.175Z",
                "lastUpdated": "2026-06-02T02:38:36.796Z"
              },
              {
                "scope": "project",
                "projectPath": "/tmp/project-one",
                "installPath": "/tmp/project/vendor/demo/1.1.0",
                "version": "1.1.0"
              },
              {
                "scope": "project",
                "projectPath": "/tmp/project-two",
                "installPath": "/tmp/project-two/vendor/demo/1.1.0",
                "version": "1.1.0"
              }
            ],
            "other@official": [
              {"scope": "user", "version": "0.1.0"}
            ]
          }
        }
        """.utf8).write(to: url)

        let plugins = try claudeInstalledPlugins(at: url)
        let scoped = Dictionary(uniqueKeysWithValues: plugins.map { plugin in
            (
                [plugin.pluginID, plugin.scope, plugin.projectPath]
                    .compactMap { $0 }
                    .joined(separator: ":"),
                plugin
            )
        })

        XCTAssertEqual(plugins.map(\.pluginID), [
            "demo@vendor", "demo@vendor", "demo@vendor", "other@official",
        ])
        XCTAssertEqual(scoped["demo@vendor:user"]?.version, "1.2.0")
        XCTAssertEqual(scoped["demo@vendor:user"]?.installPath, "/tmp/cache/vendor/demo/1.2.0")
        XCTAssertNotNil(scoped["demo@vendor:user"]?.lastUpdated)
        XCTAssertEqual(scoped["demo@vendor:project:/tmp/project-one"]?.version, "1.1.0")
        XCTAssertEqual(scoped["demo@vendor:project:/tmp/project-two"]?.version, "1.1.0")
        XCTAssertNil(scoped["other@official:user"]?.lastUpdated)
    }

    func testClaudeMarketplaceOwnershipSeparatesAnthropicFromThirdParty() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-plugin-tests")
        let url = root.appendingPathComponent("known_marketplaces.json")
        try Data("""
        {
          "claude-plugins-official": {
            "source": {"source": "github", "repo": "anthropics/claude-plugins-official"},
            "installLocation": "/tmp/marketplaces/claude-plugins-official"
          },
          "vendor": {
            "source": {"source": "git", "url": "https://example.com/vendor.git"},
            "autoUpdate": true,
            "installLocation": "/tmp/marketplaces/vendor"
          },
          "manual-official": {
            "source": {"source": "github", "repo": "anthropics/manual"},
            "autoUpdate": false
          }
        }
        """.utf8).write(to: url)

        let marketplaces = try claudeKnownMarketplaces(at: url)

        XCTAssertEqual(marketplaces["claude-plugins-official"]?.isAnthropicOwned, true)
        XCTAssertEqual(marketplaces["claude-plugins-official"]?.updatePolicy, .automatic)
        XCTAssertEqual(marketplaces["vendor"]?.updatePolicy, .automatic)
        XCTAssertEqual(marketplaces["vendor"]?.sourceDetail, "https://example.com/vendor.git")
        XCTAssertEqual(marketplaces["manual-official"]?.updatePolicy, .manual)
    }

    func testClaudePluginRecordsComposeInventoryPolicyAndEnabledState() throws {
        let home = try makeTemporaryRoot(prefix: "metagent-plugin-tests")
        let plugins = home.appendingPathComponent(".claude/plugins")
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude"),
            withIntermediateDirectories: true
        )
        try Data("""
        {
          "version": 2,
          "plugins": {
            "official@claude-plugins-official": [{"scope": "user", "version": "1.0.0"}],
            "vendor@vendor": [{"scope": "user", "version": "0.2.0"}]
          }
        }
        """.utf8).write(to: plugins.appendingPathComponent("installed_plugins.json"))
        try Data("""
        {
          "claude-plugins-official": {
            "source": {"source": "github", "repo": "anthropics/claude-plugins-official"}
          },
          "vendor": {
            "source": {"source": "github", "repo": "vendor/agent-plugins"}
          }
        }
        """.utf8).write(to: plugins.appendingPathComponent("known_marketplaces.json"))
        try Data("""
        {"enabledPlugins": {"official@claude-plugins-official": true, "vendor@vendor": false}}
        """.utf8).write(to: home.appendingPathComponent(".claude/settings.json"))

        let result = MetagentCore.claudePluginRecords(home: home)
        let records = Dictionary(uniqueKeysWithValues: result.records.map { ($0.pluginID, $0) })

        XCTAssertEqual(result.records.count, 2)
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertEqual(records["official@claude-plugins-official"]?.updatePolicy, .automatic)
        XCTAssertEqual(records["official@claude-plugins-official"]?.enabled, true)
        XCTAssertEqual(records["vendor@vendor"]?.updatePolicy, .manual)
        XCTAssertEqual(records["vendor@vendor"]?.enabled, false)
        XCTAssertEqual(records["vendor@vendor"]?.marketplace, "vendor")
        XCTAssertEqual(records["vendor@vendor"]?.scope, "user")
        XCTAssertEqual(records["vendor@vendor"]?.sourceDetail, "vendor/agent-plugins")
    }

    func testClaudePluginRecordsWithoutInstallRegistryReturnsEmpty() throws {
        let home = try makeTemporaryRoot(prefix: "metagent-plugin-tests")

        let result = MetagentCore.claudePluginRecords(home: home)

        XCTAssertTrue(result.records.isEmpty)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    // MARK: - Codex plugin list

    func testCodexPluginListDecodeCarriesMarketplaceSourceType() throws {
        let data = Data("""
        {
          "installed": [
            {
              "pluginId": "vendor@vendor",
              "name": "vendor",
              "marketplaceName": "vendor",
              "version": "1.0.0",
              "installed": true,
              "enabled": true,
              "source": {"source": "local", "path": "/tmp/plugins/vendor"},
              "marketplaceSource": {"sourceType": "git", "source": "https://example.com/vendor.git"}
            },
            {
              "pluginId": "bundled@openai-bundled",
              "name": "bundled",
              "marketplaceName": "openai-bundled",
              "version": "2.0.0",
              "installed": true,
              "enabled": false,
              "source": {"source": "local", "path": "/tmp/bundled"}
            }
          ]
        }
        """.utf8)

        let list = try JSONDecoder().decode(CodexPluginList.self, from: data)

        XCTAssertEqual(list.installed[0].marketplaceSource?.sourceType, "git")
        XCTAssertNil(list.installed[1].marketplaceSource)
        XCTAssertFalse(list.installed[1].enabled)
    }

    // MARK: - Marketplace snapshot versions

    func testCodexSnapshotVersionResolvesPluginPathThroughManifest() throws {
        let home = try makeTemporaryRoot(prefix: "metagent-plugin-tests")
        let marketplace = home.appendingPathComponent(".codex/.tmp/marketplaces/vendor")
        let manifestDir = marketplace.appendingPathComponent(".agents/plugins")
        let pluginManifestDir = marketplace.appendingPathComponent("tools/demo/.codex-plugin")
        try FileManager.default.createDirectory(at: manifestDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pluginManifestDir, withIntermediateDirectories: true)
        try Data("""
        {"name": "vendor", "plugins": [{"name": "demo", "source": {"source": "local", "path": "./tools/demo"}}]}
        """.utf8).write(to: manifestDir.appendingPathComponent("marketplace.json"))
        try Data("""
        {"name": "demo", "version": "3.1.4"}
        """.utf8).write(to: pluginManifestDir.appendingPathComponent("plugin.json"))

        let version = MetagentCore.codexMarketplaceSnapshotVersion(
            marketplace: "vendor",
            pluginName: "demo",
            home: home
        )

        XCTAssertEqual(version, "3.1.4")
    }

    func testCodexSnapshotVersionFallsBackToConventionalPluginsLayout() throws {
        let home = try makeTemporaryRoot(prefix: "metagent-plugin-tests")
        let pluginManifestDir = home.appendingPathComponent(
            ".codex/.tmp/marketplaces/vendor/plugins/demo/.claude-plugin"
        )
        try FileManager.default.createDirectory(at: pluginManifestDir, withIntermediateDirectories: true)
        try Data("""
        {"name": "demo", "version": "0.9.0"}
        """.utf8).write(to: pluginManifestDir.appendingPathComponent("plugin.json"))

        let version = MetagentCore.codexMarketplaceSnapshotVersion(
            marketplace: "vendor",
            pluginName: "demo",
            home: home
        )

        XCTAssertEqual(version, "0.9.0")
    }

    func testClaudeMarketplaceManifestVersionReadsRefreshedCheckout() throws {
        let home = try makeTemporaryRoot(prefix: "metagent-plugin-tests")
        let manifestDir = home.appendingPathComponent(
            ".claude/plugins/marketplaces/vendor/.claude-plugin"
        )
        try FileManager.default.createDirectory(at: manifestDir, withIntermediateDirectories: true)
        try Data("""
        {"name": "vendor", "plugins": [{"name": "demo", "version": "2.2.0"}, {"name": "unversioned"}]}
        """.utf8).write(to: manifestDir.appendingPathComponent("marketplace.json"))

        XCTAssertEqual(
            MetagentCore.claudeMarketplaceManifestVersion(
                marketplace: "vendor",
                pluginName: "demo",
                home: home
            ),
            "2.2.0"
        )
        XCTAssertNil(
            MetagentCore.claudeMarketplaceManifestVersion(
                marketplace: "vendor",
                pluginName: "unversioned",
                home: home
            )
        )
    }

    func testClaudeUpdatesOnlySupportUserScopeWithoutProjectContext() {
        XCTAssertTrue(MetagentCore.isSupportedClaudeUpdateScope("user"))
        XCTAssertFalse(MetagentCore.isSupportedClaudeUpdateScope("project"))
        XCTAssertFalse(MetagentCore.isSupportedClaudeUpdateScope("local"))
        XCTAssertFalse(MetagentCore.isSupportedClaudeUpdateScope("managed"))
        XCTAssertFalse(MetagentCore.isSupportedClaudeUpdateScope(nil))
    }

    func testSemanticVersionComparisonHandlesPrereleasesAndBuildMetadata() {
        XCTAssertEqual(semanticVersionComparison("1.0.0", "1.0.0-beta"), .orderedDescending)
        XCTAssertEqual(semanticVersionComparison("1.0.0-beta.2", "1.0.0-beta.10"), .orderedAscending)
        XCTAssertEqual(semanticVersionComparison("1.0.0+2", "1.0.0+1"), .orderedSame)
        XCTAssertNil(semanticVersionComparison("rolling", "1.0.0"))
    }

    func testClaudeEnabledStateUsesOwningProjectScope() throws {
        let home = try makeTemporaryRoot(prefix: "metagent-plugin-tests")
        let project = home.appendingPathComponent("project")
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent(".claude"),
            withIntermediateDirectories: true
        )
        try Data("""
        {"enabledPlugins": {"demo@vendor": false}}
        """.utf8).write(to: project.appendingPathComponent(".claude/settings.json"))
        let plugin = ClaudeInstalledPlugin(
            pluginID: "demo@vendor",
            version: "1.0.0",
            scope: "project",
            projectPath: project.path
        )

        XCTAssertFalse(claudePluginEnabledState(
            plugin,
            home: home,
            userStates: ["demo@vendor": true]
        ))
    }
}
