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
                // Opening the window is when staleness is actually seen, so it
                // is the one moment worth a quiet catch-up scan.
                .onAppear {
                    model.refreshIfStale()
                }
        }
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)

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
