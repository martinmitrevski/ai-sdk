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

final class AskViewModel: ObservableObject {
    @Published var question: String = ""
    @Published var streamedAnswer: String = ""
    @Published var isStreaming: Bool = false
    @Published var errorMessage: String?
    @Published var showGreetingAlert: Bool = false
    @Published var greetingMessage: String = "hi"

    private var streamTask: Task<Void, Never>?
    private let baseURL: URL
    private var clientToolServer: LocalMCPToolServer!

    init(baseURL: URL = URL(string: "http://localhost:3000")!) {
        self.baseURL = baseURL
        self.clientToolServer = LocalMCPToolServer { [weak self] event in
            await self?.handleLocalMCPEvent(event)
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

    deinit {
        streamTask?.cancel()
    }

    func sendQuestion() {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty else {
            errorMessage = "Type a question before asking."
            streamedAnswer = ""
            return
        }

        streamTask?.cancel()
        errorMessage = nil
        streamedAnswer = ""
        isStreaming = true

        streamTask = Task {
            defer {
                Task { @MainActor in
                    self.isStreaming = false
                }
            }

            do {
                try await streamAnswer(for: trimmedQuestion)
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func streamAnswer(for question: String) async throws {
        guard let askURL = URL(string: "/ask", relativeTo: baseURL) else {
            throw AskError.invalidURL
        }

        var request = URLRequest(url: askURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: ["question": question])

        let (byteStream, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AskError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let errorBody = await bodyString(from: byteStream)
            throw AskError.server(status: httpResponse.statusCode, message: errorBody)
        }

        var collectedPlainText = ""
        var sawStreamingPayload = false

        for try await line in byteStream.lines {
            try Task.checkCancellation()

            if line.hasPrefix("data:") {
                sawStreamingPayload = true
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)

                guard !payload.isEmpty, payload != "[DONE]" else { continue }

                if let data = payload.data(using: .utf8),
                   let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   await handleStreamEvent(jsonObject) {
                    continue
                }

                if let data = payload.data(using: .utf8),
                   let chunk = try? JSONDecoder().decode(PlainTextChunk.self, from: data),
                   await handlePlainTextChunk(chunk) {
                    continue
                }

                await MainActor.run {
                    self.streamedAnswer.append(payload)
                }
            } else if line.isEmpty {
                continue
            } else if !sawStreamingPayload {
                collectedPlainText.append(line)
            }
        }

        if !collectedPlainText.isEmpty {
            if let data = collectedPlainText.data(using: .utf8),
               let response = try? JSONDecoder().decode(AskResponse.self, from: data) {
                await MainActor.run {
                    self.streamedAnswer = response.answer
                }
            } else {
                await MainActor.run {
                    if self.streamedAnswer.isEmpty {
                        self.streamedAnswer = collectedPlainText
                    } else {
                        self.streamedAnswer.append(collectedPlainText)
                    }
                }
            }
        }
    }

    private func handlePlainTextChunk(_ chunk: PlainTextChunk) async -> Bool {
        if let error = chunk.error {
            await MainActor.run {
                self.errorMessage = error
            }
            return true
        }

        if let delta = chunk.delta {
            await MainActor.run {
                self.streamedAnswer.append(delta)
            }
            return true
        }

        if let text = chunk.text {
            await MainActor.run {
                self.streamedAnswer.append(text)
            }
            return true
        }

        if let answer = chunk.answer {
            await MainActor.run {
                self.streamedAnswer = answer
            }
            return true
        }

        return false
    }

    private func handleStreamEvent(_ event: [String: Any]) async -> Bool {
        if let error = event["error"] as? String {
            await MainActor.run {
                self.errorMessage = error
            }
            return true
        }

        if let delta = event["delta"] as? String {
            await MainActor.run {
                self.streamedAnswer.append(delta)
            }
            return true
        }

        if let text = event["text"] as? String {
            await MainActor.run {
                self.streamedAnswer.append(text)
            }
            return true
        }

        if let answer = event["answer"] as? String {
            await MainActor.run {
                self.streamedAnswer = answer
            }
            return true
        }

        guard let type = event["type"] as? String else {
            return false
        }

        switch type {
        case "tool-call":
            await handleToolCallEvent(event)
        case "tool-result":
            await handleToolResultEvent(event)
        case "tool-error":
            await handleToolErrorEvent(event)
        case "client-tool-request":
            await handleClientToolRequest(event)
        default:
            break
        }

        return true
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
        await MainActor.run {
            if self.streamedAnswer.isEmpty {
                self.streamedAnswer = addition
            } else {
                self.streamedAnswer.append("\n")
                self.streamedAnswer.append(addition)
            }
        }
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
            let doubleValue = number.doubleValue
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            } else if doubleValue.rounded() == doubleValue {
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

    private struct PlainTextChunk: Decodable {
        let delta: String?
        let text: String?
        let answer: String?
        let error: String?
    }

    private struct AskResponse: Decodable {
        let answer: String
    }

    func dismissGreetingAlert() {
        showGreetingAlert = false
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
