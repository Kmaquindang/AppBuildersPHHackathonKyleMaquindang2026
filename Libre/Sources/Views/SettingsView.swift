// SettingsView.swift
// Device name, AI peer settings (Mac only: engine, model, admins, roster), and the forced-relay block list.

import SwiftUI
import UniformTypeIdentifiers

/// Team memory backup file for the Mac's Export and Import buttons.
struct MemoryBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var mesh: MeshService
    @Environment(\.dismiss) private var dismiss
    @State private var nameDraft = ""
    @State private var personDraft = ""
    @State private var manualBlock = ""
    @State private var engineDraft: AIEngine = .assistant
    @State private var modelDraft = ""
    @State private var fallbackDraft = ""
    @State private var rosterDraft = ""
    @State private var confirmReset = false
    @State private var exportDoc: MemoryBackupDocument?
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var pendingImport: Data?
    @State private var backupMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Your name", text: $personDraft)
                    Button("Save your name") {
                        mesh.setPersonName(personDraft)
                        personDraft = mesh.personName
                    }
                    .disabled(PeopleDirectory.clean(personDraft).isEmpty || PeopleDirectory.clean(personDraft) == mesh.personName)
                } header: {
                    Text("You")
                } footer: {
                    Text("Shown on your messages. \"@pasa remind \(mesh.personName.isEmpty ? "Ana" : mesh.personName) ...\" sends tasks to this device. Pick a name nobody else on the team uses.")
                }

                Section {
                    TextField("Device id", text: $nameDraft)
                    Button("Save device id") {
                        mesh.rename(to: nameDraft)
                        nameDraft = mesh.displayName
                    }
                    .disabled(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || nameDraft == mesh.displayName)
                } header: {
                    Text("This device")
                } footer: {
                    Text("The mesh address of this device. It must be unique, and it stays the same unless you change it here. Saving restarts the mesh link. Admin rights belong to the device id, never to a name.")
                }

                RoomSettingsSection()

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
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Roster override, optional (one per line: Ana = iPhone 12). Names people pick on their phones work without it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $rosterDraft)
                            .font(.body.monospaced())
                            .frame(minHeight: 70)
                    }
                    HStack {
                        Button("Save AI settings") {
                            mesh.updateAssistantSettings(engine: engineDraft, model: modelDraft, fallback: fallbackDraft, rosterText: rosterDraft)
                        }
                        Button("Check Ollama") { mesh.checkOllama() }
                    }
                    Text(mesh.ollamaStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Picker("Voice note transcripts", selection: Binding(get: { mesh.speechLocale }, set: { mesh.setSpeechLocale($0) })) {
                        ForEach(VoiceTranscriber.choices, id: \.id) { choice in
                            Text(choice.label).tag(choice.id)
                        }
                    }
                    Text("Transcripts use Apple's on-device speech recognition only (audio never leaves this Mac). If Filipino has no on-device model here, English (US) is used and the transcript says so.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Export \(mesh.activeRoom.label) memory...") {
                            do {
                                exportDoc = MemoryBackupDocument(data: try mesh.exportMemoryData())
                                showExporter = true
                            } catch {
                                backupMessage = "Export failed: \(error.localizedDescription)"
                            }
                        }
                        Button("Import into \(mesh.activeRoom.label)...") { showImporter = true }
                    }
                    if let backupMessage {
                        Text(backupMessage).font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Reset team memory...", role: .destructive) {
                        confirmReset = true
                    }
                } header: {
                    Text("AI peer")
                } footer: {
                    Text("Runs on this Mac through Ollama at 127.0.0.1:11434. No internet needed after the model is downloaded (ollama pull \(OllamaClient.defaultModel)). Macs with less than 12 GB of memory default to \(OllamaClient.lowMemoryModel) (this Mac has \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB). While this Mac is the AI peer it does not idle-sleep and keeps the model warm; keep the lid open and the charger in.")
                }

                Section {
                    LabeledContent("This Mac (\(mesh.label(for: mesh.displayName)))", value: "always admin")
                    if !mesh.activeRoom.creator.isEmpty && mesh.activeRoom.creator != mesh.displayName {
                        LabeledContent("Room creator (\(adminLabel(mesh.activeRoom.creator)))", value: "pinned admin")
                    }
                    if mesh.adminCandidates.isEmpty {
                        Text("No other devices seen yet. Open Pasa on a phone nearby, then come back here.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(mesh.adminCandidates.filter { $0 != mesh.activeRoom.creator }, id: \.self) { device in
                        Toggle(adminLabel(device), isOn: Binding(
                            get: { mesh.adminDevices.contains(device) },
                            set: { mesh.setAdmin(device, $0) }
                        ))
                    }
                } header: {
                    Text("Admins for \(mesh.activeRoom.displayName)")
                } footer: {
                    Text("Admins can edit, lock, unlock and delete rules in this room. Each room has its own admins, and its creator is always one. Tick devices, not names: anyone can change their display name, so a name never grants admin.")
                }
                #endif

                Section {
                    if knownPeers.isEmpty {
                        Text("No peers seen yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(knownPeers, id: \.self) { name in
                        Toggle("Block direct link to \(mesh.label(for: name))\(mesh.label(for: name) == name ? "" : " (\(name))")", isOn: Binding(
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
                    Text("A blocked peer cannot link to this device directly, so messages must hop through another device. Example: on Ana's phone block Site Office (and on Site Office block Ana's phone), then the path becomes Ana -> Kyle -> Site Office. Blocking a peer that is already linked ends that link (if it lingers, all links restart once and re-form in a few seconds). The chat header shows \"Forced relay mode\" while any block is on.")
                }

                Section {
                    LabeledContent("Linked peers", value: "\(mesh.connectedCount)")
                    LabeledContent("Messages relayed", value: "\(mesh.relayedCount)")
                    LabeledContent("Queued in outbox", value: "\(mesh.outboxCount)")
                    Button(clearLabel, role: .destructive) {
                        mesh.clearTimeline()
                    }
                } header: {
                    Text("Stats")
                } footer: {
                    Text(clearFooter)
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
                personDraft = mesh.personName
                engineDraft = mesh.aiEngine
                modelDraft = mesh.ollamaModel
                fallbackDraft = mesh.ollamaFallbackModel
                rosterDraft = mesh.rosterText
            }
            #if os(macOS)
            .confirmationDialog("Erase all tasks, notes, rules and the chat log of \(mesh.activeRoom.displayName) on this Mac?", isPresented: $confirmReset) {
                Button("Erase team memory", role: .destructive) { mesh.resetMemory() }
            }
            .fileExporter(isPresented: $showExporter, document: exportDoc, contentType: .json,
                          defaultFilename: "pasa-\(mesh.activeRoom.label.lowercased())-memory-\(Date().formatted(.iso8601.year().month().day())).json") { result in
                switch result {
                case .success(let url): backupMessage = "Saved \(url.lastPathComponent)."
                case .failure(let error): backupMessage = "Export failed: \(error.localizedDescription)"
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url):
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let data = try Data(contentsOf: url)
                        _ = try OrgMemory.decodeBackup(data)   // check it is Pasa team memory before asking
                        pendingImport = data
                    } catch {
                        backupMessage = "That file is not a Pasa team memory backup."
                    }
                case .failure(let error):
                    backupMessage = "Import failed: \(error.localizedDescription)"
                }
            }
            .confirmationDialog("Replace the team memory of \(mesh.activeRoom.displayName) with the backup? Its current rules, tasks, notes and chat log are replaced. Other rooms are not touched.",
                                isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } })) {
                Button("Replace team memory", role: .destructive) {
                    if let data = pendingImport {
                        do {
                            try mesh.importMemory(data)
                            backupMessage = "Imported. Linked phones were updated."
                        } catch {
                            backupMessage = "Import failed: \(error.localizedDescription)"
                        }
                    }
                    pendingImport = nil
                }
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

    private func adminLabel(_ device: String) -> String {
        let name = mesh.label(for: device)
        return name == device ? device : "\(name) (\(device))"
    }

    private var clearLabel: String {
        mesh.isAIPeer ? "Clear timeline for the whole team" : "Clear timeline"
    }

    private var clearFooter: String {
        if mesh.isAIPeer {
            return "Clears the chat on this Mac and on every phone (linked phones now, the rest when they next link). Old messages do not come back, and \"what did I miss\" ignores them."
        }
        return "Clears the chat on this device. Old messages do not come back from the AI Mac."
    }
}
