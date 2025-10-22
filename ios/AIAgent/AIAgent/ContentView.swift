//
//  ContentView.swift
//  AIAgent
//
//  Created by Martin Mitrevski on 21.10.25.
//

import SwiftUI
import StreamChatAI

enum ChatRole: String, Codable {
    case user
    case assistant
}

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    let role: ChatRole
    var content: String
    var isStreaming: Bool

    var scrollAnchorKey: String { "\(id.uuidString)-\(content.count)" }
}

struct ContentView: View {
    @StateObject private var viewModel = AskViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let state = viewModel.currentState, !state.isEmpty {
                    AITypingIndicatorView(text: state)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }

                ChatScrollView(messages: viewModel.messages)

                if let error = viewModel.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 12) {
                    TextField("Ask the agent…", text: $viewModel.question)
                        .textFieldStyle(.roundedBorder)
                        .disabled(viewModel.isStreaming)
                        .submitLabel(.send)
                        .onSubmit { viewModel.sendQuestion() }

                    Button {
                        viewModel.sendQuestion()
                    } label: {
                        if viewModel.isStreaming {
                            ProgressView()
                                .progressViewStyle(.circular)
                        } else {
                            Image(systemName: "paperplane.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        viewModel.isStreaming ||
                            viewModel.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
            .padding()
            .navigationTitle("AI Agent")
            .alert("Greeting", isPresented: $viewModel.showGreetingAlert) {
                Button("OK", role: .cancel) {
                    viewModel.dismissGreetingAlert()
                }
            } message: {
                Text(viewModel.greetingMessage)
            }
        }
    }
}

struct ChatScrollView: View {
    let messages: [ChatMessage]

    @State private var isUserInteracting = false
    @State private var autoScrollTask: Task<Void, Never>?
    private let bottomAnchor = UUID()
    private let throttleDelay: UInt64 = 300_000_000 // 0.3s

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if messages.isEmpty {
                        Text("Ask something to start the conversation.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 32)
                    } else {
                        ForEach(messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)

                Color.clear
                    .frame(height: 1)
                    .id(bottomAnchor)
            }
            .scrollIndicators(.hidden)
            .gesture(
                DragGesture()
                    .onChanged { _ in
                        isUserInteracting = true
                        autoScrollTask?.cancel()
                    }
                    .onEnded { _ in
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            isUserInteracting = false
                        }
                    }
            )
            .onAppear {
                scheduleAutoScroll(proxy, animated: false)
            }
            .onChange(of: messages.last?.scrollAnchorKey) { _, _ in
                scheduleAutoScroll(proxy, animated: true)
            }
            .onChange(of: messages.count) { _, _ in
                scheduleAutoScroll(proxy, animated: true)
            }
            .onDisappear {
                autoScrollTask?.cancel()
            }
        }
    }

    private func scheduleAutoScroll(_ proxy: ScrollViewProxy, animated: Bool) {
        guard !isUserInteracting else { return }
        autoScrollTask?.cancel()
        autoScrollTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: throttleDelay)
            if Task.isCancelled { return }
            let action = {
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
            if animated {
                withAnimation(.easeOut(duration: 0.25)) {
                    action()
                }
            } else {
                action()
            }
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack {
            if isUser {
                Spacer(minLength: 32)
            }

            StreamingMessageView(
                content: message.content,
                isGenerating: message.isStreaming,
                letterInterval: 0.001
            )
            .padding()
            .background(isUser ? Color.accentColor : Color(.secondarySystemBackground))
            .foregroundColor(isUser ? Color.white : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)

            if !isUser {
                Spacer(minLength: 32)
            }
        }
        .padding(.horizontal, 4)
    }
}
