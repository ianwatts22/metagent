import Darwin
import Foundation

// Drives the single public removal entrance:
//   <root> <skill[,skill]> apply|plan|refuse
// `refuse` applies with manager-owned removal disallowed.
@main
struct Probe {
    static func main() {
        let projectRoot = CommandLine.arguments[1]
        let targets = CommandLine.arguments[2]
            .split(separator: ",")
            .map { SkillRemovalTarget.canonical(projectRoot: projectRoot, skillName: String($0)) }
        let mode = CommandLine.arguments.dropFirst(3).first
        let report = MetagentCore.removeSkills(
            targets: targets,
            apply: mode == "apply" || mode == "refuse",
            allowManagedRemoval: mode != "refuse"
        )
        print(report.outcomes.flatMap(\.lines).joined(separator: "\n"))
        guard report.failures.isEmpty else {
            FileHandle.standardError.write(Data(
                report.failures
                    .map { "\($0.skillName): \($0.message)" }
                    .joined(separator: "\n")
                    .utf8
            ))
            exit(1)
        }
    }
}
