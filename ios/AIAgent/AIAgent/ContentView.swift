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
    @State private var isSidebarOpen = false
    @State private var sidebarDragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let drawerWidth = geometry.size.width * 0.8

            ZStack(alignment: .leading) {
                mainContent
                    .frame(width: geometry.size.width)
                    .offset(x: mainContentOffset(drawerWidth: drawerWidth))
                    .disabled(isSidebarOpen)
                    .overlay {
                        if isSidebarOpen || sidebarDragOffset != 0 {
                            Color.black.opacity(0.3)
                                .ignoresSafeArea()
                                .onTapGesture { toggleSidebar(false) }
                        }
                    }

                ConversationSidebar(
                    conversations: viewModel.conversations,
                    selectedConversationId: viewModel.conversationId,
                    onNewConversation: {
                        viewModel.startNewConversation()
                        toggleSidebar(false)
                    },
                    onSelectConversation: { summary in
                        viewModel.selectConversation(summary)
                        toggleSidebar(false)
                    }
                )
                .frame(width: drawerWidth)
                .offset(x: sidebarOffset(drawerWidth: drawerWidth))
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        updateDrag(translation: value.translation.width, drawerWidth: drawerWidth)
                    }
                    .onEnded { value in
                        finishDrag(translation: value.translation.width, drawerWidth: drawerWidth)
                    }
            )
        }
        .onAppear {
            viewModel.refreshConversations()
        }
    }

    @ViewBuilder
    private var mainContent: some View {
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
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        toggleSidebar(true)
                    } label: {
                        Image(systemName: "line.3.horizontal")
                    }
                }
            }
            .alert("Greeting", isPresented: $viewModel.showGreetingAlert) {
                Button("OK", role: .cancel) {
                    viewModel.dismissGreetingAlert()
                }
            } message: {
                Text(viewModel.greetingMessage)
            }
        }
    }

    private func sidebarOffset(drawerWidth: CGFloat) -> CGFloat {
        let base = isSidebarOpen ? 0 : -drawerWidth
        let combined = base + sidebarDragOffset
        return min(0, max(-drawerWidth, combined))
    }

    private func mainContentOffset(drawerWidth: CGFloat) -> CGFloat {
        let base = isSidebarOpen ? drawerWidth : 0
        let combined = base + sidebarDragOffset
        return min(drawerWidth, max(0, combined))
    }

    private func updateDrag(translation: CGFloat, drawerWidth: CGFloat) {
        if isSidebarOpen {
            sidebarDragOffset = max(-drawerWidth, min(0, translation))
        } else if translation > 0 {
            sidebarDragOffset = min(drawerWidth, translation)
        } else {
            sidebarDragOffset = 0
        }
    }

    private func finishDrag(translation: CGFloat, drawerWidth: CGFloat) {
        let threshold = drawerWidth * 0.3
        if isSidebarOpen {
            if -sidebarDragOffset > threshold {
                toggleSidebar(false)
            } else {
                toggleSidebar(true)
            }
        } else {
            if sidebarDragOffset > threshold {
                toggleSidebar(true)
            } else {
                toggleSidebar(false)
            }
        }
        sidebarDragOffset = 0
    }

    private func toggleSidebar(_ open: Bool) {
        withAnimation(.easeOut(duration: 0.25)) {
            isSidebarOpen = open
            sidebarDragOffset = 0
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

struct ConversationSidebar: View {
    let conversations: [ConversationSummary]
    let selectedConversationId: String?
    let onNewConversation: () -> Void
    let onSelectConversation: (ConversationSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Button {
                onNewConversation()
            } label: {
                Label("New Conversation", systemImage: "plus")
                    .font(.headline)
            }
            .padding(.vertical)

            if conversations.isEmpty {
                Text("No conversations yet.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(conversations) { conversation in
                            ConversationRow(
                                conversation: conversation,
                                isSelected: conversation.conversationId == selectedConversationId,
                                onSelect: { onSelectConversation(conversation) }
                            )
                        }
                    }
                }
            }

            Spacer()
        }
        .padding(.top, 48)
        .padding(.horizontal, 20)
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .ignoresSafeArea()
    }
}

private struct ConversationRow: View {
    let conversation: ConversationSummary
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Conversation #\(conversation.conversationId)")
                    .fontWeight(.semibold)
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                Text("\(conversation.messageCount) message\(conversation.messageCount == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                if let lastMessage = conversation.lastMessage, !lastMessage.isEmpty {
                    Text(lastMessage)
                        .font(.footnote)
                        .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.secondary)
                        .lineLimit(2)
                } else {
                    Text("No messages yet")
                        .font(.footnote)
                        .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor : Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
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
