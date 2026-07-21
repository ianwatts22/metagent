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
        let rootURL = try resolveProjectRoot(root)
        let scanOptions = SkillScanOptions(
            roots: [rootURL.path],
            maxDepth: 0,
            respectConfiguredIgnores: false
        )
        let skills = try scanSkills(options: scanOptions)
        let pluginSkills: SkillScanReport
        do {
            pluginSkills = try scanCodexPlugins()
        } catch {
            pluginSkills = SkillScanReport(
                projects: [],
                warnings: ["Codex plugin inventory unavailable: \(error.localizedDescription)"]
            )
        }
        let doctor = try doctor(options: scanOptions)
        let allMCP = scanMCPHealth(
            homeDirectory: homeDirectory,
            codexExecutableOverride: codexExecutableOverride,
            additionalProjectPaths: [rootURL.path],
            observedAt: generatedAt
        )
        let mcp = MCPHealthSnapshot(
            servers: allMCP.servers.compactMap { $0.scoped(to: rootURL.path) },
            observedAt: allMCP.observedAt
        )
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

        return ProjectAnalysisReport(
            root: rootURL.path,
            generatedAt: generatedAt,
            instructions: projectInstructionFiles(at: rootURL),
            skills: skills,
            pluginSkills: pluginSkills,
            doctor: doctor,
            mcp: mcp,
            usage: usage
        )
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
