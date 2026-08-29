import AppKit
import Foundation
import MetagentCore
import SwiftUI
import UniformTypeIdentifiers

func formatNumber(_ value: Int) -> String {
    value.formatted()
}

/// A privacy-safe Accessibility readiness token for installed-app latency
/// measurement. The identifier changes only when the state or ordered rows
/// presented by a section change. It intentionally contains no paths, search
/// text, or row names.
func presentationReadyIdentifier(
    section: String,
    state: [String],
    orderedRowIDs: [String]
) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    func mix(_ value: String) {
        var byteCount = UInt64(value.utf8.count)
        for _ in 0..<MemoryLayout<UInt64>.size {
            hash ^= byteCount & 0xff
            hash &*= 0x100000001b3
            byteCount >>= 8
        }
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
    }

    mix(section)
    mix("state-count:\(state.count)")
    state.forEach(mix)
    mix("row-count:\(orderedRowIDs.count)")
    orderedRowIDs.forEach(mix)
    let token = String(hash, radix: 16, uppercase: false)
    return "metagent.\(section).content.ready.\(String(repeating: "0", count: 16 - token.count))\(token)"
}

/// The semantic sort state actually supplied to `Table`: column key paths and
/// directions only, without private comparator debug internals or an
/// input-generation counter.
func sortPresentationState<Row>(
    _ sortOrder: [KeyPathComparator<Row>]
) -> String {
    sortOrder.map { comparator in
        let direction = comparator.order == .forward ? "forward" : "reverse"
        return "\(String(describing: comparator.keyPath)):\(direction)"
    }.joined(separator: "|")
}

func copyToPasteboard(_ text: String) {
    guard !text.isEmpty else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}

func skillDirectoryURLs(for rows: [SkillTableRow]) -> [URL] {
    rows.filter { $0.inventory != nil }.compactMap(\.canonicalPath).compactMap { path in
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return url
    }.uniqued()
}

func skillFileURLs(for rows: [SkillTableRow]) -> [URL] {
    skillDirectoryURLs(for: rows).compactMap { directory in
        let file = directory.appendingPathComponent("SKILL.md")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }
}

@MainActor func openSkillFiles(_ urls: [URL]) {
    urls.forEach { NSWorkspace.shared.open($0) }
}

@MainActor func openSkillDirectoriesInEditor(_ directories: [URL], skillFiles: [URL]) {
    guard !directories.isEmpty else { return }
    guard let editor = preferredCodeEditor(for: skillFiles.first) else {
        openSkillFiles(skillFiles)
        return
    }
    openSkillDirectories(directories, with: editor)
}

@MainActor func preferredCodeEditor(for skillFile: URL?) -> URL? {
    let knownEditorBundleIdentifiers = [
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.microsoft.VSCode",
        "com.exafunction.windsurf",
        "dev.zed.Zed",
        "com.sublimetext.4",
        "com.panic.Nova",
        "com.barebones.bbedit",
        "com.macromates.TextMate",
        "com.apple.dt.Xcode",
    ]
    if let override = UserDefaults.standard.string(forKey: "metagent.editor.bundle-id"),
       let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: override)
    {
        return application
    }
    if let skillFile,
       let defaultApplication = NSWorkspace.shared.urlForApplication(toOpen: skillFile),
       let bundleIdentifier = Bundle(url: defaultApplication)?.bundleIdentifier,
       knownEditorBundleIdentifiers.contains(bundleIdentifier)
    {
        return defaultApplication
    }
    return knownEditorBundleIdentifiers.lazy.compactMap {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
    }.first
}

@MainActor func openSkillDirectories(_ urls: [URL], with applicationURL: URL? = nil) {
    guard !urls.isEmpty else { return }
    guard let applicationURL else {
        urls.forEach { NSWorkspace.shared.open($0) }
        return
    }
    NSWorkspace.shared.open(
        urls,
        withApplicationAt: applicationURL,
        configuration: NSWorkspace.OpenConfiguration()
    ) { _, error in
        if error != nil { NSSound.beep() }
    }
}

func skillScopeLabel(_ scope: String) -> String {
    switch scope {
    case "project": "Project"
    case "global": "Global"
    case "plugin": "Plugin"
    case "system": "System"
    default: "Unknown"
    }
}

func standardizedDirectoryPath(_ path: String) -> String {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    if FileManager.default.fileExists(atPath: url.path) {
        return url.resolvingSymlinksInPath().standardizedFileURL.path
    }
    return url.path
}

/// Revision-local path normalization for Skills row construction.
///
/// Resolving symlinks touches the filesystem. Skills row construction compares
/// the same paths in several indexes, so keeping one cache for the complete
/// detached build makes each distinct raw path pay that cost at most once.
/// Rows retain the resulting immutable keys; SwiftUI filtering, sorting, and
/// identity never call this resolver.
struct SkillPathCanonicalizer {
    typealias Resolver = (String) -> String

    private let resolver: Resolver
    private var pathsByRawValue: [String: String] = [:]

    init(resolver: @escaping Resolver = standardizedDirectoryPath) {
        self.resolver = resolver
    }

    mutating func canonicalPath(_ rawPath: String) -> String {
        if let cached = pathsByRawValue[rawPath] { return cached }
        let canonical = resolver(rawPath)
        pathsByRawValue[rawPath] = canonical
        // Downstream stages pass canonical keys back through this same build
        // context. Treat a resolved result as its own known key so that handoff
        // does not perform a second filesystem lookup.
        pathsByRawValue[canonical] = canonical
        return canonical
    }

    mutating func canonicalPath(_ rawPath: String?) -> String? {
        rawPath.map { canonicalPath($0) }
    }
}

func isGlobalRoot(_ path: String) -> Bool {
    standardizedDirectoryPath(path) == standardizedDirectoryPath(NSHomeDirectory())
}

func displayUserPath(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path == home {
        return "~"
    }
    guard path.hasPrefix(home + "/") else {
        return path
    }
    return "~" + path.dropFirst(home.count)
}

// ISO8601DateFormatter is documented as thread-safe.
nonisolated(unsafe) private let fractionalISO8601Formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

nonisolated(unsafe) private let plainISO8601Formatter = ISO8601DateFormatter()

func parseISO8601Date(_ value: String) -> Date? {
    fractionalISO8601Formatter.date(from: value) ?? plainISO8601Formatter.date(from: value)
}

func githubRepositoryName(url: String?) -> String? {
    guard let url, !url.isEmpty else { return nil }
    let normalized = url
        .replacingOccurrences(of: "git@github.com:", with: "https://github.com/")
        .replacingOccurrences(of: "ssh://git@github.com/", with: "https://github.com/")
    guard let components = URL(string: normalized)?.pathComponents.filter({ $0 != "/" }),
          components.count >= 2
    else { return nil }
    return components.prefix(2).joined(separator: "/").replacingOccurrences(of: ".git", with: "")
}

func githubRepositoryName(source: String?) -> String? {
    guard let source, !source.isEmpty, !source.hasPrefix("path:") else { return nil }
    guard !source.hasPrefix("/"),
          !source.hasPrefix("~/"),
          !source.hasPrefix("./"),
          !source.hasPrefix("../"),
          !source.hasPrefix("file:")
    else { return nil }
    if source.contains("github.com") { return githubRepositoryName(url: source) }
    let components = source.split(separator: "/")
    guard components.count >= 2 else { return nil }
    return components.prefix(2).joined(separator: "/").replacingOccurrences(of: ".git", with: "")
}

func improvementPrompt(paths: [String]) -> String {
    let pathList = paths.uniqued().map { "- \($0)" }.joined(separator: "\n")
    return """
    Please review and improve the following skill(s):
    \(pathList)

    Use the applicable skill-authoring guidance. Improve trigger precision, clarity, progressive disclosure, and safety while preserving each skill's intended scope and manager ownership. Validate the edited canonical source.
    """
}

func scoreTint(_ grade: SkillGrade) -> Color {
    switch grade {
    case .a: .green
    case .b: .blue
    case .c: .orange
    case .d: .pink
    case .f: .red
    }
}

struct DirectoryFilterOption: Identifiable {
    let root: String
    let name: String

    var id: String { root }
}

func directoryFilterOptions(
    projects: [ProjectStatus],
    mcpHealth: MCPHealthSnapshot,
    doctorIssues: [DoctorIssue]
) -> [DirectoryFilterOption] {
    var namesByRoot: [String: String] = [:]
    for project in projects {
        let isPluginProject = !project.skills.isEmpty && project.skills.allSatisfy { $0.location == "plugin" }
        guard !isPluginProject else { continue }
        namesByRoot[standardizedDirectoryPath(project.root)] = project.name
    }
    let additionalRoots = mcpHealth.servers.flatMap { $0.projectStates.map(\.path) }
        + doctorIssues.compactMap(\.projectRoot)
    for root in additionalRoots {
        let canonicalRoot = standardizedDirectoryPath(root)
        if namesByRoot[canonicalRoot] == nil {
            namesByRoot[canonicalRoot] = URL(fileURLWithPath: canonicalRoot).lastPathComponent
        }
    }
    return namesByRoot.map { DirectoryFilterOption(root: $0.key, name: $0.value) }
        .sorted { left, right in
            if left.root == NSHomeDirectory() { return true }
            if right.root == NSHomeDirectory() { return false }
            let nameOrder = left.name.localizedStandardCompare(right.name)
            return nameOrder == .orderedSame ? left.root < right.root : nameOrder == .orderedAscending
        }
}

func directoryFilterLabel(_ directory: DirectoryFilterOption, options: [DirectoryFilterOption]) -> String {
    guard options.filter({ $0.name == directory.name }).count > 1 else {
        return directory.name
    }
    let parent = URL(fileURLWithPath: directory.root).deletingLastPathComponent().lastPathComponent
    return "\(directory.name) — \(parent)"
}

func logicalSkillCount(projects: [ProjectStatus], selectedProjectRoot: String) -> Int {
    Set<String>(projects.flatMap { project in
        project.skills.compactMap { skill in
            guard skill.scope == "project", project.root == selectedProjectRoot else { return nil }
            return "\(project.root)\u{0}\(skill.name)"
        }
    }).count
}

func projectFilteredMCPHealth(
    _ snapshot: MCPHealthSnapshot,
    selectedProjectRoot: String?
) -> MCPHealthSnapshot {
    guard let selectedProjectRoot else { return snapshot }
    return snapshot.projectOnly(at: selectedProjectRoot)
}

func groupedDoctorActionCount(_ findings: [DoctorIssue]) -> Int {
    Set(findings.map { issue in
        [
            issue.projectRoot ?? "general",
            issue.category?.rawValue ?? "general",
            issue.repairAction?.rawValue ?? "review",
            issue.summary ?? issue.message
        ].joined(separator: "|")
    }).count
}

extension MCPClient {
    var bundleIdentifier: String {
        switch self {
        case .codex: "com.openai.codex"
        case .claude: "com.anthropic.claudefordesktop"
        }
    }
}

extension MCPConnectionState {
    var displayLabel: String {
        switch self {
        case .configured: "Configured"
        case .disabled: "Disabled"
        case .pendingApproval: "Pending approval"
        case .needsSignIn: "Needs sign-in"
        case .unavailable: "Unavailable"
        }
    }

    var displaySymbol: String {
        switch self {
        case .configured: "checkmark.circle"
        case .disabled: "pause.circle"
        case .pendingApproval: "questionmark.circle"
        case .needsSignIn: "person.crop.circle.badge.exclamationmark"
        case .unavailable: "exclamationmark.triangle.fill"
        }
    }

    var displayTint: Color {
        switch self {
        case .configured: .green
        case .disabled: .secondary
        case .pendingApproval, .needsSignIn: .orange
        case .unavailable: .red
        }
    }
}

extension View {
    func cardBackground() -> some View {
        self
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.separator.opacity(0.55), lineWidth: 0.5)
            }
    }
}

extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

extension Sequence {
    func uniqued<Value: Hashable>(by keyPath: KeyPath<Element, Value>) -> [Element] {
        var seen = Set<Value>()
        return filter { seen.insert($0[keyPath: keyPath]).inserted }
    }
}
