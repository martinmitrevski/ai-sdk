//
//  ContentView.swift
//  AIAgent
//
//  Created by Martin Mitrevski on 21.10.25.
//

import SwiftUI
import Foundation
import MCP
import CoreFoundation
import Combine

struct ContentView: View {
    @StateObject private var viewModel = AskViewModel()

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                TextField("Ask the agent…", text: $viewModel.question)
                    .textFieldStyle(.roundedBorder)
                    .disabled(viewModel.isStreaming)
                    .submitLabel(.send)
                    .onSubmit {
                        viewModel.sendQuestion()
                    }

                Button {
                    viewModel.sendQuestion()
                } label: {
                    HStack {
                        Image(systemName: "paperplane.fill")
                        Text(viewModel.isStreaming ? "Streaming…" : "Ask")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isStreaming || viewModel.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if let error = viewModel.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }

                ScrollView {
                    Text(viewModel.streamedAnswer.isEmpty ? "Your answer will appear here." : viewModel.streamedAnswer)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                }

                if viewModel.isStreaming {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                Spacer()
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
