import Foundation
import MetagentCore
import Testing
@testable import MetagentMenuBar

@Test func projectPresentationRetainsCompleteScanMetadataThroughMerge() throws {
    let original = SkillProject(
        root: "/tmp/project",
        skillsDir: "/tmp/custom-skill-container",
        validSkills: ["first"],
        skills: [],
        invalidSkillDirs: ["broken"],
        hiddenSkillDirs: [".hidden"]
    )
    let additional = SkillProject(
        root: original.root,
        skillsDir: "/tmp/another-container",
        validSkills: ["second"],
        skills: [],
        invalidSkillDirs: ["another-broken"],
        hiddenSkillDirs: [".another-hidden"]
    )
    let presentation = ProjectStatus.previewFixture(project: original)
    #expect(presentation.coreProject == original)
    let merged = presentation.merged(with: .previewFixture(project: additional))
    #expect(merged.coreProject == original.merging(with: additional))

    // This is the value saved to the launch cache and passed to core analysis.
    let cached = try JSONDecoder().decode(
        SkillProject.self,
        from: JSONEncoder().encode(merged.coreProject)
    )
    #expect(cached.skillsDir == original.skillsDir)
    #expect(cached.invalidSkillDirs == ["another-broken", "broken"])
    #expect(cached.hiddenSkillDirs == [".another-hidden", ".hidden"])
}

@Test func repairPresentationKeepsExactApprovalActionsAndPaths() {
    let project = SkillsRepairProject(
        root: "/tmp/project",
        lines: [
            SkillsRepairLine(kind: .info, text: "valid local skills: 2"),
            SkillsRepairLine(kind: .action, text: "would remove obsolete Codex link: /tmp/project/link"),
            SkillsRepairLine(kind: .warning, text: "manual review needed"),
            SkillsRepairLine(kind: .skipped, text: "leave external skill alone")
        ],
        plannedCodexProjectionPaths: ["/tmp/project/link"]
    )
    let report = SkillsRepairReport(apply: false, projects: [project])
    #expect(report.title == "Cleanup Preview")
    #expect(report.canApply)
    #expect(report.actionsByProject == [project.root: project.actions.map(\.text)])
    #expect(report.plannedCodexProjectionPaths == ["/tmp/project/link"])
    #expect(project.warnings.count == 1)
    #expect(project.skipped.count == 1)
    #expect(project.info.count == 1)
    #expect(report.summaryText == "Cleanup Preview: 1 projects, 2 valid skills, 1 planned actions, 1 warnings")
    #expect(!SkillsRepairReport(apply: false, projects: []).canApply)
    #expect(!SkillsRepairReport(
        apply: false,
        projects: [SkillsRepairProject(root: project.root, lines: project.warnings)]
    ).canApply)
}
