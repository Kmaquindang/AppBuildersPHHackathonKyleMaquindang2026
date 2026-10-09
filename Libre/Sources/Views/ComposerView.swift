// ComposerView.swift
// iMessage-style composer: photo and mic on the left, a rounded field with the send arrow inside
// it, and one row of suggestion chips that hides while you type.
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
        VStack(alignment: .leading, spacing: 6) {
            // One scrollable row of suggestions, only while the field is empty. Starter prompts in
            // an empty conversation, quick asks otherwise. Each goes gray while the same question
            // is still waiting, so it cannot be queued twice.
            if text.isEmpty && mesh.activeRoom.canSend {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if mesh.entries.isEmpty || mesh.showStarterChips {
                            ForEach(StarterChips.prompts, id: \.self) { prompt in
                                chip(AssistantMention.strip(prompt).map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? prompt,
                                     ask: AssistantMention.strip(prompt) ?? prompt, starter: true)
                            }
                        } else {
                            chip("What did I miss?", ask: "what did I miss?")
                            chip("My tasks", ask: "my tasks")
                            chip("More", ask: "more")
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }

            if let partial = mentionPartial {
                Button {
                    insertMention(replacing: partial)
                } label: {
                    Label("@pasa  ask the AI", systemImage: "sparkles")
                        .font(.callout.weight(.semibold))
                        .frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(.purple)
                .accessibilityHint("Starts your message with @pasa")
            }

            if recorder.isRecording {
                TintedLabel(text: "Recording \(MediaManifest.clock(recorder.elapsed)) / 0:30. Release to send.", symbol: "record.circle", tint: .red, font: .callout.weight(.semibold))
            } else if let problem = recorder.problem ?? note ?? mesh.composerNote {
                TintedLabel(text: problem, symbol: "info.circle", tint: .orange, font: .footnote)
            }

            HStack(alignment: .bottom, spacing: 4) {
                Button {
                    if mesh.primerNeeded("photos") { primer = "photos" } else { showPicker = true }
                } label: {
                    Group {
                        if preparingPhoto {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "photo.on.rectangle").font(.title3)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(preparingPhoto)
                .accessibilityLabel("Photo")
                .accessibilityHint("Pick a photo to send to the room")

                micButton

                HStack(alignment: .bottom, spacing: 4) {
                    TextField("Message, or @pasa to ask", text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .padding(.vertical, 10)
                        .onSubmit(send)
                        .accessibilityLabel("Message")
                        .accessibilityHint("Start with @pasa to ask the AI")
                    if !trimmed.isEmpty {
                        Button(action: send) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2)
                                .foregroundStyle(isAsk ? Color.purple : BubbleStyle.mine)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isAsk ? "Ask Pasa" : "Send")
                        .keyboardShortcut(.return, modifiers: .command)
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, trimmed.isEmpty ? 14 : 0)
                .frame(minHeight: 44)
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.secondary.opacity(0.35), lineWidth: 1))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
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

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func chip(_ title: String, ask: String, starter: Bool = false) -> some View {
        Button {
            mesh.quickAsk(ask)
            if starter { mesh.hideStarterChips() }
        } label: {
            Label(title, systemImage: "sparkles")
                .font(.footnote)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .tint(.purple)
        .disabled(mesh.isAskPending(ask))
        .accessibilityLabel("Ask Pasa: \(title)")
        .accessibilityHint(mesh.isAskPending(ask) ? "Already asked, waiting for the answer" : "Sends this question to the AI Mac")
    }

    /// Hold to record, release to send.
    private var micButton: some View {
        Image(systemName: recorder.isRecording ? "mic.fill" : "mic")
            .font(.title3)
            .foregroundStyle(recorder.isRecording ? Color.white : Color.accentColor)
            .frame(width: 44, height: 44)
            .background(recorder.isRecording ? Color.red : Color.clear, in: Circle())
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
