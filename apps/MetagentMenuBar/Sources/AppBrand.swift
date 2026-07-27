import AppKit
import Foundation
import MetagentCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor enum AppBrand {
    /// Width-to-height ratio of the wide brand glyph, so callers can size it without letterboxing.
    static let markAspectRatio: CGFloat = 506 / 400

    /// True in dev-channel builds, whose bundle ID carries a `.dev` suffix so
    /// they never share an identity with the website-installed app.
    static let isDevChannel = Bundle.main.bundleIdentifier?.hasSuffix(".dev") ?? false

    static let menuBarIcon: NSImage? = {
        let icon = loadMenuBarIcon(in: .main) ?? loadMenuBarIcon(in: .module)
        // Both channels can sit in the menu bar at once; without a mark they
        // are pixel-identical and the wrong one gets clicked.
        guard isDevChannel, let icon else { return icon }
        return devBadged(icon)
    }()

    private static let applicationIcons: [String: NSImage] = {
        MCPClient.allCases.map(\.bundleIdentifier).reduce(into: [:]) { icons, bundleIdentifier in
            guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
                return
            }
            icons[bundleIdentifier] = NSWorkspace.shared.icon(forFile: applicationURL.path)
        }
    }()

    private static let skillIcons = NSCache<NSString, NSImage>()

    static func applicationIcon(bundleIdentifier: String) -> NSImage? {
        applicationIcons[bundleIdentifier]
    }

    static func skillIcon(path: String?) -> NSImage? {
        guard let path, !path.isEmpty else { return nil }
        let key = path as NSString
        if let cached = skillIcons.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        skillIcons.setObject(image, forKey: key)
        return image
    }

    static func clearSkillIconCache() {
        skillIcons.removeAllObjects()
    }

    /// A small filled dot in the glyph's lower-right corner. Drawn into the
    /// template image so it inherits menu bar tinting in light, dark, and
    /// active states rather than fighting them with a fixed colour.
    private static func devBadged(_ icon: NSImage) -> NSImage {
        let size = icon.size
        let badged = NSImage(size: size, flipped: false) { rect in
            icon.draw(in: rect)
            let diameter = min(rect.width, rect.height) * 0.32
            let dot = NSRect(
                x: rect.maxX - diameter,
                y: rect.minY,
                width: diameter,
                height: diameter
            )
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        badged.isTemplate = true
        return badged
    }

    private static func loadMenuBarIcon(in bundle: Bundle) -> NSImage? {
        guard let url = bundle.url(forResource: "MenuBarIconTemplate", withExtension: "pdf"),
              let image = NSImage(contentsOf: url)
        else { return nil }
        image.isTemplate = true
        // Keep the glyph's own proportions; a square size makes `scaledToFit` letterbox it.
        image.size = NSSize(width: 18, height: 18 / markAspectRatio)
        return image
    }
}
