import AppKit
import Foundation
import MetagentCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor enum AppBrand {
    static let menuBarIcon: NSImage? = {
        loadMenuBarIcon(in: .main) ?? loadMenuBarIcon(in: .module)
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

    private static func loadMenuBarIcon(in bundle: Bundle) -> NSImage? {
        guard let url = bundle.url(forResource: "MenuBarIconTemplate", withExtension: "pdf"),
              let image = NSImage(contentsOf: url)
        else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }
}
