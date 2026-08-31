import Foundation

public enum ProjectRootKind: String, Codable, CaseIterable, Sendable {
    case project
    case global
    case plugin
}

public struct ProjectQueryOptions: Equatable, Sendable {
    public static let defaultLimit = 50
    public static let maximumLimit = 200

    public var kinds: Set<ProjectRootKind>
    public var limit: Int
    public var cursor: String?

    public init(
        kinds: Set<ProjectRootKind> = [.project],
        limit: Int = defaultLimit,
        cursor: String? = nil
    ) {
        self.kinds = kinds
        self.limit = limit
        self.cursor = cursor
    }

    var boundedLimit: Int {
        min(max(limit, 1), Self.maximumLimit)
    }
}

public struct ProjectQueryItem: Codable, Equatable, Sendable {
    public let root: String
    public let rootKind: ProjectRootKind
    /// Logical skill bundles. Projection copies do not increase this count.
    public let skillCount: Int
    /// Every discovered representation, retained so callers can still audit projections.
    public let representationCount: Int
    public let projectionCount: Int
    /// Canonical skill count by source location. Projection locations are omitted.
    public let locations: [String: Int]

    public init(
        root: String,
        rootKind: ProjectRootKind,
        skillCount: Int,
        representationCount: Int,
        projectionCount: Int,
        locations: [String: Int]
    ) {
        self.root = root
        self.rootKind = rootKind
        self.skillCount = skillCount
        self.representationCount = representationCount
        self.projectionCount = projectionCount
        self.locations = locations
    }
}

public struct ProjectQueryPage: Codable, Equatable, Sendable {
    public static let schemaVersion = 2

    public let schemaVersion: Int
    /// Total roots matching the filter, retained under the original field name.
    public let projectCount: Int
    /// Total canonical skills across every matching root, not just this page.
    public let skillCount: Int
    public let representationCount: Int
    public let projects: [ProjectQueryItem]
    public let returnedCount: Int
    public let truncated: Bool
    public let nextCursor: String?
    public let kinds: [ProjectRootKind]
    public let warnings: [String]

    public init(
        projectCount: Int,
        skillCount: Int,
        representationCount: Int,
        projects: [ProjectQueryItem],
        nextCursor: String?,
        kinds: [ProjectRootKind],
        warnings: [String]
    ) {
        self.schemaVersion = Self.schemaVersion
        self.projectCount = projectCount
        self.skillCount = skillCount
        self.representationCount = representationCount
        self.projects = projects
        self.returnedCount = projects.count
        self.truncated = nextCursor != nil
        self.nextCursor = nextCursor
        self.kinds = kinds
        self.warnings = warnings
    }
}

public extension MetagentCore {
    static func queryProjects(
        options: ProjectQueryOptions = ProjectQueryOptions()
    ) throws -> ProjectQueryPage {
        try queryProjects(
            options: options,
            report: scanPortfolio(),
            homeDirectory: homeURL()
        )
    }

    static func queryProjects(
        options: ProjectQueryOptions,
        report: SkillScanReport,
        homeDirectory: URL
    ) throws -> ProjectQueryPage {
        let requestedKinds = options.kinds.isEmpty
            ? Set(ProjectRootKind.allCases)
            : options.kinds
        let kindList = requestedKinds.sorted { $0.rawValue < $1.rawValue }
        let allItems = report.projects.compactMap { project -> ProjectQueryItem? in
            let kind = projectRootKind(project, homeDirectory: homeDirectory)
            guard requestedKinds.contains(kind) else { return nil }
            let canonical = canonicalInventorySkills(in: project)
            return ProjectQueryItem(
                root: project.root,
                rootKind: kind,
                skillCount: canonical.count,
                representationCount: project.skills.count,
                projectionCount: project.skills.count(where: { $0.representation == "projection" }),
                locations: Dictionary(grouping: canonical, by: \.location).mapValues(\.count)
            )
        }
        .sorted { $0.root < $1.root }

        let offset = try projectQueryOffset(
            options.cursor,
            kinds: kindList
        )
        guard offset <= allItems.count else {
            throw projectQueryError("project query cursor is beyond the available results")
        }
        let end = min(offset + options.boundedLimit, allItems.count)
        let page = Array(allItems[offset..<end])
        let nextCursor = end < allItems.count
            ? projectQueryCursor(kinds: kindList, offset: end)
            : nil

        return ProjectQueryPage(
            projectCount: allItems.count,
            skillCount: allItems.reduce(0) { $0 + $1.skillCount },
            representationCount: allItems.reduce(0) { $0 + $1.representationCount },
            projects: page,
            nextCursor: nextCursor,
            kinds: kindList,
            warnings: report.warnings
        )
    }
}

func canonicalInventorySkills(in project: SkillProject) -> [SkillInventoryItem] {
    var byPath: [String: SkillInventoryItem] = [:]
    for skill in project.skills where skill.representation != "projection" {
        let path = canonicalExistingPath(
            skill.canonicalPath.isEmpty ? skill.path : skill.canonicalPath
        )
        if let existing = byPath[path], existing.representation == "canonical" {
            continue
        }
        byPath[path] = skill
    }
    return byPath.values.sorted()
}

private func projectRootKind(
    _ project: SkillProject,
    homeDirectory: URL
) -> ProjectRootKind {
    let root = canonicalProjectPath(URL(fileURLWithPath: project.root))
    if root == canonicalProjectPath(homeDirectory) {
        return .global
    }
    if !project.skills.isEmpty,
       project.skills.allSatisfy({
           $0.manager == "codex-plugin" || $0.originKind == "codex-plugin"
       })
    {
        return .plugin
    }
    return .project
}

private struct ProjectQueryCursor: Codable {
    let version: Int
    let kinds: [ProjectRootKind]
    let offset: Int
}

private func projectQueryCursor(kinds: [ProjectRootKind], offset: Int) -> String {
    let cursor = ProjectQueryCursor(version: 1, kinds: kinds, offset: offset)
    return (try? JSONEncoder().encode(cursor).base64EncodedString()) ?? ""
}

private func projectQueryOffset(
    _ cursor: String?,
    kinds: [ProjectRootKind]
) throws -> Int {
    guard let cursor else { return 0 }
    guard let data = Data(base64Encoded: cursor),
          let decoded = try? JSONDecoder().decode(ProjectQueryCursor.self, from: data)
    else {
        throw projectQueryError("invalid project query cursor")
    }
    guard decoded.version == 1, decoded.kinds == kinds, decoded.offset >= 0 else {
        throw projectQueryError("project query cursor does not match the requested root kinds")
    }
    return decoded.offset
}

private func projectQueryError(_ message: String) -> NSError {
    NSError(domain: "MetagentProjectQuery", code: 1, userInfo: [
        NSLocalizedDescriptionKey: message
    ])
}
