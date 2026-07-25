import Foundation
import XCTest
@testable import MetagentCore

extension SkillInventoryItem {
    static func fixture(
        name: String = "demo",
        description: String? = "fixture",
        path: String,
        location: String = "agents",
        locationLabel: String = ".agents",
        originKind: String = "user-local",
        scope: String = "project",
        manager: String = "local",
        authority: String = "unknown",
        mutability: String = "editable",
        representation: String = "canonical",
        source: String? = nil,
        sourceType: String? = nil,
        ref: String? = nil,
        updatedAt: String? = nil,
        folderKind: String = "fixture",
        characterCount: Int = 100,
        wordCount: Int = 20,
        tokenEstimate: Int = 25
    ) -> SkillInventoryItem {
        SkillInventoryItem(
            name: name,
            description: description,
            path: path,
            location: location,
            locationLabel: locationLabel,
            originKind: originKind,
            scope: scope,
            manager: manager,
            authority: authority,
            mutability: mutability,
            representation: representation,
            canonicalPath: path,
            source: source,
            sourceType: sourceType,
            sourceURL: nil,
            ref: ref,
            installedAt: nil,
            updatedAt: updatedAt,
            symlinkedContainer: false,
            folderKind: folderKind,
            characterCount: characterCount,
            wordCount: wordCount,
            tokenEstimate: tokenEstimate,
            skillFileCharacterCount: characterCount,
            skillFileWordCount: wordCount,
            skillFileTokenEstimate: tokenEstimate,
            textFileCount: 1,
            referenceFileCount: 0,
            scriptFileCount: 0,
            assetFileCount: 0,
            otherFileCount: 0,
            otherFolderCount: 0,
            hasOpenAIYaml: false,
            hasIconSmall: false,
            hasIconLarge: false,
            hasIconAndLogo: false,
            iconSmallPath: nil,
            iconLargePath: nil
        )
    }
}

extension XCTestCase {
    func makeTemporaryRoot(prefix: String = "metagent-test") throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}

func restoreEnvironment(_ name: String, _ value: String?) {
    if let value {
        setenv(name, value, 1)
    } else {
        unsetenv(name)
    }
}

@discardableResult
func writeSkillFixture(
    at directory: URL,
    name: String = "demo",
    description: String = "fixture",
    body: String? = nil
) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var content = "---\nname: \(name)\ndescription: \(description)\n---\n"
    if let body {
        content += "\n" + body
    }
    try content.write(
        to: directory.appendingPathComponent("SKILL.md"),
        atomically: true,
        encoding: .utf8
    )
    return directory
}
