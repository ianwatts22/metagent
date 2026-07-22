import Foundation
import Darwin
import XCTest
@testable import MetagentCore

final class MCPHealthTests: XCTestCase {
    func testCodexInventorySeparatesConfigurationSignInAndDisabledStates() throws {
        let data = Data("""
        [
          {"name":"ready","enabled":true,"disabled_reason":null,"auth_status":"oauth"},
          {"name":"login","enabled":true,"disabled_reason":null,"auth_status":"not_logged_in"},
          {"name":"paused","enabled":false,"disabled_reason":"user","auth_status":"unsupported"}
        ]
        """.utf8)

        let servers = try MetagentCore.parseCodexMCPInventory(data)

        XCTAssertEqual(servers.map(\.state), [.configured, .needsSignIn, .disabled])
        XCTAssertFalse(servers[0].detail.localizedCaseInsensitiveContains("working"))
    }

    func testClaudeInventoryCombinesDirectAndEnabledPluginConfiguration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-mcp-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let activePlugin = root.appendingPathComponent(".claude/plugins/cache/vendor/demo/1.10.0")
        let stalePlugin = root.appendingPathComponent(".claude/plugins/cache/vendor/demo/1.9.0")
        let projectRoot = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(
            at: activePlugin,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: activePlugin.appendingPathComponent(".claude-plugin"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: stalePlugin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: projectRoot.appendingPathComponent(".claude"),
            withIntermediateDirectories: true
        )
        try Data("""
        {
          "disabledMcpServers":["global"],
          "enabledPlugins":{"demo@vendor":true}
        }
        """.utf8).write(to: root.appendingPathComponent(".claude/settings.json"))
        try Data("""
        {
          "mcpServers":{"global":{}},
          "projects":{"\(projectRoot.path)":{"mcpServers":{"local-server":{}}}}
        }
        """.utf8).write(to: root.appendingPathComponent(".claude.json"))
        try Data("""
        {"mcpServers":{"project-server":{}}}
        """.utf8).write(to: projectRoot.appendingPathComponent(".mcp.json"))
        try Data("""
        {"disabledMcpjsonServers":["project-server"]}
        """.utf8).write(to: projectRoot.appendingPathComponent(".claude/settings.local.json"))
        try Data("""
        {"mcpServers":{"plugin-server":{"type":"http","url":"https://example.invalid"}}}
        """.utf8).write(to: activePlugin.appendingPathComponent(".mcp.json"))
        try Data("""
        {"name":"DemoName"}
        """.utf8).write(to: activePlugin.appendingPathComponent(".claude-plugin/plugin.json"))
        try Data("""
        {"mcpServers":{"stale-server":{"type":"http","url":"https://example.invalid"}}}
        """.utf8).write(to: stalePlugin.appendingPathComponent(".mcp.json"))
        try Data("""
        {"version":2,"plugins":{"demo@vendor":[{"installPath":"\(activePlugin.path)","version":"1.10.0"}]}}
        """.utf8).write(to: root.appendingPathComponent(".claude/plugins/installed_plugins.json"))
        let servers = MetagentCore.scanClaudeMCPConfiguration(homeDirectory: root)

        XCTAssertEqual(servers.map(\.name), ["global", "local-server", "plugin:DemoName:plugin-server", "project-server"])
        XCTAssertEqual(servers.map(\.state), [.disabled, .configured, .configured, .disabled])
    }

    func testClaudeInventoryReadsInlineAndCustomPluginMCPDeclarations() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-mcp-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let inlineRoot = root.appendingPathComponent(".claude/plugins/cache/vendor/inline/1.0.0")
        let customRoot = root.appendingPathComponent(".claude/plugins/cache/vendor/custom/1.0.0")
        for pluginRoot in [inlineRoot, customRoot] {
            try FileManager.default.createDirectory(
                at: pluginRoot.appendingPathComponent(".claude-plugin"),
                withIntermediateDirectories: true
            )
        }
        try FileManager.default.createDirectory(
            at: customRoot.appendingPathComponent("config"),
            withIntermediateDirectories: true
        )
        try Data("""
        {"enabledPlugins":{"inline@vendor":true,"custom@vendor":true}}
        """.utf8).write(to: root.appendingPathComponent(".claude/settings.json"))
        try Data("""
        {"name":"InlinePlugin","mcpServers":{"inline-server":{}}}
        """.utf8).write(to: inlineRoot.appendingPathComponent(".claude-plugin/plugin.json"))
        try Data("""
        {"name":"CustomPlugin","mcpServers":"./config/servers.json"}
        """.utf8).write(to: customRoot.appendingPathComponent(".claude-plugin/plugin.json"))
        try Data("""
        {"custom-server":{}}
        """.utf8).write(to: customRoot.appendingPathComponent("config/servers.json"))
        try Data("""
        {
          "version":2,
          "plugins":{
            "inline@vendor":[{"installPath":"\(inlineRoot.path)","scope":"user"}],
            "custom@vendor":[{"installPath":"\(customRoot.path)","scope":"user"}]
          }
        }
        """.utf8).write(to: root.appendingPathComponent(".claude/plugins/installed_plugins.json"))

        let servers = MetagentCore.scanClaudeMCPConfiguration(homeDirectory: root)

        XCTAssertEqual(
            servers.map(\.name),
            ["plugin:CustomPlugin:custom-server", "plugin:InlinePlugin:inline-server"]
        )
        XCTAssertEqual(servers.map(\.state), [.configured, .configured])
    }

    func testClaudeInventorySurfacesMalformedExistingConfiguration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-mcp-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".claude"),
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: root.appendingPathComponent(".claude/settings.json"))

        let servers = MetagentCore.scanClaudeMCPConfiguration(homeDirectory: root)

        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers[0].state, .unavailable)
        XCTAssertTrue(servers[0].detail.contains("could not be read"))
    }

    func testClaudeInventoryIgnoresUnsupportedRootLocalSettings() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-mcp-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".claude"),
            withIntermediateDirectories: true
        )
        try Data("""
        {"mcpServers":{"ready":{}}}
        """.utf8).write(to: root.appendingPathComponent(".claude.json"))
        try Data("""
        {"disabledMcpServers":["ready"]}
        """.utf8).write(to: root.appendingPathComponent(".claude/settings.local.json"))

        let servers = MetagentCore.scanClaudeMCPConfiguration(homeDirectory: root)

        XCTAssertEqual(servers.map(\.name), ["ready"])
        XCTAssertEqual(servers.map(\.state), [.configured])
    }

    func testClaudeInventoryIgnoresDirectServersInUserSettings() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-mcp-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".claude"),
            withIntermediateDirectories: true
        )
        try Data("""
        {"mcpServers":{"ignored":{}}}
        """.utf8).write(to: root.appendingPathComponent(".claude/settings.json"))

        let servers = MetagentCore.scanClaudeMCPConfiguration(homeDirectory: root)

        XCTAssertTrue(servers.isEmpty)
    }

    func testClaudeInventoryPreservesPerProjectDisabledState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-mcp-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstProject = root.appendingPathComponent("one")
        let secondProject = root.appendingPathComponent("two")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".claude"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: firstProject, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondProject, withIntermediateDirectories: true)
        try Data("""
        {
          "projects": {
            "\(firstProject.path)": {
              "mcpServers": {"shared": {}, "disabled-only": {}},
              "disabledMcpServers": ["shared", "disabled-only"]
            },
            "\(secondProject.path)": {"mcpServers": {"shared": {}}}
          }
        }
        """.utf8).write(to: root.appendingPathComponent(".claude.json"))

        let servers = MetagentCore.scanClaudeMCPConfiguration(homeDirectory: root)

        XCTAssertEqual(servers.map(\.name), ["disabled-only", "shared"])
        XCTAssertEqual(servers.map(\.state), [.disabled, .configured])
    }

    func testClaudeInventoryKeepsPluginServerNamespacesDistinct() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-mcp-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstPlugin = root.appendingPathComponent(".claude/plugins/cache/vendor/first/1.0.0")
        let secondPlugin = root.appendingPathComponent(".claude/plugins/cache/vendor/second/1.0.0")
        try FileManager.default.createDirectory(at: firstPlugin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondPlugin, withIntermediateDirectories: true)
        try Data("""
        {
          "enabledPlugins":{"first@vendor":true,"second@vendor":true},
          "disabledMcpServers":["plugin:first:shared"]
        }
        """.utf8).write(to: root.appendingPathComponent(".claude/settings.json"))
        for plugin in [firstPlugin, secondPlugin] {
            try Data("""
            {"mcpServers":{"shared":{"type":"http","url":"https://example.invalid"}}}
            """.utf8).write(to: plugin.appendingPathComponent(".mcp.json"))
        }
        try Data("""
        {
          "version":2,
          "plugins":{
            "first@vendor":[{"installPath":"\(firstPlugin.path)","version":"1.0.0"}],
            "second@vendor":[{"installPath":"\(secondPlugin.path)","version":"1.0.0"}]
          }
        }
        """.utf8).write(to: root.appendingPathComponent(".claude/plugins/installed_plugins.json"))

        let servers = MetagentCore.scanClaudeMCPConfiguration(homeDirectory: root)

        XCTAssertEqual(servers.map(\.name), ["plugin:first:shared", "plugin:second:shared"])
        XCTAssertEqual(servers.map(\.state), [.disabled, .configured])
    }

    func testClaudeInventorySurfacesPendingManifestAndProjectPlugin() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-mcp-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let projectRoot = root.appendingPathComponent("project")
        let pluginRoot = root.appendingPathComponent(".claude/plugins/cache/vendor/project-plugin/1.0.0")
        let userPluginRoot = root.appendingPathComponent(".claude/plugins/cache/vendor/project-plugin/2.0.0")
        let inheritedPluginRoot = root.appendingPathComponent(".claude/plugins/cache/vendor/user-only/1.0.0")
        try FileManager.default.createDirectory(
            at: projectRoot.appendingPathComponent(".claude"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: pluginRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: userPluginRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inheritedPluginRoot, withIntermediateDirectories: true)
        try Data("""
        {"projects":{"\(projectRoot.path)":{}}}
        """.utf8).write(to: root.appendingPathComponent(".claude.json"))
        try Data("""
        {"mcpServers":{"new-project-server":{}}}
        """.utf8).write(to: projectRoot.appendingPathComponent(".mcp.json"))
        try Data("""
        {"enabledPlugins":{"project-plugin@vendor":true,"user-only@vendor":true}}
        """.utf8).write(to: projectRoot.appendingPathComponent(".claude/settings.local.json"))
        try Data("""
        {"mcpServers":{"tools":{}}}
        """.utf8).write(to: pluginRoot.appendingPathComponent(".mcp.json"))
        try Data("""
        {"mcpServers":{"wrong-user-scope":{}}}
        """.utf8).write(to: userPluginRoot.appendingPathComponent(".mcp.json"))
        try Data("""
        {"mcpServers":{"inherited":{}}}
        """.utf8).write(to: inheritedPluginRoot.appendingPathComponent(".mcp.json"))
        try Data("""
        {
          "version":2,
          "plugins":{
            "project-plugin@vendor":[
            {
              "installPath":"\(userPluginRoot.path)",
              "version":"2.0.0",
              "scope":"user"
            },
            {
              "installPath":"\(pluginRoot.path)",
              "version":"1.0.0",
              "scope":"local",
              "projectPath":"\(projectRoot.path)"
            }],
            "user-only@vendor":[{
              "installPath":"\(inheritedPluginRoot.path)",
              "version":"1.0.0",
              "scope":"user"
            }]
          }
        }
        """.utf8).write(to: root.appendingPathComponent(".claude/plugins/installed_plugins.json"))

        let servers = MetagentCore.scanClaudeMCPConfiguration(homeDirectory: root)

        XCTAssertEqual(
            servers.map(\.name),
            ["new-project-server", "plugin:project-plugin:tools", "plugin:user-only:inherited"]
        )
        XCTAssertEqual(servers.map(\.state), [.pendingApproval, .configured, .configured])
    }

    func testClaudeInventoryDoesNotLetSharedSettingsApproveManifest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-mcp-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let projectRoot = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(
            at: projectRoot.appendingPathComponent(".claude"),
            withIntermediateDirectories: true
        )
        try Data("""
        {"projects":{"\(projectRoot.path)":{}}}
        """.utf8).write(to: root.appendingPathComponent(".claude.json"))
        try Data("""
        {"mcpServers":{"shared-cannot-approve-itself":{}}}
        """.utf8).write(to: projectRoot.appendingPathComponent(".mcp.json"))
        try Data("""
        {"enableAllProjectMcpServers":true,"enabledMcpjsonServers":["shared-cannot-approve-itself"]}
        """.utf8).write(to: projectRoot.appendingPathComponent(".claude/settings.json"))

        let servers = MetagentCore.scanClaudeMCPConfiguration(homeDirectory: root)

        XCTAssertEqual(servers.map(\.name), ["shared-cannot-approve-itself"])
        XCTAssertEqual(servers.map(\.state), [.pendingApproval])
    }

    func testClaudeInventoryFindsAncestorManifestFromNestedProjectPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-mcp-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let projectRoot = root.appendingPathComponent("repo")
        let nestedRoot = projectRoot.appendingPathComponent("nested/deeper")
        try FileManager.default.createDirectory(at: nestedRoot, withIntermediateDirectories: true)
        try Data("""
        {"projects":{"\(nestedRoot.path)":{}}}
        """.utf8).write(to: root.appendingPathComponent(".claude.json"))
        try Data("""
        {"mcpServers":{"ancestor":{}}}
        """.utf8).write(to: projectRoot.appendingPathComponent(".mcp.json"))

        let servers = MetagentCore.scanClaudeMCPConfiguration(homeDirectory: root)

        XCTAssertEqual(servers.map(\.name), ["ancestor"])
        XCTAssertEqual(servers.map(\.state), [.pendingApproval])
    }

    func testClaudeInventoryKeepsManifestRejectionSeparateFromDirectDisable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-mcp-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let projectRoot = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".claude"),
            withIntermediateDirectories: true
        )
        try Data("""
        {
          "mcpServers":{"same":{}},
          "projects":{"\(projectRoot.path)":{}}
        }
        """.utf8).write(to: root.appendingPathComponent(".claude.json"))
        try Data("""
        {"disabledMcpjsonServers":["same"]}
        """.utf8).write(to: root.appendingPathComponent(".claude/settings.json"))
        try Data("""
        {"mcpServers":{"same":{}}}
        """.utf8).write(to: projectRoot.appendingPathComponent(".mcp.json"))

        let servers = MetagentCore.scanClaudeMCPConfiguration(homeDirectory: root)

        XCTAssertEqual(servers.map(\.name), ["same"])
        XCTAssertEqual(servers.map(\.state), [.configured])
    }

    func testClaudeInventoryHonorsUserProjectManifestApprovals() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-mcp-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let projectRoot = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".claude"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try Data("""
        {"projects":{"\(projectRoot.path)":{}}}
        """.utf8).write(to: root.appendingPathComponent(".claude.json"))
        try Data("""
        {
          "enabledMcpjsonServers":["approved"],
          "disabledMcpjsonServers":["rejected"]
        }
        """.utf8).write(to: root.appendingPathComponent(".claude/settings.json"))
        try Data("""
        {"mcpServers":{"approved":{},"pending":{},"rejected":{}}}
        """.utf8).write(to: projectRoot.appendingPathComponent(".mcp.json"))

        let servers = MetagentCore.scanClaudeMCPConfiguration(homeDirectory: root)

        XCTAssertEqual(servers.map(\.name), ["approved", "pending", "rejected"])
        XCTAssertEqual(servers.map(\.state), [.configured, .pendingApproval, .disabled])
    }

    func testClaudeInventoryKeepsPendingWhenSameNameIsApprovedElsewhere() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-mcp-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstProject = root.appendingPathComponent("first")
        let secondProject = root.appendingPathComponent("second")
        for project in [firstProject, secondProject] {
            try FileManager.default.createDirectory(
                at: project.appendingPathComponent(".claude"),
                withIntermediateDirectories: true
            )
            try Data("""
            {"mcpServers":{"shared":{}}}
            """.utf8).write(to: project.appendingPathComponent(".mcp.json"))
        }
        try Data("""
        {"projects":{"\(firstProject.path)":{},"\(secondProject.path)":{}}}
        """.utf8).write(to: root.appendingPathComponent(".claude.json"))
        try Data("""
        {"enabledMcpjsonServers":["shared"]}
        """.utf8).write(to: firstProject.appendingPathComponent(".claude/settings.local.json"))

        let servers = MetagentCore.scanClaudeMCPConfiguration(homeDirectory: root)

        XCTAssertEqual(servers.map(\.name), ["shared"])
        XCTAssertEqual(servers.map(\.state), [.pendingApproval])
        XCTAssertEqual(
            servers[0].projectPaths,
            [secondProject.path]
        )
    }

    func testClaudeInventoryLetsProjectApprovalOverrideUserDefault() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-mcp-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let projectRoot = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(
            at: projectRoot.appendingPathComponent(".claude"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".claude"),
            withIntermediateDirectories: true
        )
        try Data("""
        {"projects":{"\(projectRoot.path)":{}}}
        """.utf8).write(to: root.appendingPathComponent(".claude.json"))
        try Data("""
        {"enableAllProjectMcpServers":false}
        """.utf8).write(to: root.appendingPathComponent(".claude/settings.json"))
        try Data("""
        {"enableAllProjectMcpServers":true}
        """.utf8).write(to: projectRoot.appendingPathComponent(".claude/settings.local.json"))
        try Data("""
        {"mcpServers":{"approved":{}}}
        """.utf8).write(to: projectRoot.appendingPathComponent(".mcp.json"))

        let servers = MetagentCore.scanClaudeMCPConfiguration(homeDirectory: root)

        XCTAssertEqual(servers.map(\.name), ["approved"])
        XCTAssertEqual(servers.map(\.state), [.configured])
    }

    func testClaudeInventoryPreservesUserApproveAllWhenProjectSetsFalse() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-mcp-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let projectRoot = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(
            at: projectRoot.appendingPathComponent(".claude"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".claude"),
            withIntermediateDirectories: true
        )
        try Data("""
        {"projects":{"\(projectRoot.path)":{}}}
        """.utf8).write(to: root.appendingPathComponent(".claude.json"))
        try Data("""
        {"enableAllProjectMcpServers":true}
        """.utf8).write(to: root.appendingPathComponent(".claude/settings.json"))
        try Data("""
        {"enableAllProjectMcpServers":false}
        """.utf8).write(to: projectRoot.appendingPathComponent(".claude/settings.local.json"))
        try Data("""
        {"mcpServers":{"approved":{}}}
        """.utf8).write(to: projectRoot.appendingPathComponent(".mcp.json"))

        let servers = MetagentCore.scanClaudeMCPConfiguration(homeDirectory: root)

        XCTAssertEqual(servers.map(\.name), ["approved"])
        XCTAssertEqual(servers.map(\.state), [.configured])
    }

    func testClaudeInventoryNormalizesManifestSelectors() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-mcp-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let projectRoot = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(
            at: projectRoot.appendingPathComponent(".claude"),
            withIntermediateDirectories: true
        )
        try Data("""
        {"projects":{"\(projectRoot.path)":{}}}
        """.utf8).write(to: root.appendingPathComponent(".claude.json"))
        try Data("""
        {"mcpServers":{"approved.server":{},"rejected/server":{}}}
        """.utf8).write(to: projectRoot.appendingPathComponent(".mcp.json"))
        try Data("""
        {
          "enabledMcpjsonServers":["approved_server"],
          "disabledMcpjsonServers":["rejected_server"]
        }
        """.utf8).write(to: projectRoot.appendingPathComponent(".claude/settings.local.json"))

        let servers = MetagentCore.scanClaudeMCPConfiguration(homeDirectory: root)

        XCTAssertEqual(servers.map(\.name), ["approved.server", "rejected/server"])
        XCTAssertEqual(servers.map(\.state), [.configured, .disabled])
    }

    func testClaudeInventoryAppliesUserDisableToProjectPlugin() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-mcp-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let projectRoot = root.appendingPathComponent("project")
        let pluginRoot = root.appendingPathComponent(".claude/plugins/cache/vendor/demo/1.0.0")
        try FileManager.default.createDirectory(
            at: projectRoot.appendingPathComponent(".claude"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: pluginRoot, withIntermediateDirectories: true)
        try Data("""
        {"projects":{"\(projectRoot.path)":{}}}
        """.utf8).write(to: root.appendingPathComponent(".claude.json"))
        try Data("""
        {"disabledMcpServers":["plugin:demo:tools"]}
        """.utf8).write(to: root.appendingPathComponent(".claude/settings.json"))
        try Data("""
        {"enabledPlugins":{"demo@vendor":true}}
        """.utf8).write(to: projectRoot.appendingPathComponent(".claude/settings.local.json"))
        try Data("""
        {"mcpServers":{"tools":{}}}
        """.utf8).write(to: pluginRoot.appendingPathComponent(".mcp.json"))
        try Data("""
        {
          "version":2,
          "plugins":{"demo@vendor":[{
            "installPath":"\(pluginRoot.path)",
            "version":"1.0.0",
            "scope":"local",
            "projectPath":"\(projectRoot.path)"
          }]}
        }
        """.utf8).write(to: root.appendingPathComponent(".claude/plugins/installed_plugins.json"))

        let servers = MetagentCore.scanClaudeMCPConfiguration(homeDirectory: root)

        XCTAssertEqual(servers.map(\.name), ["plugin:demo:tools"])
        XCTAssertEqual(servers.map(\.state), [.disabled])
    }

    func testSnapshotCountsDisabledAndUnavailableSeparately() {
        let snapshot = MCPHealthSnapshot(servers: [
            MCPServerHealth(client: .codex, name: "one", state: .configured, detail: ""),
            MCPServerHealth(client: .codex, name: "two", state: .disabled, detail: ""),
            MCPServerHealth(client: .claude, name: "three", state: .needsSignIn, detail: ""),
            MCPServerHealth(client: .claude, name: "inventory", state: .unavailable, detail: ""),
            MCPServerHealth(client: .claude, name: "pending", state: .pendingApproval, detail: "")
        ])

        XCTAssertEqual(snapshot.configuredCount, 2)
        XCTAssertEqual(snapshot.count(for: .codex), 1)
        XCTAssertEqual(snapshot.count(for: .claude), 1)
        XCTAssertEqual(snapshot.attention.count, 3)
        XCTAssertEqual(snapshot.disabledCount(for: .codex), 1)
    }

    func testSnapshotInventoryMergesClientsAndScopesByServerName() {
        let snapshot = MCPHealthSnapshot(servers: [
            MCPServerHealth(
                client: .codex,
                name: "shared",
                state: .configured,
                detail: "",
                globalState: .configured
            ),
            MCPServerHealth(
                client: .claude,
                name: "shared",
                state: .pendingApproval,
                detail: "",
                projectStates: [
                    MCPProjectState(path: "/projects/one", state: .configured),
                    MCPProjectState(path: "/projects/two", state: .pendingApproval)
                ]
            ),
            MCPServerHealth(client: .claude, name: "other", state: .disabled, detail: "")
        ])

        XCTAssertEqual(snapshot.inventory.map(\.name), ["other", "shared"])
        let shared = try! XCTUnwrap(snapshot.inventory.first { $0.name == "shared" })
        XCTAssertEqual(shared.clients, [.claude, .codex])
        XCTAssertEqual(shared.globalClients, [.codex])
        XCTAssertEqual(shared.projectPaths, ["/projects/one", "/projects/two"])
        XCTAssertEqual(shared.state, .pendingApproval)
        XCTAssertEqual(shared.state(for: .codex), .configured)
        XCTAssertEqual(shared.state(for: .claude), .pendingApproval)
    }

    func testClaudeInventoryIgnoresDeletedProjectHistory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-mcp-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let deletedProject = root.appendingPathComponent("deleted-worktree")
        try Data("""
        {"projects":{"\(deletedProject.path)":{"mcpServers":{"stale":{}}}}}
        """.utf8).write(to: root.appendingPathComponent(".claude.json"))

        let servers = MetagentCore.scanClaudeMCPConfiguration(homeDirectory: root)

        XCTAssertTrue(servers.isEmpty)
    }

    func testClaudeInventoryReportsUnreadableProjectHistory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-mcp-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let unreadableProject = root.appendingPathComponent("unreadable-project")
        try FileManager.default.createDirectory(at: unreadableProject, withIntermediateDirectories: true)
        try Data("""
        {"projects":{"\(unreadableProject.path)":{"mcpServers":{"unknown":{}}}}}
        """.utf8).write(to: root.appendingPathComponent(".claude.json"))
        XCTAssertEqual(chmod(unreadableProject.path, 0o000), 0)
        defer { _ = chmod(unreadableProject.path, 0o700) }

        let servers = MetagentCore.scanClaudeMCPConfiguration(homeDirectory: root)

        XCTAssertEqual(servers.map(\.name), ["Claude configuration"])
        XCTAssertEqual(servers.map(\.state), [.unavailable])
    }
}
