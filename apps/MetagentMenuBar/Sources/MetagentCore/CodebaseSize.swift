import Foundation

/// How a tracked file counts toward codebase size.
///
/// Size alone does not say whether a repository is carrying weight it should
/// not. The split does: hand-written code, its tests, prose, configuration, and
/// machine-written output each grow for different reasons, and only the first
/// two are the codebase a person has to hold in their head.
public enum CodebaseFileCategory: String, Codable, CaseIterable, Sendable {
    case code
    case tests
    case documentation
    case configuration
    case generated
    case assets
    case other
}

/// Keeps `categories` encoded as a JSON object rather than the flat key/value
/// array Swift falls back to for non-string dictionary keys.
extension CodebaseFileCategory: CodingKeyRepresentable {}

public struct CodebaseCategorySize: Codable, Equatable, Sendable {
    public var files: Int
    public var lines: Int

    public init(files: Int = 0, lines: Int = 0) {
        self.files = files
        self.lines = lines
    }

    mutating func add(lines newLines: Int) {
        files += 1
        lines += newLines
    }
}

public struct CodebaseLanguageSize: Codable, Equatable, Sendable {
    public var language: String
    public var files: Int
    public var lines: Int

    public init(language: String, files: Int, lines: Int) {
        self.language = language
        self.files = files
        self.lines = lines
    }
}

public struct CodebaseFileSize: Codable, Equatable, Sendable {
    public var path: String
    public var lines: Int
    public var category: CodebaseFileCategory

    public init(path: String, lines: Int, category: CodebaseFileCategory) {
        self.path = path
        self.lines = lines
        self.category = category
    }
}

/// Derived ratios that answer "is this codebase carrying slop?" without the
/// caller having to redo the arithmetic.
public struct CodebaseSizeSignals: Codable, Equatable, Sendable {
    /// Test lines as a share of code plus test lines.
    public var testLineRatio: Double
    /// Prose lines as a share of every counted line. Agent-written repositories
    /// drift high here long before the code itself gets large.
    public var documentationLineRatio: Double
    /// Machine-written lines as a share of every counted line.
    public var generatedLineRatio: Double
    /// Code lines living in files at or over `longFileThreshold`, as a share of
    /// all code lines.
    public var longFileLineRatio: Double
    public var longFileCount: Int
    public var medianCodeFileLines: Int
    public var largestCodeFileLines: Int

    public init(
        testLineRatio: Double = 0,
        documentationLineRatio: Double = 0,
        generatedLineRatio: Double = 0,
        longFileLineRatio: Double = 0,
        longFileCount: Int = 0,
        medianCodeFileLines: Int = 0,
        largestCodeFileLines: Int = 0
    ) {
        self.testLineRatio = testLineRatio
        self.documentationLineRatio = documentationLineRatio
        self.generatedLineRatio = generatedLineRatio
        self.longFileLineRatio = longFileLineRatio
        self.longFileCount = longFileCount
        self.medianCodeFileLines = medianCodeFileLines
        self.largestCodeFileLines = largestCodeFileLines
    }
}

public struct CodebaseSizeReport: Codable, Equatable, Sendable {
    public var root: String
    /// `false` when the folder is not a git repository. Every count is zero in
    /// that case: size is only measured where git can name the tracked files.
    public var isGitRepository: Bool
    public var measuredAt: Date
    /// Tracked files git reported, including ones with no countable lines.
    public var totalFiles: Int
    /// Lines across every text file git tracks, in every category.
    public var totalLines: Int
    /// Hand-written source lines, excluding tests, prose, config, and generated
    /// output. This is the number to compare two codebases by.
    public var codeLines: Int
    public var categories: [CodebaseFileCategory: CodebaseCategorySize]
    public var languages: [CodebaseLanguageSize]
    public var largestFiles: [CodebaseFileSize]
    public var signals: CodebaseSizeSignals
    public var longFileThreshold: Int
    public var warnings: [String]

    public init(
        root: String,
        isGitRepository: Bool,
        measuredAt: Date = Date(),
        totalFiles: Int = 0,
        totalLines: Int = 0,
        codeLines: Int = 0,
        categories: [CodebaseFileCategory: CodebaseCategorySize] = [:],
        languages: [CodebaseLanguageSize] = [],
        largestFiles: [CodebaseFileSize] = [],
        signals: CodebaseSizeSignals = CodebaseSizeSignals(),
        longFileThreshold: Int = CodebaseSizeOptions.defaultLongFileThreshold,
        warnings: [String] = []
    ) {
        self.root = root
        self.isGitRepository = isGitRepository
        self.measuredAt = measuredAt
        self.totalFiles = totalFiles
        self.totalLines = totalLines
        self.codeLines = codeLines
        self.categories = categories
        self.languages = languages
        self.largestFiles = largestFiles
        self.signals = signals
        self.longFileThreshold = longFileThreshold
        self.warnings = warnings
    }

    public func lines(in category: CodebaseFileCategory) -> Int {
        categories[category]?.lines ?? 0
    }

    public func files(in category: CodebaseFileCategory) -> Int {
        categories[category]?.files ?? 0
    }
}

public struct CodebaseSizeOptions: Equatable, Sendable {
    public static let defaultLongFileThreshold = 500
    public static let defaultMaximumFiles = 25_000
    public static let defaultMaximumFileBytes = 4 * 1_024 * 1_024

    /// Code files at or over this many lines count as long files.
    public var longFileThreshold: Int
    /// Stop after this many tracked files and warn, so one enormous repository
    /// cannot stall a portfolio-wide scan.
    public var maximumFiles: Int
    /// Files larger than this are counted but not read.
    public var maximumFileBytes: Int
    public var largestFileCount: Int
    public var timeout: TimeInterval

    public init(
        longFileThreshold: Int = defaultLongFileThreshold,
        maximumFiles: Int = defaultMaximumFiles,
        maximumFileBytes: Int = defaultMaximumFileBytes,
        largestFileCount: Int = 10,
        timeout: TimeInterval = 30
    ) {
        self.longFileThreshold = longFileThreshold
        self.maximumFiles = maximumFiles
        self.maximumFileBytes = maximumFileBytes
        self.largestFileCount = largestFileCount
        self.timeout = timeout
    }
}

public extension MetagentCore {
    /// Measures how much codebase a git repository actually carries.
    ///
    /// File discovery goes through `git ls-files`, so the answer covers exactly
    /// what the repository tracks: ignored build output, dependencies, and
    /// caches never inflate the count, and nothing outside version control gets
    /// credited to the project.
    static func measureCodebaseSize(
        root: String,
        options: CodebaseSizeOptions = CodebaseSizeOptions(),
        measuredAt: Date = Date()
    ) throws -> CodebaseSizeReport {
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL
        guard isGitRepository(rootURL) else {
            return CodebaseSizeReport(
                root: rootURL.path,
                isGitRepository: false,
                measuredAt: measuredAt,
                longFileThreshold: options.longFileThreshold
            )
        }

        var warnings: [String] = []
        var relativePaths = try trackedFilePaths(root: rootURL, timeout: options.timeout)
        if relativePaths.count > options.maximumFiles {
            warnings.append(
                "measured the first \(options.maximumFiles) of \(relativePaths.count) tracked files"
            )
            relativePaths = Array(relativePaths.prefix(options.maximumFiles))
        }

        var categories: [CodebaseFileCategory: CodebaseCategorySize] = [:]
        var languageTotals: [String: CodebaseCategorySize] = [:]
        var measuredFiles: [CodebaseFileSize] = []
        var codeFileLines: [Int] = []
        var longFileCount = 0
        var longFileLines = 0
        var unreadableCount = 0

        for relativePath in relativePaths {
            let category = categorize(relativePath: relativePath)
            let fileURL = rootURL.appendingPathComponent(relativePath)
            let lines = countableCategories.contains(category)
                ? lineCount(at: fileURL, maximumBytes: options.maximumFileBytes)
                : 0
            if lines == nil {
                unreadableCount += 1
            }
            let counted = lines ?? 0

            categories[category, default: CodebaseCategorySize()].add(lines: counted)

            if category == .code || category == .tests,
               let language = languageName(for: relativePath)
            {
                languageTotals[language, default: CodebaseCategorySize()].add(lines: counted)
            }

            if category == .code, let lines {
                codeFileLines.append(lines)
                if lines >= options.longFileThreshold {
                    longFileCount += 1
                    longFileLines += lines
                }
            }

            if counted > 0, category == .code || category == .tests {
                measuredFiles.append(CodebaseFileSize(
                    path: relativePath,
                    lines: counted,
                    category: category
                ))
            }
        }

        if unreadableCount > 0 {
            warnings.append("\(unreadableCount) tracked file(s) could not be read as text")
        }

        let totalLines = categories.values.reduce(0) { $0 + $1.lines }
        let codeLines = categories[.code]?.lines ?? 0
        let testLines = categories[.tests]?.lines ?? 0
        let documentationLines = categories[.documentation]?.lines ?? 0
        let generatedLines = categories[.generated]?.lines ?? 0

        return CodebaseSizeReport(
            root: rootURL.path,
            isGitRepository: true,
            measuredAt: measuredAt,
            totalFiles: relativePaths.count,
            totalLines: totalLines,
            codeLines: codeLines,
            categories: categories,
            languages: languageTotals
                .map { CodebaseLanguageSize(language: $0.key, files: $0.value.files, lines: $0.value.lines) }
                .sorted { left, right in
                    left.lines == right.lines ? left.language < right.language : left.lines > right.lines
                },
            largestFiles: Array(
                measuredFiles
                    .sorted { left, right in
                        left.lines == right.lines ? left.path < right.path : left.lines > right.lines
                    }
                    .prefix(options.largestFileCount)
            ),
            signals: CodebaseSizeSignals(
                testLineRatio: ratio(testLines, of: codeLines + testLines),
                documentationLineRatio: ratio(documentationLines, of: totalLines),
                generatedLineRatio: ratio(generatedLines, of: totalLines),
                longFileLineRatio: ratio(longFileLines, of: codeLines),
                longFileCount: longFileCount,
                medianCodeFileLines: median(codeFileLines),
                largestCodeFileLines: codeFileLines.max() ?? 0
            ),
            longFileThreshold: options.longFileThreshold,
            warnings: warnings
        )
    }

    /// Measures every root that is a git repository, skipping the rest. Roots
    /// that fail to measure are reported as warnings rather than aborting the
    /// batch, so one broken checkout cannot blank the whole table.
    static func measureCodebaseSizes(
        roots: [String],
        options: CodebaseSizeOptions = CodebaseSizeOptions(),
        measuredAt: Date = Date()
    ) -> [String: CodebaseSizeReport] {
        roots.reduce(into: [:]) { reports, root in
            let key = URL(fileURLWithPath: root).standardizedFileURL.path
            guard reports[key] == nil else { return }
            do {
                let report = try measureCodebaseSize(
                    root: root,
                    options: options,
                    measuredAt: measuredAt
                )
                guard report.isGitRepository else { return }
                reports[key] = report
            } catch {
                reports[key] = CodebaseSizeReport(
                    root: key,
                    isGitRepository: true,
                    measuredAt: measuredAt,
                    longFileThreshold: options.longFileThreshold,
                    warnings: [error.localizedDescription]
                )
            }
        }
    }
}

/// Categories whose lines are worth reading off disk. Assets are counted as
/// files only.
private let countableCategories: Set<CodebaseFileCategory> = [
    .code, .tests, .documentation, .configuration, .generated, .other
]

func isGitRepository(_ root: URL) -> Bool {
    // Worktrees and submodules store a `.git` file rather than a directory.
    fileManager.fileExists(atPath: root.appendingPathComponent(".git").path)
}

func gitExecutable() throws -> URL {
    guard let path = firstExecutableCandidate(
        named: "git",
        environmentOverride: "METAGENT_GIT",
        extraCandidates: ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
    ) else {
        throw NSError(domain: "MetagentCodebaseSize", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "git executable not found; set METAGENT_GIT to measure codebase size"
        ])
    }
    return URL(fileURLWithPath: path)
}

private func trackedFilePaths(root: URL, timeout: TimeInterval) throws -> [String] {
    let result = try runSubprocess(
        executable: try gitExecutable(),
        arguments: ["ls-files", "-z", "--cached", "--exclude-standard"],
        currentDirectory: root,
        timeout: timeout
    )
    try requireSubprocessSuccess(
        result,
        output: String(decoding: result.standardError, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines),
        domain: "MetagentCodebaseSize",
        timeoutCode: 2,
        timeoutMessage: "git ls-files timed out in \(root.path)",
        failureMessage: "git ls-files failed in \(root.path)"
    )
    return String(decoding: result.standardOutput, as: UTF8.self)
        .split(separator: "\0", omittingEmptySubsequences: true)
        .map(String.init)
}

/// Counts newlines, plus a final line when the file does not end in one.
/// Returns `nil` for binary content and for files the process cannot read.
private func lineCount(at url: URL, maximumBytes: Int) -> Int? {
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
    guard size > 0 else { return 0 }
    guard size <= maximumBytes else { return nil }
    guard let data = try? Data(contentsOf: url) else { return nil }
    return data.withUnsafeBytes { buffer -> Int? in
        guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return nil }
        var newlines = 0
        for index in 0..<buffer.count {
            let byte = base[index]
            if byte == 0 { return nil }
            if byte == 0x0A { newlines += 1 }
        }
        return base[buffer.count - 1] == 0x0A ? newlines : newlines + 1
    }
}

private func ratio(_ value: Int, of total: Int) -> Double {
    total > 0 ? Double(value) / Double(total) : 0
}

private func median(_ values: [Int]) -> Int {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    return sorted.count.isMultiple(of: 2)
        ? (sorted[middle - 1] + sorted[middle]) / 2
        : sorted[middle]
}

func categorize(relativePath: String) -> CodebaseFileCategory {
    let components = relativePath.split(separator: "/").map(String.init)
    let name = components.last ?? relativePath
    let lowercasedName = name.lowercased()
    let lowercasedComponents = components.dropLast().map { $0.lowercased() }

    if generatedFileNames.contains(lowercasedName)
        || lowercasedComponents.contains(where: generatedDirectoryNames.contains)
        || generatedNameFragments.contains(where: lowercasedName.contains)
    {
        return .generated
    }

    let fileExtension = (lowercasedName as NSString).pathExtension
    if assetExtensions.contains(fileExtension) {
        return .assets
    }
    if documentationExtensions.contains(fileExtension) {
        return .documentation
    }
    if codeExtensions.keys.contains(fileExtension) {
        return isTestPath(components: lowercasedComponents, name: lowercasedName) ? .tests : .code
    }
    if configurationExtensions.contains(fileExtension) || configurationFileNames.contains(lowercasedName) {
        return .configuration
    }
    return .other
}

private func isTestPath(components: [String], name: String) -> Bool {
    if components.contains(where: testDirectoryNames.contains) {
        return true
    }
    let stem = (name as NSString).deletingPathExtension
    return stem.hasSuffix(".test")
        || stem.hasSuffix(".spec")
        || stem.hasSuffix("_test")
        || stem.hasSuffix("tests")
        || stem.hasPrefix("test_")
}

func languageName(for relativePath: String) -> String? {
    codeExtensions[(relativePath.lowercased() as NSString).pathExtension]
}

private let testDirectoryNames: Set<String> = [
    "test", "tests", "__tests__", "spec", "specs", "e2e", "testing"
]

private let generatedDirectoryNames: Set<String> = [
    "node_modules", "vendor", "pods", "deriveddata", ".build", "build", "dist",
    "out", ".next", ".nuxt", ".turbo", "coverage", "_generated", "generated",
    "__generated__", "__pycache__", ".venv", "target", "migrations"
]

private let generatedFileNames: Set<String> = [
    "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "cargo.lock",
    "package.resolved", "poetry.lock", "gemfile.lock", "composer.lock", "go.sum",
    "uv.lock", "podfile.lock", "flake.lock"
]

private let generatedNameFragments: [String] = [
    ".generated.", ".min.", ".pb.", "_pb2.", ".g.dart", ".d.ts"
]

private let documentationExtensions: Set<String> = [
    "md", "markdown", "mdx", "rst", "adoc", "txt"
]

private let configurationExtensions: Set<String> = [
    "json", "yaml", "yml", "toml", "ini", "cfg", "conf", "properties", "plist",
    "xml", "env", "gradle", "entitlements", "pbxproj", "xcconfig", "editorconfig"
]

private let configurationFileNames: Set<String> = [
    ".gitignore", ".gitattributes", ".dockerignore", ".npmrc", ".nvmrc",
    "dockerfile", "makefile", "procfile", "brewfile", "codeowners"
]

private let assetExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "svg", "webp", "ico", "icns", "pdf", "car",
    "mp3", "mp4", "wav", "aiff", "mov", "webm", "woff", "woff2", "ttf", "otf",
    "eot", "zip", "gz", "tar", "bz2", "xz", "dmg", "bin", "dat", "sqlite", "db"
]

private let codeExtensions: [String: String] = [
    "swift": "Swift",
    "ts": "TypeScript",
    "tsx": "TypeScript",
    "js": "JavaScript",
    "jsx": "JavaScript",
    "mjs": "JavaScript",
    "cjs": "JavaScript",
    "py": "Python",
    "rb": "Ruby",
    "go": "Go",
    "rs": "Rust",
    "java": "Java",
    "kt": "Kotlin",
    "kts": "Kotlin",
    "c": "C",
    "h": "C",
    "cc": "C++",
    "cpp": "C++",
    "hpp": "C++",
    "m": "Objective-C",
    "mm": "Objective-C",
    "cs": "C#",
    "php": "PHP",
    "scala": "Scala",
    "sh": "Shell",
    "bash": "Shell",
    "zsh": "Shell",
    "fish": "Shell",
    "lua": "Lua",
    "dart": "Dart",
    "ex": "Elixir",
    "exs": "Elixir",
    "erl": "Erlang",
    "hs": "Haskell",
    "clj": "Clojure",
    "sql": "SQL",
    "vue": "Vue",
    "svelte": "Svelte",
    "css": "CSS",
    "scss": "CSS",
    "sass": "CSS",
    "less": "CSS",
    "html": "HTML",
    "applescript": "AppleScript"
]
