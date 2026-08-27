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
        guard let url = Bundle.module.url(forResource: "mcp-server", withExtension: "svg"),
              let image = NSImage(contentsOf: url)
        else {
            return nil
        }
        image.isTemplate = true
        return image
    }()
}
