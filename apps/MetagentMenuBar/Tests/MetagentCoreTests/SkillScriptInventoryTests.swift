import Darwin
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
        try "#!/usr/bin/env sh\nHOME=/Users/private-user\n".write(
            to: skill.appendingPathComponent("scripts/helper.sh"),
            atomically: true,
            encoding: .utf8
        )
        try "#!/usr/bin/env ruby\nload 'scripts/helper.sh'\n".write(
            to: skill.appendingPathComponent("scripts/driver.rb"),
            atomically: true,
            encoding: .utf8
        )
        try "console.log('orphan')\n".write(
            to: skill.appendingPathComponent("scripts/orphan.js"),
            atomically: true,
            encoding: .utf8
        )
        try "#!/usr/bin/env shellcheck\nexit 0\n".write(
            to: skill.appendingPathComponent("scripts/not-a-shell"),
            atomically: true,
            encoding: .utf8
        )
        try "#!/usr/bin/env -S -iu PYTHONHOME -- 1=bar python3 -u\nprint('ok')\n".write(
            to: skill.appendingPathComponent("scripts/env-python"),
            atomically: true,
            encoding: .utf8
        )
        try "#!/usr/bin/env -iSpython3 -u\nprint('ok')\n".write(
            to: skill.appendingPathComponent("scripts/env-python-attached"),
            atomically: true,
            encoding: .utf8
        )
        try "#!/usr/bin/env -S--chdir /tmp FOO='hello world' python3 -u\nprint('ok')\n".write(
            to: skill.appendingPathComponent("scripts/env-python-quoted"),
            atomically: true,
            encoding: .utf8
        )
        try "#!/usr/bin/env --split-string='-a ignored FOO=hello python3 -u'\nprint('ok')\n".write(
            to: skill.appendingPathComponent("scripts/env-python-long"),
            atomically: true,
            encoding: .utf8
        )
        try "#!/usr/bin/env --split-string=FOO=\"hello world\" python3 -u\nprint('ok')\n".write(
            to: skill.appendingPathComponent("scripts/env-python-long-assignment"),
            atomically: true,
            encoding: .utf8
        )
        try "#!/usr/bin/env -uSHELL python3\nprint('ok')\n".write(
            to: skill.appendingPathComponent("scripts/env-python-unset"),
            atomically: true,
            encoding: .utf8
        )
        try "#!/usr/bin/env -S 'python3\nprint('not executable')\n".write(
            to: skill.appendingPathComponent("scripts/env-invalid-split-quote"),
            atomically: true,
            encoding: .utf8
        )
        try "#!/usr/bin/env FOO='hello world' python3\nprint('not executable')\n".write(
            to: skill.appendingPathComponent("scripts/env-invalid-quote"),
            atomically: true,
            encoding: .utf8
        )

        let inventory = try MetagentCore.inventorySkillScripts(path: skill.path)

        XCTAssertEqual(inventory.scripts.map(\.relativePath), [
            "scripts/driver.rb",
            "scripts/env-invalid-quote",
            "scripts/env-invalid-split-quote",
            "scripts/env-python",
            "scripts/env-python-attached",
            "scripts/env-python-long",
            "scripts/env-python-long-assignment",
            "scripts/env-python-quoted",
            "scripts/env-python-unset",
            "scripts/helper.sh",
            "scripts/not-a-shell",
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
        XCTAssertEqual(helper.referencedBy, [
            "references/architecture.md",
            "scripts/driver.rb",
        ])
        XCTAssertTrue(helper.warnings.contains("Contains an absolute user-home path."))

        let notAShell = try XCTUnwrap(inventory.scripts.first {
            $0.relativePath == "scripts/not-a-shell"
        })
        XCTAssertEqual(notAShell.runtime, "unknown")

        let envPython = try XCTUnwrap(inventory.scripts.first {
            $0.relativePath == "scripts/env-python"
        })
        XCTAssertEqual(envPython.runtime, "python")

        let envPythonAttached = try XCTUnwrap(inventory.scripts.first {
            $0.relativePath == "scripts/env-python-attached"
        })
        XCTAssertEqual(envPythonAttached.runtime, "python")

        let envPythonQuoted = try XCTUnwrap(inventory.scripts.first {
            $0.relativePath == "scripts/env-python-quoted"
        })
        XCTAssertEqual(envPythonQuoted.runtime, "python")

        let envPythonLong = try XCTUnwrap(inventory.scripts.first {
            $0.relativePath == "scripts/env-python-long"
        })
        XCTAssertEqual(envPythonLong.runtime, "python")

        let envPythonLongAssignment = try XCTUnwrap(inventory.scripts.first {
            $0.relativePath == "scripts/env-python-long-assignment"
        })
        XCTAssertEqual(envPythonLongAssignment.runtime, "python")

        let envPythonUnset = try XCTUnwrap(inventory.scripts.first {
            $0.relativePath == "scripts/env-python-unset"
        })
        XCTAssertEqual(envPythonUnset.runtime, "python")

        let envInvalidQuote = try XCTUnwrap(inventory.scripts.first {
            $0.relativePath == "scripts/env-invalid-quote"
        })
        XCTAssertEqual(envInvalidQuote.runtime, "unknown")

        let envInvalidSplitQuote = try XCTUnwrap(inventory.scripts.first {
            $0.relativePath == "scripts/env-invalid-split-quote"
        })
        XCTAssertEqual(envInvalidSplitQuote.runtime, "unknown")

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

    func testInventoryDoesNotFollowUnsafeSymlinks() throws {
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

        Use `scripts/inside.sh`, `scripts/outside.sh`, `scripts/broken.sh`, and `scripts/pipe.sh`.
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
        let pipeTarget = skill.appendingPathComponent("assets/pipe.sh")
        XCTAssertEqual(mkfifo(pipeTarget.path, 0o600), 0)
        try FileManager.default.createSymbolicLink(
            atPath: skill.appendingPathComponent("scripts/pipe.sh").path,
            withDestinationPath: "../assets/pipe.sh"
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
        let pipe = try XCTUnwrap(inventory.scripts.first {
            $0.relativePath == "scripts/pipe.sh"
        })

        XCTAssertEqual(inside.containment, .bundledSymlink)
        XCTAssertNotNil(inside.sha256)
        XCTAssertEqual(outside.containment, .escapesBundle)
        XCTAssertNil(outside.sha256)
        XCTAssertEqual(broken.containment, .brokenSymlink)
        XCTAssertNil(broken.sha256)
        XCTAssertEqual(pipe.containment, .bundledSymlink)
        XCTAssertNil(pipe.sha256)
        XCTAssertTrue(pipe.warnings.contains {
            $0.contains("not a regular file")
        })

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
