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
                checkoutCommit: nil, upstreamCommit: nil, links: nil
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
        func status(_ state: SkillPublicationGitState, _ detail: String, upstream: String? = nil)
            -> SkillPublicationGitStatus {
            SkillPublicationGitStatus(
                state: state, checkedAt: now, detail: detail,
                checkoutCommit: checkoutCommit, upstreamCommit: upstream, links: links
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
}

private enum PublicationGitError: Error {
    case unavailable
}
