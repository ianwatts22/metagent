import Foundation

public struct SkillPublicationRepositorySetup: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable { case created, reused, blocked, failed }
    public let outcome: Outcome
    public let path: String
    public let message: String
    public var succeeded: Bool { outcome == .created || outcome == .reused }
}

public extension MetagentCore {
    /// Local setup only: never stages files, commits, creates a remote, or pushes.
    static func prepareDefaultSkillPublicationRepository() -> SkillPublicationRepositorySetup {
        prepareSkillPublicationRepository(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    internal static func prepareSkillPublicationRepository(home: URL) -> SkillPublicationRepositorySetup {
        let manager = FileManager.default
        let root = home.resolvingSymlinksInPath().appendingPathComponent("public-agent-setup").standardizedFileURL
        func result(_ outcome: SkillPublicationRepositorySetup.Outcome, _ message: String) -> SkillPublicationRepositorySetup {
            SkillPublicationRepositorySetup(outcome: outcome, path: root.path, message: message)
        }
        // A fresh environment prevents inherited Git routing, templates, and
        // configuration from writing somewhere other than this new repository.
        func git(_ arguments: [String]) throws -> SubprocessResult {
            try runSubprocess(executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: [
                "-i", "PATH=/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null",
                "GIT_TERMINAL_PROMPT=0", "GIT_ALLOW_PROTOCOL=", "GIT_NO_LAZY_FETCH=1",
                "/usr/bin/git", "--no-optional-locks", "-c", "core.hooksPath=/dev/null",
                "-c", "core.fsmonitor=false", "-C", root.path,
            ] + arguments, timeout: 10)
        }
        do {
            let attributes = try? manager.attributesOfItem(atPath: root.path)
            if let attributes {
                guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                    return result(.blocked, "The publishing path is a file or symlink. Choose another checkout; nothing was changed.")
                }
                let entries = try manager.contentsOfDirectory(atPath: root.path)
                if !entries.isEmpty {
                    let metadata = try? manager.attributesOfItem(atPath: root.appendingPathComponent(".git").path)
                    guard metadata?[.type] as? FileAttributeType == .typeDirectory else {
                        return result(.blocked, "This folder already contains files and is not a standalone Git repository. Choose another checkout; nothing was changed.")
                    }
                    let check = try git(["rev-parse", "--show-toplevel"])
                    let reported = String(decoding: check.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !check.timedOut, check.status == 0, !reported.isEmpty,
                          URL(fileURLWithPath: reported).resolvingSymlinksInPath().standardizedFileURL == root else {
                        return result(.blocked, "The existing repository could not be verified. Choose another checkout; nothing was changed.")
                    }
                    return result(.reused, "Using the existing local Git repository. Nothing was committed or published.")
                }
            } else {
                try manager.createDirectory(at: root, withIntermediateDirectories: false)
            }
            let initialized = try git(["init", "--initial-branch=main", "--template="])
            guard !initialized.timedOut, initialized.status == 0 else {
                return result(.failed, "Git initialization did not finish successfully. The folder was left in place; check Git installation and folder permissions before retrying.")
            }
            return result(.created, "Local Git repository ready. No files were committed or published. Connect a GitHub remote and push the initial branch before using Publish.")
        } catch {
            return result(.failed, "Could not prepare the publishing folder: \(error.localizedDescription)")
        }
    }
}
