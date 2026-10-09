// MeshService.swift
// Pasa: glue between the link layer (MeshTransport), our relay layer (RelayEngine), team memory
// (OrgMemory), the AI peer (ExecutiveAssistant / AIResponder) and the SwiftUI views.
// Everything here runs on the main actor.
//
// Identity: `displayName` is the device id used as the mesh address (MCPeerID), saved on first
// launch and stable. `personName` is the name the person picked ("Kyle"); it rides on every
// message as `senderName` and is what the UI shows. `directory` maps device id -> person name.
//
// Persistence: the timeline and outbox are saved to Application Support (timeline.json) and
// reloaded on launch. Phones ask the AI Mac to backfill what they missed whenever a link comes up.
//
// Admins are device ids ticked in the Mac's Settings (plus the Mac itself). A display name never
// grants admin, because anyone can type any name.

import Foundation
import SwiftUI

/// Which brain the Mac AI peer uses.
enum AIEngine: String, CaseIterable, Identifiable {
    case assistant = "Executive assistant"
    case plain = "Plain model"
    case echo = "Echo stub"
    var id: String { rawValue }
}

struct PeerInfo: Identifiable, Equatable {
    /// Device id (mesh address).
    var name: String
    /// What the UI shows: the person's chosen name when known, else the device id.
    var label: String
    var state: PeerLinkState
    var isBlocked: Bool
    var id: String { name }
}

/// One AI peer request, for the Mac dashboard.
struct AssistantLogEntry: Identifiable, Equatable {
    let id: UUID
    var at: Date
    var asker: String
    var question: String
    var askHops: Int
    var intent: String
    var reply: String
    var model: String?
    var latencyMs: Int
    var tokensPerSecond: Double?
    var compact: Bool
    var error: String?
}

@MainActor
final class MeshService: ObservableObject {
    // MARK: Published state

    @Published private(set) var displayName: String
    @Published private(set) var blocked: Set<String>
    @Published private(set) var isAIPeer: Bool
    @Published private(set) var peerStates: [String: PeerLinkState] = [:]
    @Published private(set) var entries: [ChatEntry] = [] {
        didSet { scheduleSave() }
    }
    @Published private(set) var outboxCount = 0
    /// The person's chosen display name. Empty until they pick one (first-launch prompt).
    @Published private(set) var personName: String
    /// Device id -> chosen display name, learned from messages and saved.
    @Published private(set) var directory: [String: String]
    @Published private(set) var relayedCount = 0
    @Published private(set) var lastProblem: String?
    /// Asks this device sent that have had no answer for 20 s or more.
    @Published private(set) var waitingAsks: Set<UUID> = []
    /// "Clear timeline" watermark: nothing older comes back through backfill or catch-ups.
    @Published private(set) var clearedAt: Date?

    /// Team memory: source of truth on the AI Mac, read-only cache on phones.
    @Published private(set) var org: OrgSnapshot

    // AI peer settings and dashboard (used on macOS; harmless defaults elsewhere).
    @Published private(set) var aiEngine: AIEngine
    @Published private(set) var ollamaModel: String
    @Published private(set) var ollamaFallbackModel: String
    /// Admin device ids chosen on the Mac (the Mac itself is always an admin too).
    @Published private(set) var adminDevices: [String]
    @Published private(set) var roster: [String: String]
    @Published private(set) var assistantLog: [AssistantLogEntry] = []
    @Published private(set) var ollamaStatus = "Not checked yet"
    @Published private(set) var modelWarm = false

    // MARK: Internals

    private let engine: RelayEngine
    private var transport: MeshTransport?
    private var sentAsks: [UUID: Date] = [:]
    private var lastSeen: [String: Date] = [:]
    private var housekeeping: Timer?
    private var savePending = false
    private var lastBackfillRequest = Date.distantPast
    /// Phones: when this device last went away (app in the background or every link lost).
    /// Sent with asks so "what did I miss" covers only what came after.
    private var awaySince: Date?
    private var isAway = false
    private let timelineURL: URL?
    private let timelineLimit: Int
    private let saveQueue = DispatchQueue(label: "pasa.timeline.save", qos: .utility)
    private let defaults = UserDefaults.standard
    private let memory: OrgMemory
    #if os(macOS)
    private let assistant: ExecutiveAssistant
    /// Keeps the Mac from idle-sleeping and App Nap from throttling timers while it is the AI peer.
    private var awakeActivity: NSObjectProtocol?
    private var ollamaTimer: Timer?
    private var ollamaBusy = false
    private var lastWarm: Date?
    #endif

    private enum Keys {
        // Keys keep the working name "libre." so settings saved before the rename to Pasa survive.
        static let name = "libre.displayName"
        static let blocked = "libre.blocked"
        static let aiPeer = "libre.isAIPeer"
        static let engine = "libre.aiEngine"
        static let model = "libre.ollamaModel"
        static let fallback = "libre.ollamaFallbackModel"
        static let legacyAdmins = "libre.adminNames"   // old "device ids or names" text field
        static let admins = "pasa.adminDevices"        // device ids only
        static let clearedAt = "pasa.clearedAt"
        static let awaySince = "pasa.awaySince"
        static let roster = "libre.roster"
        static let personName = "pasa.personName"
        static let directory = "pasa.directory"
    }

    /// Peers that are not linked and have not been seen for this long leave the peer strip.
    static let stalePeerAfter: TimeInterval = 60

    init() {
        let store = UserDefaults.standard
        let name = MeshTransport.sanitize(store.string(forKey: Keys.name) ?? MeshService.defaultDeviceName())
        let storedBlocked = store.stringArray(forKey: Keys.blocked) ?? []

        #if os(macOS)
        let ai = store.object(forKey: Keys.aiPeer) as? Bool ?? true
        #else
        let ai = false
        #endif

        let engineChoice = AIEngine(rawValue: store.string(forKey: Keys.engine) ?? "") ?? .assistant
        let model = store.string(forKey: Keys.model) ?? OllamaClient.defaultModel
        let fallback = store.string(forKey: Keys.fallback) ?? OllamaClient.defaultFallbackModel
        let rosterMap = (store.dictionary(forKey: Keys.roster) as? [String: String]) ?? [:]
        let person = PeopleDirectory.clean(store.string(forKey: Keys.personName) ?? "")
        var dir = (store.dictionary(forKey: Keys.directory) as? [String: String]) ?? [:]
        if !person.isEmpty { dir[name] = person }
        let admins: [String]
        if let stored = store.stringArray(forKey: Keys.admins) {
            admins = stored
        } else {
            // One-time migration: keep old entries only if they are a known device id.
            admins = AdminPolicy.migrate(legacy: store.stringArray(forKey: Keys.legacyAdmins) ?? [], knownDevices: Set(dir.keys))
            store.set(admins, forKey: Keys.admins)
        }
        let cleared = store.object(forKey: Keys.clearedAt) as? Date
        let away = store.object(forKey: Keys.awaySince) as? Date

        #if os(macOS)
        let fileName = "org-memory.json"   // source of truth
        #else
        let fileName = "org-cache.json"    // read-only cache from the mesh
        #endif
        #if os(macOS)
        let limit = TimelineStore.macLimit   // the Mac keeps the long history (source of truth for backfill)
        #else
        let limit = TimelineStore.phoneLimit
        #endif
        let url = MeshService.storageURL("timeline.json")
        let saved = url.map { TimelineStore.load(from: $0, limit: limit) } ?? PersistedTimeline()
        for entry in saved.entries {
            if let sender = entry.message.senderName, !sender.isEmpty, entry.message.origin != name, dir[entry.message.origin] == nil {
                dir[entry.message.origin] = sender
            }
        }
        let mem = OrgMemory(fileURL: MeshService.storageURL(fileName), admins: AdminPolicy.devices(adminIDs: admins, selfID: name))
        let relay = RelayEngine(selfName: name, roles: ai ? [MeshDestination.aiRole] : [])
        relay.senderName = person.isEmpty ? nil : person
        relay.restoreOutbox(saved.outbox)
        for entry in saved.entries.suffix(300) { relay.markSeen(entry.id) }

        displayName = name
        blocked = Set(storedBlocked)
        isAIPeer = ai
        aiEngine = engineChoice
        ollamaModel = model
        ollamaFallbackModel = fallback
        adminDevices = admins
        clearedAt = cleared
        awaySince = away
        roster = rosterMap
        memory = mem
        org = mem.snapshot
        engine = relay
        personName = person
        directory = dir
        timelineURL = url
        timelineLimit = limit
        entries = TimelineStore.dropping(saved.entries, before: cleared)
        outboxCount = relay.outbox.count

        #if os(macOS)
        let brain = ExecutiveAssistant(
            memory: mem,
            llm: OllamaClient(model: model, fallbackModel: fallback.isEmpty ? nil : fallback),
            selfName: name,
            roster: rosterMap,
            knownDevices: Array(Set(rosterMap.values).union(dir.keys)).sorted()
        )
        brain.directory = dir
        brain.clearedAt = cleared
        assistant = brain
        #endif
    }

    static func defaultDeviceName() -> String {
        let suffix = String(UUID().uuidString.prefix(4))
        #if os(macOS)
        let host = Host.current().localizedName ?? "Mac"
        return host.isEmpty ? "Mac \(suffix)" : host
        #else
        return "iPhone \(suffix)"
        #endif
    }

    /// Application Support/Libre/<file> (folder keeps the working name so saved team memory survives the rename). Inside the app sandbox container on macOS.
    static func storageURL(_ fileName: String) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("Libre", isDirectory: true).appendingPathComponent(fileName)
    }

    // MARK: Derived

    var peers: [PeerInfo] {
        var names = Set(peerStates.keys)
        names.formUnion(blocked)
        return names.sorted().map { name in
            PeerInfo(name: name, label: label(for: name), state: peerStates[name] ?? .disconnected, isBlocked: blocked.contains(name))
        }
    }

    /// Chosen name for a device id, or the id itself.
    func label(for device: String) -> String {
        if device == displayName { return personName.isEmpty ? device : personName }
        return PeopleDirectory.label(for: device, directory: directory)
    }

    /// Name shown on a message: the sender's chosen name, then the directory, then the device id.
    func senderLabel(for message: MeshMessage) -> String {
        if message.kind == .answer { return "Pasa AI" }
        if let name = message.senderName, !name.isEmpty { return name }
        return label(for: message.origin)
    }

    var needsPersonName: Bool { personName.isEmpty }

    var connectedCount: Int {
        peerStates.filter { $0.value == .connected && !blocked.contains($0.key) }.count
    }

    var aiResponderName: String {
        switch aiEngine {
        case .assistant: return "Executive assistant (\(ollamaModel))"
        case .plain: return "Plain model (\(ollamaModel))"
        case .echo: return "Echo stub"
        }
    }

    /// Tasks for this device (phones) from the cached memory.
    var myTasks: [TaskItem] {
        memory.tasks(forDevice: displayName, roster: roster, includeDone: true)
    }

    var rosterText: String { Roster.format(roster) }

    /// "Forced relay mode: no direct link to Site Office" while any block is active.
    var forcedRelayBadge: String? {
        ForcedRelayStatus.badge(blocked: blocked.map { label(for: $0) })
    }

    /// Devices the Mac can tick as admins: every device it has seen, labelled by name in the UI.
    var adminCandidates: [String] {
        AdminPolicy.candidates(seen: Array(peerStates.keys), directory: directory, admins: adminDevices, selfID: displayName)
    }

    func isAdminDevice(_ device: String) -> Bool {
        device == displayName || adminDevices.contains(device)
    }

    // MARK: Lifecycle

    func start() {
        guard transport == nil else { return }
        let newTransport = MeshTransport(displayName: displayName, blocked: blocked) { [weak self] event in
            guard let service = self else { return }
            // Main queue keeps events in arrival order (unstructured Tasks do not promise that).
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    service.handle(event)
                }
            }
        }
        transport = newTransport
        newTransport.start()
        startHousekeeping()
        #if os(macOS)
        updateAwakeActivity()
        startOllamaWatch()
        checkOllama()
        #endif
    }

    func stop() {
        transport?.stop()
        transport = nil
        peerStates.removeAll()
        housekeeping?.invalidate()
        housekeeping = nil
        #if os(macOS)
        ollamaTimer?.invalidate()
        ollamaTimer = nil
        endAwakeActivity()
        #endif
    }

    /// App came back to the foreground: restart discovery, send what is queued, catch up.
    func appBecameActive() {
        transport?.restartDiscovery(force: true)
        if connectedCount > 0 {
            flushOutbox()
            requestBackfill()
            isAway = false
        }
    }

    /// App left the foreground (iOS suspends it and drops links): remember when, for catch-ups.
    func appWentToBackground() {
        markAway()
    }

    private func markAway(at now: Date = Date()) {
        guard !isAway, !isAIPeer else { return }
        isAway = true
        awaySince = now
        defaults.set(now, forKey: Keys.awaySince)
    }

    /// Every 5 s: drop stale peers from the strip and retry the outbox if a link is up.
    private func startHousekeeping() {
        housekeeping?.invalidate()
        housekeeping = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.housekeepingTick()
                }
            }
        }
    }

    private func housekeepingTick() {
        let now = Date()
        let stale = peerStates.filter { pair in
            pair.value != .connected && now.timeIntervalSince(lastSeen[pair.key] ?? .distantPast) > MeshService.stalePeerAfter
        }.map { $0.key }
        for name in stale { peerStates.removeValue(forKey: name) }
        if !engine.outbox.isEmpty && connectedCount > 0 { flushOutbox() }
        refreshWaitingAsks(now: now)
    }

    private func refreshWaitingAsks(now: Date = Date()) {
        sentAsks = AskWatch.pruned(sentAsks, now: now)
        let waiting = AskWatch.waiting(sentAsks, now: now)
        if waiting != waitingAsks { waitingAsks = waiting }
    }

    // MARK: Persistence

    /// Coalesces saves: at most one write per second, done off the main thread.
    private func scheduleSave() {
        guard timelineURL != nil, !savePending else { return }
        savePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                self?.saveNow()
            }
        }
    }

    private func saveNow() {
        savePending = false
        guard let url = timelineURL else { return }
        let snapshot = PersistedTimeline(entries: entries, outbox: engine.outbox)
        let limit = timelineLimit
        saveQueue.async {
            TimelineStore.save(snapshot, to: url, limit: limit)
        }
    }

    // MARK: Settings

    /// Sets the person's display name ("Kyle"). No mesh restart needed: it rides on messages.
    func setPersonName(_ raw: String) {
        let clean = PeopleDirectory.clean(raw)
        guard !clean.isEmpty, clean != personName else { return }
        personName = clean
        defaults.set(clean, forKey: Keys.personName)
        engine.senderName = clean
        learn(device: displayName, name: clean)
    }

    /// Remembers which name a device uses, and refreshes admin and assistant lookups.
    private func learn(device: String, name: String?) {
        guard let name = name.map(PeopleDirectory.clean), !name.isEmpty, directory[device] != name else { return }
        directory[device] = name
        defaults.set(directory, forKey: Keys.directory)
        // Admin rights do not change here: they follow device ids, never names.
        #if os(macOS)
        assistant.directory = directory
        refreshKnownDevices()
        #endif
    }

    /// Changes the device id (mesh address). Restarts the link. The person's name is separate.
    func rename(to newName: String) {
        let clean = MeshTransport.sanitize(newName)
        guard clean != displayName else { return }
        stop()
        let oldName = displayName
        displayName = clean
        defaults.set(clean, forKey: Keys.name)
        engine.rename(to: clean)
        if !personName.isEmpty {
            directory.removeValue(forKey: oldName)
            directory[clean] = personName
            defaults.set(directory, forKey: Keys.directory)
        }
        memory.admins = AdminPolicy.devices(adminIDs: adminDevices, selfID: clean)
        #if os(macOS)
        assistant.selfName = clean
        assistant.directory = directory
        #endif
        start()
    }

    func setBlocked(_ name: String, _ isBlocked: Bool) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != displayName else { return }
        if isBlocked { blocked.insert(clean) } else { blocked.remove(clean) }
        defaults.set(Array(blocked).sorted(), forKey: Keys.blocked)
        // The transport also drops an existing direct link with a newly blocked peer.
        transport?.setBlocked(blocked)
    }

    /// Clears this device's timeline and records a watermark so backfill and catch-ups never
    /// bring the old messages back. On the AI Mac this clears the whole team's timeline: linked
    /// phones drop older messages now, the rest on their next link.
    func clearTimeline() {
        let now = Date()
        entries.removeAll()
        sentAsks.removeAll()
        waitingAsks.removeAll()
        clearedAt = now
        defaults.set(now, forKey: Keys.clearedAt)
        #if os(macOS)
        assistant.clearedAt = now
        if isAIPeer { pushManifestToLinkedPeers() }
        #endif
    }

    /// Phone side: adopt the AI Mac's team-wide clear (only ever moves the watermark forward).
    private func adoptClear(_ macClearedAt: Date?) {
        guard let macClearedAt, macClearedAt > (clearedAt ?? .distantPast) else { return }
        clearedAt = macClearedAt
        defaults.set(macClearedAt, forKey: Keys.clearedAt)
        let kept = TimelineStore.dropping(entries, before: macClearedAt)
        if kept.count != entries.count { entries = kept }
    }

    /// Delete (retire) a rule from the Rules tab. On the AI Mac this happens right away (the Mac
    /// is an admin). On a phone it becomes "@pasa delete rule: <title>" and the Mac checks that
    /// the phone is an admin device before deleting.
    func deleteRule(_ rule: RuleEntry) {
        #if os(macOS)
        if isAIPeer {
            let change = memory.retireRule(title: rule.title, by: displayName)
            if let tombstone = change.entry { broadcastRule(tombstone) }
            refreshOrg()
            return
        }
        #endif
        send("\(AssistantMention.primary) delete rule: \(rule.title)")
    }

    /// Lock or unlock a rule. On the AI Mac this happens right away; on a phone it becomes
    /// "@pasa lock rule: <title>" and the Mac checks that the phone is an admin device.
    func setRuleLocked(_ rule: RuleEntry, locked: Bool) {
        #if os(macOS)
        if isAIPeer {
            if case .updated(let changed) = memory.setLocked(title: rule.title, locked: locked, by: displayName) {
                broadcastRule(changed)
            }
            refreshOrg()
            return
        }
        #endif
        send("\(AssistantMention.primary) \(locked ? "lock" : "unlock") rule: \(rule.title)")
    }

    #if os(macOS)
    func setAIPeer(_ on: Bool) {
        isAIPeer = on
        defaults.set(on, forKey: Keys.aiPeer)
        engine.roles = on ? [MeshDestination.aiRole] : []
        updateAwakeActivity()
        if on { checkOllama() }
    }

    /// Ticks or unticks a device id as admin (Mac Settings). Names are never used.
    func setAdmin(_ device: String, _ on: Bool) {
        let clean = device.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != displayName else { return }
        var ids = adminDevices.filter { $0 != clean }
        if on { ids.append(clean) }
        adminDevices = ids.sorted()
        defaults.set(adminDevices, forKey: Keys.admins)
        memory.admins = AdminPolicy.devices(adminIDs: adminDevices, selfID: displayName)
    }

    // MARK: Keep the AI peer awake and warm

    /// While this Mac is the AI peer: no idle sleep and no App Nap (closing the lid still sleeps).
    private func updateAwakeActivity() {
        if isAIPeer && transport != nil {
            guard awakeActivity == nil else { return }
            awakeActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Pasa is the team's AI peer: answering the mesh and keeping the model warm"
            )
        } else {
            endAwakeActivity()
        }
    }

    private func endAwakeActivity() {
        if let activity = awakeActivity {
            ProcessInfo.processInfo.endActivity(activity)
            awakeActivity = nil
        }
    }

    /// Every 60 s: if Ollama was not ready, check again (and warm up when it appears); if the
    /// model is loaded, refresh keep_alive every 10 minutes so it stays loaded while Pasa runs.
    private func startOllamaWatch() {
        ollamaTimer?.invalidate()
        ollamaTimer = Timer.scheduledTimer(withTimeInterval: WarmthPolicy.tickEvery, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.ollamaTick()
                }
            }
        }
    }

    private func ollamaTick() {
        guard isAIPeer, aiEngine != .echo else { return }
        switch WarmthPolicy.next(ready: modelWarm, busy: ollamaBusy, lastWarm: lastWarm) {
        case .check: checkOllama()
        case .refresh: refreshWarm()
        case .wait: break
        }
    }

    private func refreshWarm() {
        let client = makeClient()
        ollamaBusy = true
        Task { [weak self] in
            do {
                _ = try await client.warmUp()
                self?.lastWarm = Date()
            } catch {
                let why = (error as? LLMError)?.errorDescription ?? error.localizedDescription
                self?.modelWarm = false
                self?.ollamaStatus = "Model went cold or Ollama stopped: \(why) Checking again every minute."
            }
            self?.ollamaBusy = false
        }
    }

    func updateAssistantSettings(engine newEngine: AIEngine, model: String, fallback: String, rosterText: String) {
        let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        aiEngine = newEngine
        ollamaModel = cleanModel.isEmpty ? OllamaClient.defaultModel : cleanModel
        ollamaFallbackModel = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        roster = Roster.parse(rosterText)

        defaults.set(newEngine.rawValue, forKey: Keys.engine)
        defaults.set(ollamaModel, forKey: Keys.model)
        defaults.set(ollamaFallbackModel, forKey: Keys.fallback)
        defaults.set(roster, forKey: Keys.roster)

        assistant.llm = makeClient()
        assistant.roster = roster
        refreshKnownDevices()
        checkOllama()
    }

    private func makeClient() -> OllamaClient {
        OllamaClient(model: ollamaModel, fallbackModel: ollamaFallbackModel.isEmpty ? nil : ollamaFallbackModel)
    }

    private func refreshKnownDevices() {
        assistant.knownDevices = Array(Set(peerStates.keys).union(roster.values).union(directory.keys)).sorted()
    }

    /// Health check: is Ollama up and is the model installed? If so, warm the model up so the
    /// first real question does not pay the ~25 s load (keep_alive keeps it loaded for 30 min).
    func checkOllama() {
        guard !ollamaBusy else { return }
        let client = makeClient()
        ollamaStatus = "Checking Ollama..."
        modelWarm = false
        ollamaBusy = true
        Task { [weak self] in
            defer { self?.ollamaBusy = false }
            var status: String
            var canWarm = false
            do {
                let models = try await client.installedModels()
                let has = models.contains(client.model) || models.contains(client.model + ":latest")
                if has {
                    status = "Ollama running. Using \(client.model)."
                    canWarm = true
                } else if let fb = client.fallbackModel, models.contains(fb) {
                    status = "Ollama running. \(client.model) not installed, falling back to \(fb). Run: ollama pull \(client.model)"
                    canWarm = true
                } else {
                    status = "Ollama running, but \(client.model) is not installed. Run: ollama pull \(client.model)"
                }
            } catch {
                status = (error as? LLMError)?.errorDescription ?? error.localizedDescription
            }
            self?.ollamaStatus = status
            guard canWarm, let service = self, service.aiEngine != .echo else { return }
            service.ollamaStatus = status + " Warming up the model (first load takes about 25 s)..."
            let started = Date()
            do {
                let loaded = try await client.warmUp()
                let seconds = Date().timeIntervalSince(started)
                self?.ollamaStatus = "Ready. \(loaded) loaded in \(String(format: "%.1f", seconds)) s. Kept warm while Pasa runs (checked every minute)."
                self?.modelWarm = true
                self?.lastWarm = Date()
            } catch {
                let why = (error as? LLMError)?.errorDescription ?? error.localizedDescription
                self?.ollamaStatus = status + " Warm-up failed: \(why)"
            }
        }
    }

    // MARK: Mac dashboard actions (the Mac acts as an admin)

    func setTaskDone(_ id: UUID, done: Bool) {
        let updated = done ? memory.markDone(id, by: displayName) : memory.reopen(id, by: displayName)
        if let updated { notifyTask(updated) }
        refreshOrg()
    }

    /// Erases team memory on the Mac. Linked phones drop their cached rules and tasks now (the
    /// manifest lists nothing), the rest on their next link.
    func resetMemory() {
        memory.reset()
        assistantLog.removeAll()
        refreshOrg()
        pushManifestToLinkedPeers()
    }

    private func pushManifestToLinkedPeers() {
        guard isAIPeer else { return }
        for (name, state) in peerStates where state == .connected && !blocked.contains(name) {
            sendManifest(to: name)
        }
    }

    private func sendManifest(to device: String) {
        guard let body = SyncPayload(manifest: memory.manifest(clearedAt: clearedAt)).encoded() else { return }
        transmit(engine.makeOutgoing(kind: .sync, body: body, destination: .peer(device)), excluding: [])
    }
    #endif

    private func refreshOrg() {
        org = memory.snapshot
    }

    // MARK: Sending

    /// One chat for everything: a line starting with "@pasa" (or the old "@libre") is an ask for
    /// the AI peer, anything else is team chat.
    func send(_ rawText: String) {
        var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        var kind: MessageKind = .chat
        if let question = AssistantMention.strip(text) {
            kind = .ask
            text = question
            if text.isEmpty { return }
        }

        let destination: MeshDestination? = kind == .ask ? .role(MeshDestination.aiRole) : nil
        var message = engine.makeOutgoing(kind: kind, body: text, destination: destination)
        if kind == .ask {
            sentAsks[message.id] = Date()
            // Phones tell the Mac since when they were away (or cleared), for "what did I miss".
            if !isAIPeer { message.since = CacheSync.latest(awaySince, clearedAt) }
        }

        var entry = ChatEntry(id: message.id, message: message, direction: .sent, receivedAt: Date())

        #if os(macOS)
        if kind == .chat {
            memory.recordChat(from: label(for: displayName), text: text, at: message.createdAt, device: displayName)
        }
        if kind == .ask && isAIPeer {
            // This Mac is the AI peer: answer locally, no mesh needed (Mac-only path for judges).
            entry.sentTo = ["this Mac (AI peer)"]
            entries.append(entry)
            answer(message)
            return
        }
        #endif

        entry.sentTo = transmit(message, excluding: [])
        entries.append(entry)
    }

    /// Quick actions: "What did I miss?", "My tasks", "More". Sent as "@pasa ..." asks.
    func quickAsk(_ text: String) {
        send("\(AssistantMention.primary) \(text)")
    }

    /// Hands a message to the transport. Parks it in the outbox if nobody can take it.
    @discardableResult
    private func transmit(_ message: MeshMessage, excluding: Set<String>) -> [String] {
        guard let transport else {
            engine.enqueue(message, excluding: excluding)
            outboxCount = engine.outbox.count
            return []
        }
        let data: Data
        do {
            data = try MeshCodec.encode(message)
        } catch {
            lastProblem = "Could not encode message: \(error.localizedDescription)"
            return []
        }
        let sentTo = transport.send(data, excluding: excluding)
        if sentTo.isEmpty {
            engine.enqueue(message, excluding: excluding)
            scheduleSave()
        }
        outboxCount = engine.outbox.count
        return sentTo
    }

    private func flushOutbox() {
        let items = engine.drainOutbox()
        outboxCount = 0
        for item in items {
            let sentTo = transmit(item.message, excluding: item.excluding)
            if !sentTo.isEmpty, let index = entries.firstIndex(where: { $0.id == item.message.id && $0.direction == .sent }) {
                entries[index].sentTo = sentTo
            }
        }
        outboxCount = engine.outbox.count
        scheduleSave()
    }

    // MARK: Backfill

    /// Phone side: ask the AI Mac for messages this device missed (throttled).
    private func requestBackfill() {
        guard !isAIPeer, Date().timeIntervalSince(lastBackfillRequest) > 10 else { return }
        lastBackfillRequest = Date()
        guard let body = SyncPayload(request: Backfill.request(from: entries, clearedAt: clearedAt)).encoded() else { return }
        let message = engine.makeOutgoing(kind: .sync, body: body, destination: .role(MeshDestination.aiRole))
        transmit(message, excluding: [])
    }

    /// AI Mac side: send the phone what it missed, at most 200 messages, in small chunks.
    private func serveBackfill(to device: String, request: SyncRequest) {
        let missing = Backfill.select(from: entries, for: device, request: request, macClearedAt: clearedAt)
        guard !missing.isEmpty else { return }
        let chunks = Backfill.chunk(missing)
        for (index, chunk) in chunks.enumerated() {
            let batch = SyncBatch(messages: chunk, part: index + 1, parts: chunks.count)
            guard let body = SyncPayload(batch: batch).encoded() else { continue }
            transmit(engine.makeOutgoing(kind: .sync, body: body, destination: .peer(device)), excluding: [])
        }
    }

    /// Phone side: merge a backfill chunk (dedupe by id, keep time order, update caches).
    /// Messages older than the clear-timeline watermark are skipped. Rule and task cards only
    /// show when they changed the cache (the Mac's sync-on-link usually got there first).
    private func applyBackfill(_ batch: SyncBatch) {
        let now = Date()
        var incoming: [ChatEntry] = []
        for m in batch.messages {
            engine.markSeen(m.id, now: now)
            if let clearedAt, m.createdAt < clearedAt { continue }
            if let name = m.senderName, m.origin != displayName { learn(device: m.origin, name: name) }
            if !isAIPeer && (m.kind == .task || m.kind == .rule) {
                guard CacheSync.applyCard(m, to: memory).show else { continue }
            }
            let mine = m.origin == displayName
            incoming.append(ChatEntry(id: m.id, message: m, direction: mine ? .sent : .received, receivedAt: now,
                                      sentTo: mine ? ["synced from the AI peer"] : [], backfilled: true))
        }
        let merged = TimelineStore.mergeBackfill(entries, incoming)
        if merged.added > 0 { entries = merged.entries }
        refreshOrg()
    }

    // MARK: Transport events

    private func handle(_ event: TransportEvent) {
        switch event {
        case .found(let name):
            lastSeen[name] = Date()
            if peerStates[name] == nil || peerStates[name] == .disconnected {
                peerStates[name] = .discovered
            }
        case .lost(let name):
            if peerStates[name] != .connected {
                peerStates.removeValue(forKey: name)
            }
        case .state(let name, let state):
            let linkedBefore = connectedCount
            peerStates[name] = state
            if state == .connected { lastSeen[name] = Date() }
            if state == .connected && !blocked.contains(name) {
                isAway = false
                flushOutbox()
                requestBackfill()
                #if os(macOS)
                syncMemory(to: name)
                #endif
            }
            if linkedBefore > 0 && connectedCount == 0 { markAway() }
            #if os(macOS)
            refreshKnownDevices()
            #endif
        case .received(let data, let from):
            lastSeen[from] = Date()
            receive(data, from: from)
        case .problem(let text):
            lastProblem = text
        }
    }

    private func receive(_ data: Data, from sender: String) {
        let message: MeshMessage
        switch MeshCodec.decodeLenient(data) {
        case .message(let decoded):
            message = decoded
        case .opaque(let packet):
            relayOpaque(packet, from: sender)
            return
        case .unreadable:
            lastProblem = "Dropped unreadable packet from \(label(for: sender))"
            return
        }

        let decision = engine.handleIncoming(message, from: sender)
        if decision.isDuplicate { return }

        if let forward = decision.forward {
            transmit(forward, excluding: decision.forwardExcluding)
            relayedCount += 1
        }

        guard let delivered = decision.deliver else { return }
        if let name = delivered.senderName, delivered.origin != displayName {
            learn(device: delivered.origin, name: name)
        }

        if delivered.kind == .sync {
            // Backfill traffic never shows in the timeline.
            guard let payload = SyncPayload.decode(delivered.body) else { return }
            if let request = payload.request, isAIPeer { serveBackfill(to: delivered.origin, request: request) }
            if let manifest = payload.manifest, !isAIPeer {
                // The Mac is the source of truth: drop cached rules and tasks it no longer has.
                CacheSync.applyManifest(manifest, to: memory)
                adoptClear(manifest.clearedAt)
                refreshOrg()
            }
            if let batch = payload.batch { applyBackfill(batch) }
            return
        }
        // Already in the timeline (for example restored from disk, or backfilled): do not repeat it.
        if entries.contains(where: { $0.id == delivered.id }) { return }

        // Phones: a rule or task update only becomes a card when it changed the cached copy and
        // is not a silent sync-on-link update. Reconnects no longer flood the chat.
        if !isAIPeer && (delivered.kind == .task || delivered.kind == .rule) {
            let result = CacheSync.applyCard(delivered, to: memory)
            if result.changed { refreshOrg() }
            guard result.show else { return }
        }

        var entry = ChatEntry(id: delivered.id, message: delivered, direction: .received, receivedAt: Date())
        if delivered.kind == .answer, let askID = delivered.replyTo, let askedAt = sentAsks.removeValue(forKey: askID) {
            entry.roundTripMs = Int((Date().timeIntervalSince(askedAt) * 1000).rounded())
            refreshWaitingAsks()
        }
        entries.append(entry)

        switch delivered.kind {
        case .task, .rule:
            break   // phones handled above; the AI peer is the source of truth
        case .chat:
            #if os(macOS)
            memory.recordChat(from: senderLabel(for: delivered), text: delivered.body, at: delivered.createdAt, device: delivered.origin)
            #endif
        case .ask:
            #if os(macOS)
            if isAIPeer { answer(delivered) }
            #endif
        case .answer, .ack, .sync:
            break
        }
    }

    /// A packet from a newer Pasa (or an unknown kind): pass it on untouched, never show it.
    private func relayOpaque(_ packet: OpaquePacket, from sender: String) {
        let decision = engine.handleIncoming(packet.envelope, from: sender)
        if decision.isDuplicate { return }
        if let forward = decision.forward, let data = packet.rewritten(ttl: forward.ttl, hops: forward.hops),
           let transport, !transport.send(data, excluding: decision.forwardExcluding).isEmpty {
            relayedCount += 1
        }
        lastProblem = "\(label(for: packet.envelope.origin)) runs a newer Pasa (format v\(packet.version)). Its messages are passed on but cannot be shown here. Update Pasa on this device."
    }

    // MARK: AI peer (macOS)

    #if os(macOS)
    private func answer(_ ask: MeshMessage) {
        switch aiEngine {
        case .assistant:
            Task { [weak self] in
                guard let self else { return }
                let outcome = await self.assistant.handle(ask.body, from: ask.origin, since: ask.since)
                let reply = AIReply(text: outcome.reply, compact: outcome.compact, model: outcome.model,
                                    latencyMs: outcome.latencyMs, tokensPerSecond: outcome.tokensPerSecond)
                self.sendAnswer(reply, to: ask, intent: outcome.intent.rawValue, error: outcome.error)
                for task in outcome.taskUpdates { self.notifyTask(task) }
                for rule in outcome.ruleUpdates { self.broadcastRule(rule) }
                self.refreshOrg()
            }
        case .plain, .echo:
            let responder: any AIResponder = aiEngine == .echo ? EchoResponder() : OllamaResponder(client: makeClient())
            let question = ask.body
            let asker = ask.origin
            Task { [weak self] in
                let started = Date()
                var reply: AIReply
                var failure: String? = nil
                do {
                    reply = try await responder.respond(to: question, from: asker)
                } catch {
                    let message = (error as? LLMError)?.errorDescription ?? error.localizedDescription
                    failure = message
                    reply = AIReply(text: message)
                }
                if reply.latencyMs == 0 { reply.latencyMs = Int(Date().timeIntervalSince(started) * 1000) }
                self?.sendAnswer(reply, to: ask, intent: "answer", error: failure)
            }
        }
    }

    private func sendAnswer(_ reply: AIReply, to ask: MeshMessage, intent: String, error: String?) {
        var message = engine.makeOutgoing(
            kind: .answer,
            body: reply.text,
            destination: .peer(ask.origin),
            replyTo: ask.id,
            replyPath: ask.hops
        )
        message.compact = reply.compact
        message.model = reply.model
        message.latencyMs = reply.latencyMs
        message.tokensPerSecond = reply.tokensPerSecond

        var entry = ChatEntry(id: message.id, message: message, direction: .sent, receivedAt: Date())
        if ask.origin == displayName {
            // Local ask on the AI Mac: show the answer as received with a local round trip.
            entry.direction = .received
            if let askedAt = sentAsks.removeValue(forKey: ask.id) {
                entry.roundTripMs = Int((Date().timeIntervalSince(askedAt) * 1000).rounded())
                refreshWaitingAsks()
            }
        } else {
            entry.sentTo = transmit(message, excluding: [])
        }
        entries.append(entry)

        assistantLog.append(AssistantLogEntry(
            id: message.id, at: Date(), asker: ask.origin, question: ask.body, askHops: ask.hopCount,
            intent: intent, reply: reply.text, model: reply.model, latencyMs: reply.latencyMs,
            tokensPerSecond: reply.tokensPerSecond, compact: reply.compact, error: error
        ))
        if assistantLog.count > 200 { assistantLog.removeFirst(assistantLog.count - 200) }
    }

    /// Sends a task to its assignee's device (and its creator, when the task is finished).
    private func notifyTask(_ task: TaskItem) {
        guard let body = MeshPayload.encode(task) else { return }
        var targets: [String] = []
        if let device = task.assigneeDevice { targets.append(device) }
        if task.status == .done, !targets.contains(task.createdBy) { targets.append(task.createdBy) }
        for device in targets where device != displayName {
            let message = engine.makeOutgoing(kind: .task, body: body, destination: .peer(device))
            var entry = ChatEntry(id: message.id, message: message, direction: .sent, receivedAt: Date())
            entry.sentTo = transmit(message, excluding: [])
            entries.append(entry)
        }
    }

    /// Broadcasts a rule summary (no history) so every phone caches a read-only copy.
    private func broadcastRule(_ rule: RuleEntry) {
        guard let body = MeshPayload.encode(rule.meshSummary) else { return }
        let message = engine.makeOutgoing(kind: .rule, body: body, destination: nil)
        var entry = ChatEntry(id: message.id, message: message, direction: .sent, receivedAt: Date())
        entry.sentTo = transmit(message, excluding: [])
        entries.append(entry)
    }

    /// When a device links: send the manifest (so stale cached rules and tasks are dropped and a
    /// team-wide clear sticks), then the rules and its open tasks as silent updates. Silent
    /// updates refresh the phone's cache without adding cards to its timeline.
    private func syncMemory(to device: String) {
        guard isAIPeer else { return }
        sendManifest(to: device)
        // allRules includes tombstones, so a phone still caching a deleted rule drops it.
        for rule in memory.allRules.suffix(60) {
            guard let body = MeshPayload.encode(rule.meshSummary) else { continue }
            var message = engine.makeOutgoing(kind: .rule, body: body, destination: .peer(device))
            message.silent = true
            transmit(message, excluding: [])
        }
        for task in memory.tasks(forDevice: device, roster: roster).prefix(30) {
            guard let body = MeshPayload.encode(task) else { continue }
            var message = engine.makeOutgoing(kind: .task, body: body, destination: .peer(device))
            message.silent = true
            transmit(message, excluding: [])
        }
    }
    #endif
}
