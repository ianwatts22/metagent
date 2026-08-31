import Foundation
import Darwin
import CoreServices
import SQLite3
import XCTest
@testable import MetagentCore

final class SkillUsageTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MetagentCore.resetSkillUsageSourceCatalogForTesting()
    }

    override func tearDown() {
        MetagentCore.resetSkillUsageSourceCatalogForTesting()
        super.tearDown()
    }

    func testParsesCodexFractionalAndWholeSecondTimestamps() {
        XCTAssertNotNil(MetagentCore.parseSkillUsageTimestamp("2026-07-19T12:00:00.000Z"))
        XCTAssertNotNil(MetagentCore.parseSkillUsageTimestamp("2026-07-19T12:00:00Z"))
    }

    func testRefreshMaterializesPrivateLaunchSnapshotWithoutChangingCanonicalLoad() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(
            at: "workspace/.agents/skills/cached-skill",
            name: "cached-skill"
        )
        try fixture.write([
            fixture.line(type: "session_meta", payload: [
                "id": "cache-session",
                "cwd": fixture.root.path
            ]),
            fixture.line(type: "turn_context", payload: [
                "turn_id": "cache-turn",
                "cwd": fixture.root.path
            ]),
            fixture.toolCall(callID: "cache-call", command: "cat \(skill.path)")
        ], to: fixture.sessions.appendingPathComponent("rollout-cache.jsonl"))

        XCTAssertNil(MetagentCore.loadCachedSkillUsageSnapshot(databasePath: fixture.database.path))
        XCTAssertNotNil(MetagentCore.loadSkillUsageSnapshot(databasePath: fixture.database.path))
        XCTAssertNil(
            MetagentCore.loadCachedSkillUsageSnapshot(databasePath: fixture.database.path),
            "an authoritative read must not silently materialize or fall back through the launch cache"
        )

        let report = try MetagentCore.refreshSkillUsage(options: fixture.options)
        XCTAssertEqual(
            MetagentCore.loadCachedSkillUsageSnapshot(databasePath: fixture.database.path),
            report.snapshot
        )
        XCTAssertEqual(
            MetagentCore.loadSkillUsageSnapshot(databasePath: fixture.database.path),
            report.snapshot
        )

        let cachePath = try MetagentCore.skillUsageLaunchCachePathForTesting(
            databasePath: fixture.database.path
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: cachePath)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
        XCTAssertEqual(permissions & 0o777, 0o600)
    }

    func testLaunchSnapshotCacheFailsClosedForMissingCorruptInsecureAndIncompatibleFiles() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let report = try MetagentCore.refreshSkillUsage(options: fixture.options)
        let cachePath = URL(fileURLWithPath: try MetagentCore.skillUsageLaunchCachePathForTesting(
            databasePath: fixture.database.path
        ))
        let validEnvelope = try JSONDecoder().decode(
            SkillUsageLaunchCacheEnvelope.self,
            from: Data(contentsOf: cachePath)
        )

        try Data("not json".utf8).write(to: cachePath, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cachePath.path)
        XCTAssertNil(MetagentCore.loadCachedSkillUsageSnapshot(databasePath: fixture.database.path))

        try writePrivateLaunchCache(
            SkillUsageLaunchCacheEnvelope(
                formatVersion: validEnvelope.formatVersion + 1,
                parserGeneration: validEnvelope.parserGeneration,
                storeID: validEnvelope.storeID,
                snapshotGeneration: validEnvelope.snapshotGeneration,
                generatedAt: validEnvelope.generatedAt,
                snapshot: report.snapshot
            ),
            to: cachePath
        )
        XCTAssertNil(MetagentCore.loadCachedSkillUsageSnapshot(databasePath: fixture.database.path))

        try writePrivateLaunchCache(
            SkillUsageLaunchCacheEnvelope(
                formatVersion: validEnvelope.formatVersion,
                parserGeneration: validEnvelope.parserGeneration + 1,
                storeID: validEnvelope.storeID,
                snapshotGeneration: validEnvelope.snapshotGeneration,
                generatedAt: validEnvelope.generatedAt,
                snapshot: report.snapshot
            ),
            to: cachePath
        )
        XCTAssertNil(MetagentCore.loadCachedSkillUsageSnapshot(databasePath: fixture.database.path))

        try writePrivateLaunchCache(
            SkillUsageLaunchCacheEnvelope(
                formatVersion: validEnvelope.formatVersion,
                parserGeneration: validEnvelope.parserGeneration,
                storeID: validEnvelope.storeID,
                snapshotGeneration: validEnvelope.snapshotGeneration,
                generatedAt: validEnvelope.generatedAt,
                snapshot: replacingTargetParserVersion(
                    in: report.snapshot,
                    with: validEnvelope.parserGeneration + 1
                )
            ),
            to: cachePath
        )
        XCTAssertNil(MetagentCore.loadCachedSkillUsageSnapshot(databasePath: fixture.database.path))

        try writePrivateLaunchCache(validEnvelope, to: cachePath)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: cachePath.path)
        XCTAssertNil(
            MetagentCore.loadCachedSkillUsageSnapshot(databasePath: fixture.database.path),
            "a path-bearing cache with group/world access must be rejected"
        )

        try FileManager.default.removeItem(at: cachePath)
        XCTAssertNil(MetagentCore.loadCachedSkillUsageSnapshot(databasePath: fixture.database.path))

        let symlinkTarget = fixture.root.appendingPathComponent("redirected-launch-cache.json")
        try writePrivateLaunchCache(validEnvelope, to: symlinkTarget)
        try FileManager.default.createSymbolicLink(at: cachePath, withDestinationURL: symlinkTarget)
        XCTAssertNil(
            MetagentCore.loadCachedSkillUsageSnapshot(databasePath: fixture.database.path),
            "the launch cache path must be a regular file rather than a redirect"
        )
        XCTAssertEqual(
            MetagentCore.loadSkillUsageSnapshot(databasePath: fixture.database.path),
            report.snapshot,
            "cache failures must not affect the SQLite source of truth"
        )
    }

    func testOlderRefreshGenerationCannotOverwriteNewerLaunchSnapshot() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let report = try MetagentCore.refreshSkillUsage(options: fixture.options)
        let newer = replacingTotalInvocations(in: report.snapshot, with: 42)
        let older = replacingTotalInvocations(in: report.snapshot, with: 7)
        let cachePath = URL(fileURLWithPath: try MetagentCore.skillUsageLaunchCachePathForTesting(
            databasePath: fixture.database.path
        ))
        let generation = try JSONDecoder().decode(
            SkillUsageLaunchCacheEnvelope.self,
            from: Data(contentsOf: cachePath)
        ).snapshotGeneration
        try FileManager.default.removeItem(at: cachePath)

        try MetagentCore.saveSkillUsageLaunchSnapshotForTesting(
            newer,
            databasePath: fixture.database.path,
            snapshotGeneration: generation
        )
        try MetagentCore.saveSkillUsageLaunchSnapshotForTesting(
            older,
            databasePath: fixture.database.path,
            snapshotGeneration: generation - 1
        )

        XCTAssertEqual(
            MetagentCore.loadCachedSkillUsageSnapshot(databasePath: fixture.database.path),
            newer
        )
    }

    func testDatabaseRollbackReplacesAFutureLaunchSnapshot() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let initial = try MetagentCore.refreshSkillUsage(options: fixture.options)
        let cachePath = URL(fileURLWithPath: try MetagentCore.skillUsageLaunchCachePathForTesting(
            databasePath: fixture.database.path
        ))
        let current = try JSONDecoder().decode(
            SkillUsageLaunchCacheEnvelope.self,
            from: Data(contentsOf: cachePath)
        )
        let future = SkillUsageLaunchCacheEnvelope(
            formatVersion: current.formatVersion,
            parserGeneration: current.parserGeneration,
            storeID: current.storeID,
            snapshotGeneration: current.snapshotGeneration + 100,
            generatedAt: current.generatedAt.addingTimeInterval(3_600),
            snapshot: replacingTotalInvocations(in: initial.snapshot, with: 42)
        )
        try writePrivateLaunchCache(future, to: cachePath)

        let refreshed = try MetagentCore.refreshSkillUsage(options: fixture.options)
        let repaired = try JSONDecoder().decode(
            SkillUsageLaunchCacheEnvelope.self,
            from: Data(contentsOf: cachePath)
        )

        XCTAssertEqual(repaired.snapshot, refreshed.snapshot)
        XCTAssertEqual(repaired.snapshotGeneration, current.snapshotGeneration + 1)
    }

    func testLaunchCachePathsPreserveTheCompleteDatabaseFilename() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sqliteDatabase = fixture.root.appendingPathComponent("usage.sqlite")
        let dbDatabase = fixture.root.appendingPathComponent("usage.db")

        let sqliteCache = try MetagentCore.skillUsageLaunchCachePathForTesting(
            databasePath: sqliteDatabase.path
        )
        let dbCache = try MetagentCore.skillUsageLaunchCachePathForTesting(
            databasePath: dbDatabase.path
        )

        XCTAssertNotEqual(sqliteCache, dbCache)
        XCTAssertTrue(sqliteCache.hasSuffix("usage.sqlite-launch-snapshot.json"))
        XCTAssertTrue(dbCache.hasSuffix("usage.db-launch-snapshot.json"))
    }

    func testLaunchCacheWriteFailureDoesNotFailCanonicalRefresh() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let cachePath = URL(fileURLWithPath: try MetagentCore.skillUsageLaunchCachePathForTesting(
            databasePath: fixture.database.path
        ))
        try FileManager.default.createDirectory(at: cachePath, withIntermediateDirectories: true)

        let report = try MetagentCore.refreshSkillUsage(options: fixture.options)

        XCTAssertEqual(report.snapshot.totalInvocations, 0)
        XCTAssertNotNil(MetagentCore.loadSkillUsageSnapshot(databasePath: fixture.database.path))
        XCTAssertNil(MetagentCore.loadCachedSkillUsageSnapshot(databasePath: fixture.database.path))
    }

    func testLaunchCacheLockRefusesSymlinkWithoutTouchingTarget() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let initial = try MetagentCore.refreshSkillUsage(options: fixture.options)
        let cachePath = URL(fileURLWithPath: try MetagentCore.skillUsageLaunchCachePathForTesting(
            databasePath: fixture.database.path
        ))
        let lockPath = cachePath.appendingPathExtension("lock")
        try FileManager.default.removeItem(at: lockPath)
        let target = fixture.root.appendingPathComponent("do-not-touch.txt")
        let sentinel = Data("private sentinel".utf8)
        try sentinel.write(to: target)
        try FileManager.default.createSymbolicLink(at: lockPath, withDestinationURL: target)

        let refreshed = try MetagentCore.refreshSkillUsage(options: fixture.options)

        XCTAssertEqual(refreshed.snapshot, initial.snapshot)
        XCTAssertEqual(try Data(contentsOf: target), sentinel)
        XCTAssertEqual(
            MetagentCore.loadCachedSkillUsageSnapshot(databasePath: fixture.database.path),
            initial.snapshot,
            "a rejected lock path must preserve the last good private cache"
        )
    }

    func testLaunchCacheLockRefusesHardLinkWithoutChangingTargetMode() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let initial = try MetagentCore.refreshSkillUsage(options: fixture.options)
        let cachePath = URL(fileURLWithPath: try MetagentCore.skillUsageLaunchCachePathForTesting(
            databasePath: fixture.database.path
        ))
        let lockPath = cachePath.appendingPathExtension("lock")
        try FileManager.default.removeItem(at: lockPath)
        let target = fixture.root.appendingPathComponent("do-not-chmod.txt")
        try Data("shared inode".utf8).write(to: target)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: target.path
        )
        try FileManager.default.linkItem(at: target, to: lockPath)

        let refreshed = try MetagentCore.refreshSkillUsage(options: fixture.options)
        let permissions = try FileManager.default.attributesOfItem(atPath: target.path)[
            .posixPermissions
        ] as? NSNumber

        XCTAssertEqual(refreshed.snapshot, initial.snapshot)
        XCTAssertEqual(permissions?.intValue, 0o644)
        XCTAssertEqual(
            MetagentCore.loadCachedSkillUsageSnapshot(databasePath: fixture.database.path),
            initial.snapshot,
            "a rejected hard-linked lock must preserve the last good cache"
        )
    }

    func testFailedCanonicalRefreshPreservesLastGoodLaunchSnapshot() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let report = try MetagentCore.refreshSkillUsage(options: fixture.options)
        let cachePath = URL(fileURLWithPath: try MetagentCore.skillUsageLaunchCachePathForTesting(
            databasePath: fixture.database.path
        ))
        let cachedData = try Data(contentsOf: cachePath)

        for path in [
            fixture.database.path,
            fixture.database.path + "-wal",
            fixture.database.path + "-shm",
        ] where FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
        try FileManager.default.createDirectory(at: fixture.database, withIntermediateDirectories: true)

        XCTAssertThrowsError(try MetagentCore.refreshSkillUsage(options: fixture.options))
        XCTAssertEqual(try Data(contentsOf: cachePath), cachedData)
        XCTAssertEqual(
            MetagentCore.loadCachedSkillUsageSnapshot(databasePath: fixture.database.path),
            report.snapshot
        )
    }

    func testContinuationCatalogIgnoresWatcherBookkeepingButInvalidatesForChanges() {
        let bookkeepingFlags: [FSEventStreamEventFlags] = [
            FSEventStreamEventFlags(kFSEventStreamEventFlagNone),
            FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone),
            FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile),
            FSEventStreamEventFlags(
                kFSEventStreamEventFlagHistoryDone | kFSEventStreamEventFlagItemIsDir
            ),
        ]
        for flags in bookkeepingFlags {
            XCTAssertFalse(
                MetagentCore.shouldInvalidateSkillUsageSourceCatalogForTesting(
                    eventFlags: flags
                )
            )
        }

        let mutationFlags: [FSEventStreamEventFlags] = [
            FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated),
            FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified),
            FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved),
            FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed),
            FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs),
            FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped),
            FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped),
            FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged),
        ]
        for flags in mutationFlags {
            XCTAssertTrue(
                MetagentCore.shouldInvalidateSkillUsageSourceCatalogForTesting(
                    eventFlags: flags
                )
            )
        }
    }

    func testContinuationCatalogIgnoresOnlyOwnedStateDirectoryBookkeeping() {
        let root = "/tmp/metagent-sessions"
        let stateDirectory = root + "/metagent-state"
        let database = stateDirectory + "/usage.sqlite"
        let modified = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
        let created = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)

        XCTAssertFalse(MetagentCore.skillUsageCatalogInvalidatesPathEventForTesting(
            roots: [root],
            databasePath: database,
            eventPath: stateDirectory,
            flags: modified
        ))
        XCTAssertTrue(MetagentCore.skillUsageCatalogInvalidatesPathEventForTesting(
            roots: [root],
            databasePath: database,
            eventPath: stateDirectory,
            flags: created
        ))
        XCTAssertTrue(MetagentCore.skillUsageCatalogInvalidatesPathEventForTesting(
            roots: [root],
            databasePath: database,
            eventPath: root + "/new-session.jsonl",
            flags: created
        ))
    }

    func testContinuationCatalogArmsOnlyAfterQueuedCallbacksDrain() {
        XCTAssertTrue(
            MetagentCore.skillUsageCatalogArmingDrainsQueuedCallbacksForTesting(),
            "callbacks queued before the event watermark must run while the catalog is disarmed"
        )
    }

    func testContinuationCatalogUsesEventWatermarkInsteadOfCallbackTiming() {
        let modified = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
        XCTAssertFalse(MetagentCore.skillUsageCatalogInvalidatesEventForTesting(
            baselineEventID: 100,
            eventID: 100,
            flags: modified
        ))
        XCTAssertTrue(MetagentCore.skillUsageCatalogInvalidatesEventForTesting(
            baselineEventID: 100,
            eventID: 101,
            flags: modified
        ))
        XCTAssertTrue(MetagentCore.skillUsageCatalogInvalidatesEventForTesting(
            baselineEventID: 100,
            eventID: 1,
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped)
        ))
    }

    func testContinuationCatalogCanonicalizesWatchRootsAndInvalidatesRootChanges() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let linkedRoot = fixture.root.appendingPathComponent("linked-sessions")
        try FileManager.default.createSymbolicLink(
            at: linkedRoot,
            withDestinationURL: fixture.sessions
        )
        let realHome = fixture.root.appendingPathComponent("real-home")
        let linkedHome = fixture.root.appendingPathComponent("linked-home")
        try FileManager.default.createDirectory(
            at: realHome.appendingPathComponent("sessions"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: linkedHome, withDestinationURL: realHome)
        XCTAssertEqual(
            MetagentCore.canonicalSkillUsageWatchPathsForTesting([
                fixture.sessions.path,
                fixture.sessions.resolvingSymlinksInPath().path,
            ]),
            [fixture.sessions.resolvingSymlinksInPath().standardizedFileURL.path]
        )
        XCTAssertEqual(
            MetagentCore.canonicalSkillUsageWatchPathsForTesting([linkedRoot.path]),
            [
                linkedRoot.deletingLastPathComponent()
                    .resolvingSymlinksInPath()
                    .appendingPathComponent(linkedRoot.lastPathComponent)
                    .standardizedFileURL.path,
            ],
            "the final component must stay unresolved so mutable symlinks remain detectable"
        )
        XCTAssertTrue(MetagentCore.skillUsageWatchSupportsReuseForTesting([
            fixture.sessions.path,
        ]))
        XCTAssertFalse(MetagentCore.skillUsageWatchSupportsReuseForTesting(["/"]))
        XCTAssertFalse(MetagentCore.skillUsageWatchSupportsReuseForTesting(["/Users"]))
        XCTAssertFalse(MetagentCore.skillUsageWatchSupportsReuseForTesting([
            linkedRoot.path,
        ]))
        XCTAssertFalse(MetagentCore.skillUsageWatchSupportsReuseForTesting([
            linkedHome.appendingPathComponent("sessions").path,
        ]))
        let initiallyMissing = fixture.root.appendingPathComponent("initially-missing")
        XCTAssertTrue(MetagentCore.skillUsageRootIsMissingForTesting(initiallyMissing.path))
        try FileManager.default.createDirectory(
            at: initiallyMissing,
            withIntermediateDirectories: true
        )
        XCTAssertFalse(MetagentCore.skillUsageRootIsMissingForTesting(initiallyMissing.path))
        let identityWatchPaths = MetagentCore.skillUsageIdentityWatchPathsForTesting([
            fixture.sessions.path,
        ])
        XCTAssertTrue(identityWatchPaths.contains(fixture.sessions.path))
        XCTAssertTrue(identityWatchPaths.contains(fixture.root.path))
        XCTAssertTrue(MetagentCore.skillUsageEventInvalidatesRootsForTesting(
            eventPath: fixture.sessions.path,
            roots: [fixture.sessions.path]
        ))
        XCTAssertTrue(MetagentCore.skillUsageEventInvalidatesRootsForTesting(
            eventPath: fixture.sessions.appendingPathComponent("new.jsonl").path,
            roots: [fixture.sessions.path]
        ))
        XCTAssertFalse(MetagentCore.skillUsageEventInvalidatesRootsForTesting(
            eventPath: fixture.root.appendingPathComponent("unrelated.jsonl").path,
            roots: [fixture.sessions.path]
        ))
        XCTAssertFalse(MetagentCore.skillUsageEventInvalidatesRootsForTesting(
            eventPath: fixture.root.appendingPathComponent("renamed-sessions").path,
            roots: [fixture.sessions.path]
        ))
        let renameSource = fixture.root.appendingPathComponent("rename-source")
        let renameDestination = fixture.root.appendingPathComponent("rename-destination")
        try FileManager.default.createDirectory(
            at: renameSource,
            withIntermediateDirectories: true
        )
        XCTAssertTrue(try MetagentCore.skillUsageRootWatcherDetectsRenameForTesting(
            rootPath: renameSource.path,
            renamedPath: renameDestination.path
        ))
        let ancestorSource = fixture.root.appendingPathComponent("ancestor-source")
        let descendantRoot = ancestorSource.appendingPathComponent("nested/sessions")
        let ancestorDestination = fixture.root.appendingPathComponent("ancestor-destination")
        try FileManager.default.createDirectory(
            at: descendantRoot,
            withIntermediateDirectories: true
        )
        XCTAssertTrue(try MetagentCore.skillUsageRootWatcherDetectsAncestorRenameForTesting(
            rootPath: descendantRoot.path,
            ancestorPath: ancestorSource.path,
            renamedAncestorPath: ancestorDestination.path
        ))
        let deleteSource = fixture.root.appendingPathComponent("delete-source")
        try FileManager.default.createDirectory(
            at: deleteSource,
            withIntermediateDirectories: true
        )
        XCTAssertTrue(try MetagentCore.skillUsageRootWatcherDetectsDeleteForTesting(
            rootPath: deleteSource.path
        ))
        XCTAssertTrue(MetagentCore.skillUsageCatalogInvalidatesEventForTesting(
            baselineEventID: 100,
            eventID: 0,
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
        ))
    }

    func testAgentRunDurationStatsUseCompletedCodexTasksAndProjectScope() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let project = fixture.root.appendingPathComponent("workspace")
        let otherProject = fixture.root.appendingPathComponent("other")
        let rollout = fixture.sessions.appendingPathComponent("rollout-runs.jsonl")
        try fixture.write([
            fixture.line(timestamp: "2026-07-30T11:59:59.000Z", type: "session_meta", payload: [
                "id": "run-session",
                "cwd": project.path,
                "thread_source": "user"
            ]),
            // Fork histories are rewritten with the new file's wrapper time.
            // Their payload times still predate this source session and must
            // not become new runs in the recent window.
            fixture.line(type: "session_meta", payload: [
                "id": "copied-parent-session",
                "cwd": project.path,
                "thread_source": "user"
            ]),
            fixture.line(
                timestamp: "2026-07-30T12:00:00.000Z",
                type: "event_msg",
                payload: [
                    "type": "task_complete",
                    "turn_id": "copied-parent-turn",
                    "started_at": fixture.epoch("2026-07-01T12:00:00Z"),
                    "completed_at": fixture.epoch("2026-07-01T12:05:00Z"),
                    "duration_ms": 300_000
                ]
            ),
            fixture.line(
                timestamp: "2026-07-30T12:00:00.000Z",
                type: "event_msg",
                payload: ["type": "task_started", "turn_id": "run-one"]
            ),
            fixture.line(
                timestamp: "2026-07-30T12:02:00.000Z",
                type: "event_msg",
                payload: [
                    "type": "task_complete",
                    "turn_id": "run-one",
                    "started_at": fixture.epoch("2026-07-30T12:00:00Z"),
                    "completed_at": fixture.epoch("2026-07-30T12:02:00Z"),
                    "duration_ms": 120_000
                ]
            ),
            fixture.line(type: "turn_context", payload: [
                "turn_id": "run-two",
                "cwd": project.appendingPathComponent("nested").path
            ]),
            fixture.line(
                timestamp: "2026-07-30T12:10:00.000Z",
                type: "event_msg",
                payload: ["type": "task_started", "turn_id": "run-two"]
            ),
            fixture.line(
                timestamp: "2026-07-30T12:14:00.000Z",
                type: "event_msg",
                payload: [
                    "type": "task_complete",
                    "turn_id": "run-two",
                    "started_at": fixture.epoch("2026-07-30T12:10:00Z"),
                    "completed_at": fixture.epoch("2026-07-30T12:14:00Z")
                ]
            ),
            fixture.line(type: "turn_context", payload: [
                "turn_id": "run-other",
                "cwd": otherProject.path
            ]),
            fixture.line(
                timestamp: "2026-07-30T13:00:00.000Z",
                type: "event_msg",
                payload: [
                    "type": "task_complete",
                    "turn_id": "run-other",
                    "started_at": fixture.epoch("2026-07-30T12:50:00Z"),
                    "completed_at": fixture.epoch("2026-07-30T13:00:00Z"),
                    "duration_ms": 600_000
                ]
            )
        ], to: rollout)

        for (name, threadSource, source) in [
            ("automation", "automation", "vscode" as Any),
            ("worker", "subagent", ["subagent": ["other": "worker"]] as Any),
            ("guardian", "guardian_review", ["subagent": ["other": "guardian"]] as Any),
        ] {
            try fixture.write([
                fixture.line(timestamp: "2026-07-30T12:00:00.000Z", type: "session_meta", payload: [
                    "id": "\(name)-session",
                    "cwd": project.path,
                    "thread_source": threadSource,
                    "source": source
                ]),
                fixture.line(timestamp: "2026-07-30T12:01:00.000Z", type: "event_msg", payload: [
                    "type": "task_complete",
                    "turn_id": "\(name)-turn",
                    "started_at": fixture.epoch("2026-07-30T12:00:00Z"),
                    "completed_at": fixture.epoch("2026-07-30T12:01:00Z"),
                    "duration_ms": 60_000
                ])
            ], to: fixture.sessions.appendingPathComponent("rollout-\(name).jsonl"))
        }

        try fixture.write([
            fixture.line(timestamp: "2026-07-30T12:00:00.000Z", type: "session_meta", payload: [
                "id": "unknown-session",
                "cwd": project.path,
                "agent_path": NSNull(),
                "parent_thread_id": NSNull(),
                "forked_from_id": NSNull(),
                "source": ["subagent": NSNull()]
            ]),
            fixture.line(timestamp: "2026-07-30T12:01:00.000Z", type: "event_msg", payload: [
                "type": "task_complete",
                "turn_id": "unknown-turn",
                "started_at": fixture.epoch("2026-07-30T12:00:00Z"),
                "completed_at": fixture.epoch("2026-07-30T12:01:00Z"),
                "duration_ms": 60_000
            ])
        ], to: fixture.sessions.appendingPathComponent("rollout-unknown.jsonl"))

        _ = try MetagentCore.refreshSkillUsage(options: fixture.options)
        let now = try XCTUnwrap(MetagentCore.parseSkillUsageTimestamp("2026-07-31T00:00:00Z"))
        let stats = try MetagentCore.agentRunDurationStats(
            databasePath: fixture.database.path,
            projectRoot: project.path,
            now: now
        )

        XCTAssertEqual(stats.runCount, 2)
        XCTAssertEqual(stats.medianMilliseconds, 180_000)
        XCTAssertEqual(stats.averageMilliseconds, 180_000)
        XCTAssertEqual(stats.p90Milliseconds, 240_000)
        XCTAssertEqual(stats.totalMilliseconds, 360_000)
        XCTAssertTrue(stats.isBackfillComplete)
        XCTAssertEqual(try fixture.scalarInt("SELECT COUNT(*) FROM agent_runs;"), 7)
        XCTAssertEqual(
            try fixture.scalarInt("SELECT COUNT(*) FROM agent_runs WHERE run_kind = 'user';"),
            3
        )
        XCTAssertEqual(
            try fixture.scalarInt("SELECT COUNT(*) FROM agent_runs WHERE run_kind = 'unknown';"),
            1
        )

        _ = try MetagentCore.refreshSkillUsage(options: fixture.options)
        XCTAssertEqual(
            try MetagentCore.agentRunDurationStats(
                databasePath: fixture.database.path,
                projectRoot: project.path,
                now: now
            ).runCount,
            2
        )
    }

    func testDailyCountsUseHistoryCalendarAndSkipInvalidTimestamps() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = MetagentCore.loadSkillUsageSnapshot(databasePath: fixture.database.path)
        let path = fixture.root.appendingPathComponent("workspace/.agents/skills/demo").path
        try fixture.executeSQL("""
        INSERT INTO skill_usage_events (
          event_id, skill_id, skill_name, canonical_path, scope, occurred_at,
          session_id, turn_id, cwd, evidence, invocation_kind, confidence,
          source_path, call_id
        ) VALUES
          ('one', 'project:demo', 'demo', '\(path)', 'project', '2026-07-20T06:30:00Z',
           'session', 'turn', '\(fixture.root.path)', 'session_backfill', 'skill_file_read',
           'observed', '/tmp/one', 'one'),
          ('two', 'project:demo', 'demo', '\(path)', 'project', '2026-07-20T08:30:00Z',
           'session', 'turn', '\(fixture.root.path)', 'session_backfill', 'skill_file_read',
           'observed', '/tmp/two', 'two'),
          ('empty', 'project:demo', 'demo', '\(path)', 'project', '',
           'session', 'turn', '\(fixture.root.path)', 'session_backfill', 'skill_file_read',
           'observed', '/tmp/empty', 'empty'),
          ('malformed', 'project:demo', 'demo', '\(path)', 'project', 'not-a-date',
           'session', 'turn', '\(fixture.root.path)', 'session_backfill', 'skill_file_read',
           'observed', '/tmp/malformed', 'malformed');
        """)
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!

        let counts = try MetagentCore.skillUsageDailyCounts(
            databasePath: fixture.database.path,
            calendar: pacific
        )

        XCTAssertEqual(counts.map(\.day), ["2026-07-19", "2026-07-20"])
        XCTAssertEqual(counts.map(\.count), [1, 1])
    }

    func testIncrementalBackfillPreservesRepeatedReadsWithoutDoubleCountingRescans() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let localSkill = try fixture.makeSkill(
            at: "workspace/.agents/skills/test-skill",
            name: "test-skill"
        )
        let pluginSkill = try fixture.makeSkill(
            at: ".codex/plugins/cache/openai-curated-remote/coderabbit/1.1.4/skills/coderabbit-review",
            name: "code-review"
        )
        let rollout = fixture.sessions.appendingPathComponent("rollout-test.jsonl")
        try fixture.write([
            fixture.line(type: "session_meta", payload: [
                "id": "session-1",
                "cwd": fixture.root.path
            ]),
            fixture.line(type: "turn_context", payload: [
                "turn_id": "turn-1",
                "cwd": fixture.root.path
            ]),
            fixture.toolCall(callID: "call-1", command: "sed -n '1,200p' \(localSkill.path)"),
            fixture.toolCall(callID: "call-2", command: "sed -n '1,200p' \(localSkill.path)"),
            fixture.toolCall(callID: "call-3", command: "sed -n '1,200p' \(pluginSkill.path)")
        ], to: rollout)

        let options = SkillUsageRefreshOptions(
            sessionRoots: [fixture.sessions.path],
            databasePath: fixture.database.path,
            maxBytes: 1_024 * 1_024,
            maxFiles: 20
        )
        let first = try MetagentCore.refreshSkillUsage(options: options)
        XCTAssertTrue(first.snapshot.isBackfillComplete)
        XCTAssertEqual(first.invocationsAdded, 3)

        let local = try XCTUnwrap(first.snapshot.summaries.first { $0.skillName == "test-skill" })
        XCTAssertEqual(local.totalInvocations, 2)
        XCTAssertEqual(local.activeTurns, 1)
        XCTAssertEqual(local.distinctThreads, 1)
        XCTAssertEqual(local.repeatInvocations, 1)
        XCTAssertEqual(local.inferredInvocations, 2)

        let plugin = try XCTUnwrap(first.snapshot.summaries.first { $0.skillName == "coderabbit:code-review" })
        XCTAssertEqual(plugin.scope, "plugin")
        XCTAssertEqual(plugin.totalInvocations, 1)

        try fixture.append([
            fixture.line(type: "turn_context", payload: [
                "turn_id": "turn-2",
                "cwd": fixture.root.path
            ]),
            fixture.toolCall(callID: "call-4", command: "sed -n '1,200p' \(localSkill.path)")
        ], to: rollout)

        let second = try MetagentCore.refreshSkillUsage(options: options)
        let updated = try XCTUnwrap(second.snapshot.summaries.first { $0.skillName == "test-skill" })
        XCTAssertEqual(second.invocationsAdded, 1)
        XCTAssertEqual(updated.totalInvocations, 3)
        XCTAssertEqual(updated.activeTurns, 2)
        XCTAssertEqual(updated.repeatInvocations, 1)

        let third = try MetagentCore.refreshSkillUsage(options: options)
        XCTAssertEqual(third.invocationsAdded, 0)
        XCTAssertEqual(third.snapshot.totalInvocations, 4)
    }

    func testUsageAggregatesAcrossFrontmatterNameChangesAtOneCanonicalPath() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(
            at: "workspace/.agents/skills/renamed-skill",
            name: "old-name"
        )
        let firstRollout = fixture.sessions.appendingPathComponent("rollout-before-rename.jsonl")
        try fixture.write([
            fixture.line(
                timestamp: "2026-07-19T12:00:00.000Z",
                type: "session_meta",
                payload: ["id": "rename-session", "cwd": fixture.root.path]
            ),
            fixture.line(
                timestamp: "2026-07-19T12:00:01.000Z",
                type: "turn_context",
                payload: ["turn_id": "rename-turn", "cwd": fixture.root.path]
            ),
            fixture.toolCall(callID: "call-before-rename", command: "cat \(skill.path)")
        ], to: firstRollout)
        _ = try MetagentCore.refreshSkillUsage(options: fixture.options)

        try "---\nname: new-name\ndescription: fixture\n---\n".write(
            to: skill,
            atomically: true,
            encoding: .utf8
        )
        let secondRollout = fixture.sessions.appendingPathComponent("rollout-after-rename.jsonl")
        try fixture.write([
            fixture.line(
                timestamp: "2026-07-19T12:01:00.000Z",
                type: "session_meta",
                payload: ["id": "rename-session", "cwd": fixture.root.path]
            ),
            fixture.line(
                timestamp: "2026-07-19T12:01:01.000Z",
                type: "turn_context",
                payload: ["turn_id": "rename-turn", "cwd": fixture.root.path]
            ),
            fixture.toolCall(callID: "call-after-rename", command: "cat \(skill.path)")
        ], to: secondRollout)

        let summaries = try MetagentCore.refreshSkillUsage(options: fixture.options).snapshot.summaries
        let summary = try XCTUnwrap(summaries.first { $0.canonicalPath == skill.deletingLastPathComponent().path })
        XCTAssertEqual(summaries.filter { $0.canonicalPath == summary.canonicalPath }.count, 1)
        XCTAssertEqual(summary.skillName, "new-name")
        XCTAssertEqual(summary.totalInvocations, 2)
        XCTAssertEqual(summary.activeTurns, 1)
        XCTAssertEqual(summary.distinctThreads, 1)
        XCTAssertEqual(summary.repeatInvocations, 1)
    }

    func testPluginUsageAggregatesAcrossVersionedCachePaths() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let oldSkill = try fixture.makeSkill(
            at: ".codex/plugins/cache/openai-curated/example-plugin/1.0.0/skills/example-skill",
            name: "old-name"
        )
        let newSkill = try fixture.makeSkill(
            at: ".codex/plugins/cache/openai-curated-remote/example-plugin/2.0.0/skills/example-skill",
            name: "new-name"
        )
        try fixture.write([
            fixture.line(
                timestamp: "2026-07-19T12:00:00.000Z",
                type: "session_meta",
                payload: ["id": "plugin-session", "cwd": fixture.root.path]
            ),
            fixture.line(
                timestamp: "2026-07-19T12:00:01.000Z",
                type: "turn_context",
                payload: ["turn_id": "plugin-turn", "cwd": fixture.root.path]
            ),
            fixture.toolCall(callID: "call-old-plugin", command: "cat \(oldSkill.path)")
        ], to: fixture.sessions.appendingPathComponent("rollout-old-plugin.jsonl"))
        _ = try MetagentCore.refreshSkillUsage(options: fixture.options)
        try fixture.write([
            fixture.line(
                timestamp: "2026-07-19T12:01:00.000Z",
                type: "session_meta",
                payload: ["id": "plugin-session", "cwd": fixture.root.path]
            ),
            fixture.line(
                timestamp: "2026-07-19T12:01:01.000Z",
                type: "turn_context",
                payload: ["turn_id": "plugin-turn", "cwd": fixture.root.path]
            ),
            fixture.toolCall(callID: "call-new-plugin", command: "cat \(newSkill.path)")
        ], to: fixture.sessions.appendingPathComponent("rollout-new-plugin.jsonl"))

        let summaries = try MetagentCore.refreshSkillUsage(options: fixture.options).snapshot.summaries
        let summary = try XCTUnwrap(summaries.first {
            $0.id == "plugin:openai-curated/example-plugin:example-skill"
        })
        XCTAssertEqual(summaries.filter { $0.id == summary.id }.count, 1)
        XCTAssertEqual(summary.skillName, "example-plugin:new-name")
        XCTAssertEqual(summary.canonicalPath, newSkill.deletingLastPathComponent().path)
        XCTAssertEqual(summary.totalInvocations, 2)
        XCTAssertEqual(summary.activeTurns, 1)
        XCTAssertEqual(summary.distinctThreads, 1)
        XCTAssertEqual(summary.repeatInvocations, 1)
    }

    func testPluginUsageKeepsSeparateMarketplacesDistinct() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let curated = try fixture.makeSkill(
            at: ".codex/plugins/cache/openai-curated/example-plugin/1.0.0/skills/example-skill",
            name: "curated-name"
        )
        let bundled = try fixture.makeSkill(
            at: ".codex/plugins/cache/openai-bundled/example-plugin/1.0.0/skills/example-skill",
            name: "bundled-name"
        )
        try fixture.write([
            fixture.line(
                timestamp: "2026-07-19T12:00:00.000Z",
                type: "session_meta",
                payload: ["id": "marketplace-session", "cwd": fixture.root.path]
            ),
            fixture.line(
                timestamp: "2026-07-19T12:00:01.000Z",
                type: "turn_context",
                payload: ["turn_id": "marketplace-turn", "cwd": fixture.root.path]
            ),
            fixture.toolCall(callID: "call-curated-plugin", command: "cat \(curated.path)"),
            fixture.toolCall(callID: "call-bundled-plugin", command: "cat \(bundled.path)")
        ], to: fixture.sessions.appendingPathComponent("rollout-marketplaces.jsonl"))

        let summaries = try MetagentCore.refreshSkillUsage(options: fixture.options).snapshot.summaries
        let pluginSummaries = summaries.filter { $0.scope == "plugin" }

        XCTAssertEqual(pluginSummaries.count, 2)
        XCTAssertEqual(
            Set(pluginSummaries.map(\.id)),
            [
                "plugin:openai-curated/example-plugin:example-skill",
                "plugin:openai-bundled/example-plugin:example-skill",
            ]
        )
        XCTAssertTrue(pluginSummaries.allSatisfy { $0.totalInvocations == 1 })
    }

    func testSameSkillIdentityAtDifferentPathsProducesUniqueSummaryIDs() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.makeSkill(
            at: "workspace/.agents/skills/first-folder",
            name: "shared-name"
        )
        let second = try fixture.makeSkill(
            at: "workspace/.agents/skills/second-folder",
            name: "shared-name"
        )
        try fixture.write([
            fixture.line(
                timestamp: "2026-07-19T12:00:00.000Z",
                type: "session_meta",
                payload: ["id": "path-collision-session", "cwd": fixture.root.path]
            ),
            fixture.toolCall(callID: "call-first-path", command: "cat \(first.path)"),
            fixture.toolCall(callID: "call-second-path", command: "cat \(second.path)")
        ], to: fixture.sessions.appendingPathComponent("rollout-path-collision.jsonl"))

        let summaries = try MetagentCore.refreshSkillUsage(options: fixture.options).snapshot.summaries
        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(Set(summaries.map(\.id)).count, 2)
        XCTAssertTrue(summaries.allSatisfy { $0.id.hasPrefix("path:") })
    }

    func testSnapshotProjectionPreservesIdentityTiesAndAllUsageCounts() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try MetagentCore.refreshSkillUsage(options: fixture.options)
        try fixture.executeSQL("""
        INSERT INTO skill_usage_events (
          event_id, skill_id, skill_name, canonical_path, scope, occurred_at,
          session_id, turn_id, cwd, evidence, invocation_kind, confidence,
          source_path, call_id
        ) VALUES
          ('old', 'old-id', 'Old name', '/fixture/skill', 'project',
           strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-35 days'),
           'session-1', 'turn-1', '', 'inferred', 'read', 'high', '', ''),
          ('middle', 'middle-id', 'Middle name', '/fixture/skill', 'project',
           strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-8 days'),
           'session-1', 'turn-2', '', 'otel', 'read', 'high', '', ''),
          ('tied-first', 'previous-id', 'Previous name', '/fixture/skill', 'project',
           strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-1 day'),
           'session-2', 'turn-1', '', 'inferred', 'read', 'high', '', ''),
          ('tied-last', 'latest-id', 'Latest name', '/fixture/skill', 'global',
           strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-1 day'),
           'session-2', 'turn-1', '', 'otel', 'read', 'high', '', '');
        """)
        let before = try XCTUnwrap(MetagentCore.loadSkillUsageSnapshot(databasePath: fixture.database.path))
        let summary = try XCTUnwrap(before.summaries.first)
        XCTAssertEqual(before.summaries.count, 1)
        XCTAssertEqual(summary.id, "latest-id")
        XCTAssertEqual(summary.skillName, "Latest name")
        XCTAssertEqual(summary.canonicalPath, "/fixture/skill")
        XCTAssertEqual(summary.scope, "global")
        XCTAssertEqual(summary.totalInvocations, 4)
        XCTAssertEqual(summary.invocations7d, 2)
        XCTAssertEqual(summary.invocations30d, 3)
        XCTAssertEqual(summary.activeTurns, 3)
        XCTAssertEqual(summary.distinctThreads, 2)
        XCTAssertEqual(summary.repeatInvocations, 1)
        XCTAssertEqual(summary.directInvocations, 2)
        XCTAssertEqual(summary.inferredInvocations, 2)
        XCTAssertLessThan(summary.firstUsedAt, summary.lastUsedAt)

        // These columns remain canonical source provenance, but none is an
        // input to the displayed summary (including equal-time rowid ranking).
        try fixture.executeSQL("""
        UPDATE skill_usage_events SET
          event_id = 'changed-' || event_id,
          cwd = '/fixture/' || hex(zeroblob(256)),
          invocation_kind = 'changed-kind',
          confidence = 'changed-confidence',
          source_path = '/sessions/' || hex(zeroblob(256)),
          call_id = 'changed-call';
        """)
        XCTAssertEqual(
            MetagentCore.loadSkillUsageSnapshot(databasePath: fixture.database.path),
            before
        )
    }

    func testDefersAnIncompleteFinalRecordUntilItIsTerminated() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(at: "workspace/.agents/skills/deferred", name: "deferred")
        let rollout = fixture.sessions.appendingPathComponent("rollout-partial.jsonl")
        let pendingLine = fixture.toolCall(callID: "call-pending", command: "cat \(skill.path)")
        let prefixCount = pendingLine.utf8.count - 12

        try fixture.write([
            fixture.line(type: "session_meta", payload: ["id": "partial-session", "cwd": fixture.root.path]),
            fixture.line(type: "turn_context", payload: ["turn_id": "turn-1", "cwd": fixture.root.path]),
            fixture.toolCall(callID: "call-complete", command: "cat \(skill.path)")
        ], to: rollout)
        try fixture.appendRaw(String(pendingLine.prefix(prefixCount)), to: rollout)

        let first = try MetagentCore.refreshSkillUsage(options: fixture.options)
        XCTAssertEqual(first.snapshot.totalInvocations, 1)
        XCTAssertFalse(first.snapshot.isBackfillComplete)

        let stalled = try MetagentCore.refreshSkillUsage(options: fixture.options)
        XCTAssertEqual(stalled.processedBytesAdvanced, 0)
        XCTAssertTrue(stalled.hasMore)

        try fixture.appendRaw(String(pendingLine.dropFirst(prefixCount)) + "\n", to: rollout)
        let second = try MetagentCore.refreshSkillUsage(options: fixture.options)
        XCTAssertEqual(second.invocationsAdded, 1)
        XCTAssertEqual(second.snapshot.totalInvocations, 2)
        XCTAssertTrue(second.snapshot.isBackfillComplete)
    }

    func testCountsOnlySupportedReadsAndHandlesQuotedPathsWithSpaces() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(
            at: "workspace with spaces/.agents/skills/skill with spaces",
            name: "space-skill"
        )
        let rollout = fixture.sessions.appendingPathComponent("rollout-spaces.jsonl")
        try fixture.write([
            fixture.line(type: "session_meta", payload: ["id": "space-session", "cwd": fixture.root.path]),
            fixture.line(type: "turn_context", payload: ["turn_id": "turn-1", "cwd": fixture.root.path]),
            fixture.toolCall(callID: "call-edit", command: "*** Update File: \(skill.path)", name: "apply_patch"),
            fixture.toolCall(callID: "call-reference", command: "echo \(skill.path)"),
            fixture.toolCall(callID: "call-quoted", command: "rg 'cat \(skill.path)' script.sh"),
            fixture.toolCall(
                callID: "call-heredoc",
                command: "cat <<'EOF' > script.sh\ncat \(skill.path)\nEOF"
            ),
            fixture.toolCall(
                callID: "call-write-target",
                command: "cat <<'EOF' > \(skill.path)\nreplacement\nEOF"
            ),
            fixture.toolCall(
                callID: "call-backup-file",
                command: "cat \(skill.path).bak",
                outputOverride: "backup content"
            ),
            fixture.toolCall(
                callID: "call-unknown-failure",
                command: "cat \(skill.path)",
                outputOverride: "cat: \(skill.path): No such file or directory"
            ),
            fixture.toolCall(
                callID: "call-conditional",
                command: "if false; then cat \(skill.path); fi"
            ),
            fixture.toolCall(
                callID: "call-failed",
                command: "cat \(skill.path)",
                succeeded: false
            ),
            fixture.toolCall(callID: "call-read", command: "sed -n '1,200p' '\(skill.path)'")
        ], to: rollout)

        let report = try MetagentCore.refreshSkillUsage(options: fixture.options)
        XCTAssertEqual(report.snapshot.totalInvocations, 1)
        let summary = try XCTUnwrap(report.snapshot.summaries.first)
        XCTAssertEqual(summary.skillName, "space-skill")
        XCTAssertEqual(summary.scope, "project")
        XCTAssertEqual(summary.canonicalPath, skill.deletingLastPathComponent().path)
    }

    func testReindexesAFileThatShrinks() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(at: "workspace/.agents/skills/replaced", name: "replaced")
        let rollout = fixture.sessions.appendingPathComponent("rollout-replaced.jsonl")
        try fixture.write([
            fixture.line(type: "session_meta", payload: ["id": "old-session", "cwd": fixture.root.path]),
            fixture.line(type: "turn_context", payload: ["turn_id": "old-turn", "cwd": fixture.root.path]),
            fixture.toolCall(callID: "old-call-1", command: "cat \(skill.path)"),
            fixture.toolCall(callID: "old-call-2", command: "cat \(skill.path)")
        ], to: rollout)
        XCTAssertEqual(
            try MetagentCore.refreshSkillUsage(options: fixture.options).snapshot.totalInvocations,
            2
        )

        try fixture.write([
            fixture.line(type: "session_meta", payload: ["id": "new-session", "cwd": fixture.root.path]),
            fixture.toolCall(callID: "new-call", command: "cat \(skill.path)")
        ], to: rollout)
        let replacement = try MetagentCore.refreshSkillUsage(options: fixture.options)
        XCTAssertEqual(replacement.invocationsAdded, 1)
        XCTAssertEqual(replacement.snapshot.totalInvocations, 1)
        XCTAssertEqual(replacement.snapshot.summaries.first?.distinctThreads, 1)
    }

    func testReindexesASameSizedReplacement() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let oldSkill = try fixture.makeSkill(at: "workspace/.agents/skills/oldskill", name: "oldskill")
        let newSkill = try fixture.makeSkill(at: "workspace/.agents/skills/newskill", name: "newskill")
        let rollout = fixture.sessions.appendingPathComponent("rollout-same-size.jsonl")
        try fixture.write([
            fixture.line(type: "session_meta", payload: ["id": "old-session", "cwd": fixture.root.path]),
            fixture.toolCall(callID: "same-call", command: "cat \(oldSkill.path)")
        ], to: rollout)
        let oldSize = try XCTUnwrap(try rollout.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertEqual(
            try MetagentCore.refreshSkillUsage(options: fixture.options).snapshot.summaries.map(\.skillName),
            ["oldskill"]
        )

        try fixture.write([
            fixture.line(type: "session_meta", payload: ["id": "new-session", "cwd": fixture.root.path]),
            fixture.toolCall(callID: "same-call", command: "cat \(newSkill.path)")
        ], to: rollout)
        let newSize = try XCTUnwrap(try rollout.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertEqual(oldSize, newSize)

        let replacement = try MetagentCore.refreshSkillUsage(options: fixture.options)
        XCTAssertEqual(replacement.invocationsAdded, 1)
        XCTAssertEqual(replacement.snapshot.summaries.map(\.skillName), ["newskill"])
    }

    func testExpandedPrefixDetectsAnInPlaceRewriteAfterAFileGrows() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let oldSkill = try fixture.makeSkill(
            at: "workspace/.agents/skills/oldskill",
            name: "oldskill"
        )
        _ = try fixture.makeSkill(
            at: "workspace/.agents/skills/newskill",
            name: "newskill"
        )
        let rollout = fixture.sessions.appendingPathComponent("rollout-growing-prefix.jsonl")
        try fixture.write([
            fixture.line(type: "session_meta", payload: [
                "id": "prefix-session",
                "cwd": fixture.root.path
            ])
        ], to: rollout)
        XCTAssertEqual(
            try MetagentCore.refreshSkillUsage(options: fixture.options).snapshot.totalInvocations,
            0
        )

        var appended = [
            fixture.line(type: "turn_context", payload: [
                "turn_id": "prefix-turn",
                "cwd": fixture.root.path
            ]),
            fixture.toolCall(callID: "prefix-call", command: "cat \(oldSkill.path)"),
        ]
        appended += (0..<100).map { index in
            fixture.line(type: "event_msg", payload: [
                "type": "token_count",
                "index": index
            ])
        }
        try fixture.append(appended, to: rollout)
        let grown = try MetagentCore.refreshSkillUsage(options: fixture.options)
        XCTAssertEqual(grown.snapshot.summaries.map(\.skillName), ["oldskill"])
        XCTAssertGreaterThan(
            try XCTUnwrap(try rollout.resourceValues(forKeys: [.fileSizeKey]).fileSize),
            8_192
        )

        let oldContents = try String(contentsOf: rollout, encoding: .utf8)
        let oldNameRange = try XCTUnwrap(oldContents.range(of: "oldskill"))
        let oldNameOffset = oldContents[..<oldNameRange.lowerBound].utf8.count
        XCTAssertLessThan(oldNameOffset, 8_192)
        let newContents = oldContents.replacingOccurrences(of: "oldskill", with: "newskill")
        XCTAssertEqual(oldContents.utf8.count, newContents.utf8.count)
        try newContents.write(to: rollout, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)],
            ofItemAtPath: rollout.path
        )

        let rewritten = try MetagentCore.refreshSkillUsage(options: fixture.options)
        XCTAssertEqual(rewritten.snapshot.summaries.map(\.skillName), ["newskill"])
        XCTAssertEqual(rewritten.snapshot.totalInvocations, 1)
    }

    func testCarriesCursorWhenCodexMovesASessionToArchive() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(at: "workspace/.agents/skills/archived", name: "archived")
        let rollout = fixture.sessions.appendingPathComponent("rollout-archive.jsonl")
        try fixture.write([
            fixture.line(type: "session_meta", payload: ["id": "archive-session", "cwd": fixture.root.path]),
            fixture.toolCall(callID: "archive-read", command: "cat \(skill.path)")
        ], to: rollout)
        XCTAssertEqual(
            try MetagentCore.refreshSkillUsage(options: fixture.options).snapshot.totalInvocations,
            1
        )

        let archived = fixture.root.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        let archivedRollout = archived.appendingPathComponent(rollout.lastPathComponent)
        try FileManager.default.moveItem(at: rollout, to: archivedRollout)
        let report = try MetagentCore.refreshSkillUsage(options: SkillUsageRefreshOptions(
            sessionRoots: [fixture.sessions.path, archived.path],
            databasePath: fixture.database.path,
            maxBytes: 1_024 * 1_024,
            maxFiles: 20
        ))
        XCTAssertEqual(report.bytesRead, 0)
        XCTAssertEqual(report.snapshot.totalInvocations, 1)
        XCTAssertTrue(report.snapshot.isBackfillComplete)
    }

    func testCountsSuccessfulFunctionCallReads() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(at: "workspace/.agents/skills/function-read", name: "function-read")
        let rollout = fixture.sessions.appendingPathComponent("rollout-function.jsonl")
        try fixture.write([
            fixture.line(type: "session_meta", payload: ["id": "function-session", "cwd": fixture.root.path]),
            fixture.functionCall(callID: "function-read", command: "cat \(skill.path)")
        ], to: rollout)

        let report = try MetagentCore.refreshSkillUsage(options: fixture.options)
        XCTAssertEqual(report.snapshot.totalInvocations, 1)
        XCTAssertEqual(report.snapshot.summaries.first?.skillName, "function-read")
    }

    func testCountsSuccessfulLegacyShellCommandReads() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(
            at: "workspace/.agents/skills/legacy-shell",
            name: "legacy-shell"
        )
        let rollout = fixture.sessions.appendingPathComponent("rollout-legacy-shell.jsonl")
        try fixture.write([
            fixture.line(type: "session_meta", payload: [
                "id": "legacy-shell-session",
                "cwd": fixture.root.path
            ]),
            fixture.legacyShellCall(callID: "legacy-shell-read", command: "cat \(skill.path)")
        ], to: rollout)

        let report = try MetagentCore.refreshSkillUsage(options: fixture.options)
        XCTAssertEqual(report.snapshot.totalInvocations, 1)
        XCTAssertEqual(report.snapshot.summaries.first?.skillName, "legacy-shell")
    }

    func testResolvesRelativeReadsAgainstWorkdirAndLeadingCD() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let workspace = fixture.root.appendingPathComponent("workspace")
        let skill = try fixture.makeSkill(at: "workspace/.agents/skills/relative", name: "relative")
        let relativePath = ".agents/skills/relative/SKILL.md"
        let rollout = fixture.sessions.appendingPathComponent("rollout-relative.jsonl")
        try fixture.write([
            fixture.line(type: "session_meta", payload: ["id": "relative-session", "cwd": fixture.root.path]),
            fixture.toolCall(
                callID: "workdir-read",
                command: "cat \(relativePath)",
                workdir: workspace.path
            ),
            fixture.toolCall(
                callID: "cd-read",
                command: "cd \(workspace.path) && cat \(relativePath)"
            )
        ], to: rollout)

        let summary = try XCTUnwrap(
            try MetagentCore.refreshSkillUsage(options: fixture.options).snapshot.summaries.first
        )
        XCTAssertEqual(summary.totalInvocations, 2)
        XCTAssertEqual(summary.canonicalPath, skill.deletingLastPathComponent().path)
    }

    func testMultipleWrapperReadsKeepPerCommandWorkdirsAndRepeats() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let firstWorkspace = fixture.root.appendingPathComponent("first-workspace")
        let secondWorkspace = fixture.root.appendingPathComponent("second-workspace")
        let firstSkill = try fixture.makeSkill(
            at: "first-workspace/.agents/skills/first-skill",
            name: "first-skill"
        )
        let secondSkill = try fixture.makeSkill(
            at: "second-workspace/.agents/skills/second-skill",
            name: "second-skill"
        )
        let rollout = fixture.sessions.appendingPathComponent("rollout-multi-wrapper.jsonl")
        try fixture.write([
            fixture.line(type: "session_meta", payload: [
                "id": "multi-session",
                "cwd": secondWorkspace.path
            ]),
            fixture.multiToolCall(
                callID: "multi-read",
                commands: [
                    ("cat .agents/skills/first-skill/SKILL.md", firstWorkspace.path),
                    ("cat .agents/skills/second-skill/SKILL.md", nil),
                    ("cat .agents/skills/first-skill/SKILL.md", firstWorkspace.path)
                ],
                skillFiles: [firstSkill, secondSkill]
            )
        ], to: rollout)

        let summaries = try MetagentCore.refreshSkillUsage(options: fixture.options).snapshot.summaries
        XCTAssertEqual(summaries.first { $0.skillName == "first-skill" }?.totalInvocations, 2)
        XCTAssertEqual(summaries.first { $0.skillName == "first-skill" }?.repeatInvocations, 1)
        XCTAssertEqual(summaries.first { $0.skillName == "second-skill" }?.totalInvocations, 1)
    }

    func testRepeatedReadsInsideOneShellCommandRemainDistinct() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(
            at: "workspace/.agents/skills/same-command-repeat",
            name: "same-command-repeat"
        )
        let rollout = fixture.sessions.appendingPathComponent("rollout-same-command-repeat.jsonl")
        try fixture.write([
            fixture.line(type: "session_meta", payload: [
                "id": "same-command-repeat-session",
                "cwd": fixture.root.path
            ]),
            fixture.toolCall(
                callID: "same-command-repeat",
                command: "cat \(skill.path); cat \(skill.path)"
            )
        ], to: rollout)

        let summary = try XCTUnwrap(
            try MetagentCore.refreshSkillUsage(options: fixture.options).snapshot.summaries.first
        )
        XCTAssertEqual(summary.totalInvocations, 2)
        XCTAssertEqual(summary.repeatInvocations, 1)
    }

    func testHistoricalOutputConfirmsASkillRemovedBeforeBackfill() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(at: "workspace/.agents/skills/removed-skill", name: "removed-skill")
        let rollout = fixture.sessions.appendingPathComponent("rollout-removed-skill.jsonl")
        try fixture.write([
            fixture.line(type: "session_meta", payload: ["id": "removed-session", "cwd": fixture.root.path]),
            fixture.toolCall(callID: "removed-read", command: "cat \(skill.path)")
        ], to: rollout)
        try FileManager.default.removeItem(at: skill.deletingLastPathComponent())

        let report = try MetagentCore.refreshSkillUsage(options: fixture.options)
        XCTAssertEqual(report.snapshot.totalInvocations, 1)
        XCTAssertEqual(report.snapshot.summaries.first?.skillName, "removed-skill")
    }

    func testClassifiesIndependentCodexAndClaudeCopiesWithoutCollapsingThem() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let codexSkill = try fixture.makeSkill(
            at: "workspace/.codex/skills/independent",
            name: "independent"
        )
        let claudeSkill = try fixture.makeSkill(
            at: "workspace/.claude/skills/independent",
            name: "independent"
        )
        let rollout = fixture.sessions.appendingPathComponent("rollout-containers.jsonl")
        try fixture.write([
            fixture.line(type: "session_meta", payload: ["id": "container-session", "cwd": fixture.root.path]),
            fixture.toolCall(callID: "codex-read", command: "cat \(codexSkill.path)"),
            fixture.toolCall(callID: "claude-read", command: "cat \(claudeSkill.path)")
        ], to: rollout)

        let summaries = try MetagentCore.refreshSkillUsage(options: fixture.options).snapshot.summaries
        XCTAssertEqual(summaries.count, 2)
        XCTAssertTrue(summaries.allSatisfy { $0.scope == "project" })
        XCTAssertEqual(Set(summaries.map(\.id)).count, 2)
        XCTAssertTrue(summaries.contains { $0.id.contains(":codex:independent") })
        XCTAssertTrue(summaries.contains { $0.id.contains(":claude:independent") })
    }

    func testDefaultPathsHonorRedirectedHome() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let previousHome = ProcessInfo.processInfo.environment["HOME"]
        let previousCodexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
        setenv("HOME", fixture.root.path, 1)
        unsetenv("CODEX_HOME")
        defer {
            restoreEnvironment("HOME", previousHome)
            restoreEnvironment("CODEX_HOME", previousCodexHome)
        }

        let skill = try fixture.makeSkill(at: ".agents/skills/global-skill", name: "global-skill")
        let defaultSessions = fixture.root.appendingPathComponent(".codex/sessions")
        try FileManager.default.createDirectory(at: defaultSessions, withIntermediateDirectories: true)
        try fixture.write([
            fixture.line(type: "session_meta", payload: ["id": "profile-session", "cwd": fixture.root.path]),
            fixture.toolCall(callID: "profile-read", command: "cat ~/.agents/skills/global-skill/SKILL.md")
        ], to: defaultSessions.appendingPathComponent("rollout-profile.jsonl"))

        let report = try MetagentCore.refreshSkillUsage(options: SkillUsageRefreshOptions(
            maxBytes: 1_024 * 1_024,
            maxFiles: 20
        ))
        XCTAssertEqual(report.snapshot.summaries.first?.scope, "global")
        XCTAssertEqual(report.snapshot.summaries.first?.canonicalPath, skill.deletingLastPathComponent().path)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent("Library/Application Support/Metagent/usage.sqlite").path
        ))
    }

    func testRelocatedCodexHomeSkillsRemainGlobal() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let previousCodexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
        let relocatedCodexHome = fixture.root.appendingPathComponent("relocated-codex-home")
        setenv("CODEX_HOME", relocatedCodexHome.path, 1)
        defer { restoreEnvironment("CODEX_HOME", previousCodexHome) }

        let skill = try fixture.makeSkill(
            at: "relocated-codex-home/skills/relocated",
            name: "relocated"
        )
        let rollout = fixture.sessions.appendingPathComponent("rollout-relocated.jsonl")
        try fixture.write([
            fixture.line(type: "session_meta", payload: [
                "id": "relocated-session",
                "cwd": fixture.root.path
            ]),
            fixture.toolCall(callID: "relocated-read", command: "cat \(skill.path)")
        ], to: rollout)

        let summary = try XCTUnwrap(
            try MetagentCore.refreshSkillUsage(options: fixture.options).snapshot.summaries.first
        )
        XCTAssertEqual(summary.id, "global:codex:relocated")
        XCTAssertEqual(summary.scope, "global")
    }

    func testKeepsSystemAndUserCodexSkillsDistinct() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let previousHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", fixture.root.path, 1)
        defer { restoreEnvironment("HOME", previousHome) }
        let systemSkill = try fixture.makeSkill(at: ".codex/skills/.system/demo", name: "demo")
        let userSkill = try fixture.makeSkill(at: ".codex/skills/demo", name: "demo")
        let rollout = fixture.sessions.appendingPathComponent("rollout-system.jsonl")
        try fixture.write([
            fixture.line(type: "session_meta", payload: ["id": "system-session", "cwd": fixture.root.path]),
            fixture.toolCall(callID: "system-read", command: "cat \(systemSkill.path)"),
            fixture.toolCall(callID: "user-read", command: "cat \(userSkill.path)")
        ], to: rollout)

        let summaries = try MetagentCore.refreshSkillUsage(options: fixture.options).snapshot.summaries
        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(Set(summaries.map(\.scope)), Set(["system", "global"]))
        XCTAssertEqual(Set(summaries.map(\.id)).count, 2)
    }

    func testThrottleCarriesAcrossSmallFiles() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(at: "workspace/.agents/skills/throttled", name: "throttled")
        let first = fixture.sessions.appendingPathComponent("rollout-throttle-1.jsonl")
        let second = fixture.sessions.appendingPathComponent("rollout-throttle-2.jsonl")
        try fixture.write([
            fixture.line(type: "session_meta", payload: ["id": "throttle-1", "cwd": fixture.root.path]),
            fixture.toolCall(callID: "read-1", command: "cat \(skill.path)")
        ], to: first)
        try fixture.write([
            fixture.line(type: "session_meta", payload: ["id": "throttle-2", "cwd": fixture.root.path]),
            fixture.toolCall(callID: "read-2", command: "cat \(skill.path)")
        ], to: second)
        let firstSize = try XCTUnwrap(
            try first.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )
        let secondSize = try XCTUnwrap(
            try second.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )
        let interval = Int64(max(firstSize, secondSize) + 1)
        let startedAt = Date()
        let report = try MetagentCore.refreshSkillUsage(options: SkillUsageRefreshOptions(
            sessionRoots: [fixture.sessions.path],
            databasePath: fixture.database.path,
            maxBytes: 1_024 * 1_024,
            maxFiles: 20,
            throttleEveryBytes: interval,
            throttleDelayMilliseconds: 60
        ))

        XCTAssertEqual(report.snapshot.totalInvocations, 2)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(startedAt), 0.05)
    }

    func testRetriesARecordThatCrossesTheRefreshSliceBoundary() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(at: "workspace/.agents/skills/boundary", name: "boundary")
        let rollout = fixture.sessions.appendingPathComponent("rollout-boundary.jsonl")
        let session = fixture.line(type: "session_meta", payload: [
            "id": "boundary-session",
            "cwd": fixture.root.path
        ])
        let toolCall = fixture.toolCall(
            callID: "boundary-read",
            command: "cat \(skill.path)",
            outputOverride: String(repeating: "x", count: 2_000)
        )
        try fixture.write([session, toolCall], to: rollout)

        let first = try MetagentCore.refreshSkillUsage(options: SkillUsageRefreshOptions(
            sessionRoots: [fixture.sessions.path],
            databasePath: fixture.database.path,
            maxBytes: Int64(session.utf8.count + 128),
            maxFiles: 20
        ))
        XCTAssertEqual(first.snapshot.totalInvocations, 0)
        XCTAssertTrue(first.hasMore)
        XCTAssertTrue(first.warnings.isEmpty)

        let resumed = try MetagentCore.refreshSkillUsage(options: SkillUsageRefreshOptions(
            sessionRoots: [fixture.sessions.path],
            databasePath: fixture.database.path,
            maxBytes: 4_096,
            maxFiles: 20
        ))
        XCTAssertEqual(resumed.snapshot.totalInvocations, 1)
        XCTAssertTrue(resumed.snapshot.isBackfillComplete)
        XCTAssertTrue(resumed.warnings.isEmpty)
    }

    func testSkipsARecordLargerThanTheRecordLimitAndResumes() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(at: "workspace/.agents/skills/oversized", name: "oversized")
        let rollout = fixture.sessions.appendingPathComponent("rollout-oversized.jsonl")
        try fixture.write([
            fixture.line(type: "session_meta", payload: [
                "id": "oversized-session",
                "cwd": fixture.root.path,
                "padding": String(repeating: "x", count: 8_000)
            ]),
            fixture.toolCall(callID: "oversized-read", command: "cat \(skill.path)")
        ], to: rollout)

        let report = try MetagentCore.refreshSkillUsage(options: SkillUsageRefreshOptions(
            sessionRoots: [fixture.sessions.path],
            databasePath: fixture.database.path,
            maxBytes: 1_024,
            maxFiles: 20,
            maxRecordBytes: 1_024
        ))
        XCTAssertGreaterThan(report.bytesRead, 1_024)
        XCTAssertGreaterThan(report.processedBytesAdvanced, 1_024)
        XCTAssertEqual(report.snapshot.totalInvocations, 0)
        XCTAssertTrue(report.hasMore)
        XCTAssertEqual(report.warnings.count, 1)

        let resumed = try MetagentCore.refreshSkillUsage(options: SkillUsageRefreshOptions(
            sessionRoots: [fixture.sessions.path],
            databasePath: fixture.database.path,
            maxBytes: 1_024 * 1_024,
            maxFiles: 20
        ))
        XCTAssertEqual(resumed.snapshot.totalInvocations, 1)
        XCTAssertTrue(resumed.snapshot.isBackfillComplete)
    }

    func testSuccessfulPartialReadWithoutFrontmatterIsObserved() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(
            at: "workspace/.agents/skills/partial-read",
            name: "partial-read"
        )
        let rollout = fixture.sessions.appendingPathComponent("rollout-partial-read.jsonl")
        try fixture.write([
            fixture.line(type: "session_meta", payload: [
                "id": "partial-read-session",
                "cwd": fixture.root.path
            ]),
            fixture.toolCall(
                callID: "partial-read",
                command: "tail -n 1 \(skill.path)",
                outputOverride: "final instruction line"
            )
        ], to: rollout)

        let report = try MetagentCore.refreshSkillUsage(options: fixture.options)
        XCTAssertEqual(report.snapshot.totalInvocations, 1)
        XCTAssertEqual(report.snapshot.summaries.first?.skillName, "partial-read")
    }

    func testSkillContentDoesNotOverrideSuccessfulProcessStatus() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(
            at: "workspace/.agents/skills/failure-examples",
            name: "failure-examples"
        )
        let rollout = fixture.sessions.appendingPathComponent("rollout-failure-examples.jsonl")
        try fixture.write([
            fixture.line(type: "session_meta", payload: [
                "id": "failure-examples-session",
                "cwd": fixture.root.path
            ]),
            fixture.toolCall(
                callID: "failure-examples-read",
                command: "cat \(skill.path)",
                outputOverride: "---\nname: failure-examples\n---\nScript failed\nProcess exited with code 1\n\"exit_code\": 1"
            )
        ], to: rollout)

        let report = try MetagentCore.refreshSkillUsage(options: fixture.options)
        XCTAssertEqual(report.snapshot.totalInvocations, 1)
        XCTAssertEqual(report.snapshot.summaries.first?.skillName, "failure-examples")
    }

    func testNestedCommandFailureOverridesCompletedWrapper() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(
            at: "workspace/.agents/skills/nested-failure",
            name: "nested-failure"
        )
        let rollout = fixture.sessions.appendingPathComponent("rollout-nested-failure.jsonl")
        try fixture.write([
            fixture.line(type: "session_meta", payload: [
                "id": "nested-failure-session",
                "cwd": fixture.root.path
            ]),
            fixture.toolCall(
                callID: "nested-failure-read",
                command: "cat \(skill.path)",
                outputOverride: "{\"exit_code\":1,\"output\":\"cat failed\"}"
            )
        ], to: rollout)

        let report = try MetagentCore.refreshSkillUsage(options: fixture.options)
        XCTAssertEqual(report.snapshot.totalInvocations, 0)
    }

    func testCompoundCommandUsesPerReadEvidenceInsteadOfAggregateExit() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let valid = try fixture.makeSkill(
            at: "workspace/.agents/skills/compound-valid",
            name: "compound-valid"
        )
        let missing = fixture.root.appendingPathComponent(
            "workspace/.agents/skills/compound-missing/SKILL.md"
        )
        let rollout = fixture.sessions.appendingPathComponent("rollout-compound-status.jsonl")
        try fixture.write([
            fixture.line(type: "session_meta", payload: [
                "id": "compound-status-session",
                "cwd": fixture.root.path
            ]),
            fixture.toolCall(
                callID: "aggregate-success",
                command: "cat \(missing.path); true",
                outputOverride: "cat: \(missing.path): No such file or directory"
            ),
            fixture.toolCall(
                callID: "aggregate-failure",
                command: "cat \(valid.path); false",
                succeeded: false,
                outputOverride: try String(contentsOf: valid, encoding: .utf8)
            ),
            fixture.toolCall(
                callID: "mixed-evidence",
                command: "cat \(valid.path); cat \(missing.path); true",
                outputOverride: try String(contentsOf: valid, encoding: .utf8)
                    + "\ncat: \(missing.path): No such file or directory"
            )
        ], to: rollout)

        let report = try MetagentCore.refreshSkillUsage(options: fixture.options)
        XCTAssertEqual(report.snapshot.totalInvocations, 2)
        XCTAssertEqual(report.snapshot.summaries.first?.skillName, "compound-valid")
    }

    func testCoverageStartsAtEarliestProcessedSession() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(
            at: "workspace/.agents/skills/coverage",
            name: "coverage"
        )
        try fixture.write([
            fixture.line(
                timestamp: "2025-01-02T03:04:05.000Z",
                type: "session_meta",
                payload: ["id": "early-session", "cwd": fixture.root.path]
            )
        ], to: fixture.sessions.appendingPathComponent("rollout-early.jsonl"))
        try fixture.write([
            fixture.line(
                timestamp: "2026-01-02T03:04:05.000Z",
                type: "session_meta",
                payload: ["id": "later-session", "cwd": fixture.root.path]
            ),
            fixture.toolCall(callID: "coverage-read", command: "cat \(skill.path)")
        ], to: fixture.sessions.appendingPathComponent("rollout-later.jsonl"))

        let snapshot = try MetagentCore.refreshSkillUsage(options: fixture.options).snapshot
        XCTAssertEqual(snapshot.coverageStartedAt, "2025-01-02T03:04:05.000Z")
        XCTAssertEqual(snapshot.totalInvocations, 1)
    }

    func testEmptyHistoryRemainsInsufficient() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let report = try MetagentCore.refreshSkillUsage(options: fixture.options)
        XCTAssertEqual(report.snapshot.totalFiles, 0)
        XCTAssertFalse(report.snapshot.isBackfillComplete)
        XCTAssertFalse(report.hasMore)
    }

    func testSnapshotKeepsResultsFromAnOlderParserVersionVisible() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(
            at: "workspace/.agents/skills/stale-parser",
            name: "stale-parser"
        )
        try fixture.write([
            fixture.line(type: "session_meta", payload: [
                "id": "stale-parser-session",
                "cwd": fixture.root.path
            ]),
            fixture.toolCall(callID: "stale-parser-read", command: "cat \(skill.path)")
        ], to: fixture.sessions.appendingPathComponent("rollout-stale-parser.jsonl"))
        XCTAssertEqual(
            try MetagentCore.refreshSkillUsage(options: fixture.options).snapshot.totalInvocations,
            1
        )

        try fixture.executeSQL(
            "UPDATE skill_usage_metadata SET value = '13' WHERE key = 'parser_version';"
        )
        let snapshot = try XCTUnwrap(
            MetagentCore.loadSkillUsageSnapshot(databasePath: fixture.database.path)
        )
        XCTAssertEqual(snapshot.totalInvocations, 1)
        XCTAssertFalse(snapshot.isBackfillComplete)
        XCTAssertTrue(snapshot.isParserUpgradeBackfill)
        XCTAssertEqual(snapshot.displayParserVersion, 13)
        XCTAssertEqual(snapshot.targetParserVersion, 17)
    }

    func testParserUpgradeServesPreviousGenerationUntilAtomicCutover() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(
            at: "workspace/.agents/skills/generation-skill",
            name: "generation-skill"
        )
        for index in 1...2 {
            try fixture.write([
                fixture.line(type: "session_meta", payload: [
                    "id": "generation-session-\(index)",
                    "cwd": fixture.root.path
                ]),
                fixture.toolCall(
                    callID: "generation-read-\(index)",
                    command: "cat \(skill.path)"
                )
            ], to: fixture.sessions.appendingPathComponent("rollout-generation-\(index).jsonl"))
        }

        let original = try MetagentCore.refreshSkillUsage(options: fixture.options).snapshot
        XCTAssertEqual(original.totalInvocations, 2)
        XCTAssertTrue(original.isBackfillComplete)

        try fixture.executeSQL(
            "UPDATE skill_usage_metadata SET value = '13' WHERE key = 'parser_version';"
        )
        let rebuilding = try MetagentCore.refreshSkillUsage(options: SkillUsageRefreshOptions(
            sessionRoots: [fixture.sessions.path],
            databasePath: fixture.database.path,
            maxBytes: 1_024 * 1_024,
            maxFiles: 1
        ))
        XCTAssertTrue(rebuilding.hasMore)
        XCTAssertEqual(rebuilding.snapshot.totalInvocations, 2)
        XCTAssertEqual(rebuilding.snapshot.completedFiles, 1)
        XCTAssertTrue(rebuilding.snapshot.isParserUpgradeBackfill)
        XCTAssertEqual(rebuilding.snapshot.displayParserVersion, 13)
        XCTAssertEqual(
            MetagentCore.loadCachedSkillUsageSnapshot(databasePath: fixture.database.path),
            rebuilding.snapshot,
            "a current writer may cache the previous display generation during rebuild"
        )

        // Older generations did not have agent_runs_previous. Treat the three
        // core previous tables as the atomic display generation so a restart
        // cannot try to rename them over themselves.
        try fixture.executeSQL("""
        DROP TABLE IF EXISTS agent_runs_previous;
        UPDATE skill_usage_metadata SET value = '12' WHERE key = 'parser_version';
        """)
        let restartedUpgrade = try MetagentCore.refreshSkillUsage(options: SkillUsageRefreshOptions(
            sessionRoots: [fixture.sessions.path],
            databasePath: fixture.database.path,
            maxBytes: 1_024 * 1_024,
            maxFiles: 1
        ))
        XCTAssertTrue(restartedUpgrade.hasMore)
        XCTAssertEqual(restartedUpgrade.invocationsAdded, 1)
        XCTAssertEqual(restartedUpgrade.snapshot.totalInvocations, 2)
        XCTAssertEqual(restartedUpgrade.snapshot.completedFiles, 1)
        XCTAssertTrue(restartedUpgrade.snapshot.isParserUpgradeBackfill)
        XCTAssertEqual(restartedUpgrade.snapshot.displayParserVersion, 13)
        XCTAssertEqual(
            MetagentCore.loadCachedSkillUsageSnapshot(databasePath: fixture.database.path),
            restartedUpgrade.snapshot
        )

        let cutover = try MetagentCore.refreshSkillUsage(options: fixture.options)
        XCTAssertFalse(cutover.hasMore)
        XCTAssertEqual(cutover.snapshot.totalInvocations, 2)
        XCTAssertTrue(cutover.snapshot.isBackfillComplete)
        XCTAssertFalse(cutover.snapshot.isParserUpgradeBackfill)
        XCTAssertEqual(cutover.snapshot.displayParserVersion, 17)
        XCTAssertEqual(
            MetagentCore.loadCachedSkillUsageSnapshot(databasePath: fixture.database.path),
            cutover.snapshot
        )
    }

    func testMaintenanceIntervalDefersDuplicateBackgroundWorkButNotManualRefresh() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(
            at: "workspace/.agents/skills/maintenance",
            name: "maintenance"
        )
        for index in 0..<3 {
            try fixture.write([
                fixture.line(type: "session_meta", payload: [
                    "id": "maintenance-session-\(index)",
                    "cwd": fixture.root.path
                ]),
                fixture.toolCall(
                    callID: "maintenance-read-\(index)",
                    command: "cat \(skill.path)"
                )
            ], to: fixture.sessions.appendingPathComponent("rollout-maintenance-\(index).jsonl"))
        }
        let maintenanceOptions = SkillUsageRefreshOptions(
            sessionRoots: [fixture.sessions.path],
            databasePath: fixture.database.path,
            maxBytes: 1_024 * 1_024,
            maxFiles: 1,
            minimumMaintenanceIntervalSeconds: 60,
            reusesSourceCatalog: true
        )

        let first = try MetagentCore.refreshSkillUsage(options: maintenanceOptions)
        XCTAssertFalse(first.wasDeferred)
        XCTAssertEqual(first.filesRead, 1)
        XCTAssertTrue(first.hasMore)

        let duplicate = try MetagentCore.refreshSkillUsage(options: maintenanceOptions)
        XCTAssertTrue(duplicate.wasDeferred)
        XCTAssertEqual(duplicate.filesRead, 0)
        XCTAssertEqual(
            MetagentCore.loadCachedSkillUsageSnapshot(databasePath: fixture.database.path),
            duplicate.snapshot,
            "a deferred process should reuse the canonical snapshot another process just advanced"
        )
        XCTAssertEqual(duplicate.processedBytesAdvanced, 0)
        XCTAssertTrue(duplicate.hasMore)

        var manualOptions = maintenanceOptions
        manualOptions.minimumMaintenanceIntervalSeconds = 0
        manualOptions.reusesSourceCatalog = false
        let manual = try MetagentCore.refreshSkillUsage(options: manualOptions)
        XCTAssertFalse(manual.wasDeferred)
        XCTAssertEqual(manual.filesRead, 1)
    }

    func testMaintenanceSlicesDiscoverNewSessionFilesImmediately() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(
            at: "workspace/.agents/skills/new-session",
            name: "new-session"
        )
        for index in 0..<2 {
            try fixture.write([
                fixture.line(type: "session_meta", payload: [
                    "id": "existing-session-\(index)",
                    "cwd": fixture.root.path
                ]),
                fixture.toolCall(
                    callID: "existing-read-\(index)",
                    command: "cat \(skill.path)"
                )
            ], to: fixture.sessions.appendingPathComponent("rollout-existing-\(index).jsonl"))
        }
        let options = SkillUsageRefreshOptions(
            sessionRoots: [fixture.sessions.path],
            databasePath: fixture.database.path,
            maxBytes: 1_024 * 1_024,
            maxFiles: 1,
            reusesSourceCatalog: true
        )

        let first = try MetagentCore.refreshSkillUsage(options: options)
        XCTAssertEqual(first.filesRead, 1)
        XCTAssertEqual(first.snapshot.totalFiles, 2)
        XCTAssertTrue(first.hasMore)

        let nestedDirectory = fixture.sessions.appendingPathComponent("2026/08/28")
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        try fixture.write([
            fixture.line(type: "session_meta", payload: [
                "id": "new-session-2",
                "cwd": fixture.root.path
            ]),
            fixture.toolCall(callID: "new-read-2", command: "cat \(skill.path)")
        ], to: nestedDirectory.appendingPathComponent("rollout-new-2.jsonl"))
        MetagentCore.invalidateSkillUsageSourceCatalogForTesting(
            databasePath: fixture.database.path
        )

        let second = try MetagentCore.refreshSkillUsage(options: options)
        XCTAssertEqual(second.filesRead, 1)
        XCTAssertEqual(second.snapshot.totalFiles, 3)
        XCTAssertTrue(second.hasMore)

        var report = second
        while report.hasMore {
            report = try MetagentCore.refreshSkillUsage(options: options)
        }
        XCTAssertEqual(report.snapshot.totalInvocations, 3)
        XCTAssertEqual(report.snapshot.completedFiles, 3)
    }

    func testUsageDiscoverySkipsPackageDescendants() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(at: "workspace/.agents/skills/packages", name: "packages")
        let ordinaryDirectory = fixture.sessions.appendingPathComponent("ordinary")
        let packageDirectory = fixture.sessions.appendingPathComponent("ignored.app/Contents")
        try FileManager.default.createDirectory(at: ordinaryDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        let lines = [
            fixture.line(type: "session_meta", payload: [
                "id": "package-session",
                "cwd": fixture.root.path
            ]),
            fixture.toolCall(callID: "package-read", command: "cat \(skill.path)")
        ]
        try fixture.write(lines, to: ordinaryDirectory.appendingPathComponent("rollout-visible.jsonl"))
        try fixture.write(lines, to: packageDirectory.appendingPathComponent("rollout-hidden.jsonl"))

        let report = try MetagentCore.refreshSkillUsage(options: fixture.options)

        XCTAssertEqual(report.snapshot.totalFiles, 1)
        XCTAssertEqual(report.snapshot.totalInvocations, 1)
    }

    func testUsageDiscoverySkipsSymlinkedSessionFilesLikeFoundationEnumeration() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let oldSkill = try fixture.makeSkill(at: "workspace/.agents/skills/link-old", name: "link-old")
        let targets = fixture.root.appendingPathComponent("targets")
        try FileManager.default.createDirectory(at: targets, withIntermediateDirectories: true)
        let oldTarget = targets.appendingPathComponent("old.jsonl")
        try fixture.write([
            fixture.line(type: "session_meta", payload: ["id": "old-link", "cwd": fixture.root.path]),
            fixture.toolCall(callID: "link-call", command: "cat \(oldSkill.path)")
        ], to: oldTarget)
        let link = fixture.sessions.appendingPathComponent("rollout-link.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: oldTarget)

        let report = try MetagentCore.refreshSkillUsage(options: fixture.options)

        XCTAssertEqual(report.snapshot.totalFiles, 0)
        XCTAssertTrue(report.snapshot.summaries.isEmpty)
    }

    func testUsageDiscoveryCollapsesOverlappingRoots() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(at: "workspace/.agents/skills/overlap", name: "overlap")
        let nested = fixture.sessions.appendingPathComponent("2026/08/28")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try fixture.write([
            fixture.line(type: "session_meta", payload: ["id": "overlap", "cwd": fixture.root.path]),
            fixture.toolCall(callID: "overlap-read", command: "cat \(skill.path)")
        ], to: nested.appendingPathComponent("rollout-overlap.jsonl"))

        let report = try MetagentCore.refreshSkillUsage(options: SkillUsageRefreshOptions(
            sessionRoots: [nested.path, fixture.sessions.path],
            databasePath: fixture.database.path,
            maxBytes: 1_024 * 1_024,
            maxFiles: 20
        ))

        XCTAssertEqual(report.snapshot.totalFiles, 1)
        XCTAssertEqual(report.snapshot.totalInvocations, 1)
    }

    func testUsageDiscoveryPreservesExplicitRootsUnderSkippedAncestors() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(at: "workspace/.agents/skills/explicit", name: "explicit")
        let hiddenRoot = fixture.sessions.appendingPathComponent(".archive/sessions")
        let finderHiddenRoot = fixture.sessions.appendingPathComponent("finder-hidden/sessions")
        let packageRoot = fixture.sessions.appendingPathComponent("History.app/Contents/sessions")
        try FileManager.default.createDirectory(at: hiddenRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: finderHiddenRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
        var finderHiddenValues = URLResourceValues()
        finderHiddenValues.isHidden = true
        var finderHiddenAncestor = finderHiddenRoot.deletingLastPathComponent()
        try finderHiddenAncestor.setResourceValues(finderHiddenValues)
        try fixture.write([
            fixture.line(type: "session_meta", payload: ["id": "hidden-explicit", "cwd": fixture.root.path]),
            fixture.toolCall(callID: "hidden-explicit-read", command: "cat \(skill.path)")
        ], to: hiddenRoot.appendingPathComponent("rollout-hidden-explicit.jsonl"))
        try fixture.write([
            fixture.line(type: "session_meta", payload: ["id": "finder-hidden-explicit", "cwd": fixture.root.path]),
            fixture.toolCall(callID: "finder-hidden-explicit-read", command: "cat \(skill.path)")
        ], to: finderHiddenRoot.appendingPathComponent("rollout-finder-hidden-explicit.jsonl"))
        try fixture.write([
            fixture.line(type: "session_meta", payload: ["id": "package-explicit", "cwd": fixture.root.path]),
            fixture.toolCall(callID: "package-explicit-read", command: "cat \(skill.path)")
        ], to: packageRoot.appendingPathComponent("rollout-package-explicit.jsonl"))

        let report = try MetagentCore.refreshSkillUsage(options: SkillUsageRefreshOptions(
            sessionRoots: [fixture.sessions.path, hiddenRoot.path, finderHiddenRoot.path, packageRoot.path],
            databasePath: fixture.database.path,
            maxBytes: 1_024 * 1_024,
            maxFiles: 20
        ))

        XCTAssertEqual(report.snapshot.totalFiles, 3)
        XCTAssertEqual(report.snapshot.totalInvocations, 3)
    }

    func testBulkMetadataMatchesExistingStatMetadata() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(at: "workspace/.agents/skills/identity", name: "identity")
        let nested = fixture.sessions.appendingPathComponent("2026/08/28")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let rollout = nested.appendingPathComponent("rollout-identity.jsonl")
        try fixture.write([
            fixture.line(type: "session_meta", payload: ["id": "identity", "cwd": fixture.root.path]),
            fixture.toolCall(callID: "identity-read", command: "cat \(skill.path)")
        ], to: rollout)
        XCTAssertEqual(
            try MetagentCore.refreshSkillUsage(options: fixture.options).snapshot.totalInvocations,
            1
        )

        var info = stat()
        XCTAssertEqual(lstat(rollout.path, &info), 0)
        let statIdentity = "\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)"
        let statModifiedAt = Double(info.st_mtimespec.tv_sec)
            + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        try fixture.executeSQL(
            """
            UPDATE skill_usage_sources
            SET file_identity = '\(statIdentity)',
                modified_at = \(String(format: "%.17g", statModifiedAt)),
                prefix_fingerprint = 'not-the-real-prefix';
            """
        )

        let warm = try MetagentCore.refreshSkillUsage(options: fixture.options)
        XCTAssertEqual(warm.filesRead, 0)
        XCTAssertEqual(warm.snapshot.totalInvocations, 1)
    }

    func testContinuationReusesCatalogUntilInvalidatedAndForegroundForcesDiscovery() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(
            at: "workspace/.agents/skills/continuation",
            name: "continuation"
        )
        try fixture.write([
            fixture.line(type: "session_meta", payload: [
                "id": "continuation-one",
                "cwd": fixture.root.path
            ]),
            fixture.toolCall(callID: "continuation-one", command: "cat \(skill.path)")
        ], to: fixture.sessions.appendingPathComponent("rollout-one.jsonl"))
        let options = SkillUsageRefreshOptions(
            sessionRoots: [fixture.sessions.path],
            databasePath: fixture.database.path,
            maxBytes: 1_024 * 1_024,
            maxFiles: 20,
            reusesSourceCatalog: true
        )

        XCTAssertEqual(
            try MetagentCore.refreshSkillUsage(options: options).snapshot.totalInvocations,
            1
        )
        XCTAssertEqual(
            MetagentCore.skillUsageSourceDiscoveryCountForTesting(
                databasePath: fixture.database.path
            ),
            1
        )

        // Surface any event callbacks already in flight when the watcher was
        // created. They predate the discovery baseline and must not invalidate
        // the catalog that discovery just established.
        usleep(250_000)
        let warm = try MetagentCore.refreshSkillUsage(options: options)
        XCTAssertEqual(warm.filesRead, 0)
        XCTAssertEqual(
            MetagentCore.skillUsageSourceDiscoveryCountForTesting(
                databasePath: fixture.database.path
            ),
            1
        )

        let nested = fixture.sessions.appendingPathComponent("2026/08/28")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try fixture.write([
            fixture.line(type: "session_meta", payload: [
                "id": "continuation-two",
                "cwd": fixture.root.path
            ]),
            fixture.toolCall(callID: "continuation-two", command: "cat \(skill.path)")
        ], to: nested.appendingPathComponent("rollout-two.jsonl"))
        MetagentCore.invalidateSkillUsageSourceCatalogForTesting(
            databasePath: fixture.database.path
        )

        let invalidated = try MetagentCore.refreshSkillUsage(options: options)
        XCTAssertEqual(invalidated.snapshot.totalFiles, 2)
        XCTAssertEqual(invalidated.snapshot.totalInvocations, 2)
        XCTAssertEqual(
            MetagentCore.skillUsageSourceDiscoveryCountForTesting(
                databasePath: fixture.database.path
            ),
            2
        )

        _ = try MetagentCore.refreshSkillUsage(options: fixture.options)
        XCTAssertEqual(
            MetagentCore.skillUsageSourceDiscoveryCountForTesting(
                databasePath: fixture.database.path
            ),
            3,
            "an explicit foreground refresh must never trust the continuation catalog"
        )
    }

    func testContinuationIgnoresItsDatabaseAndLaunchCacheInsideTheSessionRoot() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(
            at: "workspace/.agents/skills/overlapping-cache",
            name: "overlapping-cache"
        )
        try fixture.write([
            fixture.line(type: "session_meta", payload: [
                "id": "overlapping-cache-session",
                "cwd": fixture.root.path
            ]),
            fixture.toolCall(callID: "overlapping-cache-read", command: "cat \(skill.path)")
        ], to: fixture.sessions.appendingPathComponent("rollout-overlapping-cache.jsonl"))
        let database = fixture.sessions.appendingPathComponent("metagent-state/usage.sqlite")
        let options = SkillUsageRefreshOptions(
            sessionRoots: [fixture.sessions.path],
            databasePath: database.path,
            maxBytes: 1_024 * 1_024,
            maxFiles: 20,
            reusesSourceCatalog: true
        )

        XCTAssertEqual(
            try MetagentCore.refreshSkillUsage(options: options).snapshot.totalInvocations,
            1
        )
        usleep(250_000)
        XCTAssertEqual(
            try MetagentCore.refreshSkillUsage(options: options).snapshot.totalInvocations,
            1
        )
        XCTAssertEqual(
            MetagentCore.skillUsageSourceDiscoveryCountForTesting(databasePath: database.path),
            1,
            "Metagent's own SQLite and launch-cache writes must not dirty the session catalog"
        )
        XCTAssertNil(
            MetagentCore.loadCachedSkillUsageSnapshot(databasePath: database.path),
            "an overlapping continuation layout must not write into its own watched tree"
        )
    }

    func testContinuationInvalidationCoversGrowthRewriteRotationAndArchiveRelocation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let firstSkill = try fixture.makeSkill(
            at: "workspace/.agents/skills/first",
            name: "first"
        )
        _ = try fixture.makeSkill(
            at: "workspace/.agents/skills/other",
            name: "other"
        )
        let archived = fixture.root.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        let rollout = fixture.sessions.appendingPathComponent("rollout-continuation.jsonl")
        try fixture.write([
            fixture.line(type: "session_meta", payload: [
                "id": "continuation-session",
                "cwd": fixture.root.path
            ]),
            fixture.toolCall(callID: "first-read", command: "cat \(firstSkill.path)")
        ], to: rollout)
        let options = SkillUsageRefreshOptions(
            sessionRoots: [fixture.sessions.path, archived.path],
            databasePath: fixture.database.path,
            maxBytes: 1_024 * 1_024,
            maxFiles: 20,
            reusesSourceCatalog: true
        )
        XCTAssertEqual(
            try MetagentCore.refreshSkillUsage(options: options).snapshot.totalInvocations,
            1
        )

        try fixture.append([
            fixture.toolCall(callID: "growth-read", command: "cat \(firstSkill.path)")
        ], to: rollout)
        MetagentCore.invalidateSkillUsageSourceCatalogForTesting(
            databasePath: fixture.database.path
        )
        XCTAssertEqual(
            try MetagentCore.refreshSkillUsage(options: options).snapshot.totalInvocations,
            2
        )

        let oldContents = try String(contentsOf: rollout, encoding: .utf8)
        let rewritten = oldContents.replacingOccurrences(of: "first", with: "other")
        XCTAssertEqual(oldContents.utf8.count, rewritten.utf8.count)
        try rewritten.write(to: rollout, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)],
            ofItemAtPath: rollout.path
        )
        MetagentCore.invalidateSkillUsageSourceCatalogForTesting(
            databasePath: fixture.database.path
        )
        let sameSizeRewrite = try MetagentCore.refreshSkillUsage(options: options)
        XCTAssertEqual(sameSizeRewrite.snapshot.totalInvocations, 2)
        XCTAssertEqual(sameSizeRewrite.snapshot.summaries.map(\.skillName), ["other"])

        let archivedRollout = archived.appendingPathComponent(rollout.lastPathComponent)
        try FileManager.default.moveItem(at: rollout, to: archivedRollout)
        MetagentCore.invalidateSkillUsageSourceCatalogForTesting(
            databasePath: fixture.database.path
        )
        let relocated = try MetagentCore.refreshSkillUsage(options: options)
        XCTAssertEqual(relocated.bytesRead, 0)
        XCTAssertEqual(relocated.snapshot.totalInvocations, 2)

        try FileManager.default.removeItem(at: archivedRollout)
        try fixture.write([
            fixture.line(type: "session_meta", payload: [
                "id": "rotated-session",
                "cwd": fixture.root.path
            ]),
            fixture.toolCall(callID: "rotated-read", command: "cat \(firstSkill.path)")
        ], to: archivedRollout)
        MetagentCore.invalidateSkillUsageSourceCatalogForTesting(
            databasePath: fixture.database.path
        )
        let rotated = try MetagentCore.refreshSkillUsage(options: options)
        XCTAssertEqual(rotated.snapshot.totalInvocations, 1)
        XCTAssertEqual(rotated.snapshot.summaries.map(\.skillName), ["first"])
    }

    func testContinuationCatalogExpiresAndParserGenerationChangeInvalidatesIt() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(
            at: "workspace/.agents/skills/generation",
            name: "generation"
        )
        try fixture.write([
            fixture.line(type: "session_meta", payload: [
                "id": "generation-session",
                "cwd": fixture.root.path
            ]),
            fixture.toolCall(callID: "generation-read", command: "cat \(skill.path)")
        ], to: fixture.sessions.appendingPathComponent("rollout-generation.jsonl"))
        let reusable = SkillUsageRefreshOptions(
            sessionRoots: [fixture.sessions.path],
            databasePath: fixture.database.path,
            maxBytes: 1_024 * 1_024,
            maxFiles: 20,
            reusesSourceCatalog: true
        )
        _ = try MetagentCore.refreshSkillUsage(options: reusable)
        _ = try MetagentCore.refreshSkillUsage(options: reusable)
        XCTAssertEqual(
            MetagentCore.skillUsageSourceDiscoveryCountForTesting(
                databasePath: fixture.database.path
            ),
            1
        )

        let expired = SkillUsageRefreshOptions(
            sessionRoots: reusable.sessionRoots,
            databasePath: reusable.databasePath,
            maxBytes: reusable.maxBytes,
            maxFiles: reusable.maxFiles,
            reusesSourceCatalog: true,
            sourceCatalogMaximumAgeSeconds: 0
        )
        _ = try MetagentCore.refreshSkillUsage(options: expired)
        XCTAssertEqual(
            MetagentCore.skillUsageSourceDiscoveryCountForTesting(
                databasePath: fixture.database.path
            ),
            2
        )

        try fixture.executeSQL(
            "UPDATE skill_usage_metadata SET value = '13' WHERE key = 'parser_version';"
        )
        let rebuilt = try MetagentCore.refreshSkillUsage(options: reusable)
        XCTAssertEqual(rebuilt.snapshot.totalInvocations, 1)
        XCTAssertEqual(
            MetagentCore.skillUsageSourceDiscoveryCountForTesting(
                databasePath: fixture.database.path
            ),
            3
        )
    }
}

private func writePrivateLaunchCache(
    _ envelope: SkillUsageLaunchCacheEnvelope,
    to path: URL
) throws {
    try JSONEncoder().encode(envelope).write(to: path, options: .atomic)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: path.path
    )
}

private func replacingTotalInvocations(
    in snapshot: SkillUsageSnapshot,
    with totalInvocations: Int
) -> SkillUsageSnapshot {
    SkillUsageSnapshot(
        summaries: snapshot.summaries,
        totalInvocations: totalInvocations,
        totalFiles: snapshot.totalFiles,
        completedFiles: snapshot.completedFiles,
        totalBytes: snapshot.totalBytes,
        processedBytes: snapshot.processedBytes,
        isBackfillComplete: snapshot.isBackfillComplete,
        isParserUpgradeBackfill: snapshot.isParserUpgradeBackfill,
        displayParserVersion: snapshot.displayParserVersion,
        targetParserVersion: snapshot.targetParserVersion,
        coverageStartedAt: snapshot.coverageStartedAt,
        lastUpdatedAt: snapshot.lastUpdatedAt
    )
}

private func replacingTargetParserVersion(
    in snapshot: SkillUsageSnapshot,
    with targetParserVersion: Int
) -> SkillUsageSnapshot {
    SkillUsageSnapshot(
        summaries: snapshot.summaries,
        totalInvocations: snapshot.totalInvocations,
        totalFiles: snapshot.totalFiles,
        completedFiles: snapshot.completedFiles,
        totalBytes: snapshot.totalBytes,
        processedBytes: snapshot.processedBytes,
        isBackfillComplete: snapshot.isBackfillComplete,
        isParserUpgradeBackfill: snapshot.isParserUpgradeBackfill,
        displayParserVersion: snapshot.displayParserVersion,
        targetParserVersion: targetParserVersion,
        coverageStartedAt: snapshot.coverageStartedAt,
        lastUpdatedAt: snapshot.lastUpdatedAt
    )
}

private final class Fixture {
    let root: URL
    let sessions: URL
    let database: URL

    var options: SkillUsageRefreshOptions {
        SkillUsageRefreshOptions(
            sessionRoots: [sessions.path],
            databasePath: database.path,
            maxBytes: 1_024 * 1_024,
            maxFiles: 20
        )
    }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-usage-tests-\(UUID().uuidString)")
        sessions = root.appendingPathComponent("sessions")
        database = root.appendingPathComponent("usage.sqlite")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    }

    func makeSkill(at relativePath: String, name: String) throws -> URL {
        try writeSkillFixture(at: root.appendingPathComponent(relativePath), name: name)
            .appendingPathComponent("SKILL.md")
    }

    func line(
        timestamp: String = "2026-07-19T12:00:00.000Z",
        type: String,
        payload: [String: Any]
    ) -> String {
        json(["timestamp": timestamp, "type": type, "payload": payload])
    }

    func epoch(_ timestamp: String) -> TimeInterval {
        MetagentCore.parseSkillUsageTimestamp(timestamp)!.timeIntervalSince1970
    }

    func toolCall(
        callID: String,
        command: String,
        name: String = "exec",
        succeeded: Bool = true,
        workdir: String? = nil,
        outputOverride: String? = nil
    ) -> String {
        let commandData = try! JSONSerialization.data(withJSONObject: command, options: [.fragmentsAllowed])
        let commandLiteral = String(decoding: commandData, as: UTF8.self)
        let workdirFragment: String
        if let workdir {
            let data = try! JSONSerialization.data(withJSONObject: workdir, options: [.fragmentsAllowed])
            workdirFragment = ", workdir: \(String(decoding: data, as: UTF8.self))"
        } else {
            workdirFragment = ""
        }
        let request = line(type: "response_item", payload: [
            "type": "custom_tool_call",
            "name": name,
            "call_id": callID,
            "input": "const result = await tools.exec_command({cmd: \(commandLiteral)\(workdirFragment)});"
        ])
        let wrapper = succeeded
            ? "Script completed\nWall time 0.1 seconds\nOutput:\n"
            : "Process exited with code 1"
        let actualOutput = succeeded
            ? (outputOverride ?? skillOutput(for: command, workdir: workdir))
            : (outputOverride ?? "cat: No such file or directory")
        let output = line(type: "response_item", payload: [
            "type": "custom_tool_call_output",
            "call_id": callID,
            "output": [
                ["type": "input_text", "text": wrapper],
                ["type": "input_text", "text": actualOutput]
            ]
        ])
        return request + "\n" + output
    }

    private func skillOutput(for command: String, workdir: String?) -> String {
        let patterns = [
            #"['\"]((?:~|/|\.\.?/)?[^'\"\n]*?/SKILL\.md)['\"]"#,
            #"((?:~|/|\.\.?/)?[^\s'\";&|]*?/SKILL\.md)"#
        ]
        let path = patterns.lazy.compactMap { pattern -> String? in
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(
                    in: command,
                    range: NSRange(command.startIndex..<command.endIndex, in: command)
                  ),
                  let pathRange = Range(match.range(at: 1), in: command)
            else { return nil }
            return String(command[pathRange])
        }.first
        guard var path else { return "" }
        if path.hasPrefix("~/") {
            path = root.appendingPathComponent(String(path.dropFirst(2))).path
        } else if !path.hasPrefix("/") {
            let base: URL
            if let workdir {
                base = URL(fileURLWithPath: workdir)
            } else if let cdRange = command.range(
                of: #"^\s*cd\s+([^;&|\s]+)\s*&&"#,
                options: .regularExpression
            ) {
                let cdCommand = String(command[cdRange])
                let directory = cdCommand
                    .replacingOccurrences(of: #"^\s*cd\s+"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"\s*&&$"#, with: "", options: .regularExpression)
                base = URL(fileURLWithPath: directory)
            } else {
                base = root
            }
            path = base.appendingPathComponent(path).path
        }
        return (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    func functionCall(callID: String, command: String) -> String {
        let argumentsData = try! JSONSerialization.data(withJSONObject: ["cmd": command])
        let arguments = String(decoding: argumentsData, as: UTF8.self)
        let request = line(type: "response_item", payload: [
            "type": "function_call",
            "name": "exec_command",
            "call_id": callID,
            "arguments": arguments
        ])
        let resultData = try! JSONSerialization.data(withJSONObject: [
            "exit_code": 0,
            "output": skillOutput(for: command, workdir: nil)
        ])
        let output = line(type: "response_item", payload: [
            "type": "function_call_output",
            "call_id": callID,
            "output": String(decoding: resultData, as: UTF8.self)
        ])
        return request + "\n" + output
    }

    func legacyShellCall(callID: String, command: String) -> String {
        let argumentsData = try! JSONSerialization.data(withJSONObject: [
            "command": command,
            "workdir": root.path
        ])
        let arguments = String(decoding: argumentsData, as: UTF8.self)
        let request = line(type: "response_item", payload: [
            "type": "function_call",
            "name": "shell_command",
            "call_id": callID,
            "arguments": arguments
        ])
        let resultData = try! JSONSerialization.data(withJSONObject: [
            "exit_code": 0,
            "output": skillOutput(for: command, workdir: root.path)
        ])
        let output = line(type: "response_item", payload: [
            "type": "function_call_output",
            "call_id": callID,
            "output": String(decoding: resultData, as: UTF8.self)
        ])
        return request + "\n" + output
    }

    func multiToolCall(
        callID: String,
        commands: [(command: String, workdir: String?)],
        skillFiles: [URL]
    ) -> String {
        let calls = commands.map { item -> String in
            let commandData = try! JSONSerialization.data(
                withJSONObject: item.command,
                options: [.fragmentsAllowed]
            )
            let command = String(decoding: commandData, as: UTF8.self)
            guard let workdir = item.workdir else {
                return "tools.exec_command({cmd: \(command)})"
            }
            let workdirData = try! JSONSerialization.data(
                withJSONObject: workdir,
                options: [.fragmentsAllowed]
            )
            return "tools.exec_command({cmd: \(command), workdir: \(String(decoding: workdirData, as: UTF8.self))})"
        }
        let request = line(type: "response_item", payload: [
            "type": "custom_tool_call",
            "name": "exec",
            "call_id": callID,
            "input": "const results = await Promise.all([\(calls.joined(separator: ", "))]);"
        ])
        let observed = skillFiles.compactMap {
            try? String(contentsOf: $0, encoding: .utf8)
        }.joined(separator: "\n")
        let output = line(type: "response_item", payload: [
            "type": "custom_tool_call_output",
            "call_id": callID,
            "output": [["type": "input_text", "text": "Script completed\n\(observed)"]]
        ])
        return request + "\n" + output
    }

    func write(_ lines: [String], to file: URL) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    func append(_ lines: [String], to file: URL) throws {
        try appendRaw(lines.joined(separator: "\n") + "\n", to: file)
    }

    func appendRaw(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func executeSQL(_ sql: String) throws {
        var connection: OpaquePointer?
        guard sqlite3_open(database.path, &connection) == SQLITE_OK else {
            throw NSError(domain: "SkillUsageTests", code: 1)
        }
        defer { sqlite3_close(connection) }
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "SkillUsageTests", code: 2)
        }
    }

    func scalarInt(_ sql: String) throws -> Int {
        var connection: OpaquePointer?
        guard sqlite3_open(database.path, &connection) == SQLITE_OK else {
            throw NSError(domain: "SkillUsageTests", code: 3)
        }
        defer { sqlite3_close(connection) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "SkillUsageTests", code: 4)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw NSError(domain: "SkillUsageTests", code: 5)
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
