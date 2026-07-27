import Foundation

/// Last observed agent-session activity per project root.
///
/// Adoption metrics are misleading when they count project skills that live in
/// directories nobody has worked in for months. This index supplies the missing
/// signal: when a project last had an agent session recorded on disk.
public struct ProjectActivityIndex: Sendable, Equatable {
    /// Standardized project root -> newest recorded session activity.
    public let lastActiveByRoot: [String: Date]
    /// `false` when no session corpus was found at all, in which case no project
    /// should be treated as dormant.
    public let isAvailable: Bool

    public init(lastActiveByRoot: [String: Date], isAvailable: Bool) {
        self.lastActiveByRoot = lastActiveByRoot
        self.isAvailable = isAvailable
    }

    public static let unavailable = ProjectActivityIndex(
        lastActiveByRoot: [:],
        isAvailable: false
    )

    /// A root is dormant only when the corpus exists and either has no record of
    /// the root or its newest record predates the window. Unknown roots stay
    /// counted whenever the corpus itself is missing.
    public func isDormant(root: String, now: Date = Date(), windowDays: Int = 30) -> Bool {
        guard isAvailable else { return false }
        let cutoff = now.addingTimeInterval(-Double(windowDays) * 86_400)
        guard let lastActive = lastActiveByRoot[standardizedActivityPath(root)] else {
            return true
        }
        return lastActive < cutoff
    }
}

public extension MetagentCore {
    /// Reads recorded Claude Code session history to find when each project root
    /// last saw agent activity. Only directory and file metadata are read, never
    /// transcript contents.
    static func scanProjectActivity(
        roots: [String],
        sessionsDirectory: URL? = nil
    ) -> ProjectActivityIndex {
        let sessionsRoot = sessionsDirectory ?? homeURL()
            .standardizedFileURL
            .appendingPathComponent(".claude/projects")
        guard let sessionDirectories = try? fileManager.contentsOfDirectory(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ), !sessionDirectories.isEmpty else {
            return .unavailable
        }

        let newestByDirectoryName = sessionDirectories.reduce(into: [String: Date]()) { newest, directory in
            guard let modifiedAt = newestSessionDate(in: directory) else { return }
            newest[directory.lastPathComponent] = modifiedAt
        }

        let lastActiveByRoot = roots.reduce(into: [String: Date]()) { activity, root in
            let standardizedRoot = standardizedActivityPath(root)
            guard let modifiedAt = newestByDirectoryName[sessionDirectoryName(for: standardizedRoot)] else {
                return
            }
            activity[standardizedRoot] = modifiedAt
        }

        return ProjectActivityIndex(lastActiveByRoot: lastActiveByRoot, isAvailable: true)
    }
}

/// Claude Code names each session directory after the project root with every
/// non-ASCII-alphanumeric character folded to `-`.
func sessionDirectoryName(for standardizedRoot: String) -> String {
    String(standardizedRoot.unicodeScalars.map { scalar in
        switch scalar.value {
        case 48...57, 65...90, 97...122:
            Character(String(scalar))
        default:
            "-"
        }
    })
}

private func newestSessionDate(in directory: URL) -> Date? {
    guard let entries = try? fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
    ) else { return nil }
    return entries
        .filter { $0.pathExtension == "jsonl" }
        .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        .max()
}

func standardizedActivityPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
}
