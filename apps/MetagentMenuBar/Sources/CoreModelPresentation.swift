import Foundation
import MetagentCore

// Presentation belongs in the app; inventory and repair values stay in the core.
extension SkillInventoryItem {
    var tableOriginText: String {
        switch manager {
        case "skills-cli": return "Skills CLI"
        case "dotagents": return "dotagents"
        case "external-cli": return authority
        case "local": return "Local / unknown"
        case "codex-plugin": return "Plugin"
        case "codex": return authority == "codex-system" ? "Codex system" : "Codex installed"
        case "claude": return "Claude installed"
        default: return "\(manager) · \(authority)"
        }
    }
}

extension SkillsRepairReport {
    var title: String { apply ? "Resolve Cleanup" : "Cleanup Preview" }
    var plannedCodexProjectionPaths: [String] { projects.flatMap(\.plannedCodexProjectionPaths) }
    var canApply: Bool { !projects.isEmpty && summary.actionCount > 0 }

    var summaryText: String {
        [
            "\(title): \(summary.projectCount) projects",
            "\(summary.validSkillCount) valid skills",
            "\(summary.actionCount) planned actions",
            "\(summary.warningCount) warnings"
        ].joined(separator: ", ")
    }
}

extension SkillsRepairProject {
    var displayName: String {
        name.isEmpty ? URL(fileURLWithPath: root).lastPathComponent : name
    }

    var actions: [SkillsRepairLine] { lines.filter { $0.kind == .action } }
    var warnings: [SkillsRepairLine] { lines.filter { $0.kind == .warning } }
    var skipped: [SkillsRepairLine] { lines.filter { $0.kind == .skipped } }
    var info: [SkillsRepairLine] { lines.filter { $0.kind == .info } }
}
