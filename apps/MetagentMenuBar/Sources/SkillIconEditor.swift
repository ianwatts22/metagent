import AppKit
import Foundation
import MetagentCore
import SwiftUI
import UniformTypeIdentifiers

enum SkillIconSource: String, CaseIterable, Identifiable {
    case emoji = "Emoji"
    case lucide = "Lucide"
    case image = "Image"

    var id: String { rawValue }
}

struct SkillIconSourceSelector: View {
    @Binding var selection: SkillIconSource

    var body: some View {
        Picker("Icon source", selection: $selection) {
            ForEach(SkillIconSource.allCases) { source in
                Text(source.rawValue).tag(source)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityLabel("Icon source")
    }
}

struct LucideSkillIcon: Identifiable {
    let id: String
    let name: String
    let body: String
    var tags: [String] = []

    var svgData: Data {
        Data("""
        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
        \(body)
        </svg>
        """.utf8)
    }

    var image: NSImage? { NSImage(data: svgData) }

    static let catalog = loadCatalog()

    private static let fallbackCatalog = [
        LucideSkillIcon(id: "sparkles", name: "Sparkles", body: #"""
        <path d="M11.017 2.814a1 1 0 0 1 1.966 0l1.051 5.558a2 2 0 0 0 1.594 1.594l5.558 1.051a1 1 0 0 1 0 1.966l-5.558 1.051a2 2 0 0 0-1.594 1.594l-1.051 5.558a1 1 0 0 1-1.966 0l-1.051-5.558a2 2 0 0 0-1.594-1.594l-5.558-1.051a1 1 0 0 1 0-1.966l5.558-1.051a2 2 0 0 0 1.594-1.594z"/><path d="M20 2v4"/><path d="M22 4h-4"/><circle cx="4" cy="20" r="2"/>
        """#),
        LucideSkillIcon(id: "search", name: "Search", body: #"""
        <path d="m21 21-4.34-4.34"/><circle cx="11" cy="11" r="8"/>
        """#),
        LucideSkillIcon(id: "wrench", name: "Wrench", body: #"""
        <path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.106-3.105c.32-.322.863-.22.983.218a6 6 0 0 1-8.259 7.057l-7.91 7.91a1 1 0 0 1-2.999-3l7.91-7.91a6 6 0 0 1 7.057-8.259c.438.12.54.662.219.984z"/>
        """#),
        LucideSkillIcon(id: "brain", name: "Brain", body: #"""
        <path d="M12 18V5"/><path d="M15 13a4.17 4.17 0 0 1-3-4 4.17 4.17 0 0 1-3 4"/><path d="M17.598 6.5A3 3 0 1 0 12 5a3 3 0 1 0-5.598 1.5"/><path d="M17.997 5.125a4 4 0 0 1 2.526 5.77"/><path d="M18 18a4 4 0 0 0 2-7.464"/><path d="M19.967 17.483A4 4 0 1 1 12 18a4 4 0 1 1-7.967-.517"/><path d="M6 18a4 4 0 0 1-2-7.464"/><path d="M6.003 5.125a4 4 0 0 0-2.526 5.77"/>
        """#),
        LucideSkillIcon(id: "palette", name: "Palette", body: #"""
        <path d="M12 22a1 1 0 0 1 0-20 10 9 0 0 1 10 9 5 5 0 0 1-5 5h-2.25a1.75 1.75 0 0 0-1.4 2.8l.3.4a1.75 1.75 0 0 1-1.4 2.8z"/><circle cx="13.5" cy="6.5" r=".5" fill="white"/><circle cx="17.5" cy="10.5" r=".5" fill="white"/><circle cx="6.5" cy="12.5" r=".5" fill="white"/><circle cx="8.5" cy="7.5" r=".5" fill="white"/>
        """#),
        LucideSkillIcon(id: "shield-check", name: "Shield Check", body: #"""
        <path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z"/><path d="m9 12 2 2 4-4"/>
        """#),
        LucideSkillIcon(id: "rocket", name: "Rocket", body: #"""
        <path d="M12 15v5s3.03-.55 4-2c1.08-1.62 0-5 0-5"/><path d="M4.5 16.5c-1.5 1.26-2 5-2 5s3.74-.5 5-2c.71-.84.7-2.13-.09-2.91a2.18 2.18 0 0 0-2.91-.09"/><path d="M9 12a22 22 0 0 1 2-3.95A12.88 12.88 0 0 1 22 2c0 2.72-.78 7.5-6 11a22.4 22.4 0 0 1-4 2z"/><path d="M9 12H4s.55-3.03 2-4c1.62-1.08 5 .05 5 .05"/>
        """#),
        LucideSkillIcon(id: "file-text", name: "Document", body: #"""
        <path d="M6 22a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h8a2.4 2.4 0 0 1 1.704.706l3.588 3.588A2.4 2.4 0 0 1 20 8v12a2 2 0 0 1-2 2z"/><path d="M14 2v5a1 1 0 0 0 1 1h5"/><path d="M10 9H8"/><path d="M16 13H8"/><path d="M16 17H8"/>
        """#),
        LucideSkillIcon(id: "code-xml", name: "Code", body: #"""
        <path d="m18 16 4-4-4-4"/><path d="m6 8-4 4 4 4"/><path d="m14.5 4-5 16"/>
        """#),
        LucideSkillIcon(id: "bot", name: "Bot", body: #"""
        <path d="M12 8V4H8"/><rect width="16" height="12" x="4" y="8" rx="2"/><path d="M2 14h2"/><path d="M20 14h2"/><path d="M15 13v2"/><path d="M9 13v2"/>
        """#),
        LucideSkillIcon(id: "database", name: "Database", body: #"""
        <ellipse cx="12" cy="5" rx="9" ry="3"/><path d="M3 5V19A9 3 0 0 0 21 19V5"/><path d="M3 12A9 3 0 0 0 21 12"/>
        """#),
        LucideSkillIcon(id: "globe", name: "Globe", body: #"""
        <circle cx="12" cy="12" r="10"/><path d="M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20"/><path d="M2 12h20"/>
        """#),
        LucideSkillIcon(id: "workflow", name: "Workflow", body: #"""
        <rect width="8" height="8" x="3" y="3" rx="2"/><path d="M7 11v4a2 2 0 0 0 2 2h4"/><rect width="8" height="8" x="13" y="13" rx="2"/>
        """#),
        LucideSkillIcon(id: "terminal", name: "Terminal", body: #"""
        <path d="M12 19h8"/><path d="m4 17 6-6-6-6"/>
        """#),
        LucideSkillIcon(id: "package", name: "Package", body: #"""
        <path d="M11 21.73a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73z"/><path d="M12 22V12"/><polyline points="3.29 7 12 12 20.71 7"/><path d="m7.5 4.27 9 5.15"/>
        """#),
        LucideSkillIcon(id: "plug", name: "Plug", body: #"""
        <path d="M12 22v-5"/><path d="M15 8V2"/><path d="M17 8a1 1 0 0 1 1 1v4a4 4 0 0 1-4 4h-4a4 4 0 0 1-4-4V9a1 1 0 0 1 1-1z"/><path d="M9 8V2"/>
        """#)
    ]

    var searchText: String {
        ([id, name] + tags).joined(separator: " ")
    }

    private static func loadCatalog() -> [LucideSkillIcon] {
        guard let spriteURL = resourceURL(
            packagedName: "Lucide-sprite",
            sourceName: "sprite",
            extension: "svg"
        ),
        let sprite = try? String(contentsOf: spriteURL, encoding: .utf8),
        let expression = try? NSRegularExpression(
            pattern: #"<symbol id="([^"]+)" viewBox="0 0 24 24">\s*(.*?)\s*</symbol>"#,
            options: [.dotMatchesLineSeparators]
        )
        else { return fallbackCatalog }

        let tags = loadTags()
        let range = NSRange(sprite.startIndex..<sprite.endIndex, in: sprite)
        let icons = expression.matches(in: sprite, range: range).compactMap { match -> LucideSkillIcon? in
            guard match.numberOfRanges == 3,
                  let idRange = Range(match.range(at: 1), in: sprite),
                  let bodyRange = Range(match.range(at: 2), in: sprite)
            else { return nil }
            let id = String(sprite[idRange])
            return LucideSkillIcon(
                id: id,
                name: id
                    .split(separator: "-")
                    .map { $0.capitalized }
                    .joined(separator: " "),
                body: String(sprite[bodyRange]),
                tags: tags[id] ?? []
            )
        }
        return icons.isEmpty ? fallbackCatalog : icons
    }

    private static func loadTags() -> [String: [String]] {
        guard let url = resourceURL(
            packagedName: "Lucide-tags",
            sourceName: "tags",
            extension: "json"
        ),
        let data = try? Data(contentsOf: url),
        let tags = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return [:] }
        return tags
    }

    private static func resourceURL(
        packagedName: String,
        sourceName: String,
        extension fileExtension: String
    ) -> URL? {
        resourceURL(
            in: .main,
            packagedName: packagedName,
            sourceName: sourceName,
            extension: fileExtension
        ) ?? resourceURL(
            in: .module,
            packagedName: packagedName,
            sourceName: sourceName,
            extension: fileExtension
        )
    }

    private static func resourceURL(
        in bundle: Bundle,
        packagedName: String,
        sourceName: String,
        extension fileExtension: String
    ) -> URL? {
        if let packaged = bundle.url(forResource: packagedName, withExtension: fileExtension) {
            return packaged
        }
        if let source = bundle.url(
            forResource: sourceName,
            withExtension: fileExtension,
            subdirectory: "Lucide"
        ) {
            return source
        }
        return bundle.url(forResource: sourceName, withExtension: fileExtension)
    }
}

struct SkillIconEditorView: View {
    @ObservedObject var model: MetagentModel
    let row: InventorySkillRow
    var skillPath: String? = nil
    var skillName: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var selectedSource = SkillIconSource.emoji
    @State private var selectedEmoji = "✨"
    @State private var selectedLucideID = LucideSkillIcon.catalog[0].id
    @State private var lucideQuery = ""
    @FocusState private var emojiFieldIsFocused: Bool

    private var selectedLucide: LucideSkillIcon {
        LucideSkillIcon.catalog.first { $0.id == selectedLucideID } ?? LucideSkillIcon.catalog[0]
    }

    private var visibleLucideIcons: [LucideSkillIcon] {
        let query = lucideQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return LucideSkillIcon.catalog }
        return LucideSkillIcon.catalog.filter {
            $0.searchText.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.skillIconPath == nil ? "Add an icon" : "Change icon")
                        .font(.title2.weight(.semibold))
                    Text(skillName ?? row.skillName)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
            }

            SkillIconSourceSelector(selection: $selectedSource)

            Group {
                switch selectedSource {
                case .emoji: emojiPane
                case .lucide: lucidePane
                case .image: imagePane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Text("Metagent writes a portable PNG to assets/metagent-icon.png and records it in agents/openai.yaml. Lucide icons are provided under the ISC license.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(primaryActionTitle) { saveSelectedIcon() }
                .buttonStyle(.glassProminent)
                .disabled(
                    model.isRunning
                        || (selectedSource == .emoji && selectedEmoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                )
            }
        }
        .padding(22)
        .frame(width: 680, height: 600)
    }

    private var emojiPane: some View {
        HStack(alignment: .top, spacing: 20) {
            emojiPreview.frame(width: 96, height: 96)
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose an emoji").font(.headline)
                TextField("Selected emoji", text: $selectedEmoji)
                    .textFieldStyle(.roundedBorder)
                    .focused($emojiFieldIsFocused)
                    .frame(width: 190)
                Button {
                    emojiFieldIsFocused = true
                    DispatchQueue.main.async {
                        NSApp.orderFrontCharacterPalette(nil)
                    }
                } label: {
                    Label("Open Emoji & Symbols", systemImage: "face.smiling")
                }
                Text("Use the macOS character palette to search the complete emoji library. Your selection is inserted into the field above.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var lucidePane: some View {
        HStack(alignment: .top, spacing: 20) {
            lucidePreview.frame(width: 96, height: 96)
            VStack(alignment: .leading, spacing: 10) {
                GlassSearchField(placeholder: "Search Lucide icons", text: $lucideQuery, width: 430)
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(54)), count: 7), spacing: 8) {
                        ForEach(visibleLucideIcons) { icon in
                            Button {
                                selectedLucideID = icon.id
                            } label: {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(Color.accentColor.opacity(selectedLucideID == icon.id ? 1 : 0.72))
                                    if let image = icon.image {
                                        Image(nsImage: image).resizable().scaledToFit().padding(12)
                                    }
                                }
                                .frame(width: 50, height: 50)
                            }
                            .buttonStyle(.plain)
                            .help(icon.name)
                            .accessibilityLabel(icon.name)
                            .accessibilityAddTraits(selectedLucideID == icon.id ? .isSelected : [])
                        }
                    }
                }
                HStack {
                    Text(selectedLucide.name)
                    Spacer()
                    Text("\(visibleLucideIcons.count.formatted()) of \(LucideSkillIcon.catalog.count.formatted())")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var imagePane: some View {
        ContentUnavailableView {
            Label("Choose an image", systemImage: "photo")
        } description: {
            Text("Import a PNG, JPEG, or HEIC—including artwork exported from Icon Composer.")
        }
    }

    private var emojiPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
            Text(selectedEmoji)
                .font(.system(size: 54))
                .lineLimit(1)
        }
    }

    private var lucidePreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.accentColor)
            if let image = selectedLucide.image {
                Image(nsImage: image).resizable().scaledToFit().padding(24)
            }
        }
    }

    private var primaryActionTitle: String {
        switch selectedSource {
        case .emoji: "Use Emoji"
        case .lucide: "Use Lucide Icon"
        case .image: "Choose Image…"
        }
    }

    private func saveSelectedIcon() {
        if selectedSource == .image {
            chooseImage()
            return
        }
        let data = selectedSource == .emoji ? emojiPNG(selectedEmoji) : lucidePNG(selectedLucide)
        guard let data, model.updateSkillIcon(
            path: skillPath ?? row.canonicalPath,
            pngData: data
        ) else {
            NSSound.beep()
            return
        }
        dismiss()
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        panel.prompt = "Use Icon"
        guard panel.runModal() == .OK,
              let url = panel.url,
              let image = NSImage(contentsOf: url),
              let data = normalizedPNG(image),
              model.updateSkillIcon(path: skillPath ?? row.canonicalPath, pngData: data)
        else { return }
        dismiss()
    }
}

/// Renders a 512×512 icon on a cleared canvas and returns PNG data.
/// `draw` receives the canvas size and paints into the active graphics context.
func renderIconPNG(_ draw: (NSSize) -> Void) -> Data? {
    guard let (bitmap, context) = iconBitmap() else { return nil }
    let size = NSSize(width: 512, height: 512)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSColor.clear.setFill()
    NSRect(origin: .zero, size: size).fill()
    draw(size)
    context.flushGraphics()
    return bitmap.representation(using: .png, properties: [:])
}

func emojiPNG(_ emoji: String) -> Data? {
    let value = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    return renderIconPNG { size in
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 340)
        ]
        let attributed = NSAttributedString(string: value, attributes: attributes)
        let textSize = attributed.size()
        attributed.draw(at: NSPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2))
    }
}

func lucidePNG(_ icon: LucideSkillIcon) -> Data? {
    guard let source = icon.image else { return nil }
    return renderIconPNG { _ in
        NSColor.controlAccentColor.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 16, y: 16, width: 480, height: 480),
            xRadius: 112,
            yRadius: 112
        ).fill()
        source.draw(
            in: NSRect(x: 104, y: 104, width: 304, height: 304),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
    }
}

func normalizedPNG(_ source: NSImage) -> Data? {
    guard source.size.width > 0, source.size.height > 0 else { return nil }
    return renderIconPNG { size in
        let sourceSize = source.size
        let scale = min(size.width / sourceSize.width, size.height / sourceSize.height)
        let drawSize = NSSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        source.draw(
            in: NSRect(
                x: (size.width - drawSize.width) / 2,
                y: (size.height - drawSize.height) / 2,
                width: drawSize.width,
                height: drawSize.height
            ),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
    }
}

func iconBitmap() -> (NSBitmapImageRep, NSGraphicsContext)? {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 512,
        pixelsHigh: 512,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [],
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
    return (bitmap, context)
}
