// ComposerView.swift
// One chat for everyone. Plain text goes to the team; a line that starts with "@pasa" (or the old
// "@libre") goes to the AI peer. Typing "@" offers an "@pasa" chip. Quick buttons send @pasa asks.

import SwiftUI

struct ComposerView: View {
    @EnvironmentObject private var mesh: MeshService
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button("What did I miss?") { mesh.quickAsk("what did I miss?") }
                Button("My tasks") { mesh.quickAsk("my tasks") }
                Button("More") { mesh.quickAsk("more") }
                Spacer(minLength: 0)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if let partial = mentionPartial {
                Button {
                    insertMention(replacing: partial)
                } label: {
                    Label("@pasa  ask the AI", systemImage: "sparkles")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(.purple)
                .controlSize(.small)
            }

            HStack(spacing: 8) {
                TextField("Message the team...", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: isAsk ? "sparkles" : "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(isAsk ? Color.purple : Color.accentColor)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var isAsk: Bool { AssistantMention.strip(text) != nil }

    /// The "@..." word being typed at the end of the text, when it could still become "@pasa".
    private var mentionPartial: String? {
        guard let last = text.split(separator: " ", omittingEmptySubsequences: false).last else { return nil }
        let word = String(last).lowercased()
        guard word.hasPrefix("@"), word != AssistantMention.primary, AssistantMention.primary.hasPrefix(word) else { return nil }
        return String(last)
    }

    private func insertMention(replacing partial: String) {
        text = String(text.dropLast(partial.count)) + AssistantMention.primary + " "
    }

    private func send() {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        mesh.send(line)
        text = ""
    }
}
