import Foundation
import Testing
@testable import MetagentCore

@Suite("Path normalization")
struct PathNormalizationTests {
    @Test("resolves existing symlinks but preserves missing intended paths")
    func normalizesByExistence() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("path-normalization-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(canonicalExistingPath(link.path) == target.standardizedFileURL.path)
        #expect(
            canonicalExistingPath(root.appendingPathComponent("missing/../future").path)
                == root.appendingPathComponent("future").standardizedFileURL.path
        )
    }
}
