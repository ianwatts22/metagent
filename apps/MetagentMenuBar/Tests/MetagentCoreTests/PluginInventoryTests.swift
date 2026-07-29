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
              }
            ],
            "other@official": [
              {"scope": "user", "version": "0.1.0"}
            ]
          }
        }
        """.utf8).write(to: url)

        let plugins = try claudeInstalledPlugins(at: url)

        XCTAssertEqual(plugins.map(\.pluginID), ["demo@vendor", "other@official"])
        XCTAssertEqual(plugins[0].version, "1.2.0")
        XCTAssertEqual(plugins[0].installPath, "/tmp/cache/vendor/demo/1.2.0")
        XCTAssertNotNil(plugins[0].lastUpdated)
        XCTAssertNil(plugins[1].lastUpdated)
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
            "installLocation": "/tmp/marketplaces/vendor"
          }
        }
        """.utf8).write(to: url)

        let marketplaces = try claudeKnownMarketplaces(at: url)

        XCTAssertEqual(marketplaces["claude-plugins-official"]?.isAnthropicOwned, true)
        XCTAssertEqual(marketplaces["vendor"]?.isAnthropicOwned, false)
        XCTAssertEqual(marketplaces["vendor"]?.sourceDetail, "https://example.com/vendor.git")
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
}
