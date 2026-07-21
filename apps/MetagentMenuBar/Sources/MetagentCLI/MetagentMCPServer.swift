import Foundation
import MCP
import MetagentCore

enum MetagentMCPServer {
    static func run() async throws {
        let server = Server(
            name: "metagent",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: [
                Tool(
                    name: "analyze_project",
                    description: "Analyze a project folder's agent instructions, skills, plugin skills, Doctor findings, passive MCP configuration, and observed skill usage.",
                    inputSchema: rootInputSchema
                ),
                Tool(
                    name: "list_skills",
                    description: "List skills discovered directly in a project folder.",
                    inputSchema: rootInputSchema
                ),
                Tool(
                    name: "doctor_project",
                    description: "Run Metagent's read-only skill and projection Doctor for a project folder.",
                    inputSchema: rootInputSchema
                )
            ])
        }

        await server.withMethodHandler(CallTool.self) { params in
            let root = params.arguments?["root"]?.stringValue
                ?? FileManager.default.currentDirectoryPath
            do {
                let text: String
                switch params.name {
                case "analyze_project":
                    text = try encodeJSON(MetagentCore.analyzeProject(root: root))
                case "list_skills":
                    text = try encodeJSON(MetagentCore.scanSkills(options: .init(
                        roots: [root],
                        maxDepth: 0,
                        respectConfiguredIgnores: false
                    )))
                case "doctor_project":
                    text = try encodeJSON(MetagentCore.doctor(options: .init(
                        roots: [root],
                        maxDepth: 0,
                        respectConfiguredIgnores: false
                    )))
                default:
                    return .init(
                        content: [.text(
                            text: "Unknown tool: \(params.name)",
                            annotations: nil,
                            _meta: nil
                        )],
                        isError: true
                    )
                }
                return .init(
                    content: [.text(text: text, annotations: nil, _meta: nil)],
                    isError: false
                )
            } catch {
                return .init(
                    content: [.text(
                        text: error.localizedDescription,
                        annotations: nil,
                        _meta: nil
                    )],
                    isError: true
                )
            }
        }

        let transport = StdioTransport()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }

    private static let rootInputSchema = Value.object([
        "type": .string("object"),
        "properties": .object([
            "root": .object([
                "type": .string("string"),
                "description": .string("Absolute or working-directory-relative project folder. Defaults to the MCP server working directory.")
            ])
        ]),
        "additionalProperties": .bool(false)
    ])

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try MetagentCore.encodeJSON(value), as: UTF8.self)
    }
}
