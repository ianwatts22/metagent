import Foundation
import MetagentCore

@main
struct MetagentCLI {
    static func main() {
        do {
            try run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.writeLine(error.localizedDescription)
            Foundation.exit(1)
        }
    }

    private static func run(_ args: [String]) throws {
        guard let command = args.first else {
            printHelp()
            return
        }

        switch command {
        case "config":
            try runConfig(Array(args.dropFirst()))
        case "skills":
            try runSkills(Array(args.dropFirst()))
        case "launch-agent":
            try runLaunchAgent(Array(args.dropFirst()))
        case "morph-mcp":
            try runMorphMCP(Array(args.dropFirst()))
        case "mcp":
            try runMCP(Array(args.dropFirst()))
        case "help", "--help", "-h":
            printHelp()
        default:
            throw CLIError.message("unknown command: \(command)")
        }
    }

    private static func runConfig(_ args: [String]) throws {
        guard let command = args.first else {
            printConfigHelp()
            return
        }

        switch command {
        case "show":
            break
        case "help", "--help", "-h":
            printConfigHelp()
            return
        default:
            throw CLIError.message("unknown config command: \(command)")
        }

        var json = false
        for arg in args.dropFirst() {
            switch arg {
            case "--json":
                json = true
            default:
                throw CLIError.message("unknown config show flag: \(arg)")
            }
        }

        let config = try MetagentCore.loadUserConfig()
        if json {
            try printJSON(config)
        } else {
            print("config: \(MetagentCore.userConfigPath().path)")
            print("roots:")
            for root in config.roots {
                print("  \(root)")
            }
            print("max depth: \(config.maxDepth)")
            if !config.ignoreProjects.isEmpty {
                print("ignored:")
                for root in config.ignoreProjects {
                    print("  \(root)")
                }
            }
        }
    }

    private static func runSkills(_ args: [String]) throws {
        guard let command = args.first else {
            printSkillsHelp()
            return
        }

        switch command {
        case "scan":
            let parsed = try parseScan(Array(args.dropFirst()))
            let report = try MetagentCore.scanSkills(options: parsed.options)
            if parsed.options == SkillScanOptions() {
                MetagentCore.saveInventorySnapshot(report)
            }
            if parsed.json {
                try printJSON(report)
            } else {
                for project in report.projects {
                    print("\(project.root)\t\(project.skills.count) skill entries\t\(locationSummary(project))")
                }
            }
        case "doctor":
            let parsed = try parseScan(Array(args.dropFirst()))
            let report = try MetagentCore.doctor(options: parsed.options)
            for issue in report.issues {
                print("\(issue.severity.rawValue): \(issue.message)")
            }
            if report.failureCount > 0 {
                throw CLIError.message("doctor found errors")
            }
        case "sync":
            let parsed = try parseSync(Array(args.dropFirst()))
            let report = try MetagentCore.syncSkills(options: parsed.options)
            if parsed.json {
                try printJSON(report)
            } else {
                printSyncReport(report)
            }
        case "help", "--help", "-h":
            printSkillsHelp()
        default:
            throw CLIError.message("unknown skills command: \(command)")
        }
    }

    private static func runLaunchAgent(_ args: [String]) throws {
        guard let command = args.first else {
            printLaunchAgentHelp()
            return
        }

        if ["help", "--help", "-h"].contains(command) {
            printLaunchAgentHelp()
            return
        }

        let options = try parseLaunchAgent(Array(args.dropFirst()))
        let report: LaunchAgentReport
        switch command {
        case "status":
            report = MetagentCore.launchAgentStatus(options: options)
        case "install":
            report = try MetagentCore.installLaunchAgent(options: options)
        case "uninstall":
            report = MetagentCore.uninstallLaunchAgent(options: options)
        default:
            throw CLIError.message("unknown launch-agent command: \(command)")
        }
        print(report.lines.joined(separator: "\n"))
    }

    private static func runMorphMCP(_ args: [String]) throws {
        guard let command = args.first else {
            printMorphMCPHelp()
            return
        }

        switch command {
        case "status":
            if let extra = args.dropFirst().first {
                throw CLIError.message("unknown morph-mcp status flag: \(extra)")
            }
            print(try MetagentCore.morphMCPStatus().lines.joined(separator: "\n"))
        case "help", "--help", "-h":
            printMorphMCPHelp()
        default:
            throw CLIError.message("unknown morph-mcp command: \(command)")
        }
    }

    private static func runMCP(_ args: [String]) throws {
        guard args.first == "--stdio" else {
            print("metagent mcp")
            print("")
            print("Usage:")
            print("  metagent mcp --stdio")
            return
        }
        throw CLIError.message("Swift MCP server entry point is reserved but not implemented yet")
    }

    private static func parseScan(_ args: [String]) throws -> (options: SkillScanOptions, json: Bool) {
        var roots: [String] = []
        var ignores: [String] = []
        var maxDepth: Int?
        var json = false
        var index = 0

        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--root":
                roots.append(try readFlagValue("--root", args: args, index: &index))
            case "--ignore-project":
                ignores.append(try readFlagValue("--ignore-project", args: args, index: &index))
            case "--max-depth":
                let value = try readFlagValue("--max-depth", args: args, index: &index)
                guard let parsed = Int(value) else {
                    throw CLIError.message("--max-depth must be an integer")
                }
                maxDepth = parsed
            case "--json":
                json = true
            default:
                throw CLIError.message("unknown scan flag: \(arg)")
            }
            index += 1
        }

        return (
            SkillScanOptions(roots: roots, maxDepth: maxDepth, ignoreProjects: ignores),
            json
        )
    }

    private static func parseSync(_ args: [String]) throws -> (options: SkillsSyncOptions, json: Bool) {
        var scanArgs: [String] = []
        var apply = false
        var replaceClaudeSkills = false
        var rewriteAgentsToml = false
        var syncOnly = false
        var runDotagents = true
        var agents: [String] = []
        var json = false
        var index = 0

        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--apply":
                apply = true
            case "--replace-claude-skills":
                replaceClaudeSkills = true
            case "--rewrite-agents-toml":
                rewriteAgentsToml = true
            case "--sync-only":
                syncOnly = true
            case "--no-dotagents":
                runDotagents = false
            case "--agents":
                agents = try readFlagValue("--agents", args: args, index: &index)
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            case "--json":
                json = true
            case "--root", "--ignore-project", "--max-depth":
                scanArgs.append(arg)
                scanArgs.append(try readFlagValue(arg, args: args, index: &index))
            default:
                throw CLIError.message("unknown sync flag: \(arg)")
            }
            index += 1
        }

        let scan = try parseScan(scanArgs).options
        return (
            SkillsSyncOptions(
                apply: apply,
                replaceClaudeSkills: replaceClaudeSkills,
                rewriteAgentsToml: rewriteAgentsToml,
                syncOnly: syncOnly,
                runDotagents: runDotagents,
                agents: agents,
                scanOptions: scan
            ),
            json
        )
    }

    private static func readFlagValue(_ flag: String, args: [String], index: inout Int) throws -> String {
        index += 1
        guard index < args.count, !args[index].hasPrefix("--") else {
            throw CLIError.message("\(flag) requires a value")
        }
        return args[index]
    }

    private static func parseLaunchAgent(_ args: [String]) throws -> LaunchAgentOptions {
        var program: String?
        var interval = 300
        var index = 0

        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--program":
                program = try readFlagValue("--program", args: args, index: &index)
            case "--interval":
                let value = try readFlagValue("--interval", args: args, index: &index)
                guard let parsed = Int(value) else {
                    throw CLIError.message("--interval must be an integer")
                }
                guard parsed > 0 else {
                    throw CLIError.message("--interval must be a positive integer")
                }
                interval = parsed
            default:
                throw CLIError.message("unknown launch-agent flag: \(arg)")
            }
            index += 1
        }

        return LaunchAgentOptions(program: program, interval: interval)
    }

    private static func printSyncReport(_ report: SkillsSyncReport) {
        print("metagent skills sync: \(report.mode)")
        for project in report.projects {
            print("")
            print("Project: \(project.root)")
            for line in project.lines {
                print("  \(line.text)")
            }
        }
    }

    private static func locationSummary(_ project: SkillProject) -> String {
        let agents = project.skills.filter { $0.location == "agents" }.count
        let codex = project.skills.filter { $0.location == "codex" }.count
        let claude = project.skills.filter { $0.location == "claude" }.count
        let npx = project.skills.filter { $0.location == "agents" && $0.originKind == "npx-skills" }.count
        let native = project.skills.filter { $0.location == "agents" && $0.originKind == "native" }.count
        return ".agents=\(agents) npx=\(npx) native=\(native) .codex=\(codex) .claude=\(claude)"
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.writeLine("")
    }

    private static func printHelp() {
        print("""
        metagent

        Usage:
          metagent config show [--json]
          metagent skills <scan|sync|doctor> [flags]
          metagent launch-agent <install|uninstall|status> [flags]
          metagent morph-mcp status
          metagent mcp --stdio
        """)
    }

    private static func printConfigHelp() {
        print("metagent config\n\nUsage:\n  metagent config show [--json]")
    }

    private static func printMorphMCPHelp() {
        print("metagent morph-mcp\n\nUsage:\n  metagent morph-mcp status")
    }

    private static func printSkillsHelp() {
        print("""
        metagent skills

        Usage:
          metagent skills scan [--root PATH] [--ignore-project PATH] [--max-depth N] [--json]
          metagent skills sync [--apply] [--replace-claude-skills] [--rewrite-agents-toml] [--sync-only] [--agents a,b] [--no-dotagents] [--root PATH] [--ignore-project PATH] [--max-depth N] [--json]
          metagent skills doctor [--root PATH] [--ignore-project PATH] [--max-depth N]
        """)
    }

    private static func printLaunchAgentHelp() {
        print("""
        metagent launch-agent

        Usage:
          metagent launch-agent install [--program PATH] [--interval SECONDS]
          metagent launch-agent status
          metagent launch-agent uninstall
        """)
    }
}

private enum CLIError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message):
            message
        }
    }
}

private extension FileHandle {
    func writeLine(_ text: String) {
        write(Data((text + "\n").utf8))
    }
}
