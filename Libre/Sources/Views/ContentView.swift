// ContentView.swift
// Main screen: who you are, nearby peers, the timeline with hop paths, and the composer.

import SwiftUI

struct ContentView: View {
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
            .navigationTitle("Libre")
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
