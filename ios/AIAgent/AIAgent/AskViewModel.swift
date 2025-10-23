//
//  AskViewModel.swift
//  AIAgent
//
//  Created by Martin Mitrevski on 22.10.25.
//

import SwiftUI
import Foundation
import MCP
import CoreFoundation
import Combine

struct ConversationSummary: Identifiable, Decodable, Equatable {
    let conversationId: String
    let lastMessage: String?
    let messageCount: Int
    let updatedAt: TimeInterval

    var id: String { conversationId }
}

enum ModelOption: String, CaseIterable, Identifiable {
    case openAIMini = "openai:gpt-4o-mini"
    case anthropicSonnet = "anthropic:claude-3-5-sonnet-20240620"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAIMini:
            return "GPT-4o mini"
        case .anthropicSonnet:
            return "Claude 3.5 Sonnet"
        }
    }

    var provider: String {
        rawValue.split(separator: ":").first.map(String.init) ?? "openai"
    }

    var modelId: String {
        rawValue.split(separator: ":").dropFirst().joined(separator: ":")
    }
}

final class AskViewModel: ObservableObject {
    @Published var question: String = ""
    @Published private(set) var messages: [ChatMessage] = []
    @Published var isStreaming: Bool = false
    @Published var errorMessage: String?
    @Published var currentState: String?
    @Published private(set) var conversations: [ConversationSummary] = []
    @Published var showGreetingAlert: Bool = false
    @Published var greetingMessage: String = "hi"
    @Published var conversationId: String?
    @Published var selectedModel: ModelOption = .openAIMini

    private var streamTask: Task<Void, Never>?
    private let baseURL: URL
    private var clientToolServer: LocalMCPToolServer!
    private var pendingAssistantMessageID: UUID?
    private var streamingAssistantBuffer: String = ""
    private let decoder = JSONDecoder()

    init(baseURL: URL = URL(string: "http://localhost:3000")!) {
        self.baseURL = baseURL
        self.clientToolServer = LocalMCPToolServer { [weak self] event in
            await self?.handleLocalMCPEvent(event)
        }

        Task {
            await fetchConversations(quiet: true)
        }
    }

    deinit {
        streamTask?.cancel()
    }

    func loadConversation(id: String) {
        streamTask?.cancel()
        streamTask = nil
        currentState = nil
        question = ""
        conversationId = id

        Task {
            await refreshConversationDetail(for: id, quietly: false)
        }
    }

    func refreshConversations() {
        Task {
            await fetchConversations(quiet: true)
        }
    }

    func startNewConversation() {
        streamTask?.cancel()
        streamTask = nil

        Task {
            do {
                guard let url = URL(string: "/conversations", relativeTo: baseURL) else {
                    throw AskError.invalidURL
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200..<300).contains(httpResponse.statusCode) else {
                    throw AskError.invalidResponse
                }

                let payload = try decoder.decode(NewConversationResponse.self, from: data)

                await MainActor.run {
                    self.conversationId = payload.conversationId
                    self.messages = []
                    self.streamingAssistantBuffer = ""
                    self.pendingAssistantMessageID = nil
                    self.currentState = nil
                    self.errorMessage = nil
                    self.isStreaming = false
                    self.question = ""
                }

                await fetchConversations(quiet: false)
                await refreshConversationDetail(for: payload.conversationId, quietly: true)
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func selectConversation(_ summary: ConversationSummary) {
        guard summary.conversationId != conversationId else { return }
        streamTask?.cancel()
        streamTask = nil
        pendingAssistantMessageID = nil
        streamingAssistantBuffer = ""
        isStreaming = false
        currentState = nil
        errorMessage = nil
        question = ""
        loadConversation(id: summary.conversationId)
    }

    func sendQuestion() {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty else {
            errorMessage = "Type a question before asking."
            return
        }

        streamTask?.cancel()
        streamTask = nil
        errorMessage = nil
        streamingAssistantBuffer = ""
        pendingAssistantMessageID = nil
        isStreaming = true
        question = ""
        currentState = nil

        let currentConversationId = conversationId

        streamTask = Task {
            defer {
                Task { @MainActor in
                    self.isStreaming = false
                }
            }

            do {
                try await streamQuestion(trimmedQuestion, conversationId: currentConversationId)
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func streamQuestion(_ question: String, conversationId: String?) async throws {
        guard let askURL = URL(string: "/ask", relativeTo: baseURL) else {
            throw AskError.invalidURL
        }

        var request = URLRequest(url: askURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 120

        var body: [String: Any] = [
            "question": question,
            "model": [
                "provider": selectedModel.provider,
                "id": selectedModel.modelId
            ]
        ]
        if let conversationId = conversationId {
            body["conversationId"] = conversationId
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (byteStream, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AskError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let errorBody = await bodyString(from: byteStream)
            throw AskError.server(status: httpResponse.statusCode, message: errorBody)
        }

        streamingAssistantBuffer = ""

        for try await line in byteStream.lines {
            try Task.checkCancellation()

            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)

            guard !payload.isEmpty, payload != "[DONE]" else { continue }

            if let data = payload.data(using: .utf8),
               let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               await handleStreamEvent(jsonObject) {
                continue
            }
        }

        await finalizeAssistantMessage(with: streamingAssistantBuffer.isEmpty ? nil : streamingAssistantBuffer)
        await fetchConversations(quiet: true)
        if let id = conversationId {
            await refreshConversationDetail(for: id, quietly: true)
        }
    }

    private func handleStreamEvent(_ event: [String: Any]) async -> Bool {
        if let error = event["error"] as? String {
            await MainActor.run {
                self.errorMessage = error
            }
            return true
        }

        if let delta = event["delta"] as? String {
            await appendAssistantDelta(delta)
            return true
        }

        if let text = event["text"] as? String {
            await appendAssistantDelta(text)
            return true
        }

        if let answer = event["answer"] as? String {
            await MainActor.run {
                self.streamingAssistantBuffer = answer
                if let id = self.pendingAssistantMessageID,
                   let index = self.messages.firstIndex(where: { $0.id == id }) {
                    self.messages[index].content = answer
                }
            }
            return true
        }

        guard let type = event["type"] as? String else {
            return false
        }

        switch type {
        case "conversation":
            if let conversationId = event["conversationId"] as? String {
                await MainActor.run {
                    self.conversationId = conversationId
                    self.currentState = nil
                }
                Task {
                    await self.fetchConversations(quiet: true)
                    await self.refreshConversationDetail(for: conversationId, quietly: true)
                }
            }
            return true

        case "message":
            guard let roleString = event["role"] as? String,
                  let role = ChatRole(rawValue: roleString),
                  let content = event["content"] as? String else {
                return true
            }

            if role == .assistant {
                await finalizeAssistantMessage(with: content)
            } else {
                await appendMessage(role: role, content: content, isStreaming: false)
            }
            return true

        case "tool-call":
            await handleToolCallEvent(event)
            return true

        case "client-tool-request":
            await handleClientToolRequest(event)
            return true

        case "tool-result":
            await handleToolResultEvent(event)
            return true

        case "tool-error":
            await handleToolErrorEvent(event)
            return true

        case "state":
            await handleStateEvent(event)
            return true

        default:
            return false
        }
    }

    private func appendAssistantDelta(_ delta: String) async {
        guard !delta.isEmpty else { return }

        await MainActor.run {
            self.streamingAssistantBuffer.append(delta)

            if let id = self.pendingAssistantMessageID,
               let index = self.messages.firstIndex(where: { $0.id == id }) {
                self.messages[index].content.append(delta)
            } else {
                let message = ChatMessage(
                    id: UUID(),
                    role: .assistant,
                    content: delta,
                    isStreaming: true
                )
                self.pendingAssistantMessageID = message.id
                self.messages.append(message)
            }
        }
    }

    private func finalizeAssistantMessage(with content: String?) async {
        await MainActor.run {
            let finalText = content ?? self.streamingAssistantBuffer

            guard !finalText.isEmpty || self.pendingAssistantMessageID != nil else {
                self.streamingAssistantBuffer = ""
                return
            }

            if let id = self.pendingAssistantMessageID,
               let index = self.messages.firstIndex(where: { $0.id == id }) {
                self.messages[index].content = finalText
                self.messages[index].isStreaming = false
            } else if !finalText.isEmpty {
                self.messages.append(
                    ChatMessage(
                        id: UUID(),
                        role: .assistant,
                        content: finalText,
                        isStreaming: false
                    )
                )
            }

            self.pendingAssistantMessageID = nil
            self.streamingAssistantBuffer = ""
        }
    }

    private func appendMessage(role: ChatRole, content: String, isStreaming: Bool) async {
        await MainActor.run {
            let message = ChatMessage(
                id: UUID(),
                role: role,
                content: content,
                isStreaming: isStreaming
            )
            self.messages.append(message)
            if role == .assistant && isStreaming {
                self.pendingAssistantMessageID = message.id
            }
        }
    }

    private func handleToolCallEvent(_ event: [String: Any]) async {
        guard let toolName = event["toolName"] as? String else { return }
        guard toolName.hasPrefix("client_") else { return }

        let arguments = arguments(from: event["input"])
        await clientToolServer.callTool(name: toolName, arguments: arguments)
    }

    private func handleClientToolRequest(_ event: [String: Any]) async {
        guard let toolName = event["toolName"] as? String else { return }
        guard toolName.hasPrefix("client_") else { return }

        let arguments = arguments(from: event["input"])
        await clientToolServer.callTool(name: toolName, arguments: arguments)
    }

    private func handleToolResultEvent(_ event: [String: Any]) async {
        guard let content = event["content"] as? [[String: Any]] else { return }

        let textSegments = content.compactMap { item -> String? in
            guard let type = item["type"] as? String, type == "text" else { return nil }
            return item["text"] as? String
        }

        guard !textSegments.isEmpty else { return }

        let addition = textSegments.joined(separator: "\n")
        await appendAssistantDelta(addition)
    }

    private func handleToolErrorEvent(_ event: [String: Any]) async {
        if let message = event["error"] as? String {
            await MainActor.run {
                self.errorMessage = message
            }
        } else if let errorObject = event["error"] as? [String: Any],
                  let message = errorObject["message"] as? String {
            await MainActor.run {
                self.errorMessage = message
            }
        }
    }

    private func handleStateEvent(_ event: [String: Any]) async {
        guard let value = (event["value"] as? String) ?? (event["state"] as? String) else { return }
        await MainActor.run {
            if value.lowercased() == "idle" {
                self.currentState = nil
            } else {
                self.currentState = value
            }
        }
    }

    private func refreshConversationDetail(for id: String, quietly: Bool) async {
        do {
            guard let url = URL(string: "/conversations/\(id)", relativeTo: baseURL) else {
                throw AskError.invalidURL
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AskError.invalidResponse
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                throw AskError.server(
                    status: httpResponse.statusCode,
                    message: String(decoding: data, as: UTF8.self)
                )
            }

            let payload = try decoder.decode(ConversationResponse.self, from: data)

            await MainActor.run {
                self.conversationId = payload.conversationId
                self.messages = payload.messages.map {
                    ChatMessage(
                        id: UUID(),
                        role: $0.role,
                        content: $0.content,
                        isStreaming: false
                    )
                }
                self.errorMessage = quietly ? self.errorMessage : nil
            }
        } catch {
            if !quietly {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func fetchConversations(quiet: Bool) async {
        do {
            guard let url = URL(string: "/conversations", relativeTo: baseURL) else {
                throw AskError.invalidURL
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                throw AskError.invalidResponse
            }

            let payload = try decoder.decode(ConversationsListResponse.self, from: data)

            await MainActor.run {
                self.conversations = payload.conversations
            }
        } catch {
            if !quiet {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func handleLocalMCPEvent(_ event: LocalMCPToolServer.Event) async {
        await MainActor.run {
            switch event {
            case let .greet(message):
                self.greetingMessage = message
                self.showGreetingAlert = true
            }
        }
    }

    private func arguments(from rawInput: Any?) -> [String: Value]? {
        guard let rawInput else { return nil }
        guard let value = convertJSONToValue(rawInput),
              case let .object(objectValue) = value else {
            return nil
        }

        return objectValue
    }

    private func convertJSONToValue(_ raw: Any) -> Value? {
        switch raw {
        case is NSNull:
            return .null
        case let bool as Bool:
            return .bool(bool)
        case let int as Int:
            return .int(int)
        case let double as Double:
            return .double(double)
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            let doubleValue = number.doubleValue
            if doubleValue.rounded() == doubleValue {
                return .int(number.intValue)
            } else {
                return .double(doubleValue)
            }
        case let array as [Any]:
            let mapped = array.compactMap { convertJSONToValue($0) }
            return .array(mapped)
        case let dictionary as [String: Any]:
            var result: [String: Value] = [:]
            for (key, value) in dictionary {
                if let converted = convertJSONToValue(value) {
                    result[key] = converted
                }
            }
            return .object(result)
        default:
            return nil
        }
    }

    private func bodyString(from bytes: URLSession.AsyncBytes) async -> String {
        var data = Data()

        do {
            for try await byte in bytes {
                data.append(byte)
            }
        } catch {
            return String(data: data, encoding: .utf8) ?? ""
        }

        return String(data: data, encoding: .utf8) ?? ""
    }

    func dismissGreetingAlert() {
        showGreetingAlert = false
    }

    private struct ConversationsListResponse: Decodable {
        let conversations: [ConversationSummary]
    }

    private struct NewConversationResponse: Decodable {
        let conversationId: String
    }

    private struct ConversationResponse: Decodable {
        struct Message: Decodable {
            let role: ChatRole
            let content: String
        }

        let conversationId: String
        let messages: [Message]
    }

    private enum AskError: LocalizedError {
        case invalidURL
        case invalidResponse
        case server(status: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Failed to build the request URL."
            case .invalidResponse:
                return "Received an invalid response from the server."
            case let .server(status, message):
                return "Server error (\(status)): \(message)"
            }
        }
    }
}
