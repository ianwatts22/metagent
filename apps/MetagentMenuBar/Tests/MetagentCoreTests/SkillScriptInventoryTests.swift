import Foundation
import XCTest
@testable import MetagentCore

final class SkillScriptInventoryTests: XCTestCase {
    func testInventoryReportsRuntimeRoleReferencesHashesAndMissingFiles() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-script-inventory")
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = root.appendingPathComponent(".agents/skills/demo")
        try FileManager.default.createDirectory(
            at: skill.appendingPathComponent("scripts"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: skill.appendingPathComponent("references"),
            withIntermediateDirectories: true
        )
        try """
        ---
        name: demo
        description: Script inventory fixture
        ---

        Run `scripts/run.py`. A removed helper used to live at `scripts/missing.sh`.
        """.write(
            to: skill.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        try "The entry point calls scripts/helper.sh.\n".write(
            to: skill.appendingPathComponent("references/architecture.md"),
            atomically: true,
            encoding: .utf8
        )
        let entryPoint = skill.appendingPathComponent("scripts/run.py")
        try "#!/bin/bash\nprintf 'fixture'\n".write(
            to: entryPoint,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: entryPoint.path
        )
        try "#!/usr/bin/env sh\ncd /Users/private-user/work\n".write(
            to: skill.appendingPathComponent("scripts/helper.sh"),
            atomically: true,
            encoding: .utf8
        )
        try "console.log('orphan')\n".write(
            to: skill.appendingPathComponent("scripts/orphan.js"),
            atomically: true,
            encoding: .utf8
        )

        let inventory = try MetagentCore.inventorySkillScripts(path: skill.path)

        XCTAssertEqual(inventory.scripts.map(\.relativePath), [
            "scripts/helper.sh",
            "scripts/orphan.js",
            "scripts/run.py",
        ])
        let run = try XCTUnwrap(inventory.scripts.first {
            $0.relativePath == "scripts/run.py"
        })
        XCTAssertEqual(run.runtime, "bash")
        XCTAssertEqual(run.role, .entryPoint)
        XCTAssertTrue(run.executable)
        XCTAssertEqual(run.referencedBy, ["SKILL.md"])
        XCTAssertEqual(run.sha256?.count, 64)
        XCTAssertTrue(run.warnings.contains {
            $0.contains("extension and shebang")
        })

        let helper = try XCTUnwrap(inventory.scripts.first {
            $0.relativePath == "scripts/helper.sh"
        })
        XCTAssertEqual(helper.role, .helper)
        XCTAssertEqual(helper.runtime, "shell")
        XCTAssertFalse(helper.executable)
        XCTAssertEqual(helper.referencedBy, ["references/architecture.md"])
        XCTAssertTrue(helper.warnings.contains("Contains an absolute user-home path."))

        let orphan = try XCTUnwrap(inventory.scripts.first {
            $0.relativePath == "scripts/orphan.js"
        })
        XCTAssertEqual(orphan.role, .unknown)
        XCTAssertTrue(orphan.warnings.contains("No bundled file references this script."))

        XCTAssertEqual(inventory.missingReferences, [
            MissingSkillScriptReference(
                relativePath: "scripts/missing.sh",
                referencedBy: ["SKILL.md"]
            ),
        ])
        let detail = try MetagentCore.getSkillDetail(path: skill.path, includeBody: false)
        XCTAssertEqual(detail.schemaVersion, 2)
        XCTAssertEqual(detail.scriptInventory, inventory)
        let encoded = String(
            data: try JSONEncoder().encode(inventory),
            encoding: .utf8
        )
        XCTAssertFalse(try XCTUnwrap(encoded).contains("private-user"))
    }

    func testInventoryDoesNotFollowEscapingOrBrokenSymlinks() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-script-symlink")
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = root.appendingPathComponent(".agents/skills/demo")
        try FileManager.default.createDirectory(
            at: skill.appendingPathComponent("scripts"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: skill.appendingPathComponent("assets"),
            withIntermediateDirectories: true
        )
        try """
        ---
        name: demo
        description: Symlink fixture
        ---

        Use `scripts/inside.sh`, `scripts/outside.sh`, and `scripts/broken.sh`.
        """.write(
            to: skill.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let insideTarget = skill.appendingPathComponent("assets/inside.sh")
        try "#!/bin/sh\nexit 0\n".write(
            to: insideTarget,
            atomically: true,
            encoding: .utf8
        )
        let outsideTarget = root.appendingPathComponent("private-outside.sh")
        try "#!/bin/sh\nprintf '/Users/private-user'\n".write(
            to: outsideTarget,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            atPath: skill.appendingPathComponent("scripts/inside.sh").path,
            withDestinationPath: "../assets/inside.sh"
        )
        try FileManager.default.createSymbolicLink(
            atPath: skill.appendingPathComponent("scripts/outside.sh").path,
            withDestinationPath: outsideTarget.path
        )
        try FileManager.default.createSymbolicLink(
            atPath: skill.appendingPathComponent("scripts/broken.sh").path,
            withDestinationPath: "../assets/missing.sh"
        )

        let inventory = try MetagentCore.inventorySkillScripts(path: skill.path)
        let inside = try XCTUnwrap(inventory.scripts.first {
            $0.relativePath == "scripts/inside.sh"
        })
        let outside = try XCTUnwrap(inventory.scripts.first {
            $0.relativePath == "scripts/outside.sh"
        })
        let broken = try XCTUnwrap(inventory.scripts.first {
            $0.relativePath == "scripts/broken.sh"
        }, "inventoried paths: \(inventory.scripts.map(\.relativePath))")

        XCTAssertEqual(inside.containment, .bundledSymlink)
        XCTAssertNotNil(inside.sha256)
        XCTAssertEqual(outside.containment, .escapesBundle)
        XCTAssertNil(outside.sha256)
        XCTAssertEqual(broken.containment, .brokenSymlink)
        XCTAssertNil(broken.sha256)

        let encoded = try XCTUnwrap(
            String(data: JSONEncoder().encode(inventory), encoding: .utf8)
        )
        XCTAssertFalse(encoded.contains(root.path))
        XCTAssertFalse(encoded.contains("private-user"))
    }

    func testSkillInventoryItemDecodesOlderJSONWithoutScriptInventory() throws {
        let item = SkillInventoryItem.fixture(
            name: "legacy",
            path: "/fixtures/.agents/skills/legacy"
        )
        let encoded = try JSONEncoder().encode(item)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "script_inventory")

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(SkillInventoryItem.self, from: legacyData)

        XCTAssertNil(decoded.scriptInventory)
        XCTAssertEqual(decoded.name, "legacy")
    }
}
