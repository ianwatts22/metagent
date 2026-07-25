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
    }

    @ViewBuilder
    private var topBar: some View {
        if showsOpenWindowButton {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    brandMark
                    directoryScopeControl
                    Spacer(minLength: 0)
                    statusFailureControl
                    settingsControl
                }
                navigation
            }
        } else {
            HStack(spacing: 10) {
                brandMark
                directoryScopeControl
                navigation
                statusFailureControl
                settingsControl
            }
        }
    }

    private var brandMark: some View {
        MenuBarIcon()
            .frame(width: 36, height: 36)
            .padding(3)
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
            .buttonBorderShape(.capsule)
            .controlSize(.regular)
            .frame(width: 42, height: 36)
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
                systemImage: "scope",
                width: showsOpenWindowButton ? 205 : 240
            )
        }
        .buttonStyle(.plain)
        .help(selectedProjectRoot.map(displayUserPath) ?? "Show all directories")
        .accessibilityLabel("Directory")
    }

    private var settingsControl: some View {
        Menu {
            Button("Open Configuration", systemImage: "slider.horizontal.3") {
                model.openConfig()
            }
            Button("Open Logs", systemImage: "doc.text") {
                model.openLogs()
            }
        } label: {
            GlassMenuLabel(
                title: nil,
                systemImage: "gearshape",
                width: 58
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

    private var navigation: some View {
        HStack(spacing: 4) {
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
            if model.isRunning {
                ProgressView()
                    .controlSize(.small)
                Text("Working…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                openMainWindow()
            } label: {
                Label("Open Window", systemImage: "macwindow")
            }
            .buttonStyle(.glassProminent)

            Button {
                model.refreshStatus()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.glass)
            .help("Refresh")
            .disabled(model.isRunning)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.glass)
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
        if isSelected {
            button
                .buttonStyle(.glassProminent)
        } else {
            button
                .buttonStyle(.glass)
        }
    }

    private var button: some View {
        Button(action: action) {
            Label(section.title, systemImage: section.symbol)
                .font(.callout.weight(isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .contentShape(Capsule())
        }
        .buttonBorderShape(.capsule)
        .controlSize(.regular)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            if let title {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 11)
        .frame(width: width, height: 36)
        .contentShape(Capsule())
        .glassEffect(.regular.interactive(), in: Capsule())
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
    case skills
    case mcps
    case projects

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .skills: "Skills"
        case .mcps: "MCPs"
        case .projects: "Projects"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge"
        case .skills: "sparkles"
        case .mcps: "server.rack"
        case .projects: "folder"
        }
    }
}
