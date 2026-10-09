// ComposerView.swift
// iMessage-style composer (round 2, Kyle's 8:55 PM screenshot):
// - One "+" button on the left opens a menu: Photo, Voice note.
// - A rounded field. Trailing inside it: the mic while the field is empty (touch and hold to
//   record, release to send), the send arrow (arrow.up.circle.fill) as soon as there is text.
// - "Voice note" in the "+" menu (and a VoiceOver double-tap on the mic) records hands-free:
//   tap Send or Cancel. Hold to record stays on the mic.
// - Typing "@" shows an inline list: @pasa, @pasa my tasks, @pasa what did I miss?, @pasa summary.
// - Small starter chips only in an empty chat or right after onboarding; hidden otherwise.
// - Asking a question that was answered in the last 10 minutes shows "Answered above" (scrolls to
//   it) and "Ask again" instead of sending a duplicate.
// One chat for everyone. Plain text goes to the team; a line that starts with "@pasa" (or the old
// "@libre") goes to the AI peer. Photos are shrunk to about 200 KB; voice notes are up to 30 s.

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
    /// Recording started from the "+" menu or VoiceOver: stops with Send or Cancel, not on release.
    @State private var tapRecording = false
    /// "mic" or "photos" primer waiting for Continue.
    @State private var primer: String?
    /// The mic primer came from the "+" menu: start recording after Continue.
    @State private var primerStartsRecording = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let hint = mesh.answeredHint {
                answeredRow(hint)
            }

            let suggestions = MentionSuggest.suggestions(for: text)
            if !suggestions.isEmpty {
                suggestionList(suggestions)
            }

            if StarterChipPolicy.visible(entriesEmpty: mesh.entries.isEmpty, afterOnboarding: mesh.showStarterChips,
                                         canSend: mesh.activeRoom.canSend, typing: !text.isEmpty) {
                starterChips
            }

            if recorder.isRecording || tapRecording {
                recordingRow
            } else if let problem = recorder.problem ?? note ?? mesh.composerNote {
                TintedLabel(text: problem, symbol: "info.circle", tint: .orange, font: .footnote)
            }

            HStack(alignment: .bottom, spacing: 6) {
                plusMenu
                field
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
                if kind == "mic" && primerStartsRecording { startTapRecording() }
                primerStartsRecording = false
            }
            Button("Not now", role: .cancel) {
                primer = nil
                primerStartsRecording = false
            }
        } message: {
            Text(primer == "mic" ? PermissionPrimer.microphone + " Then hold the mic button to record, or pick Voice note from the + menu." : PermissionPrimer.photos)
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            sendPhoto(item)
        }
        .onChange(of: text) { _, new in
            if !new.isEmpty, mesh.answeredHint != nil { mesh.answeredHint = nil }
        }
        .onChange(of: recorder.problem) { _, problem in
            if problem != nil { tapRecording = false }
        }
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isAsk: Bool { AssistantMention.strip(text) != nil }

    // MARK: Input row

    /// "+" opens Photo and Voice note.
    private var plusMenu: some View {
        Menu {
            Button {
                if mesh.primerNeeded("photos") { primer = "photos" } else { showPicker = true }
            } label: { Label("Photo", systemImage: "photo.on.rectangle") }
            Button {
                if mesh.primerNeeded("mic") {
                    primerStartsRecording = true
                    primer = "mic"
                } else {
                    startTapRecording()
                }
            } label: { Label("Voice note", systemImage: "mic") }
        } label: {
            Group {
                if preparingPhoto {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .background(Color.secondary.opacity(0.18), in: Circle())
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        #endif
        .disabled(preparingPhoto || recorder.isRecording || !mesh.activeRoom.canSend)
        .accessibilityLabel("Add photo or voice note")
        .accessibilityHint("Opens a menu: Photo, Voice note")
    }

    /// Rounded field with the mic (empty) or the send arrow (any text) inside, trailing.
    private var field: some View {
        HStack(alignment: .bottom, spacing: 0) {
            TextField("Message, or @pasa to ask", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($fieldFocused)
                .padding(.vertical, 11)
                .padding(.leading, 14)
                .padding(.trailing, 4)
                .onSubmit(send)
                .accessibilityLabel("Message")
                .accessibilityHint("Start with @pasa to ask the AI")
            if trimmed.isEmpty {
                micButton
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, isAsk ? AskStyle.fill : BubbleStyle.mine)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isAsk ? "Ask Pasa" : "Send")
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .frame(minHeight: 44)
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.secondary.opacity(0.4), lineWidth: 1))
    }

    /// Hold to record, release to send. VoiceOver: double-tap to start, double-tap again to send.
    private var micButton: some View {
        Image(systemName: recorder.isRecording ? "mic.fill" : "mic")
            .font(.title3)
            .foregroundStyle(recorder.isRecording ? Color.white : Color.secondary)
            .frame(width: 36, height: 36)
            .background(recorder.isRecording ? Color.red : Color.clear, in: Circle())
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressing, !tapRecording else { return }
                        pressing = true
                        if mesh.primerNeeded("mic") {
                            primer = "mic"   // explain first; the system prompt comes on the next hold
                            return
                        }
                        note = nil
                        recorder.begin()
                    }
                    .onEnded { _ in
                        guard pressing else { return }
                        pressing = false
                        if primer != nil { return }   // the primer is up; nothing was recorded
                        if let clip = recorder.end() {
                            mesh.sendMedia(clip.data, kind: .audio, mime: "audio/mp4", durationSeconds: clip.seconds)
                        }
                    }
            )
            .disabled(!mesh.activeRoom.canSend)
            .accessibilityElement()
            .accessibilityLabel(recorder.isRecording ? "Recording voice note" : "Voice note")
            .accessibilityHint(tapRecording ? "Double-tap to send" : "Touch and hold to record, release to send. Or double-tap to start, then double-tap again to send.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                if tapRecording { finishTapRecording(send: true) } else if mesh.primerNeeded("mic") {
                    primerStartsRecording = true
                    primer = "mic"
                } else {
                    startTapRecording()
                }
            }
    }

    // MARK: Recording

    private var recordingRow: some View {
        HStack(spacing: 8) {
            TintedLabel(text: tapRecording
                        ? "Recording \(MediaManifest.clock(recorder.elapsed)) / 0:30"
                        : "Recording \(MediaManifest.clock(recorder.elapsed)) / 0:30. Release to send.",
                        symbol: "record.circle", tint: .red, font: .callout.weight(.semibold))
            if tapRecording {
                Spacer(minLength: 4)
                Button("Cancel") { finishTapRecording(send: false) }
                    .frame(minHeight: 44)
                    .accessibilityHint("Deletes this recording")
                Button {
                    finishTapRecording(send: true)
                } label: {
                    Label("Send", systemImage: "arrow.up.circle.fill").font(.callout.weight(.semibold))
                        .frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Sends the voice note to the room")
            }
        }
    }

    private func startTapRecording() {
        note = nil
        tapRecording = true
        recorder.begin()
    }

    private func finishTapRecording(send: Bool) {
        tapRecording = false
        let clip = recorder.end()
        if send, let clip {
            mesh.sendMedia(clip.data, kind: .audio, mime: "audio/mp4", durationSeconds: clip.seconds)
        } else if send, recorder.problem == "Hold the mic button while you talk." {
            recorder.problem = "That voice note was too short. Talk for at least a second."
        } else if !send {
            recorder.problem = nil
        }
    }

    // MARK: Hints, suggestions, chips

    /// The same question was answered in the last 10 minutes.
    private func answeredRow(_ hint: AnsweredHint) -> some View {
        HStack(spacing: 4) {
            Button {
                mesh.scrollRequest = ScrollRequest(id: hint.answerID)
            } label: {
                Label("Answered above", systemImage: "arrow.up.circle")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Scrolls to Pasa's answer to the same question")
            Spacer(minLength: 4)
            Button {
                let question = hint.question
                mesh.answeredHint = nil
                mesh.send("\(AssistantMention.primary) \(question)", force: true)
            } label: {
                Text("Ask again").font(.footnote.weight(.semibold)).frame(minHeight: 44)
            }
            .accessibilityHint("Sends the question to Pasa again")
            Button {
                mesh.answeredHint = nil
            } label: {
                Image(systemName: "xmark").font(.footnote).frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 12)
        .background(BubbleStyle.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Typing "@": ready asks. Picking one fills the field (it does not send).
    private func suggestionList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element) { index, item in
                Button {
                    text = MentionSuggest.apply(item, to: text)
                    fieldFocused = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles").foregroundStyle(.purple).accessibilityHidden(true)
                        Text(item).foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Fills the message field")
                if index < items.count - 1 { Divider().padding(.leading, 40) }
            }
        }
        .background(BubbleStyle.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
    }

    /// Small, quiet chips: caption text, secondary fill, scroll sideways, never truncated.
    private var starterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(StarterChipPolicy.asks, id: \.title) { item in
                    let pending = mesh.isAskPending(item.ask)
                    Button {
                        mesh.quickAsk(item.ask)
                        mesh.hideStarterChips()
                    } label: {
                        Label {
                            Text(item.title).foregroundStyle(.primary)
                        } icon: {
                            Image(systemName: "sparkles").foregroundStyle(.purple)
                        }
                        .font(.caption)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(pending)
                    .opacity(pending ? 0.5 : 1)
                    .accessibilityLabel("Ask Pasa: \(item.title)")
                    .accessibilityHint(pending ? "Already asked, waiting for the answer" : "Sends this question to the AI Mac")
                }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: Sending

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

    private func send() {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        mesh.send(line)
        text = ""
    }
}

/// Ask color for the send arrow when the line starts with @pasa (deep purple, white arrow above 4.5:1).
enum AskStyle {
    static let fill = Color(red: 0.42, green: 0.20, blue: 0.62)
}
