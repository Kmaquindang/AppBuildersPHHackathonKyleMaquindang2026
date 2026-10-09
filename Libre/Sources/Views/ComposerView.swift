// ComposerView.swift
// One chat for everyone. Plain text goes to the team; a line that starts with "@pasa" (or the old
// "@libre") goes to the AI peer. Typing "@" offers an "@pasa" chip. Quick buttons send @pasa asks.
// Photo button: pick a photo (shrunk to about 200 KB before sending). Mic button: hold to record a
// voice note (up to 30 s), release to send.

import SwiftUI
import PhotosUI

struct ComposerView: View {
    @EnvironmentObject private var mesh: MeshService
    @StateObject private var recorder = VoiceRecorder()
    @State private var text = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var preparingPhoto = false
    @State private var pressing = false
    @State private var note: String?

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

            if recorder.isRecording {
                Label("Recording \(MediaManifest.clock(recorder.elapsed)) / 0:30. Release to send.", systemImage: "record.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
            } else if let problem = recorder.problem ?? note {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }

            HStack(spacing: 8) {
                PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                    if preparingPhoto {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "photo")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(preparingPhoto)
                .accessibilityLabel("Send a photo")

                micButton

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
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            sendPhoto(item)
        }
    }

    /// Hold to record, release to send.
    private var micButton: some View {
        Image(systemName: recorder.isRecording ? "mic.fill" : "mic")
            .foregroundStyle(recorder.isRecording ? Color.white : Color.accentColor)
            .frame(width: 34, height: 28)
            .background(recorder.isRecording ? Color.red : Color.gray.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressing else { return }
                        pressing = true
                        note = nil
                        recorder.begin()
                    }
                    .onEnded { _ in
                        pressing = false
                        if let clip = recorder.end() {
                            mesh.sendMedia(clip.data, kind: .audio, mime: "audio/mp4", durationSeconds: clip.seconds)
                        }
                    }
            )
            .accessibilityLabel("Hold to record a voice note")
    }

    private func sendPhoto(_ item: PhotosPickerItem) {
        preparingPhoto = true
        note = nil
        Task {
            defer {
                preparingPhoto = false
                photoItem = nil
            }
            guard let raw = try? await item.loadTransferable(type: Data.self) else {
                note = "Could not read that photo."
                return
            }
            let shrunk = await Task.detached(priority: .userInitiated) { MediaImage.compress(raw) }.value
            guard let shrunk else {
                note = "Could not shrink that photo enough to send."
                return
            }
            mesh.sendMedia(shrunk.data, kind: .image, mime: "image/jpeg", width: shrunk.width, height: shrunk.height)
        }
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
