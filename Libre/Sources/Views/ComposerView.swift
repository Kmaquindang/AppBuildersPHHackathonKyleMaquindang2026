// ComposerView.swift
// iMessage-style composer (round 2, Kyle's 8:55 PM screenshot):
// - One "+" button on the left opens a menu: Photo, Voice note.
// - A rounded field. Trailing inside it: the mic while the field is empty (touch and hold to
//   record, release to send), the send arrow (arrow.up.circle.fill) as soon as there is text.
// - Photos are staged, not sent: up to 4 thumbnails sit in the composer with an X each, you can
//   add a caption (an "@pasa ..." caption asks the AI Mac about the photos as one question), and
//   nothing leaves until the send arrow.
// - Releasing the mic shows a small preview (play, duration, delete, send) instead of sending.
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
    @State private var draft = ComposerDraft()
    @State private var photoItems: [PhotosPickerItem] = []
    /// Small thumbnails of staged photos, made once when they are staged.
    @State private var thumbs: [UUID: CGImage] = [:]
    /// A recorded voice note waiting for Send or Delete.
    @State private var voiceDraft: StagedItem?
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

            let suggestions = MentionSuggest.suggestions(for: draft.text)
            if !suggestions.isEmpty {
                suggestionList(suggestions)
            }

            if StarterChipPolicy.visible(entriesEmpty: mesh.entries.isEmpty, afterOnboarding: mesh.showStarterChips,
                                         canSend: mesh.activeRoom.canSend, typing: !draft.text.isEmpty || !draft.photos.isEmpty) {
                starterChips
            }

            if !draft.photos.isEmpty {
                stagedPhotos
            }

            if let voice = voiceDraft, !recorder.isRecording {
                VoicePreviewRow(item: voice,
                                onDelete: { voiceDraft = nil },
                                onSend: {
                                    mesh.sendMedia(voice.data, kind: .audio, mime: voice.mime, durationSeconds: voice.seconds)
                                    voiceDraft = nil
                                })
            } else if recorder.isRecording || tapRecording {
                recordingRow
            } else if let problem = recorder.problem ?? note ?? mesh.composerNote {
                TintedLabel(text: problem, symbol: "info.circle", tint: .orange, font: .footnote)
            }

            HStack(alignment: .bottom, spacing: 6) {
                #if os(macOS)
                macPlusButton
                #else
                plusMenu
                #endif
                field
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .photosPicker(isPresented: $showPicker, selection: $photoItems, maxSelectionCount: max(1, draft.photoSlots),
                      selectionBehavior: .ordered, matching: .images, photoLibrary: .shared())
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
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            stagePhotos(items)
        }
        .onChange(of: draft.text) { _, new in
            if !new.isEmpty, mesh.answeredHint != nil { mesh.answeredHint = nil }
        }
        .onChange(of: recorder.problem) { _, problem in
            if problem != nil { tapRecording = false }
        }
    }

    private var isAsk: Bool { AssistantMention.strip(draft.text) != nil }

    // MARK: Input row

    #if os(macOS)
    @State private var showPlus = false

    /// Mac: a real 44 pt button inside the composer row (a borderless Menu dropped its frame and
    /// drew the "+" clipped at the window's bottom-left corner). Opens a small popover.
    private var macPlusButton: some View {
        Button { showPlus = true } label: {
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
        .buttonStyle(.plain)
        .disabled(preparingPhoto || recorder.isRecording || voiceDraft != nil || !mesh.activeRoom.canSend)
        .accessibilityLabel("Add photo or voice note")
        .help("Add a photo or voice note")
        .popover(isPresented: $showPlus, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    showPlus = false
                    if mesh.primerNeeded("photos") { primer = "photos" } else { showPicker = true }
                } label: { Label(draft.photoSlots == 0 ? "Photo (4 max)" : "Photo", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity, alignment: .leading) }
                .disabled(draft.photoSlots == 0)
                Button {
                    showPlus = false
                    if mesh.primerNeeded("mic") {
                        primerStartsRecording = true
                        primer = "mic"
                    } else {
                        startTapRecording()
                    }
                } label: { Label("Voice note", systemImage: "mic").frame(maxWidth: .infinity, alignment: .leading) }
            }
            .buttonStyle(.borderless)
            .padding(12)
            .frame(minWidth: 160)
        }
    }
    #endif

    /// "+" opens Photo and Voice note.
    private var plusMenu: some View {
        Menu {
            Button {
                if mesh.primerNeeded("photos") { primer = "photos" } else { showPicker = true }
            } label: { Label(draft.photoSlots == 0 ? "Photo (4 max)" : "Photo", systemImage: "photo.on.rectangle") }
            .disabled(draft.photoSlots == 0)
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
        .disabled(preparingPhoto || recorder.isRecording || voiceDraft != nil || !mesh.activeRoom.canSend)
        .accessibilityLabel("Add photo or voice note")
        .accessibilityHint("Opens a menu: Photo, Voice note")
    }

    /// Rounded field with the mic (empty) or the send arrow (any text) inside, trailing.
    private var field: some View {
        HStack(alignment: .bottom, spacing: 0) {
            TextField(draft.photos.isEmpty ? "Message" : "Add a caption", text: $draft.text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($fieldFocused)
                .padding(.vertical, 11)
                .padding(.leading, 14)
                .padding(.trailing, 4)
                .onSubmit(send)
                .accessibilityLabel("Message")
                .accessibilityHint("Start with @libre to ask the AI")
            if !draft.canSend {
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
                .accessibilityLabel(isAsk ? (draft.photos.isEmpty ? "Ask Libre" : "Ask Libre about the photos") : (draft.photos.isEmpty ? "Send" : "Send \(draft.photos.count) photo\(draft.photos.count == 1 ? "" : "s")"))
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
                            voiceDraft = StagedItem(kind: .audio, data: clip.data, mime: "audio/mp4", seconds: clip.seconds)
                        }
                    }
            )
            .disabled(!mesh.activeRoom.canSend)
            .accessibilityElement()
            .accessibilityLabel(recorder.isRecording ? "Recording voice note" : "Voice note")
            .accessibilityHint(tapRecording ? "Double-tap to stop and preview" : "Touch and hold to record, release to preview. Or double-tap to start, then double-tap again to stop.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                if tapRecording { finishTapRecording(keep: true) } else if mesh.primerNeeded("mic") {
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
                        : "Recording \(MediaManifest.clock(recorder.elapsed)) / 0:30. Release to stop.",
                        symbol: "record.circle", tint: .red, font: .callout.weight(.semibold))
            if tapRecording {
                Spacer(minLength: 4)
                Button("Cancel") { finishTapRecording(keep: false) }
                    .frame(minHeight: 44)
                    .accessibilityHint("Deletes this recording")
                Button {
                    finishTapRecording(keep: true)
                } label: {
                    Label("Stop", systemImage: "stop.circle.fill").font(.callout.weight(.semibold))
                        .frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Stops recording and shows a preview before sending")
            }
        }
    }

    private func startTapRecording() {
        note = nil
        tapRecording = true
        recorder.begin()
    }

    private func finishTapRecording(keep: Bool) {
        tapRecording = false
        let clip = recorder.end()
        if keep, let clip {
            voiceDraft = StagedItem(kind: .audio, data: clip.data, mime: "audio/mp4", seconds: clip.seconds)
        } else if keep, recorder.problem == "Hold the mic button while you talk." {
            recorder.problem = "That voice note was too short. Talk for at least a second."
        } else if !keep {
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
            .accessibilityHint("Scrolls to Libre's answer to the same question")
            Spacer(minLength: 4)
            Button {
                let question = hint.question
                mesh.answeredHint = nil
                mesh.send("\(AssistantMention.primary) \(question)", force: true)
            } label: {
                Text("Ask again").font(.footnote.weight(.semibold)).frame(minHeight: 44)
            }
            .accessibilityHint("Sends the question to Libre again")
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
                    draft.text = MentionSuggest.apply(item, to: draft.text)
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

    /// At most 3 quiet chips, only in an empty chat: one row when they fit, stacked at large text.
    private var starterChips: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { chipButtons }
            VStack(alignment: .leading, spacing: 2) { chipButtons }
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private var chipButtons: some View {
                ForEach(StarterChipPolicy.asks.prefix(StarterChipPolicy.maxChips), id: \.title) { item in
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
                    .accessibilityLabel("Ask \(AppBrand.name): \(item.title)")
                    .accessibilityHint(pending ? "Already asked, waiting for the answer" : "Sends this question to the AI Mac")
                }
    }

    // MARK: Sending

    /// Loads, shrinks and stages picked photos (up to 4 in the composer). Nothing is sent here.
    private func stagePhotos(_ items: [PhotosPickerItem]) {
        preparingPhoto = true
        note = nil
        Task {
            defer {
                preparingPhoto = false
                photoItems = []
            }
            var staged: [StagedItem] = []
            var failed = 0
            let slots = draft.photoSlots
            for item in items.prefix(slots) {
                guard let raw = try? await item.loadTransferable(type: Data.self),
                      let shrunk = await Task.detached(priority: .userInitiated, operation: { MediaImage.compress(raw) }).value else {
                    failed += 1
                    continue
                }
                let photo = StagedItem(kind: .image, data: shrunk.data, mime: "image/jpeg", width: shrunk.width, height: shrunk.height)
                thumbs[photo.id] = MediaImage.thumbnail(shrunk.data, maxPixel: 180)
                staged.append(photo)
            }
            let dropped = draft.addPhotos(staged) + max(0, items.count - slots)
            if failed > 0 { note = failed == 1 ? "Could not read one photo." : "Could not read \(failed) photos." }
            else if dropped > 0 { note = "Up to \(ComposerDraft.maxPhotos) photos per message." }
        }
    }

    /// Staged photo thumbnails with an X each. Scrolls sideways at large text sizes.
    private var stagedPhotos: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(draft.photos) { photo in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let thumb = thumbs[photo.id] {
                                Image(decorative: thumb, scale: 1).resizable().scaledToFill()
                            } else {
                                Color.secondary.opacity(0.2)
                            }
                        }
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityElement()
                        .accessibilityLabel(draft.accessibilityLabel(for: photo.id))
                        Button {
                            draft.removePhoto(photo.id)
                            thumbs[photo.id] = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Color.white, Color.black.opacity(0.7))
                                .font(.title3)
                                .frame(width: 44, height: 44, alignment: .topTrailing)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .offset(x: 6, y: -6)
                        .accessibilityLabel("Remove photo \((draft.photos.firstIndex(of: photo) ?? 0) + 1)")
                    }
                    .padding(.top, 6)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func send() {
        let plan = draft.plan
        guard !plan.isEmpty else { return }
        if plan.photos.isEmpty {
            if let text = plan.text { mesh.send(text) }
        } else {
            mesh.sendStaged(plan)
        }
        draft.clear()
        thumbs = [:]
    }
}

/// After recording: play, duration, delete or send. Nothing leaves until Send.
struct VoicePreviewRow: View {
    @ObservedObject private var player = AudioPlayback.shared
    let item: StagedItem
    var onDelete: () -> Void
    var onSend: () -> Void

    var body: some View {
        let playing = player.playingID == item.id
        HStack(spacing: 6) {
            Button {
                player.toggle(item.id, data: item.data)
            } label: {
                Image(systemName: playing ? "stop.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .accessibilityLabel(playing ? "Stop preview" : "Play your voice note, \(MediaManifest.clock(item.seconds ?? 0))")
            Image(systemName: "waveform").foregroundStyle(.secondary).accessibilityHidden(true)
            Text(MediaManifest.clock(item.seconds ?? 0))
                .font(.callout.monospacedDigit())
                .accessibilityHidden(true)
            Spacer(minLength: 4)
            Button(role: .destructive) {
                if playing { player.stop() }
                onDelete()
            } label: {
                Image(systemName: "trash").frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .accessibilityLabel("Delete voice note")
            Button {
                if playing { player.stop() }
                onSend()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, BubbleStyle.mine)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Send voice note")
        }
        .padding(.leading, 4)
        .background(BubbleStyle.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// Ask color for the send arrow when the line starts with @pasa (deep purple, white arrow above 4.5:1).
enum AskStyle {
    static let fill = Color(red: 0.42, green: 0.20, blue: 0.62)
}
