import Foundation
import XCTest
@testable import MetagentCore

final class SkillPublicationGitTests: XCTestCase {
    func testExplicitPublishCommitsOnlyApprovedNewSkillAndPushesIt() throws {
        let fixture = try GitPublicationFixture()
        defer { fixture.remove() }
        try fixture.removePath("skills")
        try fixture.write("Repository\n", at: "README.md")
        try fixture.commit()
        try fixture.configureBareRemote()
        try fixture.writeSkill("First public version")

        let preview = fixture.preparePublish()
        XCTAssertTrue(preview.isReady, preview.blocker ?? "")
        XCTAssertEqual(preview.action, .publish)
        XCTAssertEqual(preview.branch, "main")
        XCTAssertEqual(preview.changes, [
            SkillPublicationChange(path: "skills/folder-name/SKILL.md", kind: .added),
        ])
        let before = try fixture.git(["rev-parse", "HEAD"])

        let result = fixture.publish(preview, message: "Publish manifest-name")
        XCTAssertEqual(result.outcome, .published, result.message)
        XCTAssertNotEqual(result.commit, before)
        XCTAssertEqual(try fixture.bareGit(["rev-parse", "refs/heads/main"]), result.commit)
        XCTAssertEqual(try fixture.git(["status", "--porcelain"]), "")
        XCTAssertEqual(fixture.inspect().state, .matchesKnownUpstream)
        XCTAssertEqual(try fixture.git(["show", "--format=", "--name-only", result.commit!]),
            "skills/folder-name/SKILL.md")
    }

    func testPublishUpdatePreviewsExactAddsModificationsAndDeletes() throws {
        let fixture = try GitPublicationFixture()
        defer { fixture.remove() }
        try fixture.write("old note", at: "skills/folder-name/old.txt")
        try fixture.commit()
        try fixture.configureBareRemote()
        try fixture.writeSkill("Updated public version")
        try fixture.removePath("skills/folder-name/old.txt")
        try fixture.write("new note", at: "skills/folder-name/new.txt")

        let preview = fixture.preparePublish()
        XCTAssertTrue(preview.isReady, preview.blocker ?? "")
        XCTAssertEqual(preview.action, .update)
        XCTAssertEqual(Set(preview.changes), Set([
            SkillPublicationChange(path: "skills/folder-name/SKILL.md", kind: .modified),
            SkillPublicationChange(path: "skills/folder-name/old.txt", kind: .deleted),
            SkillPublicationChange(path: "skills/folder-name/new.txt", kind: .added),
        ]))
        XCTAssertEqual(fixture.publish(preview, message: "Update manifest-name").outcome, .published)
    }

    func testPublishBlocksUnrelatedDirtyAndUnpublishedHistory() throws {
        let fixture = try GitPublicationFixture()
        defer { fixture.remove() }
        try fixture.commit()
        try fixture.configureBareRemote()
        try fixture.writeSkill("Changed")
        try fixture.write("private", at: "private.txt")
        var preview = fixture.preparePublish()
        XCTAssertFalse(preview.isReady)
        XCTAssertTrue(preview.blocker?.contains("outside") == true)

        try fixture.commit()
        preview = fixture.preparePublish()
        XCTAssertFalse(preview.isReady)
        XCTAssertTrue(preview.blocker?.contains("histories differ") == true)
    }

    func testPublishApprovalExpiresWhenMirroredBytesChange() throws {
        let fixture = try GitPublicationFixture()
        defer { fixture.remove() }
        try fixture.commit()
        try fixture.configureBareRemote()
        try fixture.writeSkill("Approved")
        let preview = fixture.preparePublish()
        let head = try fixture.git(["rev-parse", "HEAD"])

        try fixture.writeSkill("Changed after approval")
        let result = fixture.publish(preview, message: "Update manifest-name")
        XCTAssertEqual(result.outcome, .previewExpired)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertNotEqual(fixture.preparePublish().plannedTree, preview.plannedTree)
    }

    func testRejectedPushKeepsExactCommitForSafeRetry() throws {
        let fixture = try GitPublicationFixture()
        defer { fixture.remove() }
        try fixture.commit()
        try fixture.configureBareRemote()
        try fixture.writeSkill("Pending publication")
        let preview = fixture.preparePublish()
        try fixture.rejectPushes()

        let first = fixture.publish(preview, message: "Update manifest-name")
        XCTAssertEqual(first.outcome, .committedLocally, first.message)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), first.commit)
        XCTAssertEqual(try fixture.git(["status", "--porcelain"]), "")
        XCTAssertNotEqual(try fixture.bareGit(["rev-parse", "refs/heads/main"]), first.commit)

        let retry = fixture.preparePublish()
        XCTAssertTrue(retry.isReady, retry.blocker ?? "")
        XCTAssertEqual(retry.action, .retryPush)
        XCTAssertEqual(retry.commitToPush, first.commit)
        try fixture.allowPushes()
        let second = fixture.publish(retry, message: "Ignored for exact retry")
        XCTAssertEqual(second.outcome, .published, second.message)
        XCTAssertEqual(second.commit, first.commit)
        XCTAssertEqual(try fixture.bareGit(["rev-parse", "refs/heads/main"]), first.commit)
    }

    func testPublishPreviewRejectsContentFiltersBeforeGitStatusCanExecuteThem() throws {
        let fixture = try GitPublicationFixture()
        defer { fixture.remove() }
        try fixture.commit()
        try fixture.configureBareRemote()
        let marker = fixture.root.appendingPathComponent("publish-filter-executed")
        let helper = fixture.root.appendingPathComponent("publish-filter-helper.sh")
        try "#!/bin/sh\ntouch '\(marker.path)'\ncat\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        try fixture.git(["config", "filter.unsafe.clean", helper.path])
        try fixture.git(["config", "filter.unsafe.required", "true"])
        try fixture.write("skills/** filter=unsafe\n", at: ".gitattributes")
        try fixture.writeSkill("Changed after filter configuration")

        let preview = fixture.preparePublish()

        XCTAssertFalse(preview.isReady)
        XCTAssertTrue(preview.blocker?.contains("content filters") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testCanonicalGitHubLinksAndInstallCommand() {
        for remote in ["https://github.com/acme/skills.git", "git@github.com:acme/skills.git", "ssh://git@github.com/acme/skills"] {
            let links = SkillPublicationLinks(remoteURL: remote, skillName: "my-skill")
            XCTAssertEqual(links?.repositoryURL.absoluteString, "https://github.com/acme/skills")
            XCTAssertEqual(links?.skillsURL.absoluteString, "https://skills.sh/acme/skills/my-skill")
            XCTAssertEqual(links?.installCommand, "npx skills add acme/skills --skill my-skill")
        }
    }

    func testUnsafeAndCredentialBearingRemotesNeverBecomeLinks() {
        for remote in [
            "https://token@github.com/acme/skills", "https://user:secret@github.com/acme/skills",
            "https://github.com.evil.test/acme/skills", "http://github.com/acme/skills",
            "https://github.com/acme/skills?token=secret", "https://github.com/acme/skills#fragment",
            "https://github.com:443/acme/skills", "ssh://other@github.com/acme/skills",
            "git@github.com:acme/skills;echo-pwned", "https://github.com/acme/%73kills",
            "https://github.com/acme/skills/tree/main", "https://github.com/acme/../skills",
            "https://github.com/acme/skills\n", "file:///tmp/skills",
        ] {
            XCTAssertNil(SkillPublicationLinks(remoteURL: remote, skillName: "skill"), remote)
        }
        for name in ["-all", "*", "../skill", "two words", "skill;echo", "$(whoami)", "skill\n"] {
            XCTAssertNil(SkillPublicationLinks(remoteURL: "https://github.com/acme/skills", skillName: name), name)
        }
    }

    func testUntrackedAndStagedSkillAreLocalChangesWithoutWritingGitIndex() throws {
        let fixture = try GitPublicationFixture()
        defer { fixture.remove() }
        XCTAssertEqual(fixture.inspect().state, .localChanges)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".git/index").path))
        try fixture.git(["add", "skills"])
        let index = try Data(contentsOf: fixture.root.appendingPathComponent(".git/index"))
        XCTAssertEqual(fixture.inspect().state, .localChanges)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent(".git/index")), index)
    }

    func testCleanCommitWithoutUpstreamDoesNotClaimPushed() throws {
        let fixture = try GitPublicationFixture()
        defer { fixture.remove() }
        try fixture.commit()
        let result = fixture.inspect()
        XCTAssertEqual(result.state, .noUpstream, result.detail)
        XCTAssertNotNil(result.checkoutCommit)
        XCTAssertNil(result.upstreamCommit)
        XCTAssertEqual(result.links?.installCommand, "npx skills add acme/skills --skill manifest-name")
    }

    func testKnownUpstreamComparisonIsSkillScopedAndExplicitlyNotLive() throws {
        let fixture = try GitPublicationFixture()
        defer { fixture.remove() }
        try fixture.commit()
        try fixture.trackCurrentCommit()
        let before = fixture.inspect()
        XCTAssertEqual(before.state, .matchesKnownUpstream)
        XCTAssertTrue(before.detail.contains("No fetch was run"))
        XCTAssertTrue(before.detail.contains("not verified"))
        try fixture.write("other skill change", at: "unrelated.txt")
        try fixture.commit()
        let after = fixture.inspect()
        XCTAssertEqual(after.state, .matchesKnownUpstream)
        XCTAssertNotEqual(after.checkoutCommit, after.upstreamCommit)
        try fixture.write("unrelated dirty file", at: "unrelated.txt")
        XCTAssertEqual(fixture.inspect().state, .matchesKnownUpstream)
        try fixture.write("new reference", at: "skills/folder-name/note.txt")
        try fixture.commit()
        XCTAssertEqual(fixture.inspect().state, .differsFromKnownUpstream)
    }

    func testIgnoredFilesPreventCleanStatus() throws {
        let fixture = try GitPublicationFixture()
        defer { fixture.remove() }
        try fixture.write("*.local\n", at: ".gitignore")
        try fixture.commit()
        try fixture.trackCurrentCommit()
        try fixture.write("ignored content", at: "skills/folder-name/notes.local")
        let result = fixture.inspect()
        XCTAssertEqual(result.state, .localChanges)
        XCTAssertTrue(result.detail.contains("ignored files"))
    }

    func testSkillAbsentFromKnownUpstreamIsAProvenDifference() throws {
        let fixture = try GitPublicationFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("skills"))
        try fixture.write("Repository", at: "README.md")
        try fixture.commit()
        try fixture.trackCurrentCommit()
        try fixture.write("---\nname: fresh-skill\ndescription: Test\n---\nBody", at: "skills/folder-name/SKILL.md")
        try fixture.commit()
        XCTAssertEqual(fixture.inspect().state, .differsFromKnownUpstream)
    }

    func testMissingUpstreamObjectIsNotReportedAsDifference() throws {
        let fixture = try GitPublicationFixture()
        defer { fixture.remove() }
        try fixture.commit()
        try fixture.trackCurrentCommit()
        let oldTree = try fixture.git(["rev-parse", "HEAD:skills/folder-name"])
        try fixture.write("---\nname: new-skill\ndescription: Test\n---\nNew body", at: "skills/folder-name/SKILL.md")
        try fixture.commit()
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent(
            ".git/objects/\(oldTree.prefix(2))/\(oldTree.dropFirst(2))"))
        XCTAssertEqual(fixture.inspect().state, .unavailable)
    }

    func testGitWorktreeWithGitFileIsSupported() throws {
        let fixture = try GitPublicationFixture()
        defer { fixture.remove() }
        try fixture.commit()
        let checkout = fixture.root.appendingPathComponent("linked-checkout")
        try fixture.git(["worktree", "add", "--detach", checkout.path])
        let catalog = SkillPublicationCatalog(id: "catalog", localRepositoryPath: checkout.path)
        let result = MetagentCore.inspectSkillPublicationGitForTesting(record: fixture.record, catalog: catalog)
        XCTAssertEqual(result.state, .noUpstream)
        XCTAssertNotNil(result.links)
    }

    func testAssumeUnchangedAndSkipWorktreeCannotClaimClean() throws {
        let fixture = try GitPublicationFixture()
        defer { fixture.remove() }
        try fixture.commit()
        try fixture.trackCurrentCommit()
        try fixture.git(["update-index", "--assume-unchanged", "skills/folder-name/SKILL.md"])
        XCTAssertEqual(fixture.inspect().state, .unavailable)
        try fixture.git(["update-index", "--no-assume-unchanged", "skills/folder-name/SKILL.md"])
        try fixture.git(["update-index", "--skip-worktree", "skills/folder-name/SKILL.md"])
        XCTAssertEqual(fixture.inspect().state, .unavailable)
    }

    func testDetachedCheckoutAndLocalUpstreamDoNotClaimPushed() throws {
        let fixture = try GitPublicationFixture()
        defer { fixture.remove() }
        try fixture.commit()
        try fixture.trackCurrentCommit()
        try fixture.git(["checkout", "--detach"])
        XCTAssertEqual(fixture.inspect().state, .noUpstream)
        try fixture.git(["checkout", "main"])
        try fixture.git(["branch", "local-copy"])
        try fixture.git(["branch", "--set-upstream-to=local-copy", "main"])
        XCTAssertEqual(fixture.inspect().state, .noUpstream)
    }

    func testMissingSkillTreeIsNotCommitted() throws {
        let fixture = try GitPublicationFixture()
        defer { fixture.remove() }
        try fixture.commit()
        let record = SkillPublicationRecord(id: "missing", sourceCanonicalPath: "/unused", skillName: "missing",
            catalogID: "catalog", destinationName: "missing")
        XCTAssertEqual(MetagentCore.inspectSkillPublicationGitForTesting(record: record, catalog: fixture.catalog).state, .notCommitted)
    }

    func testInvalidRepositoryAndTraversalAreUnavailable() throws {
        let fixture = try GitPublicationFixture()
        defer { fixture.remove() }
        let nested = SkillPublicationCatalog(id: "catalog", localRepositoryPath: fixture.root.appendingPathComponent("skills").path)
        XCTAssertEqual(MetagentCore.inspectSkillPublicationGitForTesting(record: fixture.record, catalog: nested).state, .unavailable)
        let unsafe = SkillPublicationRecord(id: "unsafe", sourceCanonicalPath: "/unused", skillName: "unsafe",
            catalogID: "catalog", destinationName: "../../elsewhere")
        XCTAssertEqual(MetagentCore.inspectSkillPublicationGitForTesting(record: unsafe, catalog: fixture.catalog).state, .unavailable)
        let rootMismatch = SkillPublicationCatalog(id: "other-catalog", localRepositoryPath: fixture.root.path)
        XCTAssertEqual(MetagentCore.inspectSkillPublicationGitForTesting(record: fixture.record, catalog: rootMismatch).state, .unavailable)
    }

    func testRepositoryFiltersAndFSMonitorAreNotExecuted() throws {
        let fixture = try GitPublicationFixture()
        defer { fixture.remove() }
        try fixture.commit()
        let marker = fixture.root.appendingPathComponent("executed-marker")
        try fixture.write("#!/bin/sh\ntouch '\(marker.path)'\ncat\n", at: "unsafe-hook.sh")
        let command = "/bin/sh '\(fixture.root.appendingPathComponent("unsafe-hook.sh").path)'"
        try fixture.git(["config", "filter.unsafe.clean", command])
        try fixture.git(["config", "filter.unsafe.process", command])
        try fixture.git(["config", "filter.unsafe.required", "true"])
        try fixture.git(["config", "core.fsmonitor", command])
        try fixture.write("skills/** filter=unsafe\n", at: ".gitattributes")
        try fixture.write("changed", at: "skills/folder-name/SKILL.md")
        let result = fixture.inspect()
        XCTAssertEqual(result.state, .unavailable)
        XCTAssertTrue(result.detail.contains("content filters"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testFSMonitorAloneIsNotExecuted() throws {
        let fixture = try GitPublicationFixture()
        defer { fixture.remove() }
        try fixture.commit()
        let marker = fixture.root.appendingPathComponent("executed-marker")
        try fixture.write("#!/bin/sh\ntouch '\(marker.path)'\n", at: "unsafe-hook.sh")
        try fixture.git(["config", "core.fsmonitor", "/bin/sh '\(fixture.root.appendingPathComponent("unsafe-hook.sh").path)'"])
        try fixture.write("changed", at: "skills/folder-name/SKILL.md")
        XCTAssertEqual(fixture.inspect().state, .localChanges)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testGlobalFiltersAndAttributesFailClosedWithoutExecutingHelper() throws {
        let fixture = try GitPublicationFixture()
        defer { fixture.remove() }
        try fixture.commit()
        let marker = fixture.root.appendingPathComponent("global-helper-executed")
        let attributes = fixture.root.appendingPathComponent("global-attributes")
        let config = fixture.root.appendingPathComponent("global-gitconfig")
        try fixture.write("skills/** filter=normalize\n", at: "global-attributes")
        try fixture.write("#!/bin/sh\ntouch '\(marker.path)'\ncat\n", at: "global-helper.sh")
        try fixture.write("""
            [core]
                attributesFile = \(attributes.path)
            [filter "normalize"]
                clean = /bin/sh '\(fixture.root.appendingPathComponent("global-helper.sh").path)'
                required = true
            """, at: "global-gitconfig")
        // Rewriting the file's bytes is enough to make status consult filters.
        let manifest = fixture.root.appendingPathComponent("skills/folder-name/SKILL.md")
        let text = try String(contentsOf: manifest, encoding: .utf8)
        try text.write(to: manifest, atomically: true, encoding: .utf8)
        for environment in [
            ["GIT_CONFIG_GLOBAL": config.path, "GIT_CONFIG_NOSYSTEM": "1"],
            ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": config.path],
        ] {
            let result = MetagentCore.inspectSkillPublicationGitForTesting(record: fixture.record, catalog: fixture.catalog,
                configurationEnvironment: environment)
            XCTAssertEqual(result.state, .unavailable)
            XCTAssertTrue(result.detail.contains("content filters"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testInjectedGitConfigurationAndRoutingAreNotForwarded() throws {
        let fixture = try GitPublicationFixture()
        defer { fixture.remove() }
        try fixture.commit()
        let result = MetagentCore.inspectSkillPublicationGitForTesting(record: fixture.record, catalog: fixture.catalog,
            configurationEnvironment: [
                "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_DIR": "/nonexistent-git-directory", "GIT_WORK_TREE": "/nonexistent-tree",
                "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "filter.fake.clean", "GIT_CONFIG_VALUE_0": "false",
            ])
        XCTAssertEqual(result.state, .noUpstream, result.detail)
    }

    func testPartialCloneMissingTreeCannotFetchOrRunRemoteHelper() throws {
        let fixture = try GitPublicationFixture()
        defer { fixture.remove() }
        try fixture.commit()
        let tree = try fixture.git(["rev-parse", "HEAD:skills/folder-name"])
        let objectPath = ".git/objects/\(tree.prefix(2))/\(tree.dropFirst(2))"
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent(objectPath))
        let marker = fixture.root.appendingPathComponent("remote-helper-executed")
        try fixture.git(["config", "remote.origin.promisor", "true"])
        try fixture.git(["config", "remote.origin.partialclonefilter", "blob:none"])
        try fixture.git(["config", "extensions.partialclone", "origin"])
        try fixture.git(["config", "protocol.ext.allow", "always"])
        try fixture.git(["remote", "set-url", "origin", "ext::touch \(marker.path)"])
        let result = fixture.inspect()
        XCTAssertEqual(result.state, .unavailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testLiteralPathDoesNotIncludeOtherSkills() throws {
        let fixture = try GitPublicationFixture()
        defer { fixture.remove() }
        try fixture.commit()
        try fixture.trackCurrentCommit()
        try fixture.write("untracked private skill", at: "skills/private-skill/SKILL.md")
        XCTAssertEqual(fixture.inspect().state, .matchesKnownUpstream)
    }

    func testCredentialRemoteIsNotEchoedAndStoredRemoteHintIsNotTrusted() throws {
        let fixture = try GitPublicationFixture()
        defer { fixture.remove() }
        try fixture.git(["remote", "set-url", "origin", "https://private-token@github.com/acme/skills"])
        let result = fixture.inspect()
        XCTAssertNil(result.links)
        XCTAssertFalse(result.detail.contains("private-token"))
        try fixture.git(["remote", "remove", "origin"])
        let stale = SkillPublicationCatalog(id: "catalog", localRepositoryPath: fixture.root.path,
            remoteURL: "https://github.com/stale/repository")
        XCTAssertNil(MetagentCore.inspectSkillPublicationGitForTesting(record: fixture.record, catalog: stale).links)
    }
}

private struct GitPublicationFixture {
    let root: URL
    let bareRemote: URL
    let record = SkillPublicationRecord(id: "record", sourceCanonicalPath: "/unused", skillName: "old-name",
        catalogID: "catalog", destinationName: "folder-name")
    var catalog: SkillPublicationCatalog { SkillPublicationCatalog(id: "catalog", localRepositoryPath: root.path) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("metagent-publication-git-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        bareRemote = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-publication-remote-\(UUID().uuidString).git")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "--initial-branch=main"])
        try git(["config", "user.name", "Publication Tests"])
        try git(["config", "user.email", "publication@example.invalid"])
        try git(["config", "commit.gpgsign", "false"])
        try git(["remote", "add", "origin", "https://github.com/acme/skills.git"])
        try write("---\nname: manifest-name\ndescription: A test skill.\n---\nTest content.\n", at: "skills/folder-name/SKILL.md")
    }

    func write(_ text: String, at path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func writeSkill(_ body: String) throws {
        try write("---\nname: manifest-name\ndescription: A test skill.\n---\n\(body)\n",
            at: "skills/folder-name/SKILL.md")
    }

    func removePath(_ path: String) throws {
        let url = root.appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    @discardableResult
    func git(_ arguments: [String]) throws -> String {
        let result = try runSubprocess(executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["-i", "PATH=/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null",
                "GIT_ALLOW_PROTOCOL=", "/usr/bin/git", "-c", "core.hooksPath=/dev/null", "-C", root.path]
                + arguments, timeout: 5)
        guard !result.timedOut, result.status == 0 else {
            throw NSError(domain: "GitPublicationFixture", code: Int(result.status), userInfo: [
                NSLocalizedDescriptionKey: String(decoding: result.standardError, as: UTF8.self),
            ])
        }
        return String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func commit() throws {
        try git(["add", "."])
        try git(["commit", "-m", "Test publication"])
    }

    func trackCurrentCommit() throws {
        try git(["update-ref", "refs/remotes/origin/main", "HEAD"])
        try git(["config", "branch.main.remote", "origin"])
        try git(["config", "branch.main.merge", "refs/heads/main"])
    }

    func configureBareRemote() throws {
        let result = try runSubprocess(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [
                "-i", "PATH=/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null",
                "GIT_ALLOW_PROTOCOL=file", "/usr/bin/git", "clone", "--bare", root.path, bareRemote.path,
            ],
            timeout: 10
        )
        guard !result.timedOut, result.status == 0 else {
            throw NSError(domain: "GitPublicationFixture", code: Int(result.status))
        }
        try git(["remote", "set-url", "origin", bareRemote.path])
        try git(["config", "branch.main.remote", "origin"])
        try git(["config", "branch.main.merge", "refs/heads/main"])
        try git(["update-ref", "refs/remotes/origin/main", "HEAD"])
    }

    func bareGit(_ arguments: [String]) throws -> String {
        let result = try runSubprocess(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [
                "-i", "PATH=/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null",
                "/usr/bin/git", "--git-dir", bareRemote.path,
            ] + arguments,
            timeout: 5
        )
        guard !result.timedOut, result.status == 0 else {
            throw NSError(domain: "GitPublicationFixture", code: Int(result.status), userInfo: [
                NSLocalizedDescriptionKey: String(decoding: result.standardError, as: UTF8.self),
            ])
        }
        return String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func rejectPushes() throws {
        let hook = bareRemote.appendingPathComponent("hooks/pre-receive")
        try "#!/bin/sh\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
    }

    func allowPushes() throws {
        let hook = bareRemote.appendingPathComponent("hooks/pre-receive")
        if FileManager.default.fileExists(atPath: hook.path) {
            try FileManager.default.removeItem(at: hook)
        }
    }

    func preparePublish() -> SkillPublicationPublishPreview {
        MetagentCore.prepareSkillPublicationPublishForTesting(record: record, catalog: catalog)
    }

    func publish(_ preview: SkillPublicationPublishPreview, message: String) -> SkillPublicationPublishResult {
        MetagentCore.commitAndPublishSkillForTesting(
            preview: preview, record: record, catalog: catalog, commitMessage: message
        )
    }

    func inspect() -> SkillPublicationGitStatus {
        MetagentCore.inspectSkillPublicationGitForTesting(record: record, catalog: catalog,
            now: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: bareRemote)
    }
}
