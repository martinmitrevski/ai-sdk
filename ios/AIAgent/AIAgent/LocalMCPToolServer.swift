import Foundation
import MCP

actor LocalMCPToolServer {
    enum Event {
        case greet(message: String)
    }

    private let server: Server
    private let client: Client
    private var isReady = false
    private var pendingInvocations: [(name: String, args: [String: Value]?)] = []
    private let notifier: @Sendable (Event) async -> Void

    init(notifier: @escaping @Sendable (Event) async -> Void) {
        self.notifier = notifier
        self.server = Server(
            name: "client-local-tools",
            version: "0.1.0",
            capabilities: Server.Capabilities(tools: Server.Capabilities.Tools()),
            configuration: .default
        )
        self.client = Client(
            name: "client-local-tools",
            version: "0.1.0",
            configuration: Client.Configuration(strict: false)
        )

        Task {
            await initialize()
        }
    }

    private func initialize() async {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        await server.withMethodHandler(ListTools.self) { _ in
            let tool = Tool(
                name: "client_greet",
                description: "Show a greeting alert on the device.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "message": .object([
                            "type": .string("string"),
                            "description": .string("Optional greeting message to display.")
                        ])
                    ]),
                    "required": .array([]),
                    "additionalProperties": .bool(false)
                ]),
                annotations: .init(title: "Greet User", readOnlyHint: true, idempotentHint: true)
            )
            return .init(tools: [tool])
        }

        await server.withMethodHandler(CallTool.self) { [notifier] params in
            guard params.name == "client_greet" else {
                return .init(
                    content: [.text("Unknown client tool '\(params.name)'")],
                    isError: true
                )
            }

            let provided = params.arguments?["message"]?.stringValue?.trimmingCharacters(
                in: .whitespacesAndNewlines)
            let message = (provided?.isEmpty == false ? provided! : "hi")

            await notifier(.greet(message: message))

            return .init(
                content: [.text("Client greeted the user with \"\(message)\".")],
                isError: false
            )
        }

        do {
            try await server.start(transport: serverTransport)
            _ = try await client.connect(transport: clientTransport)
            isReady = true

            if !pendingInvocations.isEmpty {
                for invocation in pendingInvocations {
                    let result = try await client.callTool(name: invocation.name, arguments: invocation.args)
                    print("\(result)")
                }
                pendingInvocations.removeAll()
            }
        } catch {
            pendingInvocations.removeAll()
            print("Local MCP server failed to initialize: \(error.localizedDescription)")
        }
    }

    func callTool(name: String, arguments: [String: Value]? = nil) async {
        if !isReady {
            pendingInvocations.append((name, arguments))
            return
        }

        do {
            _ = try await client.callTool(name: name, arguments: arguments)
        } catch {
            print("Local MCP tool call '\(name)' failed: \(error.localizedDescription)")
        }
    }
}
