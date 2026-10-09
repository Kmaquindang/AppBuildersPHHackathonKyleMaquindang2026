// ContentView.swift
// Main screen: tabs for chat (peers, hop-path timeline, composer), tasks, rules and, on the Mac, the AI dashboard.

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var mesh: MeshService

    var body: some View {
        if mesh.onboardingDone {
            main
        } else {
            OnboardingFlow()
        }
    }

    private var main: some View {
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
                StarterChips()
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
                    .accessibilityHint("Name, room, AI and relay settings")
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(mesh)
            }
        }
    }
}

/// Two rows that wrap instead of truncating: who and which room, then the status in plain words.
/// Below them, one offline banner when messages are waiting for a teammate.
struct StatusHeader: View {
    @EnvironmentObject private var mesh: MeshService

    private var statusLine: String {
        StatusWords.line(linked: mesh.connectedCount, nearby: mesh.peers.count, isAIPeer: mesh.isAIPeer, ai: mesh.aiAvailability)
            + (mesh.aiAvailability == .awake && !mesh.isAIPeer ? internetWords : "")
    }

    /// The AI Mac's own internet state from its status beacon ("no internet" proves answers are local).
    private var internetWords: String {
        switch mesh.aiDetail?.internet {
        case .offline?: return ", no internet"
        case .connected?: return ", internet not used"
        default: return ""
        }
    }

    private var statusSymbol: String {
        mesh.connectedCount > 0 ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { nameText; RoomSwitcherChip(); Spacer(minLength: 0) }
                VStack(alignment: .leading, spacing: 4) { nameText; RoomSwitcherChip() }
            }
            Label {
                Text(statusLine)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: statusSymbol)
                    .foregroundStyle(mesh.connectedCount > 0 ? Color.green : Color.orange)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Status: \(statusLine.replacingOccurrences(of: " · ", with: ". "))")
            if let banner = StatusWords.offlineBanner(linked: mesh.connectedCount, queued: mesh.queuedMineCount) {
                Label {
                    Text(banner).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "clock").foregroundStyle(.orange)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityElement(children: .combine)
            }
            if let blocker = mesh.activeRoom.sendBlocker {
                notice(blocker, symbol: "lock", tint: .orange)
            }
            if let badge = mesh.forcedRelayBadge {
                notice(badge, symbol: "arrow.triangle.branch", tint: .orange)
            }
            if let problem = mesh.lastProblem {
                notice(problem, symbol: "exclamationmark.triangle.fill", tint: .red)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var nameText: some View {
        Text(mesh.personName.isEmpty ? "You are \(mesh.displayName)" : "You: \(mesh.personName)")
            .font(.headline)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(mesh.personName.isEmpty ? "You are \(mesh.displayName)" : "You are \(mesh.personName)")
    }

    /// Colored icon, text in the primary label color (colored text on white fails 4.5:1).
    private func notice(_ text: String, symbol: String, tint: Color) -> some View {
        Label {
            Text(text).font(.footnote).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Header chip: active room with member count and cap; tap to switch rooms quickly.
struct RoomSwitcherChip: View {
    @EnvironmentObject private var mesh: MeshService

    private var title: String {
        let name = mesh.activeRoom.isDefault ? "Default room" : "Room \(mesh.activeRoom.label)"
        if let count = mesh.roomCountText { return "\(name) \(count)" }
        return name
    }

    var body: some View {
        Menu {
            ForEach(mesh.joinedRooms) { room in
                Button {
                    mesh.activateRoom(room.id)
                } label: {
                    if room.id == mesh.activeRoom.id {
                        Label(room.displayName, systemImage: "checkmark")
                    } else {
                        Text(room.isClosed ? "\(room.displayName) (closed)" : room.displayName)
                    }
                }
            }
        } label: {
            Label(title, systemImage: "person.3")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(minHeight: 44)
                .background((mesh.activeRoom.isDefault ? Color.gray : (mesh.activeRoom.canSend ? Color.green : Color.orange)).opacity(0.2), in: Capsule())
                .fixedSize(horizontal: false, vertical: true)
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
        .accessibilityLabel("Room: \(title)")
        .accessibilityHint("Opens the list of your rooms to switch")
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
                TintedLabel(text: roomError, symbol: "exclamationmark.triangle.fill", tint: .red)
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
                    if let beacon = mesh.nearbyRooms.first(where: { $0.beacon.label == Room.cleanLabel(roomName) })?.beacon {
                        switch await mesh.joinNearby(beacon, passcode: passcode) {
                        case .joined: break
                        case .wrongPasscode:
                            roomError = "Wrong passcode for \(beacon.label). Ask the room admin."
                            return
                        case .failed:
                            roomError = "Could not join. Check the room name and passcode."
                            return
                        }
                    } else if await mesh.joinRoom(name: roomName, passcode: passcode) == nil {
                        roomError = "Could not join. Check the room name and passcode."
                        return
                    }
                }
            }
            mesh.setPersonName(draft)
        }
    }
}
