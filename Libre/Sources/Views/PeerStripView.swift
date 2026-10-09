// PeerStripView.swift
// Horizontal list of nearby devices with their link state.

import SwiftUI

struct PeerStripView: View {
    @EnvironmentObject private var mesh: MeshService

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if mesh.peers.isEmpty {
                    Text("Looking for nearby devices...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            Text(peer.name)
                .font(.caption)
                .lineLimit(1)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.gray.opacity(0.15), in: Capsule())
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
