import CryptoKit
import Foundation
import MetagentCore
import SwiftUI

struct AttentionItem: Identifiable {
    enum Action {
        case doctor(DoctorIssue)
        case duplicate(String)
        case mcp(MCPServerHealth)
    }

    let id: String
    let fingerprint: String
    let title: String
    let detail: String
    let action: Action

    static func fingerprint(_ fields: [String]) -> String {
        let data = (try? JSONEncoder().encode(fields)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func consolidatingDuplicates(_ items: [AttentionItem]) -> [AttentionItem] {
        let duplicates = items.filter { if case .duplicate = $0.action { return true }; return false }
        guard !duplicates.isEmpty else { return items }
        let summary = AttentionItem(
            id: "duplicates:summary",
            fingerprint: fingerprint(duplicates.sorted { $0.id < $1.id }.flatMap { [$0.id, $0.fingerprint] }),
            title: "\(duplicates.count) potential duplicate skills",
            detail: "Review which copies to keep",
            action: .duplicate("")
        )
        var inserted = false
        return items.compactMap { item in
            guard case .duplicate = item.action else { return item }
            guard !inserted else { return nil }
            inserted = true
            return summary
        }
    }
}

/// One locally persisted dismissal registry shared by the window and menu bar.
/// Dismissals describe a condition, not a category: a changed condition resurfaces.
@MainActor
final class AttentionCenterStore: ObservableObject {
    typealias OverlapBuilder = @Sendable ([SkillInventoryItem]) async -> [SkillOverlapGroup]
    static let shared = AttentionCenterStore()
    static let storageKey = "metagent.attention.ignored.v1"
    @Published private(set) var ignored: [String: String]
    @Published private(set) var overlaps: [SkillOverlapGroup] = []
    private let defaults: UserDefaults
    private let buildOverlaps: OverlapBuilder
    private var inventorySignature: String?
    private var generation = 0

    init(defaults: UserDefaults = .standard,
         buildOverlaps: @escaping OverlapBuilder = { MetagentCore.detectSkillOverlaps($0) }) {
        self.defaults = defaults
        self.buildOverlaps = buildOverlaps
        ignored = defaults.dictionary(forKey: Self.storageKey) as? [String: String] ?? [:]
    }

    func isIgnored(_ item: AttentionItem) -> Bool { ignored[item.id] == item.fingerprint }

    func ignore(_ item: AttentionItem) {
        ignored[item.id] = item.fingerprint
        defaults.set(ignored, forKey: Self.storageKey)
    }

    func restore(_ item: AttentionItem) {
        ignored.removeValue(forKey: item.id)
        defaults.set(ignored, forKey: Self.storageKey)
    }

    func restoreAll() {
        ignored = [:]
        defaults.removeObject(forKey: Self.storageKey)
    }

    /// No filesystem work in a view body. The caller supplies an inventory-only
    /// revision: usage-index progress must not rebuild bundle fingerprints.
    func refreshOverlaps(projects: [SkillProject], revision: Int) async {
        let data = (try? JSONEncoder().encode(projects)) ?? Data()
        let signature = "\(revision):\(SHA256.hash(data: data).description)"
        guard signature != inventorySignature else { return }
        inventorySignature = signature
        overlaps = []
        generation += 1
        let request = generation
        let skills = projects.flatMap(\.skills)
        let buildOverlaps = buildOverlaps
        let result = await Task.detached(priority: .utility) {
            await buildOverlaps(skills)
        }.value
        guard generation == request else { return }
        overlaps = result
    }

    func items(doctor: [DoctorIssue], mcp: MCPHealthSnapshot, projects: [SkillProject], scope: String?) -> [AttentionItem] {
        let scope = scope.map(standardizedDirectoryPath)
        var result = doctor.filter {
            $0.severity != .ok && (scope == nil || $0.projectRoot.map(standardizedDirectoryPath) == scope)
        }.map { issue in
            AttentionItem(
                id: "doctor:\(issue.projectRoot ?? "global"):\(issue.id)",
                fingerprint: AttentionItem.fingerprint([issue.message, issue.guidance ?? "", issue.severity.rawValue, issue.repairAction?.rawValue ?? ""]),
                title: issue.summary ?? issue.message,
                detail: [issue.projectRoot.map(displayUserPath), issue.guidance].compactMap { $0 }.joined(separator: " · "),
                action: .doctor(issue)
            )
        }
        let paths = Set(projects.filter { scope == nil || standardizedDirectoryPath($0.root) == scope }.flatMap(\.skills).map {
            $0.canonicalPath.isEmpty ? $0.path : $0.canonicalPath
        })
        for group in overlaps where scope == nil || group.members.contains(where: { paths.contains($0.canonicalPath) }) {
            result.append(AttentionItem(
                id: "duplicate:\(group.id)",
                fingerprint: AttentionItem.fingerprint(
                    [group.kind.rawValue, String(group.similarity)]
                        + group.members.sorted { $0.canonicalPath < $1.canonicalPath }.flatMap {
                            [$0.canonicalPath, $0.contentFingerprint ?? "unknown", $0.manager]
                        }
                ),
                title: "\(group.skillName): potential duplicate skills",
                detail: "\(group.members.count) copies · Review which copies to keep",
                action: .duplicate(group.id)
            ))
        }
        for server in projectFilteredMCPHealth(mcp, selectedProjectRoot: scope).attention {
            result.append(AttentionItem(
                id: "mcp:\(server.id)",
                fingerprint: AttentionItem.fingerprint([server.state.rawValue, server.detail, server.globalState?.rawValue ?? ""] + server.projectStates.map { "\($0.path):\($0.state.rawValue)" }.sorted()),
                title: "\(server.name) MCP (\(server.client.displayName)) \(server.state == .needsSignIn ? "needs auth" : server.state == .pendingApproval ? "needs approval" : "is unavailable")",
                detail: server.detail,
                action: .mcp(server)
            ))
        }
        // Preserve existing individual dismissals while presenting one category row.
        return AttentionItem.consolidatingDuplicates(result.filter { !isIgnored($0) || !($0.id.hasPrefix("duplicate:")) })
    }
}

/// Both surfaces render this exact list, including scope and dismissal state.
struct AttentionCenterList: View {
    @ObservedObject var model: MetagentModel
    @ObservedObject var store: AttentionCenterStore
    let items: [AttentionItem]
    let openDuplicateReview: () -> Void
    @State private var showsIgnored = false
    @State private var repairRoot: String?
    @State private var showsRepair = false
    @State private var detailIssue: DoctorIssue?
    @State private var listHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    let active = items.filter { !store.isIgnored($0) }
                    if active.isEmpty {
                        Text("You're all caught up")
                            .foregroundStyle(.secondary)
                            .padding(16)
                    }
                    ForEach(active) { item in
                        Divider()
                        itemRow(item)
                    }
                    if !store.ignored.isEmpty {
                        Divider()
                        DisclosureGroup("Ignored", isExpanded: $showsIgnored) {
                            ForEach(items.filter(store.isIgnored)) { item in
                                HStack {
                                    Text(item.title).font(.callout)
                                    Spacer()
                                    Button("Restore") { store.restore(item) }
                                        .buttonStyle(.glass).buttonBorderShape(.capsule)
                                }.padding(.vertical, 6)
                            }
                            Button("Restore all ignored items") { store.restoreAll() }
                                .padding(.top, 6)
                                .help("Also clears dismissals for conditions that are not currently present")
                        }
                        .padding(16)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            .frame(height: min(listHeight, 320))
        }
        .sheet(isPresented: $showsRepair) {
            RepairSection(model: model, projectRoot: repairRoot)
        }
        .sheet(item: $detailIssue) { issue in
            DoctorFindingsView(model: model, findings: [issue]) { root in
                detailIssue = nil
                repairRoot = root
                model.previewRepair(projectRoot: root)
                showsRepair = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .metagentDismissPresentations)) { _ in
            showsRepair = false
            detailIssue = nil
        }
    }

    private func itemRow(_ item: AttentionItem) -> some View {
        HStack(spacing: 12) {
            if case .mcp = item.action {
                MCPServerIcon(size: 18, weight: .medium).foregroundStyle(.orange)
            } else {
                Image(systemName: itemSymbol(item)).foregroundStyle(.orange)
            }
            Text(item.title).font(.callout.weight(.medium))
            if case let .mcp(server) = item.action, let error = model.mcpAttentionErrors[server.id] {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .help(error)
                    .accessibilityLabel("Action failed: \(error)")
            }
            Spacer(minLength: 8)
            Button(actionTitle(item)) { perform(item) }
                .buttonStyle(.glass).buttonBorderShape(.capsule)
                .disabled(isDisabled(item))
            Button { store.ignore(item) } label: {
                Image(systemName: "xmark").frame(width: 24, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(isChecking(item))
            .help("Ignore this condition. Restore it from Ignored.")
            .accessibilityLabel("Ignore \(item.title)")
        }.padding(14)
    }

    private func itemSymbol(_ item: AttentionItem) -> String {
        if case .duplicate = item.action { return "square.on.square" }
        return "wrench.and.screwdriver"
    }

    private func isChecking(_ item: AttentionItem) -> Bool {
        guard case let .mcp(server) = item.action else { return false }
        return model.pendingMCPAttentionIDs.contains(server.id)
    }

    private func actionTitle(_ item: AttentionItem) -> String {
        switch item.action {
        case let .doctor(issue): return issue.repairAction == nil ? "Details" : "Preview fix"
        case .duplicate: return "Review"
        case let .mcp(server):
            if isChecking(item) { return "Checking" }
            if model.authenticatingMCPServerID == server.id { return "Authenticating" }
            if server.supportsAuthentication { return "Authenticate" }
            if server.state == .pendingApproval { return "Open approval" }
            return "Open \(server.client.displayName)"
        }
    }

    private func isDisabled(_ item: AttentionItem) -> Bool {
        if isChecking(item) { return true }
        if case let .mcp(server) = item.action {
            return mcpAuthenticationActionIsDisabled(for: server, authenticationInProgress: model.authenticatingMCPServerID != nil)
        }
        return model.isRunning
    }

    private func perform(_ item: AttentionItem) {
        switch item.action {
        case let .duplicate(groupID):
            UserDefaults.standard.set(groupID, forKey: "metagent.skills.requested-duplicate-group.v1")
            openDuplicateReview()
        case let .mcp(server): model.openMCPServer(server)
        case let .doctor(issue):
            guard issue.repairAction != nil else { detailIssue = issue; return }
            repairRoot = issue.projectRoot
            model.previewRepair(projectRoot: issue.projectRoot)
            showsRepair = true
        }
    }
}
