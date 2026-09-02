import AppKit
import SwiftUI

/// Hugeicons' free `McpServerIcon`, packaged as a template image so the app can
/// apply the same semantic colors used by native macOS symbols.
struct MCPServerIcon: View {
    var size: CGFloat = 16
    var weight: Font.Weight = .regular

    var body: some View {
        Group {
            if let image = Self.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "server.rack")
                    .fontWeight(weight)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private static let image: NSImage? = {
        guard let url = resourceURL(),
              let image = NSImage(contentsOf: url)
        else {
            return nil
        }
        image.isTemplate = true
        return image
    }()

    /// Release builds are assembled as app bundles rather than launched from
    /// SwiftPM's build directory. Look in the app's packaged resources first,
    /// then in the adjacent SwiftPM resource bundle used by local builds and
    /// tests. Avoid `Bundle.module` here: its generated accessor traps when a
    /// hand-assembled app is missing that bundle, preventing the SF Symbol
    /// fallback above from ever rendering.
    private static func resourceURL() -> URL? {
        if let packaged = Bundle.main.url(forResource: "mcp-server", withExtension: "svg") {
            return packaged
        }

        let resourceBundleName = "MetagentMenuBar_MetagentMenuBar.bundle"
        var bundleURLs = [Bundle.main.bundleURL.appendingPathComponent(resourceBundleName)]
        if let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent() {
            bundleURLs.append(executableDirectory.appendingPathComponent(resourceBundleName))
        }

        return bundleURLs.lazy
            .compactMap(Bundle.init(url:))
            .compactMap { $0.url(forResource: "mcp-server", withExtension: "svg") }
            .first
    }
}
