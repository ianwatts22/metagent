import AppKit
import Foundation
import MetagentCore
import SwiftUI
import UniformTypeIdentifiers

struct MetagentPanel: View {
    @ObservedObject var model: MetagentModel
    let showsOpenWindowButton: Bool
    @Environment(\.openWindow) private var openWindow
    @Binding var selectedSection: PanelSection
    @Binding var selectedProjectRoot: String?
    @State private var showsSettings = false

    private var directoryOptions: [DirectoryFilterOption] {
        directoryFilterOptions(
            projects: model.projects,
            mcpHealth: model.mcpHealth,
            doctorIssues: model.doctorIssues
        )
    }

    var body: some View {
        ZStack {
            PanelBackdrop()

            VStack(alignment: .leading, spacing: showsOpenWindowButton ? 12 : 14) {
                topBar
                panelContent
                    .animation(.snappy(duration: 0.25), value: selectedSection)

                if showsOpenWindowButton {
                    compactFooter
                }
            }
            .padding(.horizontal, showsOpenWindowButton ? 16 : 18)
            .padding(.top, showsOpenWindowButton ? 16 : 10)
            .padding(.bottom, showsOpenWindowButton ? 16 : 18)
        }
        .onChange(of: directoryOptions.map(\.root)) { _, roots in
            if let selectedProjectRoot, !roots.contains(selectedProjectRoot) {
                self.selectedProjectRoot = nil
            }
        }
        .sheet(isPresented: $showsSettings) {
            SettingsView(model: model)
        }
    }

    @ViewBuilder
    private var topBar: some View {
        if showsOpenWindowButton {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    brandMark
                    directoryScopeControl
                    Spacer(minLength: 0)
                    activityControl
                    statusFailureControl
                    refreshControl
                    settingsControl
                }
                navigation
            }
        } else {
            HStack(spacing: 10) {
                brandMark
                directoryScopeControl
                navigation
                activityControl
                statusFailureControl
                refreshControl
                settingsControl
            }
        }
    }

    /// Attention states only; work in progress reports through the refresh
    /// slot instead, so the control line never grows a second capsule.
    @ViewBuilder
    private var activityControl: some View {
        if let activity = model.activity, activity.needsAttention {
            ActivityBadge(activity: activity)
        }
    }

    /// The one reload: rescan skills and Doctor findings, recheck MCP
    /// configuration, and continue indexing session history. While work is
    /// running the button gives its slot to the progress indicator — reload
    /// would be a no-op then anyway.
    @ViewBuilder
    private var refreshControl: some View {
        if let activity = model.activity, !activity.needsAttention {
            ActivityBadge(activity: activity)
        } else {
            Button {
                model.refreshAll()
            } label: {
                GlassMenuLabel(
                    title: nil,
                    systemImage: "arrow.clockwise",
                    width: 36,
                    showsChevron: false
                )
            }
            .buttonStyle(.plain)
            .disabled(model.isRefreshing)
            .help("Rescan skills, Doctor findings, and MCP configuration, and continue indexing session history")
            .accessibilityLabel("Reload")
        }
    }

    private var brandMark: some View {
        // The mark is a wide glyph, so a square frame would letterbox it.
        MenuBarIcon()
            .frame(width: 38, height: 38 / AppBrand.markAspectRatio)
            .padding(.horizontal, 2)
            .frame(height: 36)
            .help("Metagent")
            .accessibilityLabel("Metagent")
    }

    @ViewBuilder
    private var statusFailureControl: some View {
        if !model.isRunning,
           model.statusText.localizedCaseInsensitiveContains("failed")
        {
            Button {
                model.openLogs()
            } label: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .frame(width: 20)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.regular)
            .frame(width: 36, height: 36)
            .help("\(model.statusText). Open logs.")
            .accessibilityLabel("\(model.statusText). Open logs.")
        }
    }

    private var directoryScopeControl: some View {
        Menu {
            Button {
                selectedProjectRoot = nil
            } label: {
                if selectedProjectRoot == nil {
                    Label("All directories", systemImage: "checkmark")
                } else {
                    Text("All directories")
                }
            }
            Divider()
            ForEach(directoryOptions) { directory in
                Button {
                    selectedProjectRoot = directory.root
                } label: {
                    if selectedProjectRoot == directory.root {
                        Label(
                            directoryFilterLabel(directory, options: directoryOptions),
                            systemImage: "checkmark"
                        )
                    } else {
                        Text(directoryFilterLabel(directory, options: directoryOptions))
                    }
                }
            }
        } label: {
            GlassMenuLabel(
                title: selectedDirectoryLabel,
                systemImage: selectedProjectRoot == nil
                    ? "line.3.horizontal.decrease"
                    : "line.3.horizontal.decrease.circle.fill",
                width: showsOpenWindowButton ? 205 : 240
            )
        }
        .buttonStyle(.plain)
        .help(selectedProjectRoot.map(displayUserPath) ?? "Show all directories")
        .accessibilityLabel("Directory")
    }

    private var settingsControl: some View {
        Button {
            showsSettings = true
        } label: {
            GlassMenuLabel(
                title: nil,
                systemImage: "gearshape",
                width: 36,
                showsChevron: false
            )
        }
        .buttonStyle(.plain)
        .help("Settings and diagnostics")
        .accessibilityLabel("Settings and diagnostics")
    }

    private var selectedDirectoryLabel: String {
        guard let selectedProjectRoot,
              let directory = directoryOptions.first(where: { $0.root == selectedProjectRoot })
        else {
            return "All directories"
        }
        return directoryFilterLabel(directory, options: directoryOptions)
    }

    /// One enclosing track holds all four destinations. Rendering them as
    /// separate capsules the same height as the neighbouring controls made them
    /// read as unrelated buttons rather than as a tab group.
    private var navigation: some View {
        HStack(spacing: 3) {
            ForEach(PanelSection.allCases) { section in
                SectionNavigationButton(
                    section: section,
                    isSelected: selectedSection == section
                ) {
                    withAnimation(.snappy(duration: 0.25)) {
                        selectedSection = section
                    }
                }
            }
        }
        .padding(4)
        .glassEffect(.regular, in: Capsule())
        .frame(maxWidth: showsOpenWindowButton ? .infinity : 620)
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @ViewBuilder
    private var panelContent: some View {
        switch selectedSection {
        case .overview:
            OverviewSection(
                model: model,
                isCompact: showsOpenWindowButton,
                selectedProjectRoot: selectedProjectRoot
            ) {
                UserDefaults.standard.set(
                    SkillTableView.duplicates.rawValue,
                    forKey: "metagent.skills.view.v2"
                )
                selectedSection = .skills
                if showsOpenWindowButton {
                    openMainWindow()
                }
            }
        case .history:
            HistorySection(
                model: model,
                isCompact: showsOpenWindowButton,
                selectedProjectRoot: selectedProjectRoot
            )
        case .skills:
            if showsOpenWindowButton {
                SkillsMenuSection(
                    model: model,
                    selectedProjectRoot: selectedProjectRoot,
                    openMainWindow: openMainWindow
                )
            } else {
                InventorySection(model: model, selectedProjectRoot: selectedProjectRoot)
            }
        case .mcps:
            if showsOpenWindowButton {
                MCPMenuSection(
                    model: model,
                    selectedProjectRoot: selectedProjectRoot,
                    openMainWindow: openMainWindow
                )
            } else {
                MCPInventorySection(model: model, selectedProjectRoot: selectedProjectRoot)
            }
        case .projects:
            if showsOpenWindowButton {
                ProjectsMenuSection(
                    model: model,
                    selectedProjectRoot: selectedProjectRoot,
                    openMainWindow: openMainWindow
                )
            } else {
                ProjectsSection(model: model, selectedProjectRoot: selectedProjectRoot)
            }
        }
    }

    private var compactFooter: some View {
        HStack(spacing: 10) {
            Spacer()

            Button {
                openMainWindow()
            } label: {
                Label("Open Window", systemImage: "macwindow")
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help("Quit Metagent")
        }
    }

}

struct PanelBackdrop: View {
    var body: some View {
        Color(nsColor: .windowBackgroundColor)
            .ignoresSafeArea()
    }
}

struct SectionNavigationButton: View {
    let section: PanelSection
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        // The enclosing track already supplies the glass, so the selected tab
        // is a solid fill rather than glass layered on glass.
        Button(action: action) {
            Label(section.title, systemImage: section.symbol)
                .font(.callout.weight(isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(isSelected ? Color.accentColor : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Whatever the app is doing right now, in one shape, so scanning, indexing,
/// MCP checks, and Plugin Eval all report through the same control.
enum AppActivity: Equatable {
    /// Work is advancing; `progress` is nil when the total is not yet known.
    case working(progress: Double?, label: String)
    /// Something finished short, or never had data to work with.
    case attention(String)

    var label: String {
        switch self {
        case let .working(_, label): label
        case let .attention(label): label
        }
    }

    var needsAttention: Bool {
        if case .attention = self { return true }
        return false
    }

    var help: String {
        switch self {
        case .working:
            return "\(label) Numbers that depend on this are provisional until it finishes."
        case .attention:
            return "\(label) Numbers that depend on retained session history cover only part of the corpus, so an absent read is not proof a skill went unused."
        }
    }
}

struct ActivityBadge: View {
    let activity: AppActivity

    var body: some View {
        // Just the indicator: the label lives in the tooltip so a long report
        // like "Plugin Eval 13 of 107" cannot crowd out the tab strip.
        Group {
            switch activity {
            case let .working(progress, _):
                if let progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            case .attention:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .frame(width: 36, height: 36)
        .glassEffect(
            .regular.tint(activity.needsAttention ? Color.orange.opacity(0.22) : nil),
            in: Circle()
        )
        .help(activity.help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(activity.label)
        .accessibilityHint(activity.help)
    }
}

/// The row count as a quiet chip beside the controls, instead of a page title
/// restating the tab the user just clicked.
struct CountChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(.quaternary.opacity(0.6), in: Capsule())
            .accessibilityLabel(text)
    }
}

struct GlassSearchField: View {
    let placeholder: String
    @Binding var text: String
    let width: CGFloat

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 11)
        .frame(width: width, height: 34)
        .glassEffect(.regular, in: Capsule())
    }
}

struct GlassMenuLabel: View {
    let title: String?
    let systemImage: String
    let width: CGFloat
    var showsChevron = true

    var body: some View {
        // With no title and no chevron the glyph is the whole control: a true
        // circle, since a 44-wide capsule reads as squashed next to real text
        // controls.
        if title == nil, !showsChevron {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .font(.callout.weight(.medium))
                .frame(width: 36, height: 36)
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: Circle())
        } else {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                if let title {
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                }
                if showsChevron {
                    if title == nil {
                        Spacer(minLength: 4)
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 11)
            .frame(width: width, height: 36)
            .contentShape(Capsule())
            .glassEffect(.regular.interactive(), in: Capsule())
        }
    }
}

struct GlassSelectionMenu<Option>: View
where Option: Hashable & Identifiable {
    let title: String
    @Binding var selection: Option
    let options: [Option]
    let optionTitle: (Option) -> String
    let width: CGFloat

    var body: some View {
        Menu {
            ForEach(options) { option in
                Button {
                    selection = option
                } label: {
                    if option == selection {
                        Label(optionTitle(option), systemImage: "checkmark")
                    } else {
                        Text(optionTitle(option))
                    }
                }
            }
        } label: {
            GlassMenuLabel(
                title: optionTitle(selection),
                systemImage: selection == options.first ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill",
                width: width
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(optionTitle(selection))
    }
}

enum PanelSection: String, CaseIterable, Identifiable {
    case overview
    case history
    case skills
    case mcps
    case projects

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .history: "History"
        case .skills: "Skills"
        case .mcps: "MCPs"
        case .projects: "Projects"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge"
        case .history: "chart.xyaxis.line"
        case .skills: "sparkles"
        case .mcps: "server.rack"
        case .projects: "folder"
        }
    }
}
