// VoiceTranscriber.swift
// Pasa (Mac only): voice note transcripts with Apple's Speech framework, on-device only
// (requiresOnDeviceRecognition = true). Audio never leaves the Mac. If the chosen language has no
// on-device model, it falls back to English (US) when that one is on-device, else returns a note.

import Foundation
#if os(macOS)
import Speech

enum VoiceTranscriber {
    /// Languages offered in Settings. Filipino works only if macOS has an on-device model for it.
    static let choices: [(id: String, label: String)] = [("en-US", "English (US)"), ("fil-PH", "Filipino (if available)")]

    static func authorize() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        if current != .notDetermined { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    /// Recognizer for `localeID` that can run on this Mac, or English (US) as a fallback.
    static func onDeviceRecognizer(_ localeID: String) -> (SFSpeechRecognizer, String, String?)? {
        if let r = SFSpeechRecognizer(locale: Locale(identifier: localeID)), r.supportsOnDeviceRecognition {
            return (r, localeID, nil)
        }
        if localeID != "en-US", let en = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), en.supportsOnDeviceRecognition {
            return (en, "en-US", "\(localeID) on-device speech is not available on this Mac, so English (US) was used.")
        }
        return nil
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        var task: SFSpeechRecognitionTask?
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    static func transcribe(url: URL, localeID: String) async -> TranscriptPayload {
        let status = await authorize()
        guard status == .authorized else {
            return TranscriptPayload(text: "", locale: localeID,
                                     note: "No transcript: allow Speech Recognition for Libre in System Settings > Privacy & Security.")
        }
        guard let (recognizer, used, fallbackNote) = onDeviceRecognizer(localeID) else {
            return TranscriptPayload(text: "", locale: localeID,
                                     note: "No transcript: on-device speech recognition for \(localeID) is not available on this Mac. Turn on Dictation in System Settings > Keyboard to download it. Libre never sends audio to a server.")
        }
        guard recognizer.isAvailable else {
            return TranscriptPayload(text: "", locale: used, note: "No transcript: speech recognition is busy or unavailable right now.")
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        return await withCheckedContinuation { continuation in
            let once = Once()
            once.task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    guard once.claim() else { return }
                    continuation.resume(returning: TranscriptPayload(text: result.bestTranscription.formattedString, locale: used, note: fallbackNote))
                } else if let error {
                    guard once.claim() else { return }
                    continuation.resume(returning: TranscriptPayload(text: "", locale: used,
                                                                     note: "No transcript: \(error.localizedDescription)"))
                }
            }
        }
    }
}
#endif
