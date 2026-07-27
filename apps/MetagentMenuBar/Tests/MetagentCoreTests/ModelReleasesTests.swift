import Foundation
import XCTest
@testable import MetagentCore

final class ModelReleasesTests: XCTestCase {
    func testSignificantModelReleasesKeepsFlagshipsAndDropsVariants() throws {
        let payload = """
        {
          "anthropic": {
            "name": "Anthropic",
            "models": {
              "claude-opus-5": {
                "name": "Claude Opus 5",
                "release_date": "2026-07-24",
                "modalities": { "input": ["text"], "output": ["text"] }
              },
              "claude-haiku-4-5": {
                "name": "Claude Haiku 4.5",
                "release_date": "2025-10-01",
                "modalities": { "input": ["text"], "output": ["text"] }
              }
            }
          },
          "openai": {
            "name": "OpenAI",
            "models": {
              "gpt-5.6-sol": {
                "name": "GPT-5.6 Sol",
                "release_date": "2026-07-09",
                "modalities": { "input": ["text"], "output": ["text"] }
              },
              "gpt-5.6-mini": {
                "name": "GPT-5.6 Mini",
                "release_date": "2026-07-09",
                "modalities": { "input": ["text"], "output": ["text"] }
              },
              "text-embedding-3-large": {
                "name": "Embedding Large",
                "release_date": "2024-01-25",
                "modalities": { "input": ["text"], "output": ["embedding"] }
              },
              "gpt-undated": {
                "name": "Undated"
              }
            }
          }
        }
        """
        let releases = try MetagentCore.significantModelReleases(from: Data(payload.utf8))
        XCTAssertEqual(Set(releases.map(\.modelID)), ["claude-opus-5", "gpt-5.6-sol"])
        XCTAssertEqual(releases.first?.modelID, "claude-opus-5")
        XCTAssertEqual(releases.first?.providerName, "Anthropic")
    }

    func testSignificantModelIDTokenMatching() {
        XCTAssertTrue(MetagentCore.isSignificantModelID("claude-opus-5"))
        XCTAssertTrue(MetagentCore.isSignificantModelID("gpt-5.6-sol"))
        XCTAssertFalse(MetagentCore.isSignificantModelID("gpt-5.6-mini"))
        XCTAssertFalse(MetagentCore.isSignificantModelID("gemini-3-flash"))
        XCTAssertFalse(MetagentCore.isSignificantModelID("gpt-realtime-2.1"))
        XCTAssertFalse(MetagentCore.isSignificantModelID("claude-haiku-4-5"))
    }

    func testAdvisoryRequiresBaselineEvidence() {
        let releases = [release("anthropic", "Anthropic", "claude-opus-5", "Claude Opus 5", "2026-07-24")]
        XCTAssertNil(MetagentCore.modelReleaseAdvisory(
            skillUpdatedAt: nil,
            affirmedAt: nil,
            releases: releases,
            trackedProviders: ["anthropic"]
        ))
    }

    func testAdvisoryPenaltyIsFlatRegardlessOfElapsedTime() {
        let releases = [release("anthropic", "Anthropic", "claude-opus-5", "Claude Opus 5", "2026-07-24")]
        let updated = day("2026-07-01")

        for now in [day("2026-07-27"), day("2026-08-20"), day("2026-12-01")] {
            let advisory = MetagentCore.modelReleaseAdvisory(
                skillUpdatedAt: updated,
                affirmedAt: nil,
                releases: releases,
                trackedProviders: ["anthropic"],
                now: now
            )
            XCTAssertEqual(advisory?.utilityPenalty, 15)
            XCTAssertEqual(advisory?.severity, "warning")
            XCTAssertTrue(advisory?.message.contains("Claude Opus 5") ?? false)
        }
    }

    func testAdvisoryClearsOnTouchAffirmationOrUntrackedProvider() {
        let releases = [release("openai", "OpenAI", "gpt-5.6", "GPT-5.6", "2026-07-09")]
        let now = day("2026-07-27")

        XCTAssertNil(MetagentCore.modelReleaseAdvisory(
            skillUpdatedAt: day("2026-07-10"),
            affirmedAt: nil,
            releases: releases,
            trackedProviders: ["openai"],
            now: now
        ), "editing the skill after the release clears the advisory")

        XCTAssertNil(MetagentCore.modelReleaseAdvisory(
            skillUpdatedAt: day("2026-06-01"),
            affirmedAt: day("2026-07-10"),
            releases: releases,
            trackedProviders: ["openai"],
            now: now
        ), "an explicit affirmation clears the advisory without edits")

        XCTAssertNil(MetagentCore.modelReleaseAdvisory(
            skillUpdatedAt: day("2026-06-01"),
            affirmedAt: nil,
            releases: releases,
            trackedProviders: ["anthropic"],
            now: now
        ), "releases from untracked providers are ignored")
    }

    func testAdvisoryGroupsSimultaneousVariantsIntoOneEvent() {
        let releases = [
            release("openai", "OpenAI", "gpt-5.6", "GPT-5.6", "2026-07-09"),
            release("openai", "OpenAI", "gpt-5.6-sol", "GPT-5.6 Sol", "2026-07-09"),
            release("openai", "OpenAI", "gpt-5.6-terra", "GPT-5.6 Terra", "2026-07-09"),
        ]
        let advisory = MetagentCore.modelReleaseAdvisory(
            skillUpdatedAt: day("2026-06-01"),
            affirmedAt: nil,
            releases: releases,
            trackedProviders: ["openai"],
            now: day("2026-07-27")
        )
        let message = advisory?.message ?? ""
        XCTAssertTrue(message.contains("+1 more"), "third variant collapses into a count: \(message)")
        XCTAssertEqual(message.components(separatedBy: "OpenAI").count, 2, "one provider event, not one per model: \(message)")
    }

    func testUtilityScoreAppliesBoundedAdvisoryPenalty() {
        let score = MetagentSkillScore(
            score: 80,
            confidence: .medium,
            components: [
                SkillScoreComponent(id: "integrity", label: "Integrity", score: 40, maximum: 40, explanation: ""),
                SkillScoreComponent(id: "adoption", label: "Adoption", score: 40, maximum: 40, explanation: ""),
            ]
        )
        let base = score.utilityScore(qualityScore: 100)
        XCTAssertEqual(score.utilityScore(qualityScore: 100, advisoryPenalty: 15), base - 15)
        XCTAssertEqual(score.utilityScore(qualityScore: 0, advisoryPenalty: 15), max(0, 30 - 15))
        XCTAssertEqual(score.utilityScore(qualityScore: 100, advisoryPenalty: -5), base, "negative penalties are ignored")
    }

    func testAffirmationRoundTripStandardizesPaths() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-release-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("affirmations.json")

        try MetagentCore.affirmModelReleaseReview(
            canonicalPath: "/tmp/skills/../skills/demo",
            date: day("2026-07-27"),
            path: store
        )
        let affirmations = MetagentCore.loadModelReleaseAffirmations(path: store)
        let key = MetagentCore.standardizedModelReleasePath("/tmp/skills/demo")
        XCTAssertEqual(affirmations[key], day("2026-07-27"))
    }

    private func release(
        _ provider: String,
        _ providerName: String,
        _ modelID: String,
        _ modelName: String,
        _ date: String
    ) -> ModelRelease {
        ModelRelease(
            provider: provider,
            providerName: providerName,
            modelID: modelID,
            modelName: modelName,
            releaseDate: day(date)
        )
    }

    private func day(_ value: String) -> Date {
        MetagentCore.parseModelReleaseDate(value)!
    }
}
