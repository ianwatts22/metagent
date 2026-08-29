import Foundation

/// Distinguishes skill-content changes from known metadata churn inside roots
/// that must still be watched recursively for newly installed plugins.
public enum SkillRootEventFilter {
    private static let ignoredFileNames = Set([
        ".codex-remote-plugin-install.json",
    ])

    /// Empty event batches fail open because FSEvents can collapse or drop
    /// path detail under pressure. A batch is ignored only when every reported
    /// path is one of the known metadata-only files.
    public static func shouldRefresh(paths: [String]) -> Bool {
        guard !paths.isEmpty else { return true }
        return paths.contains { path in
            !ignoredFileNames.contains(URL(fileURLWithPath: path).lastPathComponent)
        }
    }
}
