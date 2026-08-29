import XCTest
@testable import MetagentCore

final class SkillRootEventFilterTests: XCTestCase {
    func testIgnoresOnlyRemotePluginInstallMetadata() {
        XCTAssertFalse(SkillRootEventFilter.shouldRefresh(paths: [
            "/tmp/cache/github/.codex-remote-plugin-install.json",
            "/tmp/cache/slack/.codex-remote-plugin-install.json",
        ]))
    }

    func testRefreshesForSkillAndPluginContentChanges() {
        XCTAssertTrue(SkillRootEventFilter.shouldRefresh(paths: [
            "/tmp/cache/github/.codex-remote-plugin-install.json",
            "/tmp/cache/github/1.0.0/skills/github/SKILL.md",
        ]))
        XCTAssertTrue(SkillRootEventFilter.shouldRefresh(paths: [
            "/tmp/cache/github/1.0.0/.codex-plugin/plugin.json",
        ]))
    }

    func testEmptyEventBatchFailsOpen() {
        XCTAssertTrue(SkillRootEventFilter.shouldRefresh(paths: []))
    }
}
