import Foundation
import Testing
@testable import MetagentCore

@Suite("Project activity")
struct ProjectActivityTests {
    @Test("matches Claude directory encoding for all punctuation")
    func matchesClaudeDirectoryEncoding() {
        #expect(
            sessionDirectoryName(for: "/Users/test/Library/Application Support/agent_tools/site.dev@work")
                == "-Users-test-Library-Application-Support-agent-tools-site-dev-work"
        )
    }

    @Test("finds activity for project roots containing spaces and at signs")
    func scansEncodedSessionDirectory() throws {
        let sessions = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-activity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sessions) }
        let root = "/Users/test/Library/CloudStorage/GoogleDrive-name@example.com/My Project"
        let sessionDirectory = sessions.appendingPathComponent(sessionDirectoryName(for: root))
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try Data().write(to: sessionDirectory.appendingPathComponent("session.jsonl"))

        let index = MetagentCore.scanProjectActivity(
            roots: [root],
            sessionsDirectory: sessions
        )

        #expect(index.isAvailable)
        #expect(index.lastActiveByRoot.keys.contains(standardizedActivityPath(root)))
    }

    @Test("missing, empty, and hidden-only corpora are unavailable")
    func preservesUnavailableCorpusSemantics() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let missing = fixture.appendingPathComponent("missing")
        #expect(MetagentCore.scanProjectActivity(roots: ["/projects/example"], sessionsDirectory: missing) == .unavailable)
        #expect(MetagentCore.scanProjectActivity(roots: ["/projects/example"], sessionsDirectory: fixture) == .unavailable)
        try FileManager.default.createDirectory(
            at: fixture.appendingPathComponent(".hidden"),
            withIntermediateDirectories: true
        )
        #expect(MetagentCore.scanProjectActivity(roots: ["/projects/example"], sessionsDirectory: fixture) == .unavailable)
    }

    @Test("unrelated or non-directory visible entries still make the corpus available")
    func preservesAvailableCorpusSemantics() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        try Data().write(to: fixture.appendingPathComponent("not-a-session-directory"))
        let index = MetagentCore.scanProjectActivity(roots: ["/projects/example"], sessionsDirectory: fixture)
        #expect(index == ProjectActivityIndex(lastActiveByRoot: [:], isAvailable: true))
        #expect(index.isDormant(root: "/projects/example"))
        #expect(!ProjectActivityIndex.unavailable.isDormant(root: "/projects/example"))
        #expect(MetagentCore.scanProjectActivity(roots: [], sessionsDirectory: fixture) == index)

        try FileManager.default.createDirectory(
            at: fixture.appendingPathComponent("unrelated-project"),
            withIntermediateDirectories: true
        )
        #expect(MetagentCore.scanProjectActivity(roots: ["/projects/example"], sessionsDirectory: fixture) == index)
    }

    @Test("reads only requested roots and coalesces standardized path aliases")
    func matchesRequestedStandardizedRoots() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let requested = "/projects/team/example"
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try makeSession(in: fixture, root: requested, name: "requested.jsonl", date: date)
        try makeSession(in: fixture, root: "/projects/unrelated", name: "newer.jsonl", date: date.addingTimeInterval(100))

        let index = MetagentCore.scanProjectActivity(
            roots: [requested, "/projects/team/./example", "/projects/team/temporary/../example"],
            sessionsDirectory: fixture
        )
        #expect(index == ProjectActivityIndex(lastActiveByRoot: [requested: date], isAvailable: true))
    }

    @Test("encoded directory collisions map activity to every requested root")
    func preservesEncodedDirectoryCollisions() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let roots = ["/projects/team-a", "/projects/team_a", "/projects/team a"]
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(Set(roots.map(sessionDirectoryName(for:))).count == 1)
        try makeSession(in: fixture, root: roots[0], name: "shared.jsonl", date: date)

        let index = MetagentCore.scanProjectActivity(roots: roots, sessionsDirectory: fixture)
        #expect(index == ProjectActivityIndex(
            lastActiveByRoot: Dictionary(uniqueKeysWithValues: roots.map { ($0, date) }),
            isAvailable: true
        ))
    }

    @Test("latest visible direct jsonl metadata wins without reading ignored entries")
    func preservesSessionEntryRules() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = "/projects/example"
        let earlier = Date(timeIntervalSince1970: 1_700_000_000)
        let latest = earlier.addingTimeInterval(100)
        let ignored = latest.addingTimeInterval(100)
        try makeSession(in: fixture, root: root, name: "b.jsonl", date: earlier)
        try makeSession(in: fixture, root: root, name: "a.jsonl", date: latest)
        try makeSession(in: fixture, root: root, name: ".hidden.jsonl", date: ignored)
        try makeSession(in: fixture, root: root, name: "not-jsonl.txt", date: ignored)
        try makeSession(in: fixture, root: root, name: "uppercase.JSONL", date: ignored)
        try makeSession(in: fixture, root: root, name: "nested/newer.jsonl", date: ignored)

        let index = MetagentCore.scanProjectActivity(roots: [root], sessionsDirectory: fixture)
        #expect(index == ProjectActivityIndex(lastActiveByRoot: [root: latest], isAvailable: true))
    }

    @Test("jsonl-named directories retain the existing metadata-only behavior")
    func preservesJSONLNamedDirectoryBehavior() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = "/projects/example"
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let directory = fixture.appendingPathComponent(sessionDirectoryName(for: root))
            .appendingPathComponent("directory.jsonl")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: directory.path)

        #expect(MetagentCore.scanProjectActivity(roots: [root], sessionsDirectory: fixture)
            == ProjectActivityIndex(lastActiveByRoot: [root: date], isAvailable: true))
    }

    @Test("each scan observes timestamp changes, deletion, replacement, and renaming")
    func rereadsFreshSessionMetadata() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = "/projects/example"
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let session = try makeSession(in: fixture, root: root, name: "session.jsonl", date: date)
        func scan() -> ProjectActivityIndex {
            MetagentCore.scanProjectActivity(roots: [root], sessionsDirectory: fixture)
        }
        #expect(scan().lastActiveByRoot == [root: date])
        let changed = date.addingTimeInterval(100)
        try FileManager.default.setAttributes([.modificationDate: changed], ofItemAtPath: session.path)
        #expect(scan().lastActiveByRoot == [root: changed])
        try FileManager.default.removeItem(at: session)
        #expect(scan() == ProjectActivityIndex(lastActiveByRoot: [:], isAvailable: true))
        let replacement = try makeSession(in: fixture, root: root, name: "session.jsonl", date: date)
        #expect(scan().lastActiveByRoot == [root: date])
        try FileManager.default.moveItem(at: replacement, to: replacement.deletingPathExtension().appendingPathExtension("txt"))
        #expect(scan().lastActiveByRoot.isEmpty)
    }

    @Test("session directory symlinks preserve the existing unavailable-activity result")
    func preservesSessionDirectorySymlinks() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let sessions = fixture.appendingPathComponent("sessions")
        let targets = fixture.appendingPathComponent("targets")
        let root = "/projects/example"
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let targetSession = try makeSession(in: targets, root: root, name: "session.jsonl", date: date)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: sessions.appendingPathComponent(sessionDirectoryName(for: root)),
            withDestinationURL: targetSession.deletingLastPathComponent()
        )
        // Foundation's metadata URLs for this linked-directory fixture do not
        // supply session dates. Narrowing the scan must not change that result.
        let expected = ProjectActivityIndex(lastActiveByRoot: [:], isAvailable: true)
        #expect(MetagentCore.scanProjectActivity(roots: [root], sessionsDirectory: sessions) == expected)
        let changed = date.addingTimeInterval(100)
        try FileManager.default.setAttributes([.modificationDate: changed], ofItemAtPath: targetSession.path)
        #expect(MetagentCore.scanProjectActivity(roots: [root], sessionsDirectory: sessions) == expected)
    }

    @Test("dormancy keeps its exact cutoff and standardized-root lookup")
    func preservesDormancyBoundary() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cutoff = now.addingTimeInterval(-30 * 86_400)
        let index = ProjectActivityIndex(lastActiveByRoot: ["/projects/example": cutoff], isAvailable: true)
        #expect(!index.isDormant(root: "/projects/./example", now: now))
        #expect(index.isDormant(root: "/projects/example", now: now.addingTimeInterval(1)))
        #expect(index.isDormant(root: "/projects/unknown", now: now))
        #expect(!ProjectActivityIndex.unavailable.isDormant(root: "/projects/unknown", now: now))
    }

    private func makeFixture() throws -> URL {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-activity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        return fixture
    }

    @discardableResult
    private func makeSession(in sessions: URL, root: String, name: String, date: Date) throws -> URL {
        let path = sessions.appendingPathComponent(sessionDirectoryName(for: root)).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: path)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path.path)
        return path
    }
}
