// ContentView.swift
// Main screen: tabs for chat (peers, hop-path timeline, composer), tasks, rules and, on the Mac, the AI dashboard.

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var mesh: MeshService

    var body: some View {
        tabs
            .sheet(isPresented: Binding(get: { mesh.needsPersonName }, set: { _ in })) {
                NameOnboardingView()
                    .environmentObject(mesh)
                    .interactiveDismissDisabled()
            }
    }

    private var tabs: some View {
        TabView {
            ChatScreen()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
            TasksView()
                .tabItem { Label("Tasks", systemImage: "checklist") }
            RulesView()
                .tabItem { Label("Rules", systemImage: "book.closed") }
            #if os(macOS)
            AssistantDashboardView()
                .tabItem { Label("Assistant", systemImage: "cpu") }
            #endif
        }
    }
}

/// Peers, timeline and composer, with the settings sheet.
struct ChatScreen: View {
    @EnvironmentObject private var mesh: MeshService
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                StatusHeader()
                PeerStripView()
                Divider()
                ChatTimelineView()
                Divider()
                ComposerView()
            }
            .navigationTitle("Pasa")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(mesh)
            }
        }
    }
}

/// "You are: iPhone 12 | 2 connected | AI peer" plus the latest problem, if any.
struct StatusHeader: View {
    @EnvironmentObject private var mesh: MeshService

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.tint)
                Text("You are \(mesh.displayName)")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(mesh.activeRoom.isDefault ? "Default room" : "Room \(mesh.activeRoom.label)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background((mesh.activeRoom.isDefault ? Color.gray : Color.green).opacity(0.2), in: Capsule())
                    .lineLimit(1)
                if mesh.isAIPeer {
                    Text("AI peer")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.purple.opacity(0.2), in: Capsule())
                }
                Spacer()
                Text("\(mesh.connectedCount) linked")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if mesh.outboxCount > 0 {
                    Text("\(mesh.outboxCount) queued")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if let badge = mesh.forcedRelayBadge {
                Label(badge, systemImage: "arrow.triangle.branch")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.15), in: Capsule())
                    .lineLimit(1)
                    .accessibilityLabel(badge)
            }
            if let problem = mesh.lastProblem {
                Text(problem)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

/// First launch: ask for the name everyone will see ("Kyle", "Ana") and pick a room.
struct NameOnboardingView: View {
    @EnvironmentObject private var mesh: MeshService
    @State private var draft = ""
    @State private var roomChoice: RoomOnboardingPicker.Choice = .open
    @State private var roomName = ""
    @State private var passcode = ""
    @State private var confirm = ""
    @State private var joinText = ""
    @State private var roomError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to Pasa")
                .font(.title2.weight(.bold))
            Text("What should your team call you? Your name shows on your messages, and \"@pasa remind \(draft.isEmpty ? "Ana" : draft) ...\" sends tasks to this device.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Your name, for example Kyle", text: $draft)
                .textFieldStyle(.roundedBorder)
            RoomOnboardingPicker(choice: $roomChoice, name: $roomName, passcode: $passcode, confirm: $confirm, joinText: $joinText)
            if let roomError {
                Text(roomError).font(.caption).foregroundStyle(.red)
            }
            Button(action: save) {
                BusyLabel(title: "Continue", busy: mesh.roomBusy)
            }
            .buttonStyle(.borderedProminent)
            .disabled(mesh.roomBusy || PeopleDirectory.clean(draft).isEmpty
                      || !RoomOnboardingPicker.isReady(choice: roomChoice, name: roomName, passcode: passcode, confirm: confirm, joinText: joinText))
            Text("Device id: \(mesh.displayName). You can change your name and room later in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        #if os(macOS)
        .frame(width: 420)
        #endif
    }

    private func save() {
        guard !PeopleDirectory.clean(draft).isEmpty, !mesh.roomBusy else { return }
        roomError = nil
        Task {
            switch roomChoice {
            case .open:
                break
            case .create:
                guard await mesh.createRoom(name: roomName, passcode: passcode) != nil else {
                    roomError = "Could not create the room. Use a name and a passcode of at least \(RoomPasscode.minLength) characters."
                    return
                }
            case .join:
                if !joinText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    guard mesh.joinRoom(joinText) else {
                        roomError = "That is not a Pasa room join string. Copy the whole PASA1... text."
                        return
                    }
                } else {
                    guard await mesh.joinRoom(name: roomName, passcode: passcode) != nil else {
                        roomError = "Could not join. Check the room name and passcode."
                        return
                    }
                }
            }
            mesh.setPersonName(draft)
        }
    }
}
