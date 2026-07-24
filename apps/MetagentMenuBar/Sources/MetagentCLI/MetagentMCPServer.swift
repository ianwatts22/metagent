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
                    description: "Return a compact, project-only summary of agent instructions, skills, Doctor findings, project MCP configuration, observed skill usage, and up to five prioritized actions. Use get_project_analysis_details for bounded records.",
                    inputSchema: rootInputSchema
                ),
                Tool(
                    name: "get_project_analysis_details",
                    description: "Page through one project-analysis section. Results are project-only, capped at 100 records per call, and provide an opaque next_cursor when more records remain.",
                    inputSchema: projectAnalysisDetailInputSchema
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
                    text = try encodeJSON(MetagentCore.analyzeProjectSummary(root: root))
                case "get_project_analysis_details":
                    guard let sectionName = params.arguments?["section"]?.stringValue,
                          let section = ProjectAnalysisSection(rawValue: sectionName)
                    else {
                        throw NSError(
                            domain: "MetagentMCP",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "section is required"]
                        )
                    }
                    text = try encodeJSON(MetagentCore.analyzeProjectDetails(
                        root: root,
                        section: section,
                        cursor: params.arguments?["cursor"]?.stringValue,
                        limit: params.arguments?["limit"]?.intValue ?? 25
                    ))
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

    private static let projectAnalysisDetailInputSchema = Value.object([
        "type": .string("object"),
        "properties": .object([
            "root": .object([
                "type": .string("string"),
                "description": .string("Absolute or working-directory-relative project folder. Defaults to the MCP server working directory.")
            ]),
            "section": .object([
                "type": .string("string"),
                "enum": .array(ProjectAnalysisSection.allCases.map { .string($0.rawValue) }),
                "description": .string("Project-only detail section to retrieve.")
            ]),
            "cursor": .object([
                "type": .string("string"),
                "description": .string("Opaque next_cursor returned by the previous page for the same section.")
            ]),
            "limit": .object([
                "type": .string("integer"),
                "minimum": .int(1),
                "maximum": .int(100),
                "default": .int(25)
            ])
        ]),
        "required": .array([.string("section")]),
        "additionalProperties": .bool(false)
    ])

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try MetagentCore.encodeJSON(value), as: UTF8.self)
    }
}
