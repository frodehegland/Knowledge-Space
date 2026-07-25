//
//  MapAgentSession.swift
//  MapAgent
//
//  The agent loop: sends the user's instruction to Claude with the map tool
//  catalog, executes tool calls against MapEngine, feeds results back, and
//  repeats until Claude finishes. Multi-turn: the session keeps conversation
//  history so follow-up instructions have context.
//
//  Transport is pluggable — the default talks to the Anthropic Messages API
//  directly (matching AIManager's approach in the apps); tests and future
//  key-proxy setups inject their own.
//

import Foundation


// MARK: - Transport

public protocol MapAgentTransport {
    /// Sends a Messages API request body and returns the raw response JSON.
    func send(requestBody: [String: Any]) async throws -> [String: Any]
}

/// Direct Anthropic Messages API transport. The API key is fetched per
/// request so the app can plug in its embedded-key system.
public struct AnthropicTransport: MapAgentTransport {

    public init(apiKeyProvider: @escaping () async throws -> String) {
        self.apiKeyProvider = apiKeyProvider
    }

    let apiKeyProvider: () async throws -> String

    public func send(requestBody: [String: Any]) async throws -> [String: Any] {
        let apiKey = try await apiKeyProvider()

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 300
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw MapAgentError.transport("No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw MapAgentError.api(statusCode: http.statusCode, body: body)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MapAgentError.transport("Response was not a JSON object")
        }
        return json
    }
}

// MARK: - Events & errors

/// Progress events for the UI while the agent works.
public enum MapAgentEvent {
    /// Claude produced user-facing text.
    case assistantText(String)
    /// Claude is invoking a map tool.
    case toolCall(name: String, summary: String)
    /// A tool finished; `result` is the message sent back to Claude.
    case toolResult(name: String, result: String, isError: Bool)
}

public enum MapAgentError: Error, CustomStringConvertible {
    case transport(String)
    case api(statusCode: Int, body: String)
    case refused(explanation: String?)
    case tooManyIterations

    public var description: String {
        switch self {
        case .transport(let reason):
            return "Transport error: \(reason)"
        case .api(let statusCode, let body):
            return "API error \(statusCode): \(body)"
        case .refused(let explanation):
            return "The model declined this request\(explanation.map { ": \($0)" } ?? "")"
        case .tooManyIterations:
            return "The agent stopped after reaching the iteration limit"
        }
    }
}

// MARK: - Session

public final class MapAgentSession {

    public init(engine: MapEngine,
                transport: MapAgentTransport,
                model: String = "claude-opus-4-8",
                maxIterationsPerTurn: Int = 25) {
        self.engine = engine
        self.transport = transport
        self.model = model
        self.maxIterationsPerTurn = maxIterationsPerTurn
    }

    public let engine: MapEngine

    private let transport: MapAgentTransport
    private let model: String
    private let maxIterationsPerTurn: Int
    private let catalog = MapToolCatalog()

    /// Conversation history in Messages API wire format, preserved across
    /// turns (including thinking blocks, echoed back unchanged as required).
    private var messages: [[String: Any]] = []

    public func clearHistory() {
        messages = []
    }

    private var systemPrompt: String {
        """
        You are the Map assistant inside Knowledge Space. You operate on the user's concept map — a spatial arrangement of nodes (concepts, citations, notes, sections, links) with connections between them. The map is planar in x/y and extends into z (depth); nodes never rotate.

        You act through tools. Anything a human can do on the map, you can do: select (by ids or by criteria such as tag, type, liked, context, name), show/hide and filter, move, align and distribute along any axis, create, rename, connect, delete, tag, and save or apply layouts. Coordinates: +x is right, +y is down, +z is toward the viewer.

        Start by calling get_map to see the current state. Prefer criteria-based selection over listing ids when the user describes a group ("all the people", "everything about climate"). After layout changes, briefly say what you did. Deleting nodes cannot be undone — only delete what the user explicitly asked to remove. Keep replies short; the user is looking at the map and can see the result.
        """
    }

    /// Runs one user instruction to completion. Returns Claude's final text.
    @discardableResult
    public func run(instruction: String, onEvent: (@MainActor (MapAgentEvent) -> Void)? = nil) async throws -> String {
        messages.append(["role": "user", "content": instruction])

        var finalText = ""

        for _ in 0..<maxIterationsPerTurn {
            let body: [String: Any] = [
                "model": model,
                "max_tokens": 16000,
                "thinking": ["type": "adaptive"],
                "system": systemPrompt,
                "tools": catalog.toolDefinitions,
                "messages": messages
            ]

            let response = try await transport.send(requestBody: body)
            let stopReason = response["stop_reason"] as? String
            let content = response["content"] as? [[String: Any]] ?? []

            if stopReason == "refusal" {
                let details = response["stop_details"] as? [String: Any]
                throw MapAgentError.refused(explanation: details?["explanation"] as? String)
            }

            // Echo the assistant content back verbatim on the next request —
            // this preserves thinking blocks and their signatures.
            messages.append(["role": "assistant", "content": content])

            var toolResults: [[String: Any]] = []

            for block in content {
                switch block["type"] as? String {
                case "text":
                    let text = block["text"] as? String ?? ""
                    finalText = text
                    if !text.isEmpty {
                        await notify(onEvent, .assistantText(text))
                    }

                case "tool_use":
                    guard let id = block["id"] as? String,
                          let name = block["name"] as? String else { continue }
                    let input = block["input"] as? [String: Any] ?? [:]

                    await notify(onEvent, .toolCall(name: name, summary: Self.summarize(name: name, input: input)))

                    var resultText: String
                    var isError = false
                    do {
                        resultText = try await executeOnMain(name: name, input: input)
                    } catch {
                        resultText = "Error: \(error)"
                        isError = true
                    }

                    await notify(onEvent, .toolResult(name: name, result: resultText, isError: isError))

                    var result: [String: Any] = [
                        "type": "tool_result",
                        "tool_use_id": id,
                        "content": resultText
                    ]
                    if isError {
                        result["is_error"] = true
                    }
                    toolResults.append(result)

                default:
                    break // thinking blocks etc. — already echoed via content
                }
            }

            if stopReason == "tool_use", !toolResults.isEmpty {
                messages.append(["role": "user", "content": toolResults])
                continue
            }

            if stopReason == "pause_turn" {
                continue
            }

            return finalText
        }

        throw MapAgentError.tooManyIterations
    }

    /// Map mutations must happen on the main actor — the renderer observes
    /// engine changes from there.
    private func executeOnMain(name: String, input: [String: Any]) async throws -> String {
        let engine = self.engine
        let catalog = self.catalog
        return try await MainActor.run {
            try catalog.execute(toolName: name, input: input, on: engine)
        }
    }

    private func notify(_ handler: (@MainActor (MapAgentEvent) -> Void)?, _ event: MapAgentEvent) async {
        guard let handler else { return }
        await MainActor.run {
            handler(event)
        }
    }

    /// One-line description of a tool call for progress UI.
    static func summarize(name: String, input: [String: Any]) -> String {
        switch name {
        case "get_map":
            return "Reading the map"
        case "select_nodes":
            return "Selecting nodes (\(input["mode"] as? String ?? "?"))"
        case "move_nodes":
            return "Moving nodes"
        case "align_nodes":
            return "Aligning (\(input["alignment"] as? String ?? "?") on \(input["axis"] as? String ?? "?"))"
        case "distribute_nodes":
            return "Distributing along \(input["axis"] as? String ?? "?")"
        case "create_node":
            return "Creating '\(input["title"] as? String ?? "?")'"
        case "delete_nodes":
            return "Deleting \((input["ids"] as? [Any])?.count ?? 0) nodes"
        case "rename_node":
            return "Renaming to '\(input["title"] as? String ?? "?")'"
        case "connect_nodes":
            return (input["action"] as? String == "disconnect") ? "Removing connections" : "Connecting nodes"
        case "set_visibility":
            return "Changing what is shown"
        case "set_hidden":
            return (input["hidden"] as? Bool == true) ? "Hiding nodes" : "Unhiding nodes"
        case "set_node_metadata":
            return "Updating node metadata"
        case "layouts":
            return "\((input["action"] as? String ?? "?").capitalized) layout '\(input["name"] as? String ?? "?")'"
        case "undo_redo":
            return (input["action"] as? String ?? "?").capitalized
        default:
            return name
        }
    }
}
