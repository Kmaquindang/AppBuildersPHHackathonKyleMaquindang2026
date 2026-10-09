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
            .sheet(item: $mesh.joinPrefill) { prefill in
                CodeJoinView(room: prefill.room)
                    .environmentObject(mesh)
                    #if os(macOS)
                    .frame(minWidth: 460, minHeight: 420)
                    #endif
            }
    }

    #if os(macOS)
    /// Mac: a native sidebar (Apple HIG) instead of segmented tabs in the title bar, so the room
    /// title, status and tabs never crowd each other. Three places: Chat, Tasks, Knowledge.
    /// The old Assistant tab (AI activity, proof, Ollama) lives in Settings, Advanced.
    @State private var section: MacSection? = .chat

    private var tabs: some View {
        NavigationSplitView {
            List(MacSection.allCases, selection: $section) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 230)
        } detail: {
            switch section ?? .chat {
            case .chat: ChatScreen()
            case .tasks: TasksView()
            case .knowledge: KnowledgeTab()
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .task { await SnapshotRunner.run { section = $0 } }
    }
    #else
    @State private var tab = 0

    private var tabs: some View {
        TabView(selection: $tab) {
            ChatScreen()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                .tag(0)
            TasksView()
                .tabItem { Label("Tasks", systemImage: "checklist") }
                .tag(1)
            KnowledgeTab()
                .tabItem { Label("Knowledge", systemImage: "books.vertical") }
                .tag(2)
        }
        .task { await SnapshotRunner.run { tab = $0 } }
    }
    #endif
}

#if os(macOS)
enum MacSection: String, CaseIterable, Identifiable, Hashable {
    case chat, tasks, knowledge
    var id: String { rawValue }
    var title: String {
        switch self {
        case .chat: return "Chat"
        case .tasks: return "Tasks"
        case .knowledge: return "Knowledge"
        }
    }
    var symbol: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .tasks: return "checklist"
        case .knowledge: return "books.vertical"
        }
    }
}
#endif

/// One Knowledge place: the room's rules first, then its documents (Kyle, Oct 9 11:03 PM).
struct KnowledgeTab: View {
    @EnvironmentObject private var mesh: MeshService
    var body: some View {
        #if os(macOS)
        if mesh.isAIPeer {
            KnowledgeView(knowledge: mesh.knowledge)
        } else {
            RulesView()
        }
        #else
        RulesView()
        #endif
    }
}

/// Timeline and composer under an iMessage-style title (room name, AI dot, one short subtitle).
/// Tapping the title opens the connection sheet: devices, links, AI status, internet state,
/// forced relay. Your own name lives in Settings, not in the header.
/// Round 2 (Kyle's 8:55 PM screenshot: old bubbles showed through the title and gear): on iPhone
/// the top bar is our own frosted `.bar` strip in the top safe area inset, and the composer sits
/// in the bottom inset, so messages scroll under both and the timeline's content insets keep the
/// first and last bubble clear of them. Text never sits on top of text.
struct ChatScreen: View {
    @EnvironmentObject private var mesh: MeshService
    @State private var showSettings = false
    @State private var showConnection = false

    var body: some View {
        NavigationStack {
            content
                .sheet(isPresented: $showSettings) {
                    SettingsView()
                        .environmentObject(mesh)
                }
                .sheet(isPresented: $showConnection) {
                    ConnectionSheet()
                        .environmentObject(mesh)
                }
                .onReceive(NotificationCenter.default.publisher(for: .pasaSnapshotSettings)) { _ in showSettings = true }
        }
    }

    @ViewBuilder
    private var content: some View {
        #if os(iOS)
        ChatTimelineView()
            .safeAreaInset(edge: .top, spacing: 0) { topBar }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ComposerView()
                    .background(.bar)
                    .overlay(alignment: .top) { Divider() }
            }
            .toolbar(.hidden, for: .navigationBar)
        #else
        VStack(spacing: 0) {
            ChatNotices()
            ChatTimelineView()
            ComposerView()
        }
        // Native title and subtitle: one status line in words, no pill, no misleading dot.
        .navigationTitle(ChatTitle.roomName(mesh))
        .navigationSubtitle(ChatTitle.statusLine(mesh))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showConnection = true } label: {
                    Label("Nearby devices", systemImage: "antenna.radiowaves.left.and.right")
                }
                .help("Nearby devices, links and AI status")
            }
            ToolbarItem(placement: .primaryAction) { settingsButton }
        }
        #endif
    }

    #if os(iOS)
    /// Frosted top bar: an invisible 44 pt spacer, the centered title, the gear. The title takes
    /// the space between them and wraps at large text sizes instead of sliding under the gear.
    private var topBar: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 4) {
                Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
                ChatTitle(onTap: { showConnection = true })
                    .frame(maxWidth: .infinity)
                settingsButton
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            ChatNotices()
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
    #endif

    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            Label("Settings", systemImage: "gearshape")
        }
        .accessibilityHint("Name, room, AI and relay settings")
    }
}

/// Room name, then one status line led by the link dot (gray searching, amber connecting, green connected).
struct ChatTitle: View {
    @EnvironmentObject private var mesh: MeshService
    var onTap: () -> Void

    static func roomName(_ mesh: MeshService) -> String {
        mesh.activeRoom.displayName
    }

    private var ready: Bool { StatusWords.aiReady(isAIPeer: mesh.isAIPeer, ai: mesh.aiAvailability) }
    private var dot: LinkDot { StatusWords.linkDot(linked: mesh.connectedCount, nearby: mesh.peers.count) }

    static func dotColor(_ dot: LinkDot) -> Color {
        switch dot {
        case .searching: return .gray
        case .connecting: return .orange
        case .connected: return .green
        }
    }

    /// Mac subtitle: the link state first, in words ("Connecting..." never comes with green).
    static func statusLine(_ mesh: MeshService) -> String {
        let linked = mesh.peers.filter { $0.state == .connected && !$0.isBlocked }
        let aiMac = mesh.aiDetail.map { mesh.label(for: $0.device) }
        let words = StatusWords.subtitle(linked: mesh.connectedCount, nearby: mesh.peers.count, isAIPeer: mesh.isAIPeer,
                                         ai: mesh.aiAvailability, aiMac: aiMac, firstPeer: linked.first?.label)
        if mesh.connectedCount == 0 && mesh.peers.isEmpty { return "Looking for nearby devices. No signal needed." }
        return words
    }

    private var subtitle: String {
        let linked = mesh.peers.filter { $0.state == .connected && !$0.isBlocked }
        let aiMac = mesh.aiDetail.map { mesh.label(for: $0.device) }
        return StatusWords.subtitle(linked: mesh.connectedCount, nearby: mesh.peers.count, isAIPeer: mesh.isAIPeer,
                                    ai: mesh.aiAvailability, aiMac: aiMac, firstPeer: linked.first?.label)
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 1) {
                Text(ChatTitle.roomName(mesh))
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                // One status indicator: the dot belongs to the status line (gray searching,
                // amber connecting, green connected), and both wrap at large text.
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Circle()
                        .fill(ChatTitle.dotColor(dot))
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(ChatTitle.roomName(mesh)). \(dot.spoken). \(subtitle). \(ready ? "\(AppBrand.name) can answer now" : "\(AppBrand.name) AI is not available right now")")
        .accessibilityHint("Shows devices, links and AI status")
        .accessibilityAddTraits(.isButton)
    }
}

/// Only what needs attention, under the title: queued messages with nobody nearby, a room you
/// cannot send in, forced relay mode, and the last problem.
struct ChatNotices: View {
    @EnvironmentObject private var mesh: MeshService

    var body: some View {
        let banner = StatusWords.offlineBanner(linked: mesh.connectedCount, queued: mesh.queuedMineCount)
        let items: [(String, String, Color)] = [
            banner.map { ($0, "clock", Color.orange) },
            mesh.activeRoom.sendBlocker.map { ($0, "lock", Color.orange) },
            mesh.forcedRelayBadge.map { ($0, "arrow.triangle.branch", Color.orange) },
            mesh.aiNotice.map { ($0, "desktopcomputer", Color.orange) },
            mesh.lastProblem.map { ($0, "exclamationmark.triangle.fill", Color.red) }
        ].compactMap { $0 }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items, id: \.0) { item in
                    TintedLabel(text: item.0, symbol: item.1, tint: item.2, font: .footnote)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.10))
        }
    }
}

/// Header chip: active room with member count and cap; tap to switch rooms quickly.
struct RoomSwitcherChip: View {
    @EnvironmentObject private var mesh: MeshService

    private var title: String {
        let name = mesh.activeRoom.isDefault ? Room.townSquareName : "Room \(mesh.activeRoom.label)"
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
                    // Menus show a second line as the subtitle (Town Square only).
                    if let subtitle = room.subtitle { Text(subtitle) }
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
            Text("Welcome to Libre")
                .font(.title2.weight(.bold))
            Text("What should your team call you? Your name shows on your messages, and \"@libre remind \(draft.isEmpty ? "Ana" : draft) ...\" sends tasks to this device.")
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
                        roomError = "That is not a Libre room join string. Copy the whole PASA1... text."
                        return
                    }
                } else {
                    if let beacon = mesh.nearbyRooms.first(where: { $0.beacon.label == Room.cleanLabel(roomName) })?.beacon {
                        switch await mesh.joinNearby(beacon, passcode: passcode) {
                        case .joined: break
                        case .wrongPasscode:
                            roomError = "Wrong passcode for \(Room.displayName(forLabel: beacon.label)). Ask the room admin."
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
