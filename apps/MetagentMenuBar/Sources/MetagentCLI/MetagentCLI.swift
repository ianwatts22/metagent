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
        case "codebase":
            try runCodebase(Array(args.dropFirst()))
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

        let json = try parseJSONOnly(Array(args.dropFirst()), command: "config show")

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
        case "list":
            try runSkillList(Array(args.dropFirst()))
        case "duplicates":
            try runSkillDuplicates(Array(args.dropFirst()))
        case "show":
            try runSkillShow(Array(args.dropFirst()))
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

    private static func runSkillList(_ args: [String]) throws {
        var root: String?
        var global = false
        var options = SkillQueryOptions()
        var managers: Set<String> = []
        var mutabilities: Set<String> = []
        var json = false
        var index = 0

        while index < args.count {
            switch args[index] {
            case "--root":
                root = try readFlagValue("--root", args: args, index: &index)
            case "--global":
                global = true
            case "--sort":
                let value = try readFlagValue("--sort", args: args, index: &index)
                guard let parsed = SkillQuerySortKey(rawValue: value) else {
                    throw CLIError.message("--sort must be one of: \(skillSortKeyList)")
                }
                options.sortKey = parsed
            case "--order":
                let value = try readFlagValue("--order", args: args, index: &index)
                switch value {
                case "asc", "ascending":
                    options.sortOrder = .ascending
                case "desc", "descending":
                    options.sortOrder = .descending
                default:
                    throw CLIError.message("--order must be asc or desc")
                }
            case "--limit":
                options.limit = Int(try readPositiveInt("--limit", args: args, index: &index))
            case "--cursor":
                options.cursor = try readFlagValue("--cursor", args: args, index: &index)
            case "--name":
                options.nameContains = try readFlagValue("--name", args: args, index: &index)
            case "--manager":
                managers.insert(try readFlagValue("--manager", args: args, index: &index))
            case "--mutability":
                mutabilities.insert(try readFlagValue("--mutability", args: args, index: &index))
            case "--min-score":
                options.minScore = Int(try readPositiveInt("--min-score", args: args, index: &index))
            case "--unused":
                options.unusedOnly = true
            case "--used-within-days":
                options.usedWithinDays = Int(try readPositiveInt("--used-within-days", args: args, index: &index))
            case "--include-projections":
                options.includeProjections = true
            case "--no-descriptions":
                options.includeDescriptions = false
            case "--json":
                json = true
            default:
                throw CLIError.message("unknown skills list flag: \(args[index])")
            }
            index += 1
        }

        options.scope = try skillQueryScope(root: root, global: global, command: "skills list")
        if !managers.isEmpty { options.managers = managers }
        if !mutabilities.isEmpty { options.mutabilities = mutabilities }

        let page = try MetagentCore.querySkills(options: options)
        if json {
            try printJSON(page)
        } else {
            printSkillQueryPage(page)
        }
    }

    private static func runSkillDuplicates(_ args: [String]) throws {
        var root: String?
        var global = false
        var json = false
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--root":
                root = try readFlagValue("--root", args: args, index: &index)
            case "--global":
                global = true
            case "--json":
                json = true
            default:
                throw CLIError.message("unknown skills duplicates flag: \(args[index])")
            }
            index += 1
        }

        let scope = try skillQueryScope(root: root, global: global, command: "skills duplicates")
        let report = try MetagentCore.findDuplicateSkills(scope: scope)
        if json {
            try printJSON(report)
            return
        }
        guard !report.groups.isEmpty else {
            print("no duplicate skill groups found")
            return
        }
        for group in report.groups {
            print("")
            let similarity = group.similarity.formatted(.percent.precision(.fractionLength(0)))
            print("\(group.kind.rawValue) · \(similarity) similar · \(group.skillName)")
            for member in group.members {
                let marker = member.suggestedRemoval ? "suggested removal" : "keep"
                print("  [\(marker)] \(member.scope) · \(member.manager) · \(member.mutability) · \(member.path)")
            }
        }
    }

    private static func runSkillShow(_ args: [String]) throws {
        guard let skillPath = args.first, !skillPath.hasPrefix("--") else {
            throw CLIError.message("skills show requires a skill directory or SKILL.md path")
        }
        var includeBody = true
        var maxBodyCharacters = 20_000
        var json = false
        var index = 1
        while index < args.count {
            switch args[index] {
            case "--no-body":
                includeBody = false
            case "--max-body-chars":
                maxBodyCharacters = Int(try readPositiveInt("--max-body-chars", args: args, index: &index))
            case "--json":
                json = true
            default:
                throw CLIError.message("unknown skills show flag: \(args[index])")
            }
            index += 1
        }

        let detail = try MetagentCore.getSkillDetail(
            path: skillPath,
            includeBody: includeBody,
            maxBodyCharacters: maxBodyCharacters
        )
        if json {
            try printJSON(detail)
            return
        }
        printSkillDetail(detail)
    }

    private static func runSkillRemoval(_ args: [String]) throws {
        var skillNames: [String] = []
        var root: String?
        var apply = false
        var json = false
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--root":
                root = try readFlagValue("--root", args: args, index: &index)
            case "--apply":
                apply = true
            case "--json":
                json = true
            default:
                guard !arg.hasPrefix("--") else {
                    throw CLIError.message("unknown skills remove flag: \(arg)")
                }
                skillNames.append(arg)
            }
            index += 1
        }
        guard !skillNames.isEmpty else {
            throw CLIError.message("skills remove requires at least one skill name")
        }

        let projectRoot = root ?? FileManager.default.currentDirectoryPath
        let targets = try skillNames.map { skillName -> SkillRemovalTarget in
            guard let target = try MetagentCore.resolveSkillRemovalTarget(
                projectRoot: projectRoot,
                skillName: skillName
            ) else {
                throw CLIError.message("no removable skill named \(skillName) in \(projectRoot)")
            }
            return target
        }

        let report = MetagentCore.removeSkills(targets: targets, apply: apply)
        if json {
            try printJSON(report)
        } else {
            printSkillRemovalReport(report)
        }
        if report.outcomes.contains(where: { !$0.succeeded }) {
            throw CLIError.message("skills remove could not complete every target")
        }
    }

    private static func skillQueryScope(
        root: String?,
        global: Bool,
        command: String
    ) throws -> SkillQueryScope {
        if global {
            guard root == nil else {
                throw CLIError.message("\(command) accepts either --root or --global")
            }
            return .global
        }
        return .project(root: root ?? FileManager.default.currentDirectoryPath)
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
                    maxBytes = try readPositiveInt("--max-bytes", args: flags, index: &index)
                case "--max-files":
                    maxFiles = Int(try readPositiveInt("--max-files", args: flags, index: &index))
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

    private static func runCodebase(_ args: [String]) throws {
        var root = FileManager.default.currentDirectoryPath
        var json = false
        var options = CodebaseSizeOptions()
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--root":
                root = try readFlagValue("--root", args: args, index: &index)
            case "--long-file-threshold":
                let value = try readFlagValue("--long-file-threshold", args: args, index: &index)
                guard let threshold = Int(value), threshold > 0 else {
                    throw CLIError.message("--long-file-threshold must be a positive integer")
                }
                options.longFileThreshold = threshold
            case "--json":
                json = true
            case "--help", "-h":
                print("""
                metagent codebase

                Usage:
                  metagent codebase [--root PATH] [--json] [--long-file-threshold N]

                Measures the tracked codebase of a git repository, split into code,
                tests, documentation, configuration, generated output, and assets.
                """)
                return
            default:
                throw CLIError.message("unknown codebase flag: \(args[index])")
            }
            index += 1
        }

        let report = try MetagentCore.measureCodebaseSize(root: root, options: options)
        if json {
            try printJSON(report)
            return
        }
        printCodebaseReport(report)
    }

    private static func printCodebaseReport(_ report: CodebaseSizeReport) {
        print("root: \(report.root)")
        guard report.isGitRepository else {
            print("not a git repository; codebase size is only measured from tracked files")
            return
        }
        print("tracked files: \(report.totalFiles.formatted())")
        print("code lines: \(report.codeLines.formatted()) of \(report.totalLines.formatted()) counted")

        print("")
        print("breakdown")
        for category in CodebaseFileCategory.allCases {
            let size = report.categories[category] ?? CodebaseCategorySize()
            guard size.files > 0 else { continue }
            print("  \(category.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0))"
                + "\(size.files.formatted()) files  \(size.lines.formatted()) lines")
        }

        if !report.languages.isEmpty {
            print("")
            print("languages")
            for language in report.languages.prefix(8) {
                print("  \(language.language.padding(toLength: 14, withPad: " ", startingAt: 0))"
                    + "\(language.files.formatted()) files  \(language.lines.formatted()) lines")
            }
        }

        let signals = report.signals
        print("")
        print("signals")
        print("  tests \(percentText(signals.testLineRatio)) of code+tests"
            + " | docs \(percentText(signals.documentationLineRatio))"
            + " | generated \(percentText(signals.generatedLineRatio))")
        print("  \(signals.longFileCount) file(s) at or over \(report.longFileThreshold) lines"
            + " hold \(percentText(signals.longFileLineRatio)) of code")
        print("  median code file \(signals.medianCodeFileLines.formatted()) lines"
            + " | largest \(signals.largestCodeFileLines.formatted()) lines")

        if !report.largestFiles.isEmpty {
            print("")
            print("largest files")
            for file in report.largestFiles {
                print("  \(file.lines.formatted()) \(file.path)")
            }
        }

        for warning in report.warnings {
            print("warning: \(warning)")
        }
    }

    private static func percentText(_ ratio: Double) -> String {
        ratio.formatted(.percent.precision(.fractionLength(0...1)))
    }

    private static func runAnalyze(_ args: [String]) throws {
        var root = FileManager.default.currentDirectoryPath
        var json = false
        var details = false
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--root":
                root = try readFlagValue("--root", args: args, index: &index)
            case "--json":
                json = true
            case "--details", "--verbose":
                details = true
            case "--help", "-h":
                print("metagent analyze\n\nUsage:\n  metagent analyze [--root PATH] [--json] [--details|--verbose]")
                return
            default:
                throw CLIError.message("unknown analyze flag: \(args[index])")
            }
            index += 1
        }

        if details {
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
            return
        }

        let summary = try MetagentCore.analyzeProjectSummary(root: root)
        if json {
            try printJSON(summary)
            return
        }
        print("project: \(summary.root)")
        print("scope: \(summary.scope) · schema v\(summary.schemaVersion)")
        print("instructions: \(summary.counts.instructionFiles)")
        print("skills: \(summary.counts.projectSkills) project")
        print("usage: \(summary.counts.observedSkills) observed skills · \(summary.counts.skillInvocations30d) invocations in 30d")
        print("MCP: \(summary.counts.projectMCPServers) project entries · \(summary.counts.mcpServersNeedingAttention) need attention")
        print("Doctor: \(summary.counts.doctorWarnings) warnings · \(summary.counts.doctorFailures) failures")
        if !summary.findings.isEmpty {
            print("Top findings:")
            for finding in summary.findings {
                print("  \(finding.severity.rawValue): \(finding.title)")
            }
        }
    }

    private static func runMCP(_ args: [String]) throws {
        if args == ["--stdio"] {
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

        guard let command = args.first else {
            printMCPHelp()
            return
        }

        switch command {
        case "install", "remove":
            let operation: MCPSetupOperation = command == "install" ? .install : .remove
            let parsed = try parseMCPSetupFlags(
                Array(args.dropFirst()),
                command: "mcp \(command)",
                requireClient: true,
                allowApply: true
            )
            let report = try runMCPSetup(
                operation: operation,
                client: parsed.client!,
                apply: parsed.apply
            )
            try printMCPSetupReport(report, json: parsed.json)
            if report.outcome == .blocked {
                throw CLIError.message(report.detail)
            }
        case "status":
            let parsed = try parseMCPSetupFlags(
                Array(args.dropFirst()),
                command: "mcp status",
                requireClient: false,
                allowApply: false
            )
            let clients = parsed.client.map { [$0] } ?? MCPClient.allCases
            let reports = try clients.map {
                try runMCPSetup(operation: .status, client: $0, apply: false)
            }
            if parsed.json {
                try printJSON(reports)
            } else {
                reports.forEach(printMCPSetupReportText)
            }
        case "help", "--help", "-h":
            printMCPHelp()
        default:
            throw CLIError.message("unknown mcp command: \(command)")
        }
    }

    private static func runMCPSetup(
        operation: MCPSetupOperation,
        client: MCPClient,
        apply: Bool
    ) throws -> MCPSetupReport {
        let metagentExecutable = MetagentCore.currentExecutableURL()
        let clientExecutable: URL
        do {
            clientExecutable = try MetagentCore.commandLineExecutable(
                named: client.rawValue,
                environmentOverride: client == .codex ? "METAGENT_CODEX" : "METAGENT_CLAUDE"
            )
        } catch {
            guard operation == .status else { throw error }
            let directVerification = MCPSystemStdioVerifier().verify(executable: metagentExecutable)
            return MCPSetupReport(
                client: client,
                operation: .status,
                outcome: .unchanged,
                serverName: MetagentCore.managedMCPServerName,
                applyRequested: false,
                changed: false,
                configurationState: .unavailable,
                expectedCommand: metagentExecutable.path,
                expectedArguments: ["mcp", "--stdio"],
                managementCommand: nil,
                directVerification: directVerification,
                detail: "\(client.displayName) CLI is not installed, so its MCP configuration cannot be inspected.",
                clientRestartRequired: false,
                runtimeCaveat: MetagentCore.mcpRuntimeCaveat
            )
        }
        return try MetagentCore.manageMCPSetup(
            client: client,
            operation: operation,
            apply: apply,
            metagentExecutable: metagentExecutable,
            clientExecutable: clientExecutable,
            executor: MCPSystemCommandExecutor()
        )
    }

    private static func parseMCPSetupFlags(
        _ args: [String],
        command: String,
        requireClient: Bool,
        allowApply: Bool
    ) throws -> (client: MCPClient?, apply: Bool, json: Bool) {
        var client: MCPClient?
        var apply = false
        var json = false
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--client":
                let value = try readFlagValue("--client", args: args, index: &index)
                guard let parsed = MCPClient(rawValue: value) else {
                    throw CLIError.message("--client must be codex or claude")
                }
                client = parsed
            case "--apply":
                guard allowApply else {
                    throw CLIError.message("unknown \(command) flag: --apply")
                }
                apply = true
            case "--json":
                json = true
            case "--help", "-h":
                printMCPHelp()
                Foundation.exit(0)
            default:
                throw CLIError.message("unknown \(command) flag: \(args[index])")
            }
            index += 1
        }
        if requireClient && client == nil {
            throw CLIError.message("\(command) requires --client codex|claude")
        }
        return (client, apply, json)
    }

    private static func printMCPSetupReport(_ report: MCPSetupReport, json: Bool) throws {
        if json {
            try printJSON(report)
        } else {
            printMCPSetupReportText(report)
        }
    }

    private static func printMCPSetupReportText(_ report: MCPSetupReport) {
        print("\(report.client.displayName): \(report.detail)")
        print("  configuration: \(report.configurationState.rawValue)")
        print("  direct stdio: \(report.directVerification.rawValue)")
        if let command = report.managementCommand {
            print("  command: \(command.map(shellQuoted).joined(separator: " "))")
        }
        print("  \(report.runtimeCaveat)")
    }

    private static func shellQuoted(_ value: String) -> String {
        guard value.contains(where: \.isWhitespace) || value.contains("'") else { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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

    private static func readPositiveInt(_ flag: String, args: [String], index: inout Int) throws -> Int64 {
        let value = try readFlagValue(flag, args: args, index: &index)
        guard let parsed = Int64(value), parsed > 0 else {
            throw CLIError.message("\(flag) must be a positive integer")
        }
        return parsed
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

    private static let skillSortKeyList = SkillQuerySortKey.allCases
        .map(\.rawValue)
        .joined(separator: ", ")

    private static func printSkillQueryPage(_ page: SkillQueryPage) {
        let nameWidth = columnWidth(page.items.map(\.name), minimum: 4)
        let scopeWidth = columnWidth(page.items.map(\.scope), minimum: 5)
        let managerWidth = columnWidth(page.items.map(\.manager), minimum: 7)
        for item in page.items {
            let columns = [
                padded(item.name, nameWidth),
                padded(item.scope, scopeWidth),
                padded(item.manager, managerWidth),
                padded(item.score.map(String.init) ?? "-", 5, alignRight: true),
                padded("\(item.invocations30d)", 5, alignRight: true),
                item.path
            ]
            print(columns.joined(separator: "  "))
        }
        print("showing \(page.returnedCount) of \(page.totalCount)")
        if let cursor = page.nextCursor {
            print("next cursor: \(cursor)")
        }
        for warning in page.warnings {
            print("warning: \(warning)")
        }
    }

    private static func printSkillDetail(_ detail: SkillDetail) {
        print("skill: \(detail.name)")
        print("path: \(detail.path)")
        if let description = detail.description { print("description: \(description)") }
        if let scope = detail.scope, let location = detail.locationLabel {
            print("scope: \(scope) · \(location)")
        }
        if let provenance = detail.provenance {
            print("provenance: \(provenance.manager) · \(provenance.authority) · \(provenance.mutability) · \(provenance.representation)")
            if let source = provenance.source {
                print("  source: \(source)\(provenance.sourceType.map { " (\($0))" } ?? "")")
            }
            if let updatedAt = provenance.updatedAt { print("  updated: \(updatedAt)") }
        }
        if let size = detail.size {
            print("size: \(size.characterCount) chars · \(size.wordCount) words · ~\(size.tokenEstimate) tokens")
            print("  SKILL.md: \(size.skillFileCharacterCount) chars · ~\(size.skillFileTokenEstimate) tokens")
            print("  files: \(size.textFileCount) text · \(size.referenceFileCount) reference · \(size.scriptFileCount) script · \(size.assetFileCount) asset")
        }
        if let usage = detail.usage {
            print("usage: \(usage.totalInvocations) invocations · \(usage.invocations30d) in 30d · \(usage.invocations7d) in 7d · \(usage.distinctThreads) threads")
            if let lastUsedAt = usage.lastUsedAt { print("  last used: \(lastUsedAt)") }
        } else {
            print("usage: no observed invocations")
        }
        if let score = detail.score {
            print("score: \(score)\(detail.grade.map { " \($0)" } ?? "")")
        }
        if let body = detail.body {
            print("")
            print(body)
            if detail.bodyTruncated {
                print("")
                print("… body truncated: showing \(body.count) of \(detail.bodyCharacterCount) characters; raise --max-body-chars for more")
            }
        } else {
            print("body: omitted (\(detail.bodyCharacterCount) characters)")
        }
    }

    private static func printSkillRemovalReport(_ report: SkillRemovalBatchReport) {
        print(report.apply ? "skills remove: applied" : "skills remove: dry run")
        for outcome in report.outcomes {
            print("")
            print("\(outcome.target.displayName) [\(outcome.target.method.rawValue)]")
            if let plan = outcome.plan {
                print("  manager: \(plan.manager) (\(plan.mutability))")
                print("  apply supported: \(plan.applySupported ? "yes" : "no")")
                if let command = plan.command { print("  manager command: \(command)") }
            }
            for line in outcome.lines { print("  \(line)") }
            if let backupPath = outcome.backupPath { print("  recovery: \(backupPath)") }
            if outcome.needsReconciliation { print("  needs reconciliation") }
            if let failureMessage = outcome.failureMessage { print("  error: \(failureMessage)") }
        }
        if !report.apply {
            print("")
            print("run again with --apply to remove these skills with recovery state")
        }
    }

    private static func columnWidth(_ values: [String], minimum: Int) -> Int {
        max(minimum, values.map(\.count).max() ?? minimum)
    }

    private static func padded(_ value: String, _ width: Int, alignRight: Bool = false) -> String {
        guard value.count < width else { return value }
        let padding = String(repeating: " ", count: width - value.count)
        return alignRight ? padding + value : value + padding
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
          metagent skills <list|show|duplicates|scan|repair|doctor|remove|evaluate> [flags]
          metagent inventory [--json]
          metagent usage <status|refresh> [flags]
          metagent analyze [--root PATH] [--json] [--details|--verbose]
          metagent codebase [--root PATH] [--json] [--long-file-threshold N]
          metagent mcp <install|status|remove> [flags]
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
          metagent skills list [--root PATH | --global] [--sort KEY] [--order asc|desc]
                               [--limit N] [--cursor C] [--name TEXT] [--manager M]...
                               [--mutability M]... [--min-score N] [--unused]
                               [--used-within-days N] [--include-projections]
                               [--no-descriptions] [--json]
          metagent skills show PATH [--no-body] [--max-body-chars N] [--json]
          metagent skills duplicates [--root PATH | --global] [--json]
          metagent skills scan [--root PATH] [--ignore-project PATH] [--max-depth N] [--json]
          metagent skills repair [--apply] [--root PATH] [--ignore-project PATH] [--max-depth N] [--json]
          metagent skills doctor [--root PATH] [--ignore-project PATH] [--max-depth N] [--json]
          metagent skills remove NAME [NAME...] [--root PATH] [--apply] [--json]
          metagent skills evaluate PATH [--provider plugin-eval|codex|all] [--json]

        list, duplicates, and remove default to the current folder; list and
        duplicates take --global for the whole portfolio, the same scope bare
        `skills doctor` reads. --sort accepts: \(skillSortKeyList).

        remove is a dry run unless --apply is supplied. Applying moves the skill
        into recovery state rather than deleting it outright.
        """)
    }

    private static func printMCPHelp() {
        print("""
        metagent mcp

        Usage:
          metagent mcp install --client codex|claude [--apply] [--json]
          metagent mcp status [--client codex|claude] [--json]
          metagent mcp remove --client codex|claude [--apply] [--json]
          metagent mcp --stdio

        Install and remove are previews unless --apply is supplied. Status verifies
        the absolute running metagent executable over stdio, but a restarted client
        or new session is still required to prove loaded, connected, or invoked state.
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
