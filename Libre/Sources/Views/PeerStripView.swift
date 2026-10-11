// PeerStripView.swift
// Horizontal list of nearby devices with their link state, shown by the person's chosen name.
// Peers that are offline and unseen for over 60 s are dropped by MeshService.

import SwiftUI

struct PeerStripView: View {
    @EnvironmentObject private var mesh: MeshService

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if mesh.peers.isEmpty {
                    Label {
                        Text("Teammates show up here when they open Libre nearby (Wi-Fi or Bluetooth).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "person.2.wave.2").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 360, alignment: .leading)
                }
                ForEach(mesh.peers) { peer in
                    PeerChip(peer: peer)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }
}

struct PeerChip: View {
    let peer: PeerInfo

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(peer.label)
                .font(.footnote)
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.gray.opacity(0.15), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(peer.label), \(label)")
    }

    private var label: String {
        if peer.isBlocked { return "blocked" }
        switch peer.state {
        case .connected: return "linked"
        case .connecting: return "connecting"
        case .discovered: return "nearby"
        case .disconnected: return "offline"
        }
    }

    private var color: Color {
        if peer.isBlocked { return .red }
        switch peer.state {
        case .connected: return .green
        case .connecting: return .yellow
        case .discovered: return .blue
        case .disconnected: return .gray
        }
    }
}
