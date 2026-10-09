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
    @State private var showPicker = false
    /// "mic" or "photos" primer waiting for Continue.
    @State private var primer: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Quick asks scroll sideways at large text sizes instead of truncating. Each one goes
            // gray while the same question is still waiting, so it cannot be queued twice.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    quickButton("What did I miss?", ask: "what did I miss?")
                    quickButton("My tasks", ask: "my tasks")
                    quickButton("More", ask: "more")
                }
            }

            if let partial = mentionPartial {
                Button {
                    insertMention(replacing: partial)
                } label: {
                    Label("@pasa  ask the AI", systemImage: "sparkles")
                        .font(.callout.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(.purple)
                .frame(minHeight: 44)
                .accessibilityHint("Starts your message with @pasa")
            }

            if recorder.isRecording {
                TintedLabel(text: "Recording \(MediaManifest.clock(recorder.elapsed)) / 0:30. Release to send.", symbol: "record.circle", tint: .red, font: .callout.weight(.semibold))
            } else if let problem = recorder.problem ?? note ?? mesh.composerNote {
                TintedLabel(text: problem, symbol: "info.circle", tint: .orange, font: .callout)
            }

            HStack(spacing: 8) {
                Button {
                    if mesh.primerNeeded("photos") { primer = "photos" } else { showPicker = true }
                } label: {
                    if preparingPhoto {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "photo")
                    }
                }
                .frame(minWidth: 44, minHeight: 44)
                .buttonStyle(.bordered)
                .disabled(preparingPhoto)
                .accessibilityLabel("Photo")
                .accessibilityHint("Pick a photo to send to the room")

                micButton

                TextField("Message the team...", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(minHeight: 44)
                    .onSubmit(send)
                    .accessibilityLabel("Message")
                    .accessibilityHint("Start with @pasa to ask the AI")
                Button(action: send) {
                    Image(systemName: isAsk ? "sparkles" : "paperplane.fill")
                        .frame(minWidth: 32, minHeight: 32)
                }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel(isAsk ? "Ask Pasa" : "Send")
                .buttonStyle(.borderedProminent)
                .tint(isAsk ? Color.purple : Color.accentColor)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .photosPicker(isPresented: $showPicker, selection: $photoItem, matching: .images, photoLibrary: .shared())
        .alert(primer == "mic" ? "Record a voice note" : "Share a photo", isPresented: Binding(get: { primer != nil }, set: { if !$0 { primer = nil } })) {
            Button("Continue") {
                let kind = primer ?? ""
                mesh.markPrimerShown(kind)
                primer = nil
                if kind == "photos" { showPicker = true }
            }
            Button("Not now", role: .cancel) { primer = nil }
        } message: {
            Text(primer == "mic" ? PermissionPrimer.microphone + " Then hold the mic button to record." : PermissionPrimer.photos)
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            sendPhoto(item)
        }
    }

    private func quickButton(_ title: String, ask: String) -> some View {
        Button(title) { mesh.quickAsk(ask) }
            .buttonStyle(.bordered)
            .frame(minHeight: 44)
            .disabled(mesh.isAskPending(ask))
            .accessibilityHint(mesh.isAskPending(ask) ? "Already asked, waiting for the answer" : "Asks the AI Mac")
    }

    /// Hold to record, release to send.
    private var micButton: some View {
        Image(systemName: recorder.isRecording ? "mic.fill" : "mic")
            .foregroundStyle(recorder.isRecording ? Color.white : Color.accentColor)
            .frame(minWidth: 44, minHeight: 44)
            .background(recorder.isRecording ? Color.red : Color.gray.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressing else { return }
                        pressing = true
                        if mesh.primerNeeded("mic") {
                            primer = "mic"   // explain first; the system prompt comes on the next hold
                            return
                        }
                        note = nil
                        recorder.begin()
                    }
                    .onEnded { _ in
                        pressing = false
                        if primer != nil { return }   // the primer is up; nothing was recorded
                        if let clip = recorder.end() {
                            mesh.sendMedia(clip.data, kind: .audio, mime: "audio/mp4", durationSeconds: clip.seconds)
                        }
                    }
            )
            .accessibilityLabel(recorder.isRecording ? "Recording voice note" : "Voice note")
            .accessibilityHint("Touch and hold to record, release to send")
            .accessibilityAddTraits(.isButton)
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
