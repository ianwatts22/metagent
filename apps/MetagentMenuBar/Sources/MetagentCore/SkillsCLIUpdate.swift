import Foundation

/// The Skills CLI (`npx skills`) has no read-only "outdated" command, so
/// staleness is tracked by when Metagent last ran `skills update`.
public enum SkillsCLIUpdatePolicy {
    public static let reminderInterval: TimeInterval = 2 * 24 * 60 * 60

    public static func isDue(lastRun: Date?, now: Date = Date()) -> Bool {
        guard let lastRun else { return true }
        return now.timeIntervalSince(lastRun) >= reminderInterval
    }
}

public struct SkillsCLIUpdateOutcome: Identifiable, Hashable, Sendable {
    /// Home directory for the global scope, otherwise the project root.
    public let root: String
    public let isGlobal: Bool
    public let succeeded: Bool
    /// Last meaningful line the CLI printed, ANSI codes removed.
    public let summary: String
    public let output: String

    public var id: String { isGlobal ? "global" : root }
}

public struct SkillsCLIUpdateReport: Sendable {
    public var outcomes: [SkillsCLIUpdateOutcome]
    public var finishedAt: Date

    public var failedCount: Int { outcomes.filter { !$0.succeeded }.count }

    public var summary: String {
        if outcomes.isEmpty { return "No Skills CLI installs to update" }
        let scopes = outcomes.count == 1 ? "1 scope" : "\(outcomes.count) scopes"
        return failedCount == 0 ? "Checked \(scopes)" : "Checked \(scopes), \(failedCount) failed"
    }
}

extension MetagentCore {
    /// Global scope plus every given project that has a Skills CLI lock.
    /// Projects without `skills-lock.json` have nothing the CLI can update.
    public static func skillsCLIUpdateTargets(projectRoots: [String]) -> (global: Bool, projects: [String]) {
        let home = canonicalProjectPath(homeURL())
        let projects = Set(projectRoots.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
            .filter { root in
                canonicalProjectPath(URL(fileURLWithPath: root)) != home
                    && fileManager.fileExists(atPath: URL(fileURLWithPath: root).appendingPathComponent("skills-lock.json").path)
            }
            .sorted()
        return (fileManager.fileExists(atPath: globalSkillLockPath().path), projects)
    }

    /// Runs `npx skills update` for the global scope and each locked project.
    /// One scope failing never stops the others.
    public static func updateSkillsCLISkills(projectRoots: [String]) -> SkillsCLIUpdateReport {
        let targets = skillsCLIUpdateTargets(projectRoots: projectRoots)
        var outcomes: [SkillsCLIUpdateOutcome] = []
        if targets.global {
            outcomes.append(runSkillsCLIUpdate(root: homeURL(), isGlobal: true))
        }
        for root in targets.projects {
            outcomes.append(runSkillsCLIUpdate(root: URL(fileURLWithPath: root), isGlobal: false))
        }
        return SkillsCLIUpdateReport(outcomes: outcomes, finishedAt: Date())
    }

    static func skillsCLIUpdateArguments(isGlobal: Bool) -> [String] {
        ["--yes", "skills", "update", isGlobal ? "--global" : "--project", "--yes"]
    }

    private static func runSkillsCLIUpdate(root: URL, isGlobal: Bool) -> SkillsCLIUpdateOutcome {
        do {
            let result = try runSubprocess(
                executable: try npxExecutable(),
                arguments: skillsCLIUpdateArguments(isGlobal: isGlobal),
                currentDirectory: root,
                timeout: 300
            )
            let output = skillsCLIPlainOutput(combinedSubprocessOutput(result))
            let succeeded = !result.timedOut && result.status == 0
            let summary = result.timedOut
                ? "Timed out after 5 minutes"
                : skillsCLIUpdateSummary(output) ?? (succeeded ? "Updated" : "skills update failed")
            return SkillsCLIUpdateOutcome(root: root.path, isGlobal: isGlobal, succeeded: succeeded, summary: summary, output: output)
        } catch {
            return SkillsCLIUpdateOutcome(
                root: root.path, isGlobal: isGlobal, succeeded: false,
                summary: error.localizedDescription, output: ""
            )
        }
    }
}

/// Strips ANSI escape sequences and spinner line clears from CLI output.
func skillsCLIPlainOutput(_ output: String) -> String {
    output.replacingOccurrences(of: #"\u001B\[[0-9;?]*[A-Za-z]"#, with: "", options: .regularExpression)
}

/// Prefers the CLI's own result lines ("✓ All global skills are up to date",
/// "Updated 2 skill(s)", "Failed to update 1 skill(s)") over progress chatter.
func skillsCLIUpdateSummary(_ output: String) -> String? {
    let lines = output
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    let results = lines.filter {
        $0.range(of: #"^(✓|✗|Updated \d+ skill|Failed to update \d+ skill)"#, options: .regularExpression) != nil
    }
    let chosen = results.isEmpty ? lines.suffix(1) : results[...]
    let summary = chosen
        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "✓✗ ")) }
        .joined(separator: "; ")
    return summary.isEmpty ? nil : summary
}
