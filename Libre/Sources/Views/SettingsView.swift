// SettingsView.swift
// Device name, AI peer settings (Mac only: engine, model, admins, roster), and the forced-relay block list.

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var mesh: MeshService
    @Environment(\.dismiss) private var dismiss
    @State private var nameDraft = ""
    @State private var manualBlock = ""
    @State private var engineDraft: AIEngine = .assistant
    @State private var modelDraft = ""
    @State private var fallbackDraft = ""
    @State private var adminsDraft = ""
    @State private var rosterDraft = ""
    @State private var confirmReset = false

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
                    Picker("Engine", selection: $engineDraft) {
                        ForEach(AIEngine.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    TextField("Ollama model", text: $modelDraft)
                    TextField("Fallback model (if the first is not installed)", text: $fallbackDraft)
                    TextField("Admin devices, comma separated", text: $adminsDraft)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Team roster (one per line: Ana = iPhone 12)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $rosterDraft)
                            .font(.body.monospaced())
                            .frame(minHeight: 70)
                    }
                    HStack {
                        Button("Save AI settings") {
                            mesh.updateAssistantSettings(engine: engineDraft, model: modelDraft, fallback: fallbackDraft, admins: adminsDraft, rosterText: rosterDraft)
                        }
                        Button("Check Ollama") { mesh.checkOllama() }
                    }
                    Text(mesh.ollamaStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button("Reset team memory...", role: .destructive) {
                        confirmReset = true
                    }
                } header: {
                    Text("AI peer")
                } footer: {
                    Text("Runs on this Mac through Ollama at 127.0.0.1:11434. No internet needed after the model is downloaded (ollama pull \(OllamaClient.defaultModel)). This Mac is always an admin.")
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
            .onAppear {
                nameDraft = mesh.displayName
                engineDraft = mesh.aiEngine
                modelDraft = mesh.ollamaModel
                fallbackDraft = mesh.ollamaFallbackModel
                adminsDraft = mesh.adminNames.joined(separator: ", ")
                rosterDraft = mesh.rosterText
            }
            #if os(macOS)
            .confirmationDialog("Erase all tasks, notes, rules and the chat log on this Mac?", isPresented: $confirmReset) {
                Button("Erase team memory", role: .destructive) { mesh.resetMemory() }
            }
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 640)
        #endif
    }

    private var knownPeers: [String] {
        mesh.peers.map { $0.name }
    }
}
