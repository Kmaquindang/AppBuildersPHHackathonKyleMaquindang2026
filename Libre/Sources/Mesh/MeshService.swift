// MeshService.swift
// Libre: glue between the link layer (MeshTransport), our relay layer (RelayEngine), the AI seam
// (AIResponder) and the SwiftUI views. Everything here runs on the main actor.

import Foundation
import SwiftUI

/// How the composer sends a line.
enum ComposeMode: String, CaseIterable, Identifiable {
    case chat = "Chat"
    case ask = "Ask AI"
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

    // MARK: Internals

    private let engine: RelayEngine
    private var transport: MeshTransport?
    private var sentAsks: [UUID: Date] = [:]
    private let defaults = UserDefaults.standard
    private let responder: any AIResponder = EchoResponder()

    private enum Keys {
        static let name = "libre.displayName"
        static let blocked = "libre.blocked"
        static let aiPeer = "libre.isAIPeer"
    }

    init() {
        let storedName = UserDefaults.standard.string(forKey: Keys.name)
        let name = MeshTransport.sanitize(storedName ?? MeshService.defaultDeviceName())
        let storedBlocked = UserDefaults.standard.stringArray(forKey: Keys.blocked) ?? []

        #if os(macOS)
        let ai = UserDefaults.standard.object(forKey: Keys.aiPeer) as? Bool ?? true
        #else
        let ai = false
        #endif

        displayName = name
        blocked = Set(storedBlocked)
        isAIPeer = ai
        engine = RelayEngine(selfName: name, roles: ai ? [MeshDestination.aiRole] : [])
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

    var aiResponderName: String { responder.name }

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
        start()
    }

    func setBlocked(_ name: String, _ isBlocked: Bool) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != displayName else { return }
        if isBlocked { blocked.insert(clean) } else { blocked.remove(clean) }
        defaults.set(Array(blocked).sorted(), forKey: Keys.blocked)
        transport?.setBlocked(blocked)
    }

    #if os(macOS)
    func setAIPeer(_ on: Bool) {
        isAIPeer = on
        defaults.set(on, forKey: Keys.aiPeer)
        engine.roles = on ? [MeshDestination.aiRole] : []
    }
    #endif

    func clearTimeline() {
        entries.removeAll()
        sentAsks.removeAll()
    }

    // MARK: Sending

    func send(_ rawText: String, mode: ComposeMode) {
        var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        var kind: MessageKind = mode == .ask ? .ask : .chat
        // "@libre question" also means ask the AI.
        if text.lowercased().hasPrefix("@libre") {
            kind = .ask
            text = String(text.dropFirst("@libre".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return }
        }

        let destination: MeshDestination? = kind == .ask ? .role(MeshDestination.aiRole) : nil
        let message = engine.makeOutgoing(kind: kind, body: text, destination: destination)
        if kind == .ask { sentAsks[message.id] = Date() }

        var entry = ChatEntry(id: message.id, message: message, direction: .sent, receivedAt: Date())

        #if os(macOS)
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
            }
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

        #if os(macOS)
        if delivered.kind == .ask && isAIPeer {
            answer(delivered)
        }
        #endif
    }

    // MARK: AI peer (macOS only in milestone 1)

    #if os(macOS)
    private func answer(_ ask: MeshMessage) {
        let responder = self.responder
        let question = ask.body
        let asker = ask.origin
        Task { [weak self] in
            let text: String
            do {
                text = try await responder.respond(to: question, from: asker)
            } catch {
                text = "AI peer error: \(error.localizedDescription)"
            }
            self?.sendAnswer(text, to: ask)
        }
    }

    private func sendAnswer(_ text: String, to ask: MeshMessage) {
        let reply = engine.makeOutgoing(
            kind: .answer,
            body: text,
            destination: .peer(ask.origin),
            replyTo: ask.id,
            replyPath: ask.hops
        )
        var entry = ChatEntry(id: reply.id, message: reply, direction: .sent, receivedAt: Date())
        if ask.origin == displayName {
            // Local ask on the AI Mac: show the answer as received with a local round trip.
            entry.direction = .received
            if let askedAt = sentAsks.removeValue(forKey: ask.id) {
                entry.roundTripMs = Int((Date().timeIntervalSince(askedAt) * 1000).rounded())
            }
        } else {
            entry.sentTo = transmit(reply, excluding: [])
        }
        entries.append(entry)
    }
    #endif
}
