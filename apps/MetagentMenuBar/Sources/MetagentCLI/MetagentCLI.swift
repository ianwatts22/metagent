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
        case "inventory":
            try runInventory(Array(args.dropFirst()))
        case "usage":
            try runUsage(Array(args.dropFirst()))
        case "analyze":
            try runAnalyze(Array(args.dropFirst()))
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
            if parsed.json {
                try printJSON(report)
            } else {
                for issue in report.issues {
                    print("\(issue.severity.rawValue): \(issue.message)")
                }
            }
            if report.failureCount > 0 {
                throw CLIError.message("doctor found errors")
            }
        case "repair":
            let parsed = try parseRepair(Array(args.dropFirst()))
            let report = try MetagentCore.repairSkills(options: parsed.options)
            if parsed.json {
                try printJSON(report)
            } else {
                printRepairReport(report)
            }
        case "remove":
            try runSkillRemoval(Array(args.dropFirst()))
        case "evaluate":
            try runSkillEvaluation(Array(args.dropFirst()))
        case "help", "--help", "-h":
            printSkillsHelp()
        default:
            throw CLIError.message("unknown skills command: \(command)")
        }
    }

    private static func runInventory(_ args: [String]) throws {
        let json = try parseJSONOnly(args, command: "inventory")
        let report = try MetagentCore.scanPortfolio()
        MetagentCore.saveInventorySnapshot(report)
        if json {
            try printJSON(report)
            return
        }
        print("\(report.projects.count) locations, \(report.projects.flatMap(\.skills).count) skill entries")
        for project in report.projects {
            print("\(project.root)\t\(project.skills.count) skill entries\t\(locationSummary(project))")
        }
        for warning in report.warnings {
            print("warning: \(warning)")
        }
    }

    private static func runSkillRemoval(_ args: [String]) throws {
        guard let skillName = args.first, !skillName.hasPrefix("--") else {
            throw CLIError.message("skills remove requires a skill name")
        }
        var root: String?
        var apply = false
        var json = false
        var index = 1
        while index < args.count {
            switch args[index] {
            case "--root":
                root = try readFlagValue("--root", args: args, index: &index)
            case "--apply":
                apply = true
            case "--json":
                json = true
            default:
                throw CLIError.message("unknown skills remove flag: \(args[index])")
            }
            index += 1
        }
        let projectRoot = root ?? FileManager.default.currentDirectoryPath
        if apply {
            let report = try MetagentCore.uninstallSkill(
                projectRoot: projectRoot,
                skillName: skillName,
                allowManagedRemoval: true
            )
            if json { try printJSON(report) } else { report.lines.forEach { print($0) } }
        } else {
            let plan = try MetagentCore.planSkillRemoval(projectRoot: projectRoot, skillName: skillName)
            if json {
                try printJSON(plan)
            } else {
                print("dry run: \(plan.skillName) is managed by \(plan.manager) (\(plan.mutability))")
                if let command = plan.command { print("package-manager action: \(command)") }
                print("run again with --apply to remove it with recovery state")
            }
        }
    }

    private static func runSkillEvaluation(_ args: [String]) throws {
        guard let skillPath = args.first, !skillPath.hasPrefix("--") else {
            throw CLIError.message("skills evaluate requires a skill directory or SKILL.md path")
        }
        var provider = "plugin-eval"
        var json = false
        var index = 1
        while index < args.count {
            switch args[index] {
            case "--provider":
                provider = try readFlagValue("--provider", args: args, index: &index)
            case "--json":
                json = true
            default:
                throw CLIError.message("unknown skills evaluate flag: \(args[index])")
            }
            index += 1
        }

        let record: SkillEvaluationRecord
        switch provider {
        case "plugin-eval":
            record = try MetagentCore.evaluateSkillWithPluginEval(at: skillPath)
        case "codex":
            record = try MetagentCore.reviewSkillWithCodex(at: skillPath)
        case "all":
            _ = try MetagentCore.evaluateSkillWithPluginEval(at: skillPath)
            record = try MetagentCore.reviewSkillWithCodex(at: skillPath)
        default:
            throw CLIError.message("--provider must be plugin-eval, codex, or all")
        }

        if json {
            try printJSON(record)
            return
        }
        print("skill: \(record.canonicalPath)")
        if let evaluation = record.pluginEval {
            print("Plugin Eval: \(evaluation.score) \(evaluation.grade) · \(evaluation.riskLevel) risk")
        }
        if let review = record.codexReview {
            print("Codex review: \(review.score) \(review.grade.rawValue)")
            print("  \(review.summary)")
            print("  next: \(review.recommendation)")
        }
    }

    private static func runUsage(_ args: [String]) throws {
        guard let command = args.first else {
            printUsageHelp()
            return
        }

        switch command {
        case "status":
            let json = try parseJSONOnly(Array(args.dropFirst()), command: "usage status")
            let snapshot = MetagentCore.loadSkillUsageSnapshot() ?? .empty
            if json {
                try printJSON(snapshot)
            } else {
                printUsageSnapshot(snapshot)
            }
        case "refresh":
            var maxBytes: Int64 = 64 * 1_024 * 1_024
            var maxFiles = 100
            var json = false
            var index = 0
            let flags = Array(args.dropFirst())
            while index < flags.count {
                switch flags[index] {
                case "--max-bytes":
                    let value = try readFlagValue("--max-bytes", args: flags, index: &index)
                    guard let parsed = Int64(value), parsed > 0 else {
                        throw CLIError.message("--max-bytes must be a positive integer")
                    }
                    maxBytes = parsed
                case "--max-files":
                    let value = try readFlagValue("--max-files", args: flags, index: &index)
                    guard let parsed = Int(value), parsed > 0 else {
                        throw CLIError.message("--max-files must be a positive integer")
                    }
                    maxFiles = parsed
                case "--json":
                    json = true
                default:
                    throw CLIError.message("unknown usage refresh flag: \(flags[index])")
                }
                index += 1
            }
            let report = try MetagentCore.refreshSkillUsage(options: SkillUsageRefreshOptions(
                maxBytes: maxBytes,
                maxFiles: maxFiles
            ))
            if json {
                try printJSON(report)
            } else {
                print("read \(report.filesRead) files / \(ByteCountFormatter.string(fromByteCount: report.bytesRead, countStyle: .file))")
                print("added \(report.invocationsAdded) invocation records")
                printUsageSnapshot(report.snapshot)
            }
        case "help", "--help", "-h":
            printUsageHelp()
        default:
            throw CLIError.message("unknown usage command: \(command)")
        }
    }

    private static func runAnalyze(_ args: [String]) throws {
        var root = FileManager.default.currentDirectoryPath
        var json = false
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--root":
                root = try readFlagValue("--root", args: args, index: &index)
            case "--json":
                json = true
            case "--help", "-h":
                print("metagent analyze\n\nUsage:\n  metagent analyze [--root PATH] [--json]")
                return
            default:
                throw CLIError.message("unknown analyze flag: \(args[index])")
            }
            index += 1
        }

        let report = try MetagentCore.analyzeProject(root: root)
        if json {
            try printJSON(report)
            return
        }
        let projectSkills = report.skills.projects.flatMap(\.skills).count
        let pluginSkills = report.pluginSkills.projects.flatMap(\.skills).count
        print("project: \(report.root)")
        print("instructions: \(report.instructions.count)")
        print("skills: \(projectSkills) project, \(pluginSkills) plugin")
        print("usage: \(report.usage.summaries.count) observed project skills")
        print("MCP: \(report.mcp.servers.count) relevant configured entries, \(report.mcp.attention.count) need attention")
        print("Doctor: \(report.doctor.warningCount) warnings, \(report.doctor.failureCount) failures")
    }

    private static func runMCP(_ args: [String]) throws {
        guard args == ["--stdio"] else {
            print("metagent mcp")
            print("")
            print("Usage:")
            print("  metagent mcp --stdio")
            return
        }
        Task {
            do {
                try await MetagentMCPServer.run()
                Foundation.exit(0)
            } catch {
                FileHandle.standardError.writeLine(error.localizedDescription)
                Foundation.exit(1)
            }
        }
        dispatchMain()
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

    private static func parseRepair(_ args: [String]) throws -> (options: SkillsRepairOptions, json: Bool) {
        var scanArgs: [String] = []
        var apply = false
        var json = false
        var index = 0

        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--apply":
                apply = true
            case "--json":
                json = true
            case "--root", "--ignore-project", "--max-depth":
                scanArgs.append(arg)
                scanArgs.append(try readFlagValue(arg, args: args, index: &index))
            default:
                throw CLIError.message("unknown repair flag: \(arg)")
            }
            index += 1
        }

        let scan = try parseScan(scanArgs).options
        return (
            SkillsRepairOptions(
                apply: apply,
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

    private static func parseJSONOnly(_ args: [String], command: String) throws -> Bool {
        var json = false
        for arg in args {
            guard arg == "--json" else {
                throw CLIError.message("unknown \(command) flag: \(arg)")
            }
            json = true
        }
        return json
    }

    private static func printUsageSnapshot(_ snapshot: SkillUsageSnapshot) {
        let progress = snapshot.totalBytes > 0
            ? Double(snapshot.processedBytes) / Double(snapshot.totalBytes)
            : 0
        print("usage: \(snapshot.totalInvocations) invocations across \(snapshot.summaries.count) observed skills")
        if snapshot.isParserUpgradeBackfill {
            let displayVersion = snapshot.displayParserVersion.map(String.init) ?? "unknown"
            print("parser: showing v\(displayVersion) while v\(snapshot.targetParserVersion) backfills")
        }
        print("backfill: \(progress.formatted(.percent.precision(.fractionLength(1)))) (\(snapshot.completedFiles)/\(snapshot.totalFiles) files)")
        for skill in snapshot.summaries.prefix(20) {
            print("  \(skill.skillName): \(skill.totalInvocations) invocations, \(skill.activeTurns) turns, \(skill.distinctThreads) threads")
        }
    }

    private static func printRepairReport(_ report: SkillsRepairReport) {
        print("metagent skills repair: \(report.mode)")
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
        let plugin = project.skills.filter { $0.location == "plugin" }.count
        let npx = project.skills.filter { $0.location == "agents" && $0.originKind == "npx-skills" }.count
        let unmanaged = project.skills.filter { $0.location == "agents" && $0.manager == "local" }.count
        return ".agents=\(agents) managed=\(npx) unmanaged=\(unmanaged) plugins=\(plugin) .codex=\(codex) .claude=\(claude)"
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let data = try MetagentCore.encodeJSON(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.writeLine("")
    }

    private static func printHelp() {
        print("""
        metagent

        Usage:
          metagent config show [--json]
          metagent skills <scan|repair|doctor|remove|evaluate> [flags]
          metagent inventory [--json]
          metagent usage <status|refresh> [flags]
          metagent analyze [--root PATH] [--json]
          metagent mcp --stdio
        """)
    }

    private static func printConfigHelp() {
        print("metagent config\n\nUsage:\n  metagent config show [--json]")
    }

    private static func printUsageHelp() {
        print("""
        metagent usage

        Usage:
          metagent usage status [--json]
          metagent usage refresh [--max-bytes N] [--max-files N] [--json]
        """)
    }

    private static func printSkillsHelp() {
        print("""
        metagent skills

        Usage:
          metagent skills scan [--root PATH] [--ignore-project PATH] [--max-depth N] [--json]
          metagent skills repair [--apply] [--root PATH] [--ignore-project PATH] [--max-depth N] [--json]
          metagent skills doctor [--root PATH] [--ignore-project PATH] [--max-depth N] [--json]
          metagent skills remove NAME [--root PATH] [--apply] [--json]
          metagent skills evaluate PATH [--provider plugin-eval|codex|all] [--json]
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
