import Foundation

public struct ProjectInstructionFile: Codable, Equatable, Sendable {
    public let path: String
    public let kind: String
    public let byteCount: Int64

    public init(path: String, kind: String, byteCount: Int64) {
        self.path = path
        self.kind = kind
        self.byteCount = byteCount
    }
}

public struct ProjectUsageAnalysis: Codable, Equatable, Sendable {
    public let summaries: [SkillUsageSummary]
    public let isBackfillComplete: Bool
    public let coverageStartedAt: String?
    public let lastUpdatedAt: String?

    public init(
        summaries: [SkillUsageSummary],
        isBackfillComplete: Bool,
        coverageStartedAt: String?,
        lastUpdatedAt: String?
    ) {
        self.summaries = summaries
        self.isBackfillComplete = isBackfillComplete
        self.coverageStartedAt = coverageStartedAt
        self.lastUpdatedAt = lastUpdatedAt
    }
}

public enum ProjectAnalysisSection: String, Codable, CaseIterable, Sendable {
    case instructions
    case skills
    case doctor
    case mcp
    case usage
}

public enum ProjectAnalysisFindingSeverity: String, Codable, Sendable {
    case failure
    case warning
    case information
}

public struct ProjectAnalysisFinding: Codable, Equatable, Sendable {
    public let id: String
    public let severity: ProjectAnalysisFindingSeverity
    public let category: String
    public let title: String
    public let detail: String
    public let recommendedAction: String?

    public init(
        id: String,
        severity: ProjectAnalysisFindingSeverity,
        category: String,
        title: String,
        detail: String,
        recommendedAction: String? = nil
    ) {
        self.id = id
        self.severity = severity
        self.category = category
        self.title = title
        self.detail = detail
        self.recommendedAction = recommendedAction
    }
}

public struct ProjectAnalysisCounts: Codable, Equatable, Sendable {
    public let instructionFiles: Int
    public let projectSkills: Int
    public let invalidSkillDirectories: Int
    public let doctorWarnings: Int
    public let doctorFailures: Int
    public let projectMCPServers: Int
    public let mcpServersNeedingAttention: Int
    public let observedSkills: Int
    public let skillInvocations30d: Int

    public init(
        instructionFiles: Int,
        projectSkills: Int,
        invalidSkillDirectories: Int,
        doctorWarnings: Int,
        doctorFailures: Int,
        projectMCPServers: Int,
        mcpServersNeedingAttention: Int,
        observedSkills: Int,
        skillInvocations30d: Int
    ) {
        self.instructionFiles = instructionFiles
        self.projectSkills = projectSkills
        self.invalidSkillDirectories = invalidSkillDirectories
        self.doctorWarnings = doctorWarnings
        self.doctorFailures = doctorFailures
        self.projectMCPServers = projectMCPServers
        self.mcpServersNeedingAttention = mcpServersNeedingAttention
        self.observedSkills = observedSkills
        self.skillInvocations30d = skillInvocations30d
    }
}

public struct ProjectAnalysisSummary: Codable, Equatable, Sendable {
    public static let schemaVersion = 2

    public let schemaVersion: Int
    public let scope: String
    public let root: String
    public let generatedAt: Date
    public let counts: ProjectAnalysisCounts
    public let usageCoverageComplete: Bool
    public let findings: [ProjectAnalysisFinding]
    public let detailTool: String
    public let detailSections: [ProjectAnalysisSection]

    public init(
        root: String,
        generatedAt: Date,
        counts: ProjectAnalysisCounts,
        usageCoverageComplete: Bool,
        findings: [ProjectAnalysisFinding],
        detailSections: [ProjectAnalysisSection]
    ) {
        self.schemaVersion = Self.schemaVersion
        self.scope = "project_only"
        self.root = root
        self.generatedAt = generatedAt
        self.counts = counts
        self.usageCoverageComplete = usageCoverageComplete
        self.findings = findings
        self.detailTool = "get_project_analysis_details"
        self.detailSections = detailSections
    }
}

public enum ProjectAnalysisDetailItem: Equatable, Sendable {
    case instruction(ProjectInstructionFile)
    case skill(SkillInventoryItem)
    case doctor(DoctorIssue)
    case mcp(MCPServerHealth)
    case usage(SkillUsageSummary)
}

extension ProjectAnalysisDetailItem: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case data
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ProjectAnalysisSection.self, forKey: .type)
        switch type {
        case .instructions:
            self = .instruction(try container.decode(ProjectInstructionFile.self, forKey: .data))
        case .skills:
            self = .skill(try container.decode(SkillInventoryItem.self, forKey: .data))
        case .doctor:
            self = .doctor(try container.decode(DoctorIssue.self, forKey: .data))
        case .mcp:
            self = .mcp(try container.decode(MCPServerHealth.self, forKey: .data))
        case .usage:
            self = .usage(try container.decode(SkillUsageSummary.self, forKey: .data))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .instruction(value):
            try container.encode(ProjectAnalysisSection.instructions, forKey: .type)
            try container.encode(value, forKey: .data)
        case let .skill(value):
            try container.encode(ProjectAnalysisSection.skills, forKey: .type)
            try container.encode(value, forKey: .data)
        case let .doctor(value):
            try container.encode(ProjectAnalysisSection.doctor, forKey: .type)
            try container.encode(value, forKey: .data)
        case let .mcp(value):
            try container.encode(ProjectAnalysisSection.mcp, forKey: .type)
            try container.encode(value, forKey: .data)
        case let .usage(value):
            try container.encode(ProjectAnalysisSection.usage, forKey: .type)
            try container.encode(value, forKey: .data)
        }
    }
}

public struct ProjectAnalysisDetailPage: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let scope: String
    public let root: String
    public let generatedAt: Date
    public let section: ProjectAnalysisSection
    public let items: [ProjectAnalysisDetailItem]
    public let nextCursor: String?

    public init(
        root: String,
        generatedAt: Date,
        section: ProjectAnalysisSection,
        items: [ProjectAnalysisDetailItem],
        nextCursor: String?
    ) {
        self.schemaVersion = Self.schemaVersion
        self.scope = "project_only"
        self.root = root
        self.generatedAt = generatedAt
        self.section = section
        self.items = items
        self.nextCursor = nextCursor
    }
}

public struct ProjectAnalysisReport: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let root: String
    public let generatedAt: Date
    public let instructions: [ProjectInstructionFile]
    public let skills: SkillScanReport
    public let pluginSkills: SkillScanReport
    public let doctor: DoctorReport
    public let mcp: MCPHealthSnapshot
    public let usage: ProjectUsageAnalysis

    public init(
        root: String,
        generatedAt: Date,
        instructions: [ProjectInstructionFile],
        skills: SkillScanReport,
        pluginSkills: SkillScanReport,
        doctor: DoctorReport,
        mcp: MCPHealthSnapshot,
        usage: ProjectUsageAnalysis
    ) {
        self.schemaVersion = Self.schemaVersion
        self.root = root
        self.generatedAt = generatedAt
        self.instructions = instructions
        self.skills = skills
        self.pluginSkills = pluginSkills
        self.doctor = doctor
        self.mcp = mcp
        self.usage = usage
    }
}

public extension MetagentCore {
    static func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    static func analyzeProject(
        root: String,
        homeDirectory: URL? = nil,
        codexExecutableOverride: URL? = nil,
        generatedAt: Date = Date()
    ) throws -> ProjectAnalysisReport {
        let snapshot = try projectAnalysisSnapshot(
            root: root,
            homeDirectory: homeDirectory,
            codexExecutableOverride: codexExecutableOverride,
            generatedAt: generatedAt
        )
        let pluginSkills: SkillScanReport
        do {
            pluginSkills = try scanCodexPlugins()
        } catch {
            pluginSkills = SkillScanReport(
                projects: [],
                warnings: ["Codex plugin inventory unavailable: \(error.localizedDescription)"]
            )
        }

        return ProjectAnalysisReport(
            root: snapshot.root.path,
            generatedAt: generatedAt,
            instructions: snapshot.instructions,
            skills: snapshot.skills,
            pluginSkills: pluginSkills,
            doctor: snapshot.doctor,
            mcp: snapshot.applicableMCP,
            usage: snapshot.usage
        )
    }

    static func analyzeProjectSummary(
        root: String,
        homeDirectory: URL? = nil,
        codexExecutableOverride: URL? = nil,
        generatedAt: Date = Date()
    ) throws -> ProjectAnalysisSummary {
        let snapshot = try projectAnalysisSnapshot(
            root: root,
            homeDirectory: homeDirectory,
            codexExecutableOverride: codexExecutableOverride,
            generatedAt: generatedAt
        )
        let skills = snapshot.skills.projects.flatMap(\.skills)
        let invalidSkillDirectories = snapshot.skills.projects
            .reduce(0) { $0 + $1.invalidSkillDirs.count }
        var sections: [ProjectAnalysisSection] = []
        if !snapshot.instructions.isEmpty { sections.append(.instructions) }
        if !skills.isEmpty { sections.append(.skills) }
        if snapshot.doctor.warningCount + snapshot.doctor.failureCount > 0 {
            sections.append(.doctor)
        }
        if !snapshot.projectMCP.servers.isEmpty { sections.append(.mcp) }
        if !snapshot.usage.summaries.isEmpty { sections.append(.usage) }

        return ProjectAnalysisSummary(
            root: snapshot.root.path,
            generatedAt: generatedAt,
            counts: ProjectAnalysisCounts(
                instructionFiles: snapshot.instructions.count,
                projectSkills: skills.count,
                invalidSkillDirectories: invalidSkillDirectories,
                doctorWarnings: snapshot.doctor.warningCount,
                doctorFailures: snapshot.doctor.failureCount,
                projectMCPServers: snapshot.projectMCP.servers.count,
                mcpServersNeedingAttention: snapshot.projectMCP.attention.count,
                observedSkills: snapshot.usage.summaries.count,
                skillInvocations30d: snapshot.usage.summaries.reduce(0) { $0 + $1.invocations30d }
            ),
            usageCoverageComplete: snapshot.usage.isBackfillComplete,
            findings: prioritizedFindings(snapshot: snapshot),
            detailSections: sections
        )
    }

    static func analyzeProjectDetails(
        root: String,
        section: ProjectAnalysisSection,
        cursor: String? = nil,
        limit: Int = 25,
        homeDirectory: URL? = nil,
        codexExecutableOverride: URL? = nil,
        generatedAt: Date = Date()
    ) throws -> ProjectAnalysisDetailPage {
        let snapshot = try projectAnalysisSnapshot(
            root: root,
            homeDirectory: homeDirectory,
            codexExecutableOverride: codexExecutableOverride,
            generatedAt: generatedAt
        )
        let items = detailItems(for: section, snapshot: snapshot)
        let offset = try detailOffset(
            cursor,
            section: section,
            root: snapshot.root.path
        )
        let boundedLimit = min(max(limit, 1), 100)
        guard offset <= items.count else {
            throw projectAnalysisError("detail cursor is beyond the available \(section.rawValue) items")
        }
        let end = min(offset + boundedLimit, items.count)
        let pageItems = Array(items[offset..<end])
        let nextCursor = end < items.count
            ? detailCursor(root: snapshot.root.path, section: section, offset: end)
            : nil

        return ProjectAnalysisDetailPage(
            root: snapshot.root.path,
            generatedAt: generatedAt,
            section: section,
            items: pageItems,
            nextCursor: nextCursor
        )
    }

    private static func projectAnalysisSnapshot(
        root: String,
        homeDirectory: URL?,
        codexExecutableOverride: URL?,
        generatedAt: Date
    ) throws -> ProjectAnalysisSnapshot {
        let rootURL = try resolveProjectRoot(root)
        let scanOptions = SkillScanOptions(
            roots: [rootURL.path],
            maxDepth: 0,
            respectConfiguredIgnores: false
        )
        let skills = try scanSkills(options: scanOptions)
        let doctor = try doctor(options: scanOptions)
        let allMCP = scanMCPHealth(
            homeDirectory: homeDirectory,
            codexExecutableOverride: codexExecutableOverride,
            additionalProjectPaths: [rootURL.path],
            observedAt: generatedAt
        )
        let applicableMCP = MCPHealthSnapshot(
            servers: allMCP.servers.compactMap { $0.scoped(to: rootURL.path) },
            observedAt: allMCP.observedAt
        )
        let projectMCP = allMCP.projectOnly(at: rootURL.path)
        let canonicalSkillPaths = Set(skills.projects.flatMap(\.skills).map {
            URL(fileURLWithPath: $0.canonicalPath).standardizedFileURL.path
        })
        let usageSnapshot = loadSkillUsageSnapshot() ?? .empty
        let usage = ProjectUsageAnalysis(
            summaries: usageSnapshot.summaries.filter { summary in
                guard let canonicalPath = summary.canonicalPath else { return false }
                return canonicalSkillPaths.contains(
                    URL(fileURLWithPath: canonicalPath).standardizedFileURL.path
                )
            },
            isBackfillComplete: usageSnapshot.isBackfillComplete,
            coverageStartedAt: usageSnapshot.coverageStartedAt,
            lastUpdatedAt: usageSnapshot.lastUpdatedAt
        )

        return ProjectAnalysisSnapshot(
            root: rootURL,
            instructions: projectInstructionFiles(at: rootURL),
            skills: skills,
            doctor: doctor,
            applicableMCP: applicableMCP,
            projectMCP: projectMCP,
            usage: usage
        )
    }

    private static func prioritizedFindings(
        snapshot: ProjectAnalysisSnapshot
    ) -> [ProjectAnalysisFinding] {
        var findings: [(priority: Int, order: Int, finding: ProjectAnalysisFinding)] = []
        var order = 0

        for issue in snapshot.doctor.issues where issue.severity != .ok {
            let severity: ProjectAnalysisFindingSeverity = issue.severity == .failure
                ? .failure
                : .warning
            findings.append((
                issue.severity == .failure ? 0 : 2,
                order,
                ProjectAnalysisFinding(
                    id: "doctor:\(order)",
                    severity: severity,
                    category: issue.category?.rawValue ?? "doctor",
                    title: issue.summary ?? issue.message,
                    detail: issue.message,
                    recommendedAction: issue.guidance
                )
            ))
            order += 1
        }

        for server in snapshot.projectMCP.attention {
            findings.append((
                1,
                order,
                ProjectAnalysisFinding(
                    id: "mcp:\(server.client.rawValue):\(server.name)",
                    severity: .warning,
                    category: "mcp",
                    title: "\(server.name) needs attention in \(server.client.displayName)",
                    detail: server.detail,
                    recommendedAction: recommendedMCPAction(server)
                )
            ))
            order += 1
        }

        for warning in snapshot.skills.warnings {
            findings.append((
                3,
                order,
                ProjectAnalysisFinding(
                    id: "skills:warning:\(order)",
                    severity: .information,
                    category: "skills",
                    title: "Skill inventory warning",
                    detail: warning
                )
            ))
            order += 1
        }

        return findings
            .sorted {
                if $0.priority != $1.priority { return $0.priority < $1.priority }
                return $0.order < $1.order
            }
            .prefix(5)
            .map(\.finding)
    }

    private static func recommendedMCPAction(_ server: MCPServerHealth) -> String {
        switch server.state {
        case .pendingApproval:
            "Approve this project's \(server.name) server in \(server.client.displayName)."
        case .needsSignIn:
            "Sign in to \(server.name) from \(server.client.displayName), then re-run the analysis."
        case .unavailable:
            "Check the \(server.name) command or endpoint configured for \(server.client.displayName)."
        case .configured, .disabled:
            "Review the \(server.name) configuration in \(server.client.displayName)."
        }
    }

    private static func detailItems(
        for section: ProjectAnalysisSection,
        snapshot: ProjectAnalysisSnapshot
    ) -> [ProjectAnalysisDetailItem] {
        switch section {
        case .instructions:
            snapshot.instructions.map(ProjectAnalysisDetailItem.instruction)
        case .skills:
            snapshot.skills.projects.flatMap(\.skills)
                .sorted()
                .map(ProjectAnalysisDetailItem.skill)
        case .doctor:
            snapshot.doctor.issues
                .filter { $0.severity != .ok }
                .map(ProjectAnalysisDetailItem.doctor)
        case .mcp:
            snapshot.projectMCP.servers.map(ProjectAnalysisDetailItem.mcp)
        case .usage:
            snapshot.usage.summaries
                .sorted {
                    if $0.invocations30d != $1.invocations30d {
                        return $0.invocations30d > $1.invocations30d
                    }
                    return $0.skillName.localizedStandardCompare($1.skillName) == .orderedAscending
                }
                .map(ProjectAnalysisDetailItem.usage)
        }
    }

    private static func detailCursor(
        root: String,
        section: ProjectAnalysisSection,
        offset: Int
    ) -> String {
        let cursor = ProjectAnalysisCursor(
            version: 1,
            root: root,
            section: section,
            offset: offset
        )
        return (try? JSONEncoder().encode(cursor).base64EncodedString()) ?? ""
    }

    private static func detailOffset(
        _ cursor: String?,
        section: ProjectAnalysisSection,
        root: String
    ) throws -> Int {
        guard let cursor else { return 0 }
        guard let data = Data(base64Encoded: cursor),
              let decoded = try? JSONDecoder().decode(ProjectAnalysisCursor.self, from: data)
        else {
            throw projectAnalysisError("invalid project analysis detail cursor")
        }
        guard decoded.version == 1,
              decoded.root == root,
              decoded.section == section,
              decoded.offset >= 0
        else {
            throw projectAnalysisError("project analysis detail cursor does not match the requested root and section")
        }
        return decoded.offset
    }

    private static func resolveProjectRoot(_ root: String) throws -> URL {
        let expanded = NSString(string: root).expandingTildeInPath
        let url = URL(
            fileURLWithPath: expanded,
            relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        ).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw NSError(domain: "MetagentProjectAnalysis", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "project root is not a readable directory: \(url.path)"
            ])
        }
        return url
    }

    private static func projectAnalysisError(_ message: String) -> NSError {
        NSError(domain: "MetagentProjectAnalysis", code: 2, userInfo: [
            NSLocalizedDescriptionKey: message
        ])
    }

    private static func projectInstructionFiles(at root: URL) -> [ProjectInstructionFile] {
        let directCandidates: [(String, String)] = [
            ("AGENTS.md", "agents"),
            ("CLAUDE.md", "claude"),
            (".claude/CLAUDE.md", "claude"),
            (".github/copilot-instructions.md", "copilot"),
            (".cursorrules", "cursor"),
            (".codex/config.toml", "codex-config"),
            (".claude/settings.json", "claude-config"),
            (".claude/settings.local.json", "claude-config"),
            (".mcp.json", "mcp-config")
        ]
        var files = directCandidates.compactMap { relativePath, kind in
            instructionFile(root.appendingPathComponent(relativePath), kind: kind)
        }
        files.append(contentsOf: nestedAgentInstructionFiles(at: root))
        let cursorRules = root.appendingPathComponent(".cursor/rules")
        if let enumerator = FileManager.default.enumerator(
            at: cursorRules,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let url as URL in enumerator where ["md", "mdc"].contains(url.pathExtension.lowercased()) {
                if let file = instructionFile(url, kind: "cursor") {
                    files.append(file)
                }
            }
        }
        return Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            .values
            .sorted { $0.path < $1.path }
    }

    private static func nestedAgentInstructionFiles(at root: URL) -> [ProjectInstructionFile] {
        let prunedDirectories: Set<String> = [
            ".build", ".git", ".next", ".swiftpm", "DerivedData", "Pods",
            "build", "dist", "node_modules", "vendor"
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var files: [ProjectInstructionFile] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                if prunedDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard url.lastPathComponent == "AGENTS.md",
                  let file = instructionFile(url, kind: "agents")
            else { continue }
            files.append(file)
        }
        return files
    }

    private static func instructionFile(_ url: URL, kind: String) -> ProjectInstructionFile? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true
        else { return nil }
        return ProjectInstructionFile(
            path: url.standardizedFileURL.path,
            kind: kind,
            byteCount: Int64(values.fileSize ?? 0)
        )
    }
}

private struct ProjectAnalysisSnapshot {
    let root: URL
    let instructions: [ProjectInstructionFile]
    let skills: SkillScanReport
    let doctor: DoctorReport
    let applicableMCP: MCPHealthSnapshot
    let projectMCP: MCPHealthSnapshot
    let usage: ProjectUsageAnalysis
}

private struct ProjectAnalysisCursor: Codable {
    let version: Int
    let root: String
    let section: ProjectAnalysisSection
    let offset: Int
}
