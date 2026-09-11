import SwiftUI

/// An empty inventory is a result only after a scan, never before one.
enum InventoryCatalogState: Equatable {
    case cataloging, ready, failed

    mutating func beginScan() {
        if self != .ready { self = .cataloging }
    }

    mutating func completeScan(succeeded: Bool) {
        self = succeeded ? .ready : .failed
    }
}

struct CatalogingView: View {
    let state: InventoryCatalogState
    var retry: () -> Void = {}

    var body: some View {
        VStack(spacing: 18) {
            if state == .failed {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .accessibilityLabel("Cataloging in progress")
            }
            Text(state == .failed ? "Couldn’t catalog your setup" : "Cataloging your setup")
                .font(.title2.weight(.semibold))
            Text(state == .failed
                 ? "The first scan didn’t finish. Try again, or check Settings to review your scan roots."
                 : "Finding your skills, plugins, and projects. Your overview will appear as soon as the first scan finishes.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if state == .failed {
                Button("Try again", action: retry)
                    .buttonStyle(.glassProminent)
            } else {
                Label("First scan · larger setups can take a little longer", systemImage: "internaldrive")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(28)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("metagent.catalog.\(state == .failed ? "failed" : "loading")")
    }
}

struct CatalogingHistoryBanner: View {
    let detail: String
    var needsAttention = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: needsAttention ? "exclamationmark.triangle" : "clock.arrow.circlepath")
                .foregroundStyle(needsAttention ? Color.orange : Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(needsAttention ? "Usage history needs attention" : "Cataloging usage history")
                    .font(.callout.weight(.semibold))
                Text("\(detail) · You can browse now; usage metrics are provisional.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("metagent.catalog.history")
    }
}

/// Presentation-only fixtures: never touch the user's inventory or caches.
struct CatalogingPreview: View {
    @Environment(\.dismiss) private var dismiss
    @State private var scenario = "First scan"
    private let scenarios = ["First scan", "Usage history", "Scan failed", "Empty result"]

    var body: some View {
        VStack(spacing: 20) {
            Text("Cataloging preview")
                .font(.title2.weight(.semibold))
            Text("Dev-only fixture · your real catalog is unchanged")
                .foregroundStyle(.secondary)
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Picker("Startup state", selection: $scenario) {
                ForEach(scenarios, id: \.self) { Text($0) }
            }
            .pickerStyle(.segmented)
            Divider()
            switch scenario {
            case "Usage history":
                CatalogingHistoryBanner(detail: "24 of 80 session files indexed")
                ContentUnavailableView("Inventory is ready", systemImage: "checkmark.circle",
                                       description: Text("The app remains usable while history fills in."))
            case "Scan failed":
                CatalogingView(state: .failed) { scenario = "First scan" }
            case "Empty result":
                ContentUnavailableView("No skills found", systemImage: "folder",
                                       description: Text("The scan finished. Check your scan roots in Settings."))
            default:
                CatalogingView(state: .cataloging)
            }
        }
        .padding(24)
        .frame(minWidth: 640, minHeight: 460)
    }
}
