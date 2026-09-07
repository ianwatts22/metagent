import MetagentCore

func mcpAttentionSnapshot(
    _ snapshot: MCPHealthSnapshot,
    retainedServers: [String: MCPServerHealth]
) -> MCPHealthSnapshot {
    let observedIDs = Set(snapshot.servers.map(\.id))
    let missing = retainedServers.values.filter { !observedIDs.contains($0.id) }
        .sorted { $0.id < $1.id }
    return MCPHealthSnapshot(servers: snapshot.servers + missing, observedAt: snapshot.observedAt)
}

/// The command succeeding is not the same as fresh connection evidence.
/// Generations reject pre-action scans; three fresh observations bound the
/// eventual-consistency grace period without continuous background polling.
struct MCPAttentionVerification {
    private(set) var generation = 0
    private var attempts: [String: Int] = [:]
    var pendingIDs: Set<String> { Set(attempts.keys) }

    mutating func invalidate() { generation += 1 }

    mutating func begin(serverID: String) {
        invalidate()
        attempts[serverID] = 0
    }

    mutating func consume(_ snapshot: MCPHealthSnapshot, generation observedGeneration: Int) -> Set<String> {
        guard observedGeneration == generation else { return [] }
        var failed = Set<String>()
        for id in Array(attempts.keys) {
            if let server = snapshot.servers.first(where: { $0.id == id }), !server.state.needsAttention {
                attempts[id] = nil
                continue
            }
            let count = (attempts[id] ?? 0) + 1
            if count >= 3 {
                attempts[id] = nil
                failed.insert(id)
            } else {
                attempts[id] = count
            }
        }
        return failed
    }
}
