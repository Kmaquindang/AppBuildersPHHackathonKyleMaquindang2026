// ComposerView.swift
// Quick actions, a Chat / Ask AI switch and the text field. Typing "@pasa ..." (or the old "@pasa ...") also asks the AI.

import SwiftUI

struct ComposerView: View {
    @EnvironmentObject private var mesh: MeshService
    @State private var text = ""
    @State private var mode: ComposeMode = .chat

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Button("What did I miss?") { mesh.quickAsk("what did I miss?") }
                Button("My tasks") { mesh.quickAsk("my tasks") }
                Button("More") { mesh.quickAsk("more") }
                Spacer(minLength: 0)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Picker("Mode", selection: $mode) {
                ForEach(ComposeMode.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 8) {
                TextField(mode == .ask ? "Ask the AI peer..." : "Message the mesh...", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding()
    }

    private func send() {
        mesh.send(text, mode: mode)
        text = ""
    }
}
