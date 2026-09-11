import AppKit
import Foundation
import MetagentCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct MetagentMenuBarApp: App {
    @StateObject private var model = MetagentModel()
    @StateObject private var updater = UpdaterModel()
    @State private var selectedSection = PanelSection.overview
    @State private var selectedProjectRoot: String?
    @State private var showsCatalogingPreview = false

    init() {
        ProductAnalytics.shared.capture(.appLaunched)
    }

    var body: some Scene {
        WindowGroup("Metagent", id: "main") {
            MetagentPanel(
                model: model,
                showsOpenWindowButton: false,
                selectedSection: $selectedSection,
                selectedProjectRoot: $selectedProjectRoot
            )
                .frame(minWidth: 1040, idealWidth: 1180, minHeight: 680, idealHeight: 760)
                .environmentObject(updater)
                .sheet(isPresented: $showsCatalogingPreview) {
                    CatalogingPreview()
                }
                // Opening the window is when staleness is actually seen, so it
                // is the one moment worth a quiet catch-up scan.
                .onAppear {
                    model.refreshIfStale()
                }
        }
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CatalogingPreviewCommands(isPresented: $showsCatalogingPreview)
        }

        Settings {
            SettingsView(model: model)
                .environmentObject(updater)
        }

        MenuBarExtra {
            MetagentPanel(
                model: model,
                showsOpenWindowButton: true,
                selectedSection: $selectedSection,
                selectedProjectRoot: $selectedProjectRoot
            )
                .frame(width: 560, height: 640)
                .environmentObject(updater)
                .onAppear {
                    model.refreshIfStale()
                }
        } label: {
            MenuBarIcon()
                .frame(width: 18, height: 18 / AppBrand.markAspectRatio)
                .accessibilityLabel("Metagent")
        }
        .menuBarExtraStyle(.window)
    }
}

struct CatalogingPreviewCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @Binding var isPresented: Bool

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true {
                Button("Preview cataloging…") {
                    openWindow(id: "main")
                    isPresented = true
                }
            }
        }
    }
}

struct MenuBarIcon: View {
    var body: some View {
        if let image = AppBrand.menuBarIcon {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "wrench.and.screwdriver")
        }
    }
}
