// ConnectionSheet.swift
// Opened by tapping the chat title: who is nearby, which links are up, Pasa's status (the AI Mac,
// its model and queue, its internet state), rooms, and the forced relay demo toggles. All the
// detail that used to crowd the chat header lives here.

import SwiftUI

struct ConnectionSheet: View {
    @EnvironmentObject private var mesh: MeshService
    @Environment(\.dismiss) private var dismiss
    /// Round 2: link-layer counters are for debugging, hidden unless turned on here.
    @AppStorage("pasa.showDebugInfo") private var showDebug = false

    private var internet: InternetState? {
        mesh.isAIPeer ? mesh.internetState : mesh.aiDetail?.internet
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Libre AI") {
                    TintedLabel(text: StatusWords.aiWords(isAIPeer: mesh.isAIPeer, ai: mesh.aiAvailability),
                                symbol: "circle.fill",
                                tint: StatusWords.aiReady(isAIPeer: mesh.isAIPeer, ai: mesh.aiAvailability) ? .green : .gray,
                                font: .body)
                    if mesh.isAIPeer {
                        Text("Model: \(mesh.ollamaModel)")
                        Text(mesh.ollamaStatus).foregroundStyle(.secondary)
                    } else if let detail = mesh.aiDetail {
                        Text("AI Mac: \(mesh.label(for: detail.device))")
                        Text("Model: \(detail.model)")
                        if detail.queue > 0 { Text("Questions in line: \(detail.queue)") }
                    }
                    if let internet {
                        TintedLabel(text: internet.detailsLabel, symbol: internet == .offline ? "wifi.slash" : "wifi",
                                    tint: internet == .offline ? .green : .secondary, font: .body)
                    }
                }

                Section {
                    if mesh.peers.isEmpty {
                        Text("No one nearby yet. Teammates show up here when they open Libre nearby (Wi-Fi or Bluetooth).")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(mesh.peers) { peer in
                        HStack {
                            Circle().fill(color(peer)).frame(width: 10, height: 10).accessibilityHidden(true)
                            Text(peer.label)
                            Spacer()
                            Text(stateWord(peer)).foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 44)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(peer.label), \(stateWord(peer))")
                    }
                } header: {
                    Text("Devices")
                } footer: {
                    Text("\(mesh.connectedCount) linked directly. Messages hop through linked phones to reach the rest.")
                }

                if mesh.joinedRooms.count > 1 {
                    Section("Rooms") {
                        ForEach(mesh.joinedRooms) { room in
                            Button {
                                mesh.activateRoom(room.id)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(room.displayName)
                                        if let subtitle = room.subtitle {
                                            RoomSubtitle(text: subtitle)
                                        }
                                    }
                                    if room.isClosed { Text("closed").foregroundStyle(.secondary) }
                                    Spacer()
                                    if room.id == mesh.activeRoom.id { Image(systemName: "checkmark").accessibilityLabel("Current room") }
                                }
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section {
                    let known = Array(Set(mesh.peers.map(\.name)).union(mesh.blocked)).sorted()
                    if known.isEmpty { Text("No devices seen yet.").foregroundStyle(.secondary) }
                    ForEach(known, id: \.self) { name in
                        Toggle(isOn: Binding(
                            get: { mesh.blocked.contains(name) },
                            set: { mesh.setBlocked(name, $0) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Make messages hop through another phone")
                                Text("No direct link to \(mesh.label(for: name))")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(minHeight: 44)
                        .accessibilityLabel("Make messages hop through another phone. No direct link to \(mesh.label(for: name))")
                    }
                } header: {
                    Text("Demo: forced relay")
                } footer: {
                    Text("For showing the relay in a demo. When this is on, this phone and that device stop talking directly, so messages go through another phone in between. You need a third device nearby. Turn it off to go back to normal.")
                }

                Section {
                    Toggle("Show debug info", isOn: $showDebug)
                        .frame(minHeight: 44)
                    if showDebug {
                        Text("Link layer: \(mesh.discoveryRestarts) discovery restarts, \(mesh.discoveryRestartsCoalesced) folded or deferred")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(mesh.bluetoothSummary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(ChatTitle.roomName(mesh))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    private func stateWord(_ peer: PeerInfo) -> String {
        if peer.isBlocked { return "blocked" }
        switch peer.state {
        case .connected: return peer.viaBluetooth ? "linked via Bluetooth" : "linked"
        case .connecting: return "connecting"
        case .discovered: return "nearby"
        case .disconnected: return "offline"
        }
    }

    private func color(_ peer: PeerInfo) -> Color {
        if peer.isBlocked { return .red }
        switch peer.state {
        case .connected: return .green
        case .connecting: return .yellow
        case .discovered: return .blue
        case .disconnected: return .gray
        }
    }
}
