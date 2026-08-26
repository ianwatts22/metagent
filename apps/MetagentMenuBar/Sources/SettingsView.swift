import AppKit
import Foundation
import MetagentCore
import SwiftUI

/// Direct editing for the handful of settings that actually change what the app
/// scans, so the config file stays an escape hatch rather than the only door.
struct SettingsView: View {
    @ObservedObject var model: MetagentModel
    @EnvironmentObject private var updater: UpdaterModel
    @Environment(\.dismiss) private var dismiss

    @State private var roots: [String] = []
    @State private var ignoreProjects: [String] = []
    @State private var maxDepth = 6
    @State private var trackedProviders: Set<String> = []
    @State private var analyticsEnabled = ProductAnalytics.defaultEnabled
    @State private var loadError: String?
    @State private var saveError: String?

    var body: some View {
        // The header stays pinned and everything below scrolls: the form is
        // taller than the compact panel, and a sheet with no scroll view clips
        // its top with no way to reach it.
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Settings")
                            .font(.title2.weight(.semibold))
                        Text(displayUserPath(MetagentCore.userConfigPath().path))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    Spacer()

                    Button("Cancel") {
                        dismiss()
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .keyboardShortcut(.cancelAction)

                    Button("Save") {
                        save()
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .keyboardShortcut(.defaultAction)
                }

                if let message = loadError ?? saveError {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            ScrollView {
                settingsForm
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 20)
            }
        }
        .frame(width: 560, height: 600)
        .task {
            load()
        }
    }

    private var settingsForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            PathListEditor(
                title: "Scan roots",
                detail: "Directories searched for projects. Leaving this empty falls back to the built-in defaults.",
                addPrompt: "Add scan root",
                paths: $roots
            )

            PathListEditor(
                title: "Ignored directories",
                detail: "Directories skipped even when they sit under a scan root.",
                addPrompt: "Ignore directory",
                paths: $ignoreProjects
            )

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Search depth")
                        .font(.headline)
                    Text("How many directory levels below each root are searched.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 16)

                Stepper(value: $maxDepth, in: 0...12) {
                    Text("\(maxDepth)")
                        .font(.body.monospacedDigit())
                        .frame(minWidth: 22, alignment: .trailing)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Model release providers")
                        .font(.headline)
                    Text("Skills unreviewed since a tracked provider's frontier release get a review advisory without changing their scores.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)],
                    alignment: .leading,
                    spacing: 6
                ) {
                    ForEach(MetagentCore.selectableModelProviders, id: \.key) { provider in
                        Toggle(provider.name, isOn: Binding(
                            get: { trackedProviders.contains(provider.key) },
                            set: { isTracked in
                                if isTracked {
                                    trackedProviders.insert(provider.key)
                                } else {
                                    trackedProviders.remove(provider.key)
                                }
                            }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Share anonymous usage data")
                        .font(.headline)
                    Text("Sends anonymous product analytics to PostHog to improve scanning, reliability, and skill publishing. Includes a persistent random install ID, app version, build, channel, action outcomes, and count ranges. Never sends skill names or content, file paths, account details, or screen recordings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 16)

                Toggle("Share anonymous usage data", isOn: $analyticsEnabled)
                    .labelsHidden()
            }

            Divider()

            HStack(spacing: 10) {
                Button("Open Configuration File", systemImage: "doc.text") {
                    model.openConfig()
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)

                Button("Open Logs", systemImage: "doc.plaintext") {
                    model.openLogs()
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)

                Spacer()
            }

            if model.isDevChannel {
                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Development")
                            .font(.headline)
                        Text("Writes three disposable `test-zz-*` skills to the global collection for exercising removal, archive, and history flows. Re-running restores any that were deleted.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Button("Add Test Skills", systemImage: "testtube.2") {
                        model.addTestSkills()
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .disabled(model.isRunning)
                }
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppVersion.display)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if !updater.isConfigured {
                        Text("This build has no update feed configured.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 16)

                Button("Check for Updates", systemImage: "arrow.down.circle") {
                    updater.checkForUpdates()
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .disabled(!updater.isConfigured || !updater.canCheckForUpdates)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 520)
        .task {
            load()
        }
    }

    private func load() {
        analyticsEnabled = ProductAnalytics.shared.isEnabled
        do {
            let config = try MetagentCore.loadUserConfig()
            roots = config.roots.uniqued()
            ignoreProjects = config.ignoreProjects.uniqued()
            maxDepth = config.maxDepth
            trackedProviders = Set(model.trackedModelProviders)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func save() {
        do {
            try MetagentCore.saveUserConfig(MetagentConfig(
                roots: roots,
                maxDepth: maxDepth,
                ignoreProjects: ignoreProjects
            ))
            model.setTrackedModelProviders(
                MetagentCore.selectableModelProviders.map(\.key).filter(trackedProviders.contains)
            )
            ProductAnalytics.shared.setEnabled(analyticsEnabled)
            model.refreshStatus()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

struct PathListEditor: View {
    let title: String
    let detail: String
    let addPrompt: String
    @Binding var paths: [String]
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            List(selection: $selection) {
                ForEach(paths, id: \.self) { path in
                    Text(displayUserPath(path))
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(path)
                }
            }
            .listStyle(.inset)
            .frame(height: 108)

            HStack(spacing: 8) {
                Button {
                    paths = (paths + chooseDirectories()).uniqued()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .accessibilityLabel(addPrompt)

                Button {
                    guard let selection else { return }
                    paths.removeAll { $0 == selection }
                    self.selection = nil
                } label: {
                    Label("Remove", systemImage: "minus")
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .disabled(selection == nil)

                Spacer()
            }
        }
    }

    private func chooseDirectories() -> [String] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Choose"
        panel.message = addPrompt
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.map { $0.standardizedFileURL.path }
    }
}
