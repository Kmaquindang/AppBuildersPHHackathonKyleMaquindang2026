// OnboardingView.swift
// First run: welcome, display name, Local Network primer (the mesh starts only after it), join or
// create a room (nearby rooms first), a skippable 3-card tour, the Mac's AI setup, then the room
// with starter chips. Existing users skip it; Settings > Replay first-run setup shows it again.

import SwiftUI
#if os(iOS)
import UIKit
#endif

enum OnboardingStep: Int, CaseIterable {
    case welcome, name, localNetwork, room, tour, macSetup, createRoom
}

struct OnboardingFlow: View {
    @EnvironmentObject private var mesh: MeshService
    @State private var step: OnboardingStep = .welcome
    @State private var nameDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ProgressView(value: Double(step.rawValue + 1), total: Double(lastStep.rawValue + 1))
                    .frame(maxWidth: 220)
                Spacer()
                if step == .tour || step == .macSetup || step == .createRoom {
                    Button("Skip") { advance() }
                }
            }
            .padding()
            ScrollView {
                content
                    .frame(maxWidth: 480, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
        }
        #if os(macOS)
        .frame(width: 560, height: 640)
        #endif
        .onAppear { nameDraft = mesh.personName }
    }

    private var lastStep: OnboardingStep {
        #if os(macOS)
        return .createRoom
        #else
        return .tour
        #endif
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: WelcomeStep { advance() }
        case .name: NameStep(draft: $nameDraft) { advance() }
        case .localNetwork: LocalNetworkStep { advance() }
        case .room: RoomStep { advance() }
        case .tour: TourStep { advance() }
        case .macSetup:
            #if os(macOS)
            MacSetupView(onDone: { advance() })
            #else
            EmptyView()
            #endif
        case .createRoom:
            // Mac onboarding ends with "Create your room" (name plus a generated code, QR join screen).
            CreateCodeRoomView(onDone: { advance() }, showSkip: true)
        }
    }

    private func advance() {
        if step == lastStep {
            mesh.finishOnboarding()
            return
        }
        var next = OnboardingStep(rawValue: step.rawValue + 1) ?? lastStep
        #if os(macOS)
        // The Mac creates its room at the end instead of joining one early.
        if next == .room { next = .tour }
        #endif
        step = next
    }
}

// MARK: Steps

private struct WelcomeStep: View {
    let next: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.largeTitle)
                .imageScale(.large)
                .accessibilityHidden(true)
                .foregroundStyle(.tint)
                .padding(.top, 30)
            Text("Walang signal? Pasa lang.")
                .font(.largeTitle.weight(.bold))
            Text("Chat and ask AI with no internet, phone to phone.")
                .font(.title3)
                .foregroundStyle(.secondary)
            Button(action: next) { Text("Get started").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 12)
        }
    }
}

private struct NameStep: View {
    @EnvironmentObject private var mesh: MeshService
    @Binding var draft: String
    let next: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your name").font(.title.weight(.bold)).padding(.top, 20)
            Text("Teammates see this on your messages. \"@pasa remind \(draft.isEmpty ? "Ana" : draft) ...\" sends tasks to you.")
                .foregroundStyle(.secondary)
            TextField("Your name, for example Kyle", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            Button(action: save) { Text("Continue").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(PeopleDirectory.clean(draft).isEmpty)
            Text("Device id: \(mesh.displayName). Change your name any time in Settings.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func save() {
        guard !PeopleDirectory.clean(draft).isEmpty else { return }
        mesh.setPersonName(draft)
        next()
    }
}

private struct LocalNetworkStep: View {
    @EnvironmentObject private var mesh: MeshService
    let next: () -> Void
    @State private var asked = false
    @State private var waited = false

    private var foundSomeone: Bool { mesh.connectedCount > 0 || !mesh.nearbyRooms.isEmpty || !mesh.peers.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "antenna.radiowaves.left.and.right").font(.largeTitle).foregroundStyle(.tint).padding(.top, 20).accessibilityHidden(true)
            Text("Find teammates nearby").font(.title.weight(.bold))
            Text("\(AppBrand.name) needs Local Network access to find teammates. Messages go phone to phone, never to the internet. Keep Wi-Fi and Bluetooth switched on. No network or signal needed.")
                .foregroundStyle(.secondary)
            if !asked {
                Button {
                    asked = true
                    mesh.startFromOnboarding()   // the system prompt appears now, in context
                    Task {
                        try? await Task.sleep(nanoseconds: 8_000_000_000)
                        waited = true
                    }
                } label: { Text("Allow and look for teammates").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                if foundSomeone {
                    TintedLabel(text: "Found \(max(mesh.connectedCount, mesh.peers.count)) device\(max(mesh.connectedCount, mesh.peers.count) == 1 ? "" : "s") nearby", symbol: "checkmark.circle.fill", tint: .green, font: .body)
                } else if mesh.localNetworkDenied || waited {
                    LocalNetworkFixCard(denied: mesh.localNetworkDenied)
                } else {
                    HStack { ProgressView(); Text("Looking for teammates...") }
                }
                Button(action: next) { Text("Continue").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
    }
}

/// Shown when no one is found or MultipeerConnectivity reports it could not start.
struct LocalNetworkFixCard: View {
    var denied: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TintedLabel(text: denied ? "Local Network looks blocked" : "No teammates found yet", symbol: denied ? "exclamationmark.triangle.fill" : "magnifyingglass",
                        tint: denied ? .orange : .secondary, font: .headline)
            #if os(iOS)
            Text("Turn it on in Settings > Pasa > Local Network. If nobody else has Pasa open nearby yet, that is fine: you can continue.")
                .font(.callout)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            #else
            Text("Turn it on in System Settings > Privacy & Security > Local Network > Pasa. If nobody else has Pasa open nearby yet, that is fine: you can continue.")
                .font(.callout)
            #endif
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((denied ? Color.orange : Color.gray).opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct RoomStep: View {
    @EnvironmentObject private var mesh: MeshService
    let next: () -> Void
    @State private var choice: RoomOnboardingPicker.Choice = .join
    @State private var name = ""
    @State private var passcode = ""
    @State private var confirm = ""
    @State private var joinText = ""
    @State private var error: String?
    @State private var showCodeJoin = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Join your team").font(.title.weight(.bold)).padding(.top, 20)
            Text("Scan the room's QR code or type its code. Or start in Town Square, open to everyone nearby.")
                .foregroundStyle(.secondary)
            RoomOnboardingPicker(choice: $choice, name: $name, passcode: $passcode, confirm: $confirm, joinText: $joinText)
            if let error { TintedLabel(text: error, symbol: "exclamationmark.triangle.fill", tint: .red, font: .callout) }
            Button {
                Task {
                    if let problem = await RoomEntry.perform(mesh: mesh, choice: choice, name: name, passcode: passcode, joinText: joinText) {
                        error = problem
                    } else {
                        next()
                    }
                }
            } label: { BusyLabel(title: choice == .create ? "Create room" : (choice == .join ? "Join room" : "Use Town Square"), busy: mesh.roomBusy).frame(maxWidth: .infinity) }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(mesh.roomBusy || !RoomOnboardingPicker.isReady(choice: choice, name: name, passcode: passcode, confirm: confirm, joinText: joinText))
            Button { showCodeJoin = true } label: {
                Label("Scan QR or type a room code", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            if choice != .open {
                Button("Use Town Square (open to everyone nearby) for now") { next() }
                    .font(.callout)
            }
        }
        .sheet(isPresented: $showCodeJoin, onDismiss: { if !mesh.activeRoom.isDefault { next() } }) {
            CodeJoinView().environmentObject(mesh)
        }
    }
}

/// Join, create or stay in Town Square (the open room). Returns an error line, or nil when done.
enum RoomEntry {
    @MainActor
    static func perform(mesh: MeshService, choice: RoomOnboardingPicker.Choice, name: String, passcode: String, joinText: String) async -> String? {
        switch choice {
        case .open:
            return nil
        case .create:
            guard await mesh.createRoom(name: name, passcode: passcode) != nil else {
                return "Could not create the room. Use a name and a passcode of at least \(RoomPasscode.minLength) characters."
            }
            return nil
        case .join:
            if !joinText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return mesh.joinRoom(joinText) ? nil : "That is not a Pasa room join string. Copy the whole PASA1... text."
            }
            if let beacon = mesh.nearbyRooms.first(where: { $0.beacon.label == Room.cleanLabel(name) })?.beacon {
                switch await mesh.joinNearby(beacon, passcode: passcode) {
                case .joined: return nil
                case .wrongPasscode: return "Wrong passcode for \(Room.displayName(forLabel: beacon.label)). Ask the room admin."
                case .failed: return "Could not join. Check the room name and passcode."
                }
            }
            return await mesh.joinRoom(name: name, passcode: passcode) == nil ? "Could not join. Check the room name and passcode." : nil
        }
    }
}

private struct TourStep: View {
    let next: () -> Void
    @State private var page = 0
    private let cards: [(String, String, String)] = [
        ("arrow.triangle.branch", "Messages hop phone to phone", "No signal needed. If a teammate is out of range, your message hops through the phones in between."),
        ("sparkles", "Start with @pasa to ask AI", "\"@pasa what are our rules?\" The AI runs on the team's Mac, offline, and cites your saved rules."),
        ("iphone.radiowaves.left.and.right", "Keep Pasa open to relay", "Your phone carries teammates' messages while Pasa is open. In the background, iOS pauses the links."),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            let card = cards[page]
            Image(systemName: card.0).font(.largeTitle).foregroundStyle(.tint).padding(.top, 30).accessibilityHidden(true)
            Text(card.1).font(.title.weight(.bold))
            Text(card.2).font(.title3).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(0..<cards.count, id: \.self) { i in
                    Circle().fill(i == page ? Color.accentColor : Color.gray.opacity(0.3)).frame(width: 8, height: 8)
                }
            }
            Button {
                if page < cards.count - 1 { page += 1 } else { next() }
            } label: { Text(page < cards.count - 1 ? "Next" : "Done").frame(maxWidth: .infinity) }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}

/// After onboarding: tap to send a first question.
struct StarterChips: View {
    @EnvironmentObject private var mesh: MeshService
    static let prompts = ["@pasa what are our rules?", "@pasa summary"]
    var body: some View {
        if mesh.showStarterChips && mesh.activeRoom.canSend {
            HStack(spacing: 8) {
                ForEach(StarterChips.prompts, id: \.self) { prompt in
                    Button(prompt) {
                        mesh.send(prompt)
                        mesh.hideStarterChips()
                    }
                    .buttonStyle(.bordered)
                    .font(.callout)
                    .frame(minHeight: 44)
                    .disabled(mesh.isAskPending(AssistantMention.strip(prompt) ?? prompt))
                    .accessibilityHint("Sends this question to the AI Mac")
                }
                Spacer()
                Button {
                    mesh.hideStarterChips()
                } label: { Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44) }
                .buttonStyle(.borderless)
                .accessibilityLabel("Hide suggestions")
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }
}

/// One-line reason before the first microphone or photo use.
struct PermissionPrimer {
    static let microphone = "Pasa uses the microphone only while you hold the mic button, to record a voice note for your room."
    static let photos = "Pick a photo to share with your room. Only the photo you pick is sent; the AI Mac can read it locally."
}
