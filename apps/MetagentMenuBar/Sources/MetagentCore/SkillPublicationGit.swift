import Foundation

/// These are local Git observations, never proof that a repository is public or
/// that skills.sh has indexed a skill. No fetch, push, or install is performed.
public enum SkillPublicationGitState: String, Equatable, Sendable {
    case unavailable
    case localChanges
    case notCommitted
    case noUpstream
    case differsFromKnownUpstream
    case matchesKnownUpstream

    public var title: String {
        switch self {
        case .unavailable: "Git status unavailable"
        case .localChanges: "Local changes to commit"
        case .notCommitted: "Not committed"
        case .noUpstream: "Committed; no remote tracking branch"
        case .differsFromKnownUpstream: "Differs from known upstream"
        case .matchesKnownUpstream: "Matches known upstream"
        }
    }
}

public struct SkillPublicationGitStatus: Equatable, Sendable {
    public let state: SkillPublicationGitState
    public let checkedAt: Date
    public let detail: String
    public let checkoutCommit: String?
    public let upstreamCommit: String?
    public let links: SkillPublicationLinks?
    public let suggestedPublishAction: SkillPublicationPublishAction?
}

public enum SkillPublicationPublishAction: String, Equatable, Sendable {
    case publish
    case update
    case retryPush

    public var title: String {
        switch self {
        case .publish: "Publish"
        case .update: "Publish Update"
        case .retryPush: "Retry Publish"
        }
    }
}

public enum SkillPublicationChangeKind: String, Equatable, Hashable, Sendable {
    case added
    case modified
    case deleted
}

public struct SkillPublicationChange: Equatable, Hashable, Sendable, Identifiable {
    public let path: String
    public let kind: SkillPublicationChangeKind

    public var id: String { "\(kind.rawValue):\(path)" }
}

/// An immutable approval envelope for one explicit commit and push. Execution
/// re-derives every field before changing a ref, so a source sync, Git action,
/// branch switch, or remote update invalidates the preview.
public struct SkillPublicationPublishPreview: Equatable, Sendable {
    public let action: SkillPublicationPublishAction?
    public let repositoryPath: String
    public let repositoryURL: URL?
    public let pushDestination: String?
    public let branch: String?
    public let destinationPath: String
    public let baseCommit: String?
    public let remoteCommit: String?
    public let plannedTree: String?
    public let commitToPush: String?
    public let changes: [SkillPublicationChange]
    public let blocker: String?

    public var isReady: Bool { blocker == nil && action != nil }
}

public enum SkillPublicationPublishOutcome: String, Equatable, Sendable {
    case published
    case committedLocally
    case outcomeUnknown
    case previewExpired
    case blocked
}

public struct SkillPublicationPublishResult: Equatable, Sendable {
    public let outcome: SkillPublicationPublishOutcome
    public let message: String
    public let commit: String?

    public init(outcome: SkillPublicationPublishOutcome, message: String, commit: String?) {
        self.outcome = outcome
        self.message = message
        self.commit = commit
    }

    public var succeeded: Bool { outcome == .published }
}

/// Only canonical, credential-free github.com sources produce shareable links.
public struct SkillPublicationLinks: Equatable, Sendable {
    public let repositoryURL: URL
    public let skillsURL: URL
    public let installCommand: String

    public init?(remoteURL: String, skillName: String) {
        let path: String
        if remoteURL.hasPrefix("git@github.com:") {
            path = String(remoteURL.dropFirst("git@github.com:".count))
        } else {
            guard let url = URLComponents(string: remoteURL),
                  url.host == "github.com", url.port == nil,
                  url.password == nil, url.query == nil, url.fragment == nil,
                  (url.scheme == "https" && url.user == nil)
                    || (url.scheme == "ssh" && url.user == "git")
            else { return nil }
            path = String(url.percentEncodedPath.dropFirst())
        }
        let repositoryPath = path.hasSuffix(".git") ? String(path.dropLast(4)) : path
        let components = repositoryPath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2,
              components.allSatisfy({ Self.isSafeName(String($0)) }),
              Self.isSafeName(skillName),
              let repositoryURL = URL(string: "https://github.com/\(repositoryPath)"),
              let skillsURL = URL(string: "https://skills.sh/\(repositoryPath)/\(skillName)")
        else { return nil }
        self.repositoryURL = repositoryURL
        self.skillsURL = skillsURL
        self.installCommand = "npx skills add \(repositoryPath) --skill \(skillName)"
    }

    private static func isSafeName(_ name: String) -> Bool {
        name.range(of: #"\A[A-Za-z0-9][A-Za-z0-9._-]*\z"#, options: .regularExpression) != nil
            && name != "." && name != ".." && name.count <= 100
    }
}

public extension MetagentCore {
    /// Explicit, on-demand check, capped at five seconds for the entire skill.
    /// It reads only the selected subtree and locally stored tracking refs.
    static func inspectSkillPublicationGit(
        record: SkillPublicationRecord,
        catalog: SkillPublicationCatalog,
        now: Date = Date()
    ) -> SkillPublicationGitStatus {
        inspectSkillPublicationGit(record: record, catalog: catalog, now: now,
            configurationEnvironment: ProcessInfo.processInfo.environment)
    }

    internal static func inspectSkillPublicationGitForTesting(
        record: SkillPublicationRecord,
        catalog: SkillPublicationCatalog,
        now: Date = Date(),
        configurationEnvironment: [String: String] = [
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
        ]
    ) -> SkillPublicationGitStatus {
        inspectSkillPublicationGit(record: record, catalog: catalog, now: now,
            configurationEnvironment: configurationEnvironment)
    }

    private static func inspectSkillPublicationGit(
        record: SkillPublicationRecord,
        catalog: SkillPublicationCatalog,
        now: Date,
        configurationEnvironment: [String: String]
    ) -> SkillPublicationGitStatus {
        let repository = URL(fileURLWithPath: catalog.localRepositoryPath).standardizedFileURL
        let relativePath = "\(catalog.skillsRelativePath)/\(record.destinationName)"
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard record.catalogID == catalog.id,
              !components.isEmpty,
              components.allSatisfy({ component in
                  !component.isEmpty && component != "." && component != ".."
                    && !component.contains(where: { $0.isNewline || $0 == "\0" })
              }),
              fileManager.fileExists(atPath: repository.appendingPathComponent(".git").path),
              repository.resolvingSymlinksInPath() == repository
        else {
            return SkillPublicationGitStatus(
                state: .unavailable, checkedAt: now,
                detail: "Choose the original, non-symlinked repository checkout.",
                checkoutCommit: nil, upstreamCommit: nil, links: nil, suggestedPublishAction: nil
            )
        }

        let deadline = ProcessInfo.processInfo.systemUptime + 5
        // Preserve only existing configuration-location variables so attribute
        // semantics and the filter probe agree with the user's Git. Never pass
        // inherited Git routing, injected config entries, tokens, or helpers.
        let configurationLocations = [
            "HOME", "XDG_CONFIG_HOME", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_CONFIG_NOSYSTEM",
        ].compactMap { name in configurationEnvironment[name].map { "\(name)=\($0)" } }
        func git(_ arguments: [String]) throws -> SubprocessResult {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw PublicationGitError.unavailable }
            // Ignore inherited Git routing and suppress fsmonitor hooks,
            // index writes, external diffs, and partial-clone lazy fetching.
            let result = try runSubprocess(
                executable: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["-i", "PATH=/usr/bin:/bin"] + configurationLocations + [
                    "GIT_NO_LAZY_FETCH=1",
                    "GIT_OPTIONAL_LOCKS=0", "GIT_TERMINAL_PROMPT=0", "GIT_ALLOW_PROTOCOL=",
                    "/usr/bin/git", "--no-optional-locks", "-c", "core.fsmonitor=false",
                    "-c", "core.hooksPath=/dev/null", "-C", repository.path,
                ] + arguments,
                timeout: remaining
            )
            guard !result.timedOut else { throw PublicationGitError.unavailable }
            return result
        }
        func output(_ arguments: [String]) throws -> String? {
            let result = try git(arguments)
            guard result.status == 0 else { return nil }
            return String(decoding: result.standardOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var links: SkillPublicationLinks?
        var checkoutCommit: String?
        var suggestedPublishAction: SkillPublicationPublishAction?
        func status(_ state: SkillPublicationGitState, _ detail: String, upstream: String? = nil)
            -> SkillPublicationGitStatus {
            SkillPublicationGitStatus(
                state: state, checkedAt: now, detail: detail,
                checkoutCommit: checkoutCommit, upstreamCommit: upstream, links: links,
                suggestedPublishAction: suggestedPublishAction
            )
        }

        do {
            guard let reportedRoot = try output(["rev-parse", "--show-toplevel"]),
                  URL(fileURLWithPath: reportedRoot).resolvingSymlinksInPath().standardizedFileURL.path
                    == repository.resolvingSymlinksInPath().standardizedFileURL.path else {
                throw PublicationGitError.unavailable
            }
            if let remote = try output(["config", "--get", "remote.origin.url"]) {
                let skillDirectory = repository.appendingPathComponent(relativePath)
                let manifest = skillDirectory.appendingPathComponent("SKILL.md")
                let values = try? manifest.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if skillDirectory.resolvingSymlinksInPath() == skillDirectory,
                   manifest.resolvingSymlinksInPath() == manifest,
                   values?.isRegularFile == true, (values?.fileSize ?? Int.max) <= 1_048_576,
                   let document = try? loadSkillDocument(at: skillDirectory.path) {
                    links = SkillPublicationLinks(remoteURL: remote, skillName: document.name)
                }
            }
            checkoutCommit = try output(["rev-parse", "--verify", "HEAD"])
            suggestedPublishAction = try output(["rev-parse", "--verify", "HEAD:\(relativePath)"]) == nil
                ? .publish : .update
            // Even `git status` can execute configured clean/process filters.
            // Fail closed rather than execute them or change their semantics.
            let filterConfig = try git(["config", "--null", "--name-only", "--get-regexp", "^filter\\."])
            guard filterConfig.status == 0 || filterConfig.status == 1 else {
                throw PublicationGitError.unavailable
            }
            guard filterConfig.standardOutput.isEmpty else {
                return status(.unavailable, "This repository configures Git content filters. Metagent does not run those helpers; inspect its status in Git yourself.")
            }
            let pathspec = ":(literal)\(relativePath)"
            let pending = try git([
                "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=matching",
                "--ignore-submodules=all",
                "--", pathspec,
            ])
            guard pending.status == 0 else { throw PublicationGitError.unavailable }
            if !pending.standardOutput.isEmpty {
                let ignored = pending.standardOutput.split(separator: 0).contains { $0.starts(with: [33, 33, 32]) }
                return status(.localChanges, ignored
                    ? "This skill has ignored files. Review Git ignore rules before committing; ignored files will not be published."
                    : "Review and commit this skill's staged, unstaged, or untracked files, then push when ready.")
            }
            // Git status can hide changes behind these index flags. Do not
            // report a clean/public copy unless all selected entries are checked.
            let flags = try git(["ls-files", "-v", "--stage", "-z", "--", pathspec])
            guard flags.status == 0,
                  flags.standardOutput.split(separator: 0).allSatisfy({ entry in
                      let metadata = String(decoding: entry, as: UTF8.self)
                          .split(separator: "\t", maxSplits: 1).first?.split(separator: " ") ?? []
                      return metadata.count == 4 && metadata[0] == "H"
                          && ["100644", "100755"].contains(metadata[1]) && metadata[3] == "0"
                  })
            else {
                return status(.unavailable, "Some skill files have skipped index checks or unsupported Git modes. Review assume-unchanged, skip-worktree, symlinks, and submodules before checking again.")
            }
            guard checkoutCommit != nil, !flags.standardOutput.isEmpty else {
                return status(.notCommitted, "Commit the selected skill before sharing its install command.")
            }
            guard let localTree = try output(["rev-parse", "--verify", "HEAD:\(relativePath)"]),
                  try output(["cat-file", "-t", localTree]) == "tree"
            else { return status(.unavailable, "Committed skill data is missing or unsupported locally. Repair or fetch the checkout yourself, then check again.") }

            guard let upstreamRef = try output(["rev-parse", "--symbolic-full-name", "@{upstream}"]),
                  upstreamRef.hasPrefix("refs/remotes/"),
                  let upstreamCommit = try output(["rev-parse", "--verify", "@{upstream}"])
            else {
                return status(.noUpstream, "Set a remote tracking branch after pushing. Detached checkouts cannot show push status.")
            }
            // An empty successful listing proves absence; a failed lookup can
            // instead mean a missing partial-clone object and is not a diff.
            let upstreamListing = try git(["ls-tree", "-z", upstreamCommit, "--", pathspec])
            guard upstreamListing.status == 0 else { throw PublicationGitError.unavailable }
            let entries = String(decoding: upstreamListing.standardOutput, as: UTF8.self).split(separator: "\0")
            guard entries.count <= 1 else { throw PublicationGitError.unavailable }
            var upstreamTree: String?
            if let entry = entries.first {
                let metadata = entry.split(separator: "\t", maxSplits: 1).first?.split(separator: " ") ?? []
                guard metadata.count == 3, metadata[1] == "tree" else { throw PublicationGitError.unavailable }
                let tree = String(metadata[2])
                guard try output(["cat-file", "-t", tree]) == "tree" else {
                    throw PublicationGitError.unavailable
                }
                upstreamTree = tree
            }
            return status(localTree == upstreamTree ? .matchesKnownUpstream : .differsFromKnownUpstream,
                "Compared this skill only with a locally stored remote tracking ref. No fetch was run; GitHub visibility, current push status, and skills.sh indexing are not verified.",
                upstream: upstreamCommit)
        } catch {
            // Never surface Git stderr or raw remotes: they can contain secrets.
            return status(.unavailable, "The local Git check could not complete. Repository data may be incomplete or the check may have timed out. Inspect the repository and try again.")
        }
    }

    /// Performs the network read required for a trustworthy publish preview.
    /// It never changes the working tree, index, refs, or remote repository.
    static func prepareSkillPublicationPublish(
        record: SkillPublicationRecord,
        catalog: SkillPublicationCatalog
    ) -> SkillPublicationPublishPreview {
        prepareSkillPublicationPublish(
            record: record,
            catalog: catalog,
            configurationEnvironment: ProcessInfo.processInfo.environment,
            requireGitHubRemote: true
        )
    }

    internal static func prepareSkillPublicationPublishForTesting(
        record: SkillPublicationRecord,
        catalog: SkillPublicationCatalog,
        configurationEnvironment: [String: String] = [
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
        ]
    ) -> SkillPublicationPublishPreview {
        prepareSkillPublicationPublish(
            record: record,
            catalog: catalog,
            configurationEnvironment: configurationEnvironment,
            requireGitHubRemote: false
        )
    }

    static func commitAndPublishSkill(
        preview: SkillPublicationPublishPreview,
        record: SkillPublicationRecord,
        catalog: SkillPublicationCatalog,
        commitMessage: String
    ) -> SkillPublicationPublishResult {
        commitAndPublishSkill(
            preview: preview,
            record: record,
            catalog: catalog,
            commitMessage: commitMessage,
            configurationEnvironment: ProcessInfo.processInfo.environment,
            requireGitHubRemote: true
        )
    }

    internal static func commitAndPublishSkillForTesting(
        preview: SkillPublicationPublishPreview,
        record: SkillPublicationRecord,
        catalog: SkillPublicationCatalog,
        commitMessage: String,
        configurationEnvironment: [String: String] = [
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
        ]
    ) -> SkillPublicationPublishResult {
        commitAndPublishSkill(
            preview: preview,
            record: record,
            catalog: catalog,
            commitMessage: commitMessage,
            configurationEnvironment: configurationEnvironment,
            requireGitHubRemote: false
        )
    }

    private static func prepareSkillPublicationPublish(
        record: SkillPublicationRecord,
        catalog: SkillPublicationCatalog,
        configurationEnvironment: [String: String],
        requireGitHubRemote: Bool
    ) -> SkillPublicationPublishPreview {
        let repositoryPath = URL(fileURLWithPath: catalog.localRepositoryPath).standardizedFileURL.path
        let destinationPath = "\(catalog.skillsRelativePath)/\(record.destinationName)"
        func blocked(_ message: String) -> SkillPublicationPublishPreview {
            SkillPublicationPublishPreview(
                action: nil,
                repositoryPath: repositoryPath,
                repositoryURL: nil,
                pushDestination: nil,
                branch: nil,
                destinationPath: destinationPath,
                baseCommit: nil,
                remoteCommit: nil,
                plannedTree: nil,
                commitToPush: nil,
                changes: [],
                blocker: message
            )
        }

        do {
            let repository = try PublicationGitRepository(
                record: record,
                catalog: catalog,
                configurationEnvironment: configurationEnvironment,
                allowFileNetwork: !requireGitHubRemote
            )
            let remote = try repository.remote(requireGitHub: requireGitHubRemote)
            let branch = try repository.currentBranch()
            let upstream = try repository.output(["rev-parse", "--symbolic-full-name", "@{upstream}"])
            guard upstream == "refs/remotes/origin/\(branch)" else {
                return blocked("This branch must track origin/\(branch) before Metagent can publish it.")
            }
            let head = try repository.requiredObject(["rev-parse", "--verify", "HEAD"])
            guard let remoteHead = try repository.remoteHead(remote.fetchURL, branch: branch) else {
                return blocked("The remote branch does not exist yet. Push the repository's existing history yourself, then try again.")
            }

            guard try !repository.hasContentFilters() else {
                return blocked("This repository configures Git content filters. Publish it manually so Metagent never executes those helpers.")
            }
            let dirtyPaths = try repository.dirtyPaths()
            guard dirtyPaths.allSatisfy({ repository.contains($0, in: destinationPath) }) else {
                return blocked("This checkout has changes outside \(destinationPath). Commit, discard, or move those changes before publishing this skill.")
            }
            guard try !repository.hasIgnoredFiles(in: destinationPath) else {
                return blocked("This skill contains ignored files. Review the repository's ignore rules before publishing.")
            }
            if head != remoteHead {
                let parent = try repository.output(["rev-parse", "--verify", "HEAD^"])
                let message = try repository.output(["log", "-1", "--format=%B", "HEAD"])
                let committedPaths = try repository.changedPaths(from: remoteHead, to: head)
                let retryMarker = "Metagent-Skill-Publication: \(record.id)"
                guard parent == remoteHead,
                      message.split(separator: "\n").contains(where: { $0 == Substring(retryMarker) }),
                      !committedPaths.isEmpty,
                      committedPaths.allSatisfy({ repository.contains($0, in: destinationPath) }),
                      dirtyPaths.isEmpty
                else {
                    return blocked("The local and remote branch histories differ. Resolve or publish those commits yourself; Metagent will not rebase, force-push, or include unrelated commits.")
                }
                let plannedTree = try repository.requiredObject(["rev-parse", "--verify", "HEAD^{tree}"])
                let changes = try repository.changes(from: remoteHead, to: plannedTree, destinationPath: destinationPath)
                return SkillPublicationPublishPreview(
                    action: .retryPush,
                    repositoryPath: repository.root.path,
                    repositoryURL: remote.repositoryURL,
                    pushDestination: remote.pushURL,
                    branch: branch,
                    destinationPath: destinationPath,
                    baseCommit: parent,
                    remoteCommit: remoteHead,
                    plannedTree: plannedTree,
                    commitToPush: head,
                    changes: changes,
                    blocker: nil
                )
            }

            let plannedTree = try repository.plannedTree(baseCommit: head, destinationPath: destinationPath)
            let changes = try repository.changes(from: head, to: plannedTree, destinationPath: destinationPath)
            guard !changes.isEmpty else {
                return blocked("The mirrored skill already matches the remote branch. There is nothing to publish.")
            }
            try repository.validatePublishedTree(plannedTree, destinationPath: destinationPath)
            let existed = try repository.objectExists("HEAD:\(destinationPath)")
            return SkillPublicationPublishPreview(
                action: existed ? .update : .publish,
                repositoryPath: repository.root.path,
                repositoryURL: remote.repositoryURL,
                pushDestination: remote.pushURL,
                branch: branch,
                destinationPath: destinationPath,
                baseCommit: head,
                remoteCommit: remoteHead,
                plannedTree: plannedTree,
                commitToPush: nil,
                changes: changes,
                blocker: nil
            )
        } catch {
            return blocked("Metagent could not safely inspect this repository. Check its Git configuration, network access, and branch tracking, then try again.")
        }
    }

    private static func commitAndPublishSkill(
        preview: SkillPublicationPublishPreview,
        record: SkillPublicationRecord,
        catalog: SkillPublicationCatalog,
        commitMessage: String,
        configurationEnvironment: [String: String],
        requireGitHubRemote: Bool
    ) -> SkillPublicationPublishResult {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard preview.isReady, !message.isEmpty, message.count <= 200,
              !message.contains(where: { $0.isNewline || $0 == "\0" })
        else {
            return SkillPublicationPublishResult(
                outcome: .blocked,
                message: "Enter a commit message between 1 and 200 characters.",
                commit: nil
            )
        }
        let fresh = prepareSkillPublicationPublish(
            record: record,
            catalog: catalog,
            configurationEnvironment: configurationEnvironment,
            requireGitHubRemote: requireGitHubRemote
        )
        guard fresh == preview else {
            return SkillPublicationPublishResult(
                outcome: .previewExpired,
                message: "The skill, branch, or remote changed after this preview. Review the refreshed publication before committing.",
                commit: nil
            )
        }
        guard let branch = preview.branch,
              let pushDestination = preview.pushDestination,
              let baseCommit = preview.baseCommit,
              let remoteCommit = preview.remoteCommit,
              let plannedTree = preview.plannedTree
        else {
            return SkillPublicationPublishResult(outcome: .blocked, message: "The publication preview is incomplete.", commit: nil)
        }

        do {
            let repository = try PublicationGitRepository(
                record: record,
                catalog: catalog,
                configurationEnvironment: configurationEnvironment,
                allowFileNetwork: !requireGitHubRemote
            )
            let commit: String
            if let existingCommit = preview.commitToPush {
                commit = existingCommit
            } else {
                let commitText = "\(message)\n\nMetagent-Skill-Publication: \(record.id)\n"
                commit = try repository.requiredObject(
                    ["commit-tree", plannedTree, "-p", baseCommit],
                    standardInput: Data(commitText.utf8)
                )
                let update = try repository.git([
                    "update-ref", "refs/heads/\(branch)", commit, baseCommit,
                ])
                guard update.status == 0 else {
                    return SkillPublicationPublishResult(
                        outcome: .previewExpired,
                        message: "The branch changed before Metagent could record the approved commit. Review a fresh preview.",
                        commit: nil
                    )
                }
                // The commit was built from a private temporary index. Align
                // only the selected subtree in the real index; unrelated index
                // entries are never reset or staged.
                let align = try repository.git([
                    "reset", "--mixed", commit, "--", ":(literal)\(preview.destinationPath)",
                ])
                guard align.status == 0 else {
                    return SkillPublicationPublishResult(
                        outcome: .committedLocally,
                        message: "The approved commit was created locally, but Git could not refresh this skill's index. Inspect the checkout before retrying the push.",
                        commit: commit
                    )
                }
            }

            let push = try repository.git(
                ["push", "--porcelain", "--", pushDestination, "\(commit):refs/heads/\(branch)"],
                network: true,
                timeout: 60
            )
            if !push.timedOut, push.status == 0 {
                repository.advanceKnownUpstream(branch: branch, from: remoteCommit, to: commit)
                return SkillPublicationPublishResult(
                    outcome: .published,
                    message: "Published commit \(commit.prefix(8)) to \(branch). GitHub visibility and skills.sh indexing still need verification.",
                    commit: commit
                )
            }

            do {
                let observed = try repository.remoteHead(pushDestination, branch: branch)
                if observed == commit {
                    repository.advanceKnownUpstream(branch: branch, from: remoteCommit, to: commit)
                    return SkillPublicationPublishResult(
                        outcome: .published,
                        message: "The push response was interrupted, but the approved commit is present on the remote branch.",
                        commit: commit
                    )
                }
                if observed == remoteCommit {
                    return SkillPublicationPublishResult(
                        outcome: .committedLocally,
                        message: "The approved commit is saved locally, but the push did not complete. Fix authentication or connectivity, then use Retry Publish; Metagent will retry this exact commit.",
                        commit: commit
                    )
                }
                return SkillPublicationPublishResult(
                    outcome: .outcomeUnknown,
                    message: "The approved commit is saved locally, but the remote branch changed during the push. Inspect both commits before continuing; Metagent will not force-push.",
                    commit: commit
                )
            } catch {
                return SkillPublicationPublishResult(
                    outcome: .outcomeUnknown,
                    message: "The approved commit is saved locally, but Metagent could not determine whether the push completed. Check the remote branch before retrying.",
                    commit: commit
                )
            }
        } catch {
            return SkillPublicationPublishResult(
                outcome: .blocked,
                message: "Metagent could not safely complete this publication. No automatic rollback, rebase, or force-push was attempted.",
                commit: preview.commitToPush
            )
        }
    }
}

private struct PublicationGitRemote {
    let fetchURL: String
    let pushURL: String
    let repositoryURL: URL?
}

private struct PublicationGitRepository {
    let root: URL
    let relativePath: String
    let configurationEnvironment: [String: String]
    let allowFileNetwork: Bool

    init(
        record: SkillPublicationRecord,
        catalog: SkillPublicationCatalog,
        configurationEnvironment: [String: String],
        allowFileNetwork: Bool
    ) throws {
        root = URL(fileURLWithPath: catalog.localRepositoryPath).standardizedFileURL
        relativePath = "\(catalog.skillsRelativePath)/\(record.destinationName)"
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard record.catalogID == catalog.id,
              !record.id.isEmpty, record.id.count <= 200,
              !record.id.contains(where: { $0.isNewline || $0 == "\0" }),
              !components.isEmpty,
              components.allSatisfy({ component in
                  !component.isEmpty && component != "." && component != ".."
                    && !component.contains(where: { $0.isNewline || $0 == "\0" })
              }),
              root.resolvingSymlinksInPath() == root,
              fileManager.fileExists(atPath: root.appendingPathComponent(".git").path)
        else { throw PublicationGitError.unavailable }
        self.configurationEnvironment = configurationEnvironment
        self.allowFileNetwork = allowFileNetwork
        let reportedRoot = try output(["rev-parse", "--show-toplevel"])
        guard URL(fileURLWithPath: reportedRoot).resolvingSymlinksInPath().standardizedFileURL == root else {
            throw PublicationGitError.unavailable
        }
    }

    func git(
        _ arguments: [String],
        network: Bool = false,
        timeout: TimeInterval = 10,
        standardInput: Data? = nil,
        extraEnvironment: [String] = []
    ) throws -> SubprocessResult {
        let configurationLocations = [
            "HOME", "XDG_CONFIG_HOME", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_CONFIG_NOSYSTEM",
            "SSH_AUTH_SOCK",
        ].compactMap { name in configurationEnvironment[name].map { "\(name)=\($0)" } }
        let protocols = network ? (allowFileNetwork ? "https:ssh:file" : "https:ssh") : ""
        return try runSubprocess(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["-i", "PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"]
                + configurationLocations
                + extraEnvironment
                + [
                    "GIT_NO_LAZY_FETCH=1", "GIT_OPTIONAL_LOCKS=0", "GIT_TERMINAL_PROMPT=0",
                    "GIT_ALLOW_PROTOCOL=\(protocols)",
                    "/usr/bin/git", "--no-optional-locks", "-c", "core.fsmonitor=false",
                    "-c", "core.hooksPath=/dev/null", "-C", root.path,
                ] + arguments,
            standardInput: standardInput,
            timeout: timeout
        )
    }

    func output(_ arguments: [String]) throws -> String {
        let result = try git(arguments)
        guard !result.timedOut, result.status == 0 else { throw PublicationGitError.unavailable }
        return String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func requiredObject(_ arguments: [String], standardInput: Data? = nil) throws -> String {
        let value: String
        if let standardInput {
            let result = try git(arguments, standardInput: standardInput)
            guard !result.timedOut, result.status == 0 else { throw PublicationGitError.unavailable }
            value = String(decoding: result.standardOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            value = try output(arguments)
        }
        guard (value.count == 40 || value.count == 64), value.allSatisfy(\.isHexDigit) else {
            throw PublicationGitError.unavailable
        }
        return value
    }

    func currentBranch() throws -> String {
        let branch = try output(["symbolic-ref", "--quiet", "--short", "HEAD"])
        guard !branch.isEmpty, !branch.hasPrefix("-"),
              !branch.contains(where: { $0.isNewline || $0 == "\0" })
        else { throw PublicationGitError.unavailable }
        let check = try git(["check-ref-format", "--branch", branch])
        guard check.status == 0 else { throw PublicationGitError.unavailable }
        return branch
    }

    func remote(requireGitHub: Bool) throws -> PublicationGitRemote {
        let fetchURLs = try output(["remote", "get-url", "--all", "origin"])
            .split(separator: "\n").map(String.init)
        let pushURLs = try output(["remote", "get-url", "--all", "--push", "origin"])
            .split(separator: "\n").map(String.init)
        guard fetchURLs.count == 1, pushURLs.count == 1 else { throw PublicationGitError.unavailable }
        if requireGitHub {
            guard let fetch = SkillPublicationLinks(remoteURL: fetchURLs[0], skillName: "metagent-check"),
                  let push = SkillPublicationLinks(remoteURL: pushURLs[0], skillName: "metagent-check"),
                  fetch.repositoryURL == push.repositoryURL
            else { throw PublicationGitError.unavailable }
            return PublicationGitRemote(
                fetchURL: fetchURLs[0], pushURL: pushURLs[0], repositoryURL: fetch.repositoryURL
            )
        }
        guard fetchURLs[0] == pushURLs[0] else { throw PublicationGitError.unavailable }
        return PublicationGitRemote(fetchURL: fetchURLs[0], pushURL: pushURLs[0], repositoryURL: nil)
    }

    func remoteHead(_ remoteURL: String, branch: String) throws -> String? {
        let result = try git(
            ["ls-remote", "--exit-code", "--", remoteURL, "refs/heads/\(branch)"],
            network: true,
            timeout: 30
        )
        if result.status == 2 { return nil }
        guard !result.timedOut, result.status == 0 else { throw PublicationGitError.unavailable }
        let lines = String(decoding: result.standardOutput, as: UTF8.self)
            .split(separator: "\n")
        guard lines.count == 1,
              let commit = lines[0].split(separator: "\t").first.map(String.init),
              (commit.count == 40 || commit.count == 64), commit.allSatisfy(\.isHexDigit)
        else { throw PublicationGitError.unavailable }
        return commit
    }

    func advanceKnownUpstream(branch: String, from oldCommit: String, to newCommit: String) {
        _ = try? git([
            "update-ref", "refs/remotes/origin/\(branch)", newCommit, oldCommit,
        ])
    }

    func dirtyPaths() throws -> [String] {
        let result = try git([
            "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=all",
        ])
        guard result.status == 0 else { throw PublicationGitError.unavailable }
        return try parsePorcelainPaths(result.standardOutput)
    }

    func hasIgnoredFiles(in destinationPath: String) throws -> Bool {
        let result = try git([
            "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=matching",
            "--ignore-submodules=all", "--", ":(literal)\(destinationPath)",
        ])
        guard result.status == 0 else { throw PublicationGitError.unavailable }
        var fields = result.standardOutput.split(separator: 0, omittingEmptySubsequences: true)
        while !fields.isEmpty {
            let entry = fields.removeFirst()
            guard entry.count >= 3 else { throw PublicationGitError.unavailable }
            if entry.starts(with: [33, 33, 32]) { return true }
            let status = entry.prefix(2)
            if status.contains(82) || status.contains(67) {
                guard !fields.isEmpty else { throw PublicationGitError.unavailable }
                fields.removeFirst()
            }
        }
        return false
    }

    func hasContentFilters() throws -> Bool {
        let result = try git(["config", "--null", "--name-only", "--get-regexp", "^filter\\."])
        guard result.status == 0 || result.status == 1 else { throw PublicationGitError.unavailable }
        return !result.standardOutput.isEmpty
    }

    func plannedTree(baseCommit: String, destinationPath: String) throws -> String {
        let index = fileManager.temporaryDirectory
            .appendingPathComponent("metagent-publication-index-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: index) }
        let environment = ["GIT_INDEX_FILE=\(index.path)"]
        let read = try git(["read-tree", baseCommit], extraEnvironment: environment)
        guard read.status == 0 else { throw PublicationGitError.unavailable }
        let add = try git([
            "add", "-A", "--", ":(literal)\(destinationPath)",
        ], extraEnvironment: environment)
        guard add.status == 0 else { throw PublicationGitError.unavailable }
        let result = try git(["write-tree"], extraEnvironment: environment)
        guard result.status == 0 else { throw PublicationGitError.unavailable }
        let tree = String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard (tree.count == 40 || tree.count == 64), tree.allSatisfy(\.isHexDigit) else {
            throw PublicationGitError.unavailable
        }
        return tree
    }

    func changes(from base: String, to tree: String, destinationPath: String) throws -> [SkillPublicationChange] {
        let result = try git([
            "diff-tree", "--no-commit-id", "--name-status", "-r", base, tree,
            "--", ":(literal)\(destinationPath)",
        ])
        guard result.status == 0 else { throw PublicationGitError.unavailable }
        let lines = String(decoding: result.standardOutput, as: UTF8.self).split(separator: "\n")
        return try lines.map { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let status = parts.first?.first,
                  let path = parts.last.map(String.init),
                  contains(path, in: destinationPath),
                  !path.contains(where: { $0.isNewline || $0 == "\0" || $0 == "\t" })
            else { throw PublicationGitError.unavailable }
            let kind: SkillPublicationChangeKind
            switch status {
            case "A": kind = .added
            case "D": kind = .deleted
            default: kind = .modified
            }
            return SkillPublicationChange(path: path, kind: kind)
        }
    }

    func changedPaths(from base: String, to commit: String) throws -> [String] {
        let result = try git(["diff", "--name-only", "-z", base, commit])
        guard result.status == 0 else { throw PublicationGitError.unavailable }
        return try result.standardOutput.split(separator: 0).map { bytes in
            let path = String(decoding: bytes, as: UTF8.self)
            guard !path.contains(where: { $0.isNewline || $0 == "\0" }) else {
                throw PublicationGitError.unavailable
            }
            return path
        }
    }

    func validatePublishedTree(_ tree: String, destinationPath: String) throws {
        let result = try git(["ls-tree", "-r", "-z", tree, "--", ":(literal)\(destinationPath)"])
        guard result.status == 0 else { throw PublicationGitError.unavailable }
        let entries = result.standardOutput.split(separator: 0)
        guard !entries.isEmpty else { throw PublicationGitError.unavailable }
        for entry in entries {
            let metadata = String(decoding: entry, as: UTF8.self)
                .split(separator: "\t", maxSplits: 1).first?.split(separator: " ") ?? []
            guard metadata.count == 3,
                  ["100644", "100755"].contains(metadata[0]), metadata[1] == "blob"
            else { throw PublicationGitError.unavailable }
        }
        guard try objectExists("\(tree):\(destinationPath)/SKILL.md") else {
            throw PublicationGitError.unavailable
        }
    }

    func objectExists(_ revision: String) throws -> Bool {
        let result = try git(["cat-file", "-e", revision])
        return result.status == 0
    }

    func contains(_ path: String, in destinationPath: String) -> Bool {
        path == destinationPath || path.hasPrefix("\(destinationPath)/")
    }

    private func parsePorcelainPaths(_ data: Data) throws -> [String] {
        var fields = data.split(separator: 0, omittingEmptySubsequences: true)
        var paths: [String] = []
        while !fields.isEmpty {
            let entry = fields.removeFirst()
            guard entry.count >= 4, entry[entry.startIndex + 2] == 32 else {
                throw PublicationGitError.unavailable
            }
            let status = entry.prefix(2)
            let path = String(decoding: entry.dropFirst(3), as: UTF8.self)
            guard !path.contains(where: { $0.isNewline || $0 == "\0" }) else {
                throw PublicationGitError.unavailable
            }
            paths.append(path)
            if status.contains(82) || status.contains(67) {
                guard !fields.isEmpty else { throw PublicationGitError.unavailable }
                let source = String(decoding: fields.removeFirst(), as: UTF8.self)
                guard !source.contains(where: { $0.isNewline || $0 == "\0" }) else {
                    throw PublicationGitError.unavailable
                }
                paths.append(source)
            }
        }
        return paths
    }
}

private enum PublicationGitError: Error {
    case unavailable
}
