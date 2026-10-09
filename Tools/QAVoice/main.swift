// Tools/QAVoice/main.swift
// Pasa QA (macOS): runs the Mac app's real VoiceTranscriber on a synthetic voice file, then
// VoiceAsk.extract on the transcript. Built and run by scripts/qa-harness.sh voice <file>.
// Speech authorization belongs to the calling process; when it is not granted this prints
// BLOCKED and exits 3 (it never asks for the permission itself).
import Foundation
import Speech

let path = CommandLine.arguments.dropFirst().first ?? "/tmp/pasa-qa-voice.m4a"
let status = SFSpeechRecognizer.authorizationStatus()
print("speech authorization: \(status.rawValue) (0 notDetermined, 1 denied, 2 restricted, 3 authorized)")
if status != .authorized {
    print("BLOCKED: this command line process has no Speech Recognition permission; the app asks for it on first voice note.")
    if let en = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) { print("en-US on-device available: \(en.supportsOnDeviceRecognition)") }
    exit(3)
}
let t = Date()
let r = await VoiceTranscriber.transcribe(url: URL(fileURLWithPath: path), localeID: "en-US")
print("transcript: '\(r.text)' locale=\(r.locale) note=\(r.note ?? "-") in \(Int(Date().timeIntervalSince(t) * 1000)) ms")
print("VoiceAsk.extract: \(VoiceAsk.extract(r.text) ?? "nil (not an ask)")")
