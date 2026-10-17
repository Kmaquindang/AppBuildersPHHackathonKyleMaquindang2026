// MediaViews.swift
// Photos and voice notes: shrinking photos before sending, recording and playing voice notes,
// and the timeline bubbles (thumbnail with tap to full size, voice note with duration and the
// Mac's transcript underneath).

import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import AVFoundation

// MARK: - Photos

enum MediaImage {
    /// Downscales to `maxEdge` (keeps orientation), JPEG at quality 0.6, stepping down until the
    /// file is at most `targetBytes`. Location and other metadata are not copied.
    static func compress(_ data: Data, maxEdge: Int = MediaLimits.imageMaxEdge,
                         targetBytes: Int = MediaLimits.imageTargetBytes) -> (data: Data, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var best: (Data, Int, Int)?
        for edge in [maxEdge, 800, 640] {
            guard let image = thumbnail(source, maxPixel: edge) else { continue }
            for quality in [0.6, 0.5, 0.4, 0.3] {
                guard let jpeg = jpeg(image, quality: quality) else { continue }
                best = (jpeg, image.width, image.height)
                if jpeg.count <= targetBytes { return best }
            }
        }
        if let best, best.0.count <= MediaLimits.maxBytes { return best }
        return nil
    }

    static func thumbnail(_ source: CGImageSource, maxPixel: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func thumbnail(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return thumbnail(source, maxPixel: maxPixel)
    }

    static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}

// MARK: - Voice notes

/// Hold to record: AAC, mono, 16 kHz, about 24 kbps, at most 30 s (about 90 KB).
@MainActor
final class VoiceRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: Double = 0
    @Published var problem: String?

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var wanted = false
    private var url: URL?

    static let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 24_000,
        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
    ]

    /// Finger down. Asks for the microphone the first time.
    func begin() {
        wanted = true
        problem = nil
        Task {
            guard await VoiceRecorder.microphoneAllowed() else {
                problem = "Microphone access is off. Allow it for Libre in Settings to send voice notes."
                wanted = false
                return
            }
            guard wanted, !isRecording else { return }   // released before permission came back
            startRecording()
        }
    }

    static func microphoneAllowed() async -> Bool {
        #if os(iOS)
        return await AVAudioApplication.requestRecordPermission()
        #else
        return await AVCaptureDevice.requestAccess(for: .audio)
        #endif
    }

    private func startRecording() {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            problem = "Could not start the microphone: \(error.localizedDescription)"
            return
        }
        #endif
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pasa-voice-\(UUID().uuidString).m4a")
        do {
            var made = try AVAudioRecorder(url: file, settings: VoiceRecorder.settings)
            if !made.prepareToRecord() {
                // Some devices refuse the bitrate: let AVFoundation pick one for 16 kHz mono AAC.
                var fallback = VoiceRecorder.settings
                fallback.removeValue(forKey: AVEncoderBitRateKey)
                made = try AVAudioRecorder(url: file, settings: fallback)
            }
            guard made.record(forDuration: MediaLimits.audioMaxSeconds) else {
                problem = "Could not start recording."
                return
            }
            recorder = made
            url = file
            isRecording = true
            elapsed = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, let r = self.recorder else { return }
                        if r.isRecording { self.elapsed = r.currentTime } else if self.isRecording { self.elapsed = MediaLimits.audioMaxSeconds }
                    }
                }
            }
        } catch {
            problem = "Could not start recording: \(error.localizedDescription)"
        }
    }

    /// Finger up. Returns the voice note, or nil when it was too short or never started.
    func end() -> (data: Data, seconds: Double)? {
        wanted = false
        timer?.invalidate()
        timer = nil
        guard let recorder, let url else { return nil }
        let seconds = recorder.isRecording ? recorder.currentTime : min(elapsed, MediaLimits.audioMaxSeconds)
        recorder.stop()
        self.recorder = nil
        self.url = nil
        isRecording = false
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        defer { try? FileManager.default.removeItem(at: url) }
        guard seconds >= 0.6 else {
            problem = "Hold the mic button while you talk."
            return nil
        }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            problem = "The recording was empty."
            return nil
        }
        return (data, min(seconds, MediaLimits.audioMaxSeconds))
    }
}

/// Plays one voice note at a time.
@MainActor
final class AudioPlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayback()
    @Published private(set) var playingID: UUID?
    private var player: AVAudioPlayer?

    func toggle(_ id: UUID, data: Data) {
        if playingID == id {
            stop()
            return
        }
        stop()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let p: AVAudioPlayer
        if let typed = try? AVAudioPlayer(data: data, fileTypeHint: AVFileType.m4a.rawValue) {
            p = typed
        } else if let sniffed = try? AVAudioPlayer(data: data) {
            p = sniffed
        } else {
            return
        }
        p.delegate = self
        p.play()
        player = p
        playingID = id
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.stop() }
        }
    }
}

// MARK: - Timeline bubbles

struct MediaBubble: View {
    @EnvironmentObject private var mesh: MeshService
    let entry: ChatEntry
    let isMine: Bool

    var body: some View {
        if let manifest = MediaManifest.decode(entry.message.body) {
            switch manifest.kind {
            case .image: PhotoBubble(manifest: manifest, isMine: isMine)
            case .audio: VoiceBubble(manifest: manifest, transcript: entry.transcript, isMine: isMine)
            }
        } else {
            Text("Unreadable media message").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Small status under a photo or voice note while it is in flight.
private struct MediaTransferStatus: View {
    @EnvironmentObject private var mesh: MeshService
    let manifest: MediaManifest
    let isMine: Bool

    var body: some View {
        let has = mesh.hasMedia(manifest.mediaId)
        if let fraction = mesh.mediaProgress[manifest.mediaId] {
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: fraction).frame(width: 140)
                Text(isMine && has ? "Sending \(Int(fraction * 100))%" : "Receiving \(Int(fraction * 100))% of \(manifest.byteCount / 1024) KB")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else if !has {
            Label("Waiting for the file. It arrives when a teammate who has it is linked.", systemImage: "arrow.down.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct PhotoBubble: View {
    @EnvironmentObject private var mesh: MeshService
    let manifest: MediaManifest
    let isMine: Bool
    @State private var thumb: CGImage?
    @State private var showFull = false

    var body: some View {
        let has = mesh.hasMedia(manifest.mediaId)
        VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
            Group {
                if let thumb {
                    Image(decorative: thumb, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 240, maxHeight: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .onTapGesture { showFull = true }
                        .accessibilityLabel("Photo. Tap to view full size.")
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.gray.opacity(0.15))
                        .frame(width: 200, height: 140)
                        .overlay(Image(systemName: "photo").font(.title).foregroundStyle(.secondary))
                }
            }
            MediaTransferStatus(manifest: manifest, isMine: isMine)
        }
        .task(id: has) {
            guard has, let data = mesh.mediaData(manifest.mediaId) else { return }
            thumb = MediaImage.thumbnail(data, maxPixel: 480)
        }
        .sheet(isPresented: $showFull) {
            PhotoViewer(mediaId: manifest.mediaId).environmentObject(mesh)
        }
    }
}

struct PhotoViewer: View {
    @EnvironmentObject private var mesh: MeshService
    @Environment(\.dismiss) private var dismiss
    let mediaId: UUID
    @State private var image: CGImage?

    var body: some View {
        NavigationStack {
            Group {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                } else {
                    ProgressView()
                }
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .task {
            if let data = mesh.mediaData(mediaId) { image = MediaImage.thumbnail(data, maxPixel: 2048) }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 520)
        #endif
    }
}

/// Round 2 (owner 8:55 PM screenshot: a squared gray-blue box with the transcript floating in
/// gray italics outside it). Your own voice notes are a normal blue bubble with white play button,
/// waveform and duration; other people's use the gray bubble. The transcript lives inside the
/// bubble under the waveform in smaller text.
struct VoiceBubble: View {
    @EnvironmentObject private var mesh: MeshService
    @ObservedObject private var player = AudioPlayback.shared
    let manifest: MediaManifest
    let transcript: String?
    let isMine: Bool

    private var ink: Color { isMine ? .white : .primary }

    var body: some View {
        let has = mesh.hasMedia(manifest.mediaId)
        let playing = player.playingID == manifest.mediaId
        VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Button {
                        if let data = mesh.mediaData(manifest.mediaId) { player.toggle(manifest.mediaId, data: data) }
                    } label: {
                        Image(systemName: playing ? "stop.circle.fill" : "play.circle.fill")
                            .font(.title2)
                            .foregroundStyle(isMine ? Color.white : Color.accentColor)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!has)
                    .opacity(has ? 1 : 0.6)
                    .accessibilityLabel(playing ? "Stop voice note" : "Play voice note, \(MediaManifest.clock(manifest.durationSeconds ?? 0))")
                    Image(systemName: "waveform")
                        .font(.title3)
                        .foregroundStyle(ink.opacity(0.85))
                        .accessibilityHidden(true)
                    Text(MediaManifest.clock(manifest.durationSeconds ?? 0))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(ink)
                        .accessibilityHidden(true)
                }
                if mesh.transcribing.contains(manifest.mediaId) {
                    Text("Transcribing on this Mac...")
                        .font(.footnote)
                        .foregroundStyle(ink)
                        .padding(.bottom, 4)
                } else if let transcript, !transcript.isEmpty {
                    Text(transcript)
                        .font(.footnote)
                        .foregroundStyle(ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 4)
                        .accessibilityLabel("Transcript: \(transcript)")
                }
            }
            .padding(.leading, 4)
            .padding(.trailing, 12)
            .padding(.vertical, 2)
            .background(isMine ? BubbleStyle.mine : BubbleStyle.other,
                        in: RoundedRectangle(cornerRadius: BubbleStyle.radius, style: .continuous))
            MediaTransferStatus(manifest: manifest, isMine: isMine)
        }
    }
}
