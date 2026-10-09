// ComposerView.swift
// Text field plus a Chat / Ask AI switch. Typing "@libre ..." also asks the AI.

import SwiftUI

struct ComposerView: View {
    @EnvironmentObject private var mesh: MeshService
    @State private var text = ""
    @State private var mode: ComposeMode = .chat

    var body: some View {
        VStack(spacing: 8) {
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
