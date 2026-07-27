import Foundation
import XCTest
@testable import MetagentCore

final class CodebaseSizeTests: XCTestCase {
    func testCategorizesSourceTestsDocsConfigurationAndGeneratedOutput() {
        XCTAssertEqual(categorize(relativePath: "Sources/App/Model.swift"), .code)
        XCTAssertEqual(categorize(relativePath: "Tests/AppTests/ModelTests.swift"), .tests)
        XCTAssertEqual(categorize(relativePath: "src/model.test.ts"), .tests)
        XCTAssertEqual(categorize(relativePath: "src/__tests__/model.ts"), .tests)
        XCTAssertEqual(categorize(relativePath: "python/test_model.py"), .tests)
        XCTAssertEqual(categorize(relativePath: "README.md"), .documentation)
        XCTAssertEqual(categorize(relativePath: "Package.swift"), .code)
        XCTAssertEqual(categorize(relativePath: "tsconfig.json"), .configuration)
        XCTAssertEqual(categorize(relativePath: "Makefile"), .configuration)
        XCTAssertEqual(categorize(relativePath: "pnpm-lock.yaml"), .generated)
        XCTAssertEqual(categorize(relativePath: "web/dist/bundle.js"), .generated)
        XCTAssertEqual(categorize(relativePath: "web/app.min.js"), .generated)
        XCTAssertEqual(categorize(relativePath: "icons/logo.svg"), .assets)
    }

    func testMeasuresTrackedFilesOnly() throws {
        let root = try makeTemporaryGitRepository()
        try write("let a = 1\nlet b = 2\nlet c = 3\n", to: root, "Sources/App.swift")
        try write("import XCTest\nfinal class T {}\n", to: root, "Tests/AppTests.swift")
        try write("# Title\n\nProse.\n", to: root, "README.md")
        try write("build/\n", to: root, ".gitignore")
        try commitEverything(in: root)
        // Written after the commit, so git never reports it.
        try write(String(repeating: "noise\n", count: 500), to: root, "build/output.swift")

        let report = try MetagentCore.measureCodebaseSize(root: root.path)

        XCTAssertTrue(report.isGitRepository)
        XCTAssertEqual(report.totalFiles, 4)
        XCTAssertEqual(report.codeLines, 3)
        XCTAssertEqual(report.lines(in: .tests), 2)
        XCTAssertEqual(report.lines(in: .documentation), 3)
        XCTAssertEqual(report.languages, [CodebaseLanguageSize(language: "Swift", files: 2, lines: 5)])
    }

    func testCountsFinalLineWithoutTrailingNewline() throws {
        let root = try makeTemporaryGitRepository()
        try write("one\ntwo", to: root, "main.swift")
        try commitEverything(in: root)

        XCTAssertEqual(try MetagentCore.measureCodebaseSize(root: root.path).codeLines, 2)
    }

    func testSignalsDescribeTestCoverageAndLongFiles() throws {
        let root = try makeTemporaryGitRepository()
        try write(String(repeating: "line\n", count: 120), to: root, "Sources/Long.swift")
        try write(String(repeating: "line\n", count: 40), to: root, "Sources/Short.swift")
        try write(String(repeating: "line\n", count: 80), to: root, "Tests/LongTests.swift")
        try commitEverything(in: root)

        let report = try MetagentCore.measureCodebaseSize(
            root: root.path,
            options: CodebaseSizeOptions(longFileThreshold: 100)
        )

        XCTAssertEqual(report.codeLines, 160)
        XCTAssertEqual(report.signals.longFileCount, 1)
        XCTAssertEqual(report.signals.longFileLineRatio, 120.0 / 160.0, accuracy: 0.0001)
        XCTAssertEqual(report.signals.testLineRatio, 80.0 / 240.0, accuracy: 0.0001)
        XCTAssertEqual(report.signals.medianCodeFileLines, 80)
        XCTAssertEqual(report.signals.largestCodeFileLines, 120)
        XCTAssertEqual(report.largestFiles.first?.path, "Sources/Long.swift")
    }

    func testUnreadableCodeFilesDoNotSkewFileSizeSignals() throws {
        let root = try makeTemporaryGitRepository()
        try write("one\ntwo\n", to: root, "Sources/Readable.swift")
        try write(String(repeating: "line\n", count: 100), to: root, "Sources/TooLarge.swift")
        try commitEverything(in: root)

        let report = try MetagentCore.measureCodebaseSize(
            root: root.path,
            options: CodebaseSizeOptions(maximumFileBytes: 20)
        )

        XCTAssertEqual(report.codeLines, 2)
        XCTAssertEqual(report.signals.medianCodeFileLines, 2)
        XCTAssertEqual(report.signals.largestCodeFileLines, 2)
        XCTAssertEqual(report.warnings, ["1 tracked file(s) could not be read as text"])
    }

    func testReportsFolderWithoutGitAsUnmeasured() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-codebase-tests")
        try write("let a = 1\n", to: root, "main.swift")

        let report = try MetagentCore.measureCodebaseSize(root: root.path)

        XCTAssertFalse(report.isGitRepository)
        XCTAssertEqual(report.totalFiles, 0)
        XCTAssertEqual(report.codeLines, 0)
    }

    func testBatchMeasurementSkipsFoldersWithoutGit() throws {
        let repository = try makeTemporaryGitRepository()
        try write("let a = 1\n", to: repository, "main.swift")
        try commitEverything(in: repository)
        let plainFolder = try makeTemporaryRoot(prefix: "metagent-codebase-tests")

        let reports = MetagentCore.measureCodebaseSizes(roots: [repository.path, plainFolder.path])

        XCTAssertEqual(Set(reports.keys), [repository.standardizedFileURL.path])
    }

    // MARK: - Fixtures

    private func makeTemporaryGitRepository() throws -> URL {
        let root = try makeTemporaryRoot(prefix: "metagent-codebase-tests")
        try runGit(["init", "--quiet"], in: root)
        return root
    }

    private func commitEverything(in root: URL) throws {
        try runGit(["add", "--all"], in: root)
        try runGit([
            "-c", "user.name=Metagent Tests",
            "-c", "user.email=tests@example.invalid",
            "commit", "--quiet", "--message", "fixture"
        ], in: root)
    }

    private func runGit(_ arguments: [String], in root: URL) throws {
        let result = try runSubprocess(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: arguments,
            currentDirectory: root,
            timeout: 30
        )
        try XCTSkipUnless(
            result.status == 0,
            "git \(arguments.joined(separator: " ")) failed: \(combinedSubprocessOutput(result))"
        )
    }

    private func write(_ contents: String, to root: URL, _ relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
