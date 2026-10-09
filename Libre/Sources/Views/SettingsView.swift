// SettingsView.swift
// Device name, AI peer role (Mac only), and the forced-relay block list.

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var mesh: MeshService
    @Environment(\.dismiss) private var dismiss
    @State private var nameDraft = ""
    @State private var manualBlock = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Display name", text: $nameDraft)
                    Button("Save name") {
                        mesh.rename(to: nameDraft)
                        nameDraft = mesh.displayName
                    }
                    .disabled(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || nameDraft == mesh.displayName)
                } header: {
                    Text("This device")
                } footer: {
                    Text("Use a unique name per device, for example iPhone 12, iPhone 14 Pro Max, MacBook Air. Saving restarts the mesh link.")
                }

                #if os(macOS)
                Section {
                    Toggle("Act as AI peer (answer Ask AI messages)", isOn: Binding(
                        get: { mesh.isAIPeer },
                        set: { mesh.setAIPeer($0) }
                    ))
                    LabeledContent("Responder", value: mesh.aiResponderName)
                } header: {
                    Text("AI peer")
                } footer: {
                    Text("Milestone 1 echoes the question back. Milestone 2 answers with a local model through Ollama.")
                }
                #endif

                Section {
                    if knownPeers.isEmpty {
                        Text("No peers seen yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(knownPeers, id: \.self) { name in
                        Toggle("Block direct link to \(name)", isOn: Binding(
                            get: { mesh.blocked.contains(name) },
                            set: { mesh.setBlocked(name, $0) }
                        ))
                    }
                    HStack {
                        TextField("Block by name", text: $manualBlock)
                        Button("Add") {
                            mesh.setBlocked(manualBlock, true)
                            manualBlock = ""
                        }
                        .disabled(manualBlock.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } header: {
                    Text("Forced relay demo")
                } footer: {
                    Text("A blocked peer cannot link to this device directly, so messages must hop through another device. Example: on iPhone 12 block MacBook Air, then the path becomes iPhone 12 -> iPhone 14 Pro Max -> MacBook Air. Unblocking a peer that is already linked takes effect right away; blocking one that is already linked stops all traffic with it, and the link fully drops the next time it reconnects.")
                }

                Section {
                    LabeledContent("Linked peers", value: "\(mesh.connectedCount)")
                    LabeledContent("Messages relayed", value: "\(mesh.relayedCount)")
                    LabeledContent("Queued in outbox", value: "\(mesh.outboxCount)")
                    Button("Clear timeline", role: .destructive) {
                        mesh.clearTimeline()
                    }
                } header: {
                    Text("Stats")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { nameDraft = mesh.displayName }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 520)
        #endif
    }

    private var knownPeers: [String] {
        mesh.peers.map { $0.name }
    }
}
