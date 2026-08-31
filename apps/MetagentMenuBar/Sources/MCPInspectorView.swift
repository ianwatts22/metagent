import MetagentCore
import SwiftUI

/// Opening this sheet is passive. Starting a server always requires a separate explicit approval.
struct MCPInspectorView: View {
    let entry: MCPInventoryEntry
    @Environment(\.dismiss) private var dismiss
    @State private var configuration: MCPInspectionConfiguration?
    @State private var snapshot: MCPInspectionSnapshot?
    @State private var session: MCPInspectionSession?
    @State private var message: String?
    @State private var confirming = false
    @State private var query = ""

    private var supported: Bool {
        entry.globalClients.contains(.codex) && entry.clientStates[.codex] == .configured
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                MCPServerIcon(size: 24)
                Text(verbatim: entry.name).font(.title2.bold())
                Spacer()
                Button("Done") { cancel(); dismiss() }.keyboardShortcut(.cancelAction)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Configured metadata").font(.headline)
                    Text("Clients: \(entry.clients.map(\.displayName).joined(separator: ", "))")
                    Text("Configuration is not proof that a server is connected. Opening this view does not contact or start a server.")
                        .font(.callout).foregroundStyle(.secondary)
                    if supported {
                        Text("Inspection source: Codex user configuration. Project overrides and other clients are not inspected.")
                            .font(.callout).foregroundStyle(.secondary)
                        if let configuration {
                            Text(verbatim: "Executable: \(configuration.executable)")
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Text("\(configuration.argumentCount) configured arguments. Argument and environment values are hidden.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button(snapshot == nil ? "Inspect server…" : "Inspect again…") { confirming = true }
                                .disabled(session != nil)
                        } else {
                            Button("Load Codex configuration") { loadConfiguration() }.disabled(session != nil)
                        }
                    } else {
                        Text("This version supports enabled, configured Codex user-scoped stdio servers only. Claude, remote HTTP, project-only, disabled, and authentication-required configurations cannot be inspected here yet.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if session != nil {
                        HStack { ProgressView().controlSize(.small); Text("Reading metadata…"); Button("Cancel", action: cancel) }
                    }
                    if let message { Text(verbatim: message).foregroundStyle(.secondary) }
                    if let snapshot {
                        Divider()
                        HStack {
                            Text("Observed server capabilities").font(.headline)
                            Spacer()
                            Text(snapshot.observedAt, style: .time).foregroundStyle(.secondary)
                        }
                        Text(verbatim: "\(snapshot.serverName.prefix(256)) · \(snapshot.serverVersion.prefix(128)) · MCP \(snapshot.protocolVersion)")
                            .textSelection(.enabled)
                        if snapshot.serverName.count > 256 || snapshot.serverVersion.count > 128 {
                            Text("Server name/version shortened for display.").font(.caption).foregroundStyle(.secondary)
                        }
                        Text("A one-time response from this server, not its live connection status in Codex. Server descriptions are untrusted text; no tools were called.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let description = snapshot.serverDescription, !description.isEmpty {
                            MCPInspectionText(title: "Server description", value: description)
                        } else {
                            Text("No server description was provided.").foregroundStyle(.secondary)
                        }
                        if let instructions = snapshot.instructions, !instructions.isEmpty {
                            MCPInspectionText(title: "Server instructions", value: instructions)
                        }
                        HStack {
                            Text("\(snapshot.tools.count) tools").font(.headline)
                            TextField("Filter tool names and descriptions", text: $query)
                        }
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(snapshot.tools.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || ($0.description?.localizedCaseInsensitiveContains(query) ?? false) }) { tool in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(verbatim: String(tool.name.prefix(256))).font(.headline).textSelection(.enabled)
                                    if tool.name.count > 256 { Text("Tool name shortened for display.").font(.caption).foregroundStyle(.secondary) }
                                    if let description = tool.description {
                                        Text(verbatim: String(description.prefix(16_384))).textSelection(.enabled)
                                        if description.count > 16_384 { Text("Description shortened for display.").font(.caption).foregroundStyle(.secondary) }
                                    }
                                    MCPInspectionText(title: "Input schema", value: tool.inputSchema)
                                    if let output = tool.outputSchema { MCPInspectionText(title: "Output schema", value: output) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .frame(width: 760, height: 660)
        .onDisappear(perform: cancel)
        .confirmationDialog("Start this configured MCP server?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Start and inspect") { inspect() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This runs the loaded executable with its configured arguments and environment. Server startup can execute code, download packages, access files, or use the network. Only continue if you trust your Codex configuration. Metagent requests descriptions and schemas only, never calls tools, and stops its process group after inspection. Configuration values are not saved or sent to analytics.")
        }
    }

    private func cancel() {
        session?.cancel()
        if session != nil { message = "Inspection cancelled." }
    }

    private func loadConfiguration() {
        let operation = MCPInspectionSession()
        let name = entry.name
        session = operation
        message = nil
        Task {
            let result = await Task.detached(priority: .utility) {
                Result { try operation.loadCodexConfiguration(name: name) }
            }.value
            guard session === operation else { return }
            session = nil
            switch result {
            case .success(let value): configuration = value
            case .failure(let error): message = (error as? MCPInspectionError)?.errorDescription ?? "Configuration could not be read."
            }
        }
    }

    private func inspect() {
        guard let configuration, session == nil else { return }
        let operation = MCPInspectionSession()
        session = operation
        snapshot = nil
        message = nil
        Task {
            let result = await Task.detached(priority: .utility) {
                Result { try operation.inspect(configuration) }
            }.value
            guard session === operation else { return }
            session = nil
            switch result {
            case .success(let value): snapshot = value
            case .failure(let error): message = (error as? MCPInspectionError)?.errorDescription ?? "Inspection failed. Raw server output is hidden."
            }
        }
    }
}

private struct MCPInspectionText: View {
    let title: String
    let value: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { expanded.toggle() } label: {
                Label(title, systemImage: expanded ? "chevron.down" : "chevron.right")
            }.buttonStyle(.plain)
            if expanded {
                Text(verbatim: String(value.prefix(65_536)))
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                if value.count > 65_536 { Text("Shortened for display (64K characters).").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}
