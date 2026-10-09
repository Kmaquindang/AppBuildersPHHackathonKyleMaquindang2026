// MeshService.swift
// Pasa: glue between the link layer (MeshTransport), our relay layer (RelayEngine), team memory
// (OrgMemory), the AI peer (ExecutiveAssistant / AIResponder) and the SwiftUI views.
// Everything here runs on the main actor.

import Foundation
import SwiftUI

/// How the composer sends a line.
enum ComposeMode: String, CaseIterable, Identifiable {
    case chat = "Chat"
    case ask = "Ask AI"
    var id: String { rawValue }
}

/// Which brain the Mac AI peer uses.
enum AIEngine: String, CaseIterable, Identifiable {
    case assistant = "Executive assistant"
    case plain = "Plain model"
    case echo = "Echo stub"
    var id: String { rawValue }
}

/// One row in the timeline.
struct ChatEntry: Identifiable, Equatable {
    enum Direction: Equatable { case sent, received }

    let id: UUID
    var message: MeshMessage
    var direction: Direction
    var receivedAt: Date
    /// For sent messages: who the first copy was handed to, or empty if it was queued.
    var sentTo: [String] = []
    /// For answers to our own asks: local send-to-answer time, measured on one clock.
    var roundTripMs: Int? = nil

    /// One-way latency from the origin's clock to ours. Only as good as device clock sync.
    var oneWayMs: Int {
        Int((receivedAt.timeIntervalSince(message.createdAt) * 1000).rounded())
    }
}

struct PeerInfo: Identifiable, Equatable {
    var name: String
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
    @Published private(set) var entries: [ChatEntry] = []
    @Published private(set) var outboxCount = 0
    @Published private(set) var relayedCount = 0
    @Published private(set) var lastProblem: String?

    /// Team memory: source of truth on the AI Mac, read-only cache on phones.
    @Published private(set) var org: OrgSnapshot

    // AI peer settings and dashboard (used on macOS; harmless defaults elsewhere).
    @Published private(set) var aiEngine: AIEngine
    @Published private(set) var ollamaModel: String
    @Published private(set) var ollamaFallbackModel: String
    @Published private(set) var adminNames: [String]
    @Published private(set) var roster: [String: String]
    @Published private(set) var assistantLog: [AssistantLogEntry] = []
    @Published private(set) var ollamaStatus = "Not checked yet"

    // MARK: Internals

    private let engine: RelayEngine
    private var transport: MeshTransport?
    private var sentAsks: [UUID: Date] = [:]
    private let defaults = UserDefaults.standard
    private let memory: OrgMemory
    #if os(macOS)
    private let assistant: ExecutiveAssistant
    #endif

    private enum Keys {
        // Keys keep the working name "libre." so settings saved before the rename to Pasa survive.
        static let name = "libre.displayName"
        static let blocked = "libre.blocked"
        static let aiPeer = "libre.isAIPeer"
        static let engine = "libre.aiEngine"
        static let model = "libre.ollamaModel"
        static let fallback = "libre.ollamaFallbackModel"
        static let admins = "libre.adminNames"
        static let roster = "libre.roster"
    }

    static let defaultAdmins = ["iPhone 14 Pro Max"]

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
        let admins = store.stringArray(forKey: Keys.admins) ?? MeshService.defaultAdmins
        let rosterMap = (store.dictionary(forKey: Keys.roster) as? [String: String]) ?? [:]

        #if os(macOS)
        let fileName = "org-memory.json"   // source of truth
        #else
        let fileName = "org-cache.json"    // read-only cache from the mesh
        #endif
        let mem = OrgMemory(fileURL: MeshService.storageURL(fileName), admins: Set(admins).union([name]))

        displayName = name
        blocked = Set(storedBlocked)
        isAIPeer = ai
        aiEngine = engineChoice
        ollamaModel = model
        ollamaFallbackModel = fallback
        adminNames = admins
        roster = rosterMap
        memory = mem
        org = mem.snapshot
        engine = RelayEngine(selfName: name, roles: ai ? [MeshDestination.aiRole] : [])

        #if os(macOS)
        assistant = ExecutiveAssistant(
            memory: mem,
            llm: OllamaClient(model: model, fallbackModel: fallback.isEmpty ? nil : fallback),
            selfName: name,
            roster: rosterMap,
            knownDevices: Array(Set(rosterMap.values))
        )
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
            PeerInfo(name: name, state: peerStates[name] ?? .disconnected, isBlocked: blocked.contains(name))
        }
    }

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
        #if os(macOS)
        checkOllama()
        #endif
    }

    func stop() {
        transport?.stop()
        transport = nil
        peerStates.removeAll()
    }

    // MARK: Settings

    func rename(to newName: String) {
        let clean = MeshTransport.sanitize(newName)
        guard clean != displayName else { return }
        stop()
        displayName = clean
        defaults.set(clean, forKey: Keys.name)
        engine.rename(to: clean)
        memory.admins = Set(adminNames).union([clean])
        #if os(macOS)
        assistant.selfName = clean
        #endif
        start()
    }

    func setBlocked(_ name: String, _ isBlocked: Bool) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != displayName else { return }
        if isBlocked { blocked.insert(clean) } else { blocked.remove(clean) }
        defaults.set(Array(blocked).sorted(), forKey: Keys.blocked)
        transport?.setBlocked(blocked)
    }

    func clearTimeline() {
        entries.removeAll()
        sentAsks.removeAll()
    }

    #if os(macOS)
    func setAIPeer(_ on: Bool) {
        isAIPeer = on
        defaults.set(on, forKey: Keys.aiPeer)
        engine.roles = on ? [MeshDestination.aiRole] : []
    }

    func updateAssistantSettings(engine newEngine: AIEngine, model: String, fallback: String, admins adminText: String, rosterText: String) {
        let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        aiEngine = newEngine
        ollamaModel = cleanModel.isEmpty ? OllamaClient.defaultModel : cleanModel
        ollamaFallbackModel = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        adminNames = adminText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        roster = Roster.parse(rosterText)

        defaults.set(newEngine.rawValue, forKey: Keys.engine)
        defaults.set(ollamaModel, forKey: Keys.model)
        defaults.set(ollamaFallbackModel, forKey: Keys.fallback)
        defaults.set(adminNames, forKey: Keys.admins)
        defaults.set(roster, forKey: Keys.roster)

        memory.admins = Set(adminNames).union([displayName])
        assistant.llm = makeClient()
        assistant.roster = roster
        refreshKnownDevices()
        checkOllama()
    }

    private func makeClient() -> OllamaClient {
        OllamaClient(model: ollamaModel, fallbackModel: ollamaFallbackModel.isEmpty ? nil : ollamaFallbackModel)
    }

    private func refreshKnownDevices() {
        assistant.knownDevices = Array(Set(peerStates.keys).union(roster.values)).sorted()
    }

    /// Health check: is Ollama up and is the model installed?
    func checkOllama() {
        let client = makeClient()
        ollamaStatus = "Checking Ollama..."
        Task { [weak self] in
            let status: String
            do {
                let models = try await client.installedModels()
                let has = models.contains(client.model) || models.contains(client.model + ":latest")
                if has {
                    status = "Ollama running. Using \(client.model)."
                } else if let fb = client.fallbackModel, models.contains(fb) {
                    status = "Ollama running. \(client.model) not installed, falling back to \(fb). Run: ollama pull \(client.model)"
                } else {
                    status = "Ollama running, but \(client.model) is not installed. Run: ollama pull \(client.model)"
                }
            } catch {
                status = (error as? LLMError)?.errorDescription ?? error.localizedDescription
            }
            self?.ollamaStatus = status
        }
    }

    // MARK: Mac dashboard actions (the Mac acts as an admin)

    func setTaskDone(_ id: UUID, done: Bool) {
        let updated = done ? memory.markDone(id, by: displayName) : memory.reopen(id, by: displayName)
        if let updated { notifyTask(updated) }
        refreshOrg()
    }

    func setRuleLocked(_ rule: RuleEntry, locked: Bool) {
        if case .updated(let changed) = memory.setLocked(title: rule.title, locked: locked, by: displayName) {
            broadcastRule(changed)
        }
        refreshOrg()
    }

    func resetMemory() {
        memory.reset()
        assistantLog.removeAll()
        refreshOrg()
    }
    #endif

    private func refreshOrg() {
        org = memory.snapshot
    }

    // MARK: Sending

    func send(_ rawText: String, mode: ComposeMode) {
        var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        var kind: MessageKind = mode == .ask ? .ask : .chat
        // "@pasa question" (or the old "@libre question") also means ask the AI.
        if let question = AssistantMention.strip(text) {
            kind = .ask
            text = question
            if text.isEmpty { return }
        }

        let destination: MeshDestination? = kind == .ask ? .role(MeshDestination.aiRole) : nil
        let message = engine.makeOutgoing(kind: kind, body: text, destination: destination)
        if kind == .ask { sentAsks[message.id] = Date() }

        var entry = ChatEntry(id: message.id, message: message, direction: .sent, receivedAt: Date())

        #if os(macOS)
        if kind == .chat {
            memory.recordChat(from: displayName, text: text, at: message.createdAt)
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

    /// Quick actions on phones: "What did I miss?", "My tasks", "More".
    func quickAsk(_ text: String) {
        send(text, mode: .ask)
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
    }

    // MARK: Transport events

    private func handle(_ event: TransportEvent) {
        switch event {
        case .found(let name):
            if peerStates[name] == nil || peerStates[name] == .disconnected {
                peerStates[name] = .discovered
            }
        case .lost(let name):
            if peerStates[name] != .connected {
                peerStates.removeValue(forKey: name)
            }
        case .state(let name, let state):
            peerStates[name] = state
            if state == .connected && !blocked.contains(name) {
                flushOutbox()
                #if os(macOS)
                syncMemory(to: name)
                #endif
            }
            #if os(macOS)
            refreshKnownDevices()
            #endif
        case .received(let data, let from):
            receive(data, from: from)
        case .problem(let text):
            lastProblem = text
        }
    }

    private func receive(_ data: Data, from sender: String) {
        let message: MeshMessage
        do {
            message = try MeshCodec.decode(data)
        } catch {
            lastProblem = "Dropped unreadable packet from \(sender)"
            return
        }

        let decision = engine.handleIncoming(message, from: sender)
        if decision.isDuplicate { return }

        if let forward = decision.forward {
            transmit(forward, excluding: decision.forwardExcluding)
            relayedCount += 1
        }

        guard let delivered = decision.deliver else { return }
        var entry = ChatEntry(id: delivered.id, message: delivered, direction: .received, receivedAt: Date())
        if delivered.kind == .answer, let askID = delivered.replyTo, let askedAt = sentAsks.removeValue(forKey: askID) {
            entry.roundTripMs = Int((Date().timeIntervalSince(askedAt) * 1000).rounded())
        }
        entries.append(entry)

        switch delivered.kind {
        case .task, .rule:
            // Phones cache what the AI peer shares. The AI peer itself is the source of truth.
            if !isAIPeer {
                if delivered.kind == .task, let task = MeshPayload.decodeTask(delivered.body) {
                    memory.mergeTask(task)
                } else if delivered.kind == .rule, let rule = MeshPayload.decodeRule(delivered.body) {
                    memory.mergeRule(rule)
                }
                refreshOrg()
            }
        case .chat:
            #if os(macOS)
            memory.recordChat(from: delivered.origin, text: delivered.body, at: delivered.createdAt)
            #endif
        case .ask:
            #if os(macOS)
            if isAIPeer { answer(delivered) }
            #endif
        case .answer, .ack:
            break
        }
    }

    // MARK: AI peer (macOS)

    #if os(macOS)
    private func answer(_ ask: MeshMessage) {
        switch aiEngine {
        case .assistant:
            Task { [weak self] in
                guard let self else { return }
                let outcome = await self.assistant.handle(ask.body, from: ask.origin)
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

    /// When a device links, send it the rules and its open tasks so its cache catches up.
    private func syncMemory(to device: String) {
        guard isAIPeer else { return }
        for rule in memory.rules.prefix(30) {
            guard let body = MeshPayload.encode(rule.meshSummary) else { continue }
            transmit(engine.makeOutgoing(kind: .rule, body: body, destination: .peer(device)), excluding: [])
        }
        for task in memory.tasks(forDevice: device, roster: roster).prefix(30) {
            guard let body = MeshPayload.encode(task) else { continue }
            transmit(engine.makeOutgoing(kind: .task, body: body, destination: .peer(device)), excluding: [])
        }
    }
    #endif
}
