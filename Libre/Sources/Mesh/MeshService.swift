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
#if os(macOS)
import AppKit
#endif

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

/// One job for the Mac's single model slot (rooms take turns in FairAskQueue).
enum AIJob {
    /// An "@pasa ..." ask.
    case ask(MeshMessage)
    /// Photo check: the media message, and the ask that asked for it (nil when automatic).
    case photo(media: MeshMessage, ask: MeshMessage?)
    /// Scheduled end-of-day digest.
    case digest(DigestClock.Due)
    /// Admin button "Send summary now".
    case summaryNow
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
    var checked: [String] = []
    var promptTokensEstimate: Int?
    var promptEvalCount: Int?
    /// Room tag and label the ask came from (multi-room AI Mac).
    var roomID: String = ""
    var roomLabel: String = ""
}

/// AI Mac: a room it serves that is not the active one (chat log, team memory, timeline).
/// Exactly one OrgMemory instance exists per room: switching rooms swaps these in and out.
final class RoomContext {
    let roomID: String
    var memory: OrgMemory
    var entries: [ChatEntry]
    let timelineURL: URL?
    var dirty = false

    init(roomID: String, memory: OrgMemory, entries: [ChatEntry], timelineURL: URL?) {
        self.roomID = roomID
        self.memory = memory
        self.entries = entries
        self.timelineURL = timelineURL
    }

    func save(limit: Int) {
        _ = memory.save()
        guard dirty, let url = timelineURL else { return }
        dirty = false
        TimelineStore.save(PersistedTimeline(entries: entries, outbox: []), to: url, limit: limit)
    }
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
    /// Room this device reads and writes (one at a time). Other rooms' packets are only relayed.
    @Published private(set) var activeRoom: Room
    @Published private(set) var joinedRooms: [Room]
    /// Other rooms' packets this device passed on without reading them.
    @Published private(set) var foreignRelayedCount = 0

    // AI peer settings and dashboard (used on macOS; harmless defaults elsewhere).
    @Published private(set) var aiEngine: AIEngine
    @Published private(set) var ollamaModel: String
    @Published private(set) var ollamaFallbackModel: String
    /// Admin device ids chosen on the Mac for the active room (the Mac itself and the room's
    /// creator are always admins too).
    @Published private(set) var adminDevices: [String]
    @Published private(set) var roster: [String: String]
    @Published private(set) var assistantLog: [AssistantLogEntry] = []
    /// Phones: Knowledge titles of the active room from the Mac (read-only, filtered by role).
    @Published private(set) var libraryListings: [LibraryListing] = []
    #if os(macOS)
    /// AI Mac: per-room Knowledge (documents, passages, vectors) in Application Support.
    let knowledge = KnowledgeService()
    #endif
    @Published private(set) var ollamaStatus = "Not checked yet"
    @Published private(set) var modelWarm = false
    /// Digest (sha256) of the model Ollama serves, for pinning. Empty until checked.
    @Published private(set) var modelDigest = ""

    // Rooms and media.
    /// True while a room key is being derived from a passcode (slow on purpose).
    @Published private(set) var roomBusy = false
    /// Code rooms with "Approve new members": valid join requests waiting for an admin, per room.
    @Published private(set) var pendingJoins: [String: [PendingJoin]] = [:]
    /// Media id -> fraction of chunks received (incoming) or sent (outgoing), while in flight.
    @Published private(set) var mediaProgress: [UUID: Double] = [:]
    /// Bumped whenever a media file lands in the cache, so bubbles reload.
    @Published private(set) var mediaVersion = 0
    /// Voice notes the Mac is transcribing right now.
    @Published private(set) var transcribing: Set<UUID> = []
    /// Mac: language for voice note transcripts ("en-US" or "fil-PH").
    @Published private(set) var speechLocale: String

    // Multi-room: discovery, admin, AI status.
    /// Listed rooms heard nearby (signed beacons, expire after 45 s).
    @Published private(set) var nearbyRooms: [BeaconRegistry.Heard] = []
    /// AI Mac status for the active room (phones from signed status beacons; the Mac itself).
    @Published private(set) var aiAvailability: AIAvailability = .unknown
    /// Phones: one notice after a voice note sent with no AI Mac nearby (cleared when one is back).
    @Published private(set) var aiNotice: String?
    /// Queue depth and model of the AI Mac serving the active room, when heard.
    @Published private(set) var aiDetail: AIStatus?
    /// Mac: true between willSleep and didWake.
    @Published private(set) var macAsleep = false
    /// Mac: asks waiting for the model, all rooms.
    @Published private(set) var aiQueueDepth = 0

    // Local AI: proof, daily digest, photo checks (Mac).
    /// Link layer debug counters: discovery restarts performed and requests folded or deferred.
    @Published private(set) var discoveryRestarts = 0
    @Published private(set) var discoveryRestartsCoalesced = 0
    #if os(iOS)
    private var backgroundedAt: Date?
    #endif

    func refreshTransportStats() {
        guard let transport else { return }
        if transport.restartCount != discoveryRestarts { discoveryRestarts = transport.restartCount }
        if transport.coalescedRestarts != discoveryRestartsCoalesced { discoveryRestartsCoalesced = transport.coalescedRestarts }
    }

    /// Mac: internet route state from NWPathMonitor (listens only, never sends).
    @Published private(set) var internetState: InternetState = .unknown
    /// Mac: last 20 answers and cards with their proof (Proof panel).
    @Published private(set) var proofLog = ProofLog()
    /// Mac: what Ollama has loaded right now (/api/ps), for the Proof panel.
    @Published private(set) var ollamaRunning: [RunningModel] = []
    /// Mac: models Ollama has installed (/api/tags).
    @Published private(set) var installedModels: [String] = []
    /// Mac: Ollama is answering on 127.0.0.1:11434.
    @Published private(set) var ollamaReachable = false
    /// Mac: vision model picked from the installed ones (nil: not installed).
    @Published private(set) var visionModel: String?
    /// Mac: describe every photo that arrives (when a vision model is installed).
    @Published private(set) var autoDescribePhotos: Bool
    @Published private(set) var digestSchedule: DigestSchedule
    /// Mac: newest digest made (any room), for the dashboard.
    @Published private(set) var lastDigest: DailyDigest?
    /// First-run onboarding finished (or skipped) on this device.
    @Published private(set) var onboardingDone: Bool
    /// MultipeerConnectivity could not browse or advertise (usually Local Network permission is off).
    @Published private(set) var localNetworkDenied = false
    /// Starter chips under the chat right after onboarding.
    @Published private(set) var showStarterChips = false
    /// One-line note under the composer (for example a coalesced duplicate ask).
    @Published var composerNote: String?
    /// AI Mac: caption asks waiting for their photo to finish arriving (media id -> ask, room).
    private var photoAsks: [UUID: (ask: MeshMessage, room: String)] = [:]
    /// AI Mac: per room context fill, last compaction and summary size (Proof panel).
    @Published private(set) var contextStats: [String: ContextStats] = [:]
    /// Round 2: the same question was answered in the last 10 minutes ("Answered above", "Ask again").
    @Published var answeredHint: AnsweredHint?
    /// Round 2: asks the timeline to scroll to a row (the answer above).
    @Published var scrollRequest: ScrollRequest?
    /// Mac: vision model chosen by Set up AI (used first when installed).
    @Published private(set) var preferredVisionModel: String?

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
    private var timelineURL: URL?
    private let rooms: RoomStore
    private let timelineLimit: Int
    private let saveQueue = DispatchQueue(label: "pasa.timeline.save", qos: .utility)
    private let defaults = UserDefaults.standard
    private var memory: OrgMemory
    private let mediaStore: MediaStore
    private let assembler = MediaAssembler()
    /// "<media id>|<requester>" -> when this device last answered that NACK (throttle).
    private var nackAnswered: [String: Date] = [:]
    private struct ChunkJob { var message: MeshMessage; var mediaId: UUID; var index: Int; var count: Int; var outgoing: Bool; var room: String }
    /// This device's signing and key agreement keys (identity.json).
    let identity: DeviceIdentity
    private let beacons = BeaconRegistry()
    private let aiTracker = AIStatusTracker()
    /// Phones: unanswered asks of the active room, resent when the AI Mac wakes.
    private var pendingAsks = PendingAskBook()
    /// Media id -> room it belongs to (so NACKs and transcripts go to the right room).
    private var mediaRoom: [UUID: String] = [:]
    /// Throttles: room id -> last time.
    private var lastJoinRequest: [String: Date] = [:]
    private var lastWant: [String: Date] = [:]
    private var lastManifestSent: [String: Date] = [:]
    private var lastBeaconAt = Date.distantPast
    private var lastStatusAt = Date.distantPast
    private var chunkQueue: [ChunkJob] = []
    private var chunkPump: Task<Void, Never>?
    #if os(macOS)
    private let assistant: ExecutiveAssistant
    /// Keeps the Mac from idle-sleeping and App Nap from throttling timers while it is the AI peer.
    private var awakeActivity: NSObjectProtocol?
    private var ollamaTimer: Timer?
    private var ollamaBusy = false
    private var lastWarm: Date?
    /// Rooms the AI Mac serves that are not active (one OrgMemory per room).
    private var contexts: [String: RoomContext] = [:]
    /// One model call at a time, rooms take turns.
    private let askQueue = FairAskQueue<AIJob>()
    private var connectivity: ConnectivityMonitor?
    private var lastDigestCheck = Date.distantPast
    /// "<room>|<day>" digests queued but not written yet.
    private var digestQueued: Set<String> = []
    /// Photo checks already made (media id -> card text and suggestions).
    private var visionCache: [UUID: (text: String, suggestions: [String])] = [:]
    private var askRunning = false
    private var sleepObservers: [NSObjectProtocol] = []
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
        static let speechLocale = "pasa.speechLocale"
        static let autoPhotos = "pasa.autoDescribePhotos"
        static let digestEnabled = "pasa.digestEnabled"
        static let digestHour = "pasa.digestHour"
        static let digestMinute = "pasa.digestMinute"
        static let onboarded = "pasa.onboardingDone"
        static let visionPref = "pasa.visionModel"
        static let primers = "pasa.primersShown"
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
        // Macs with less than 12 GB of memory default to qwen3:4b-instruct.
        let model = store.string(forKey: Keys.model) ?? OllamaClient.recommendedModel(physicalMemory: ProcessInfo.processInfo.physicalMemory)
        let fallback = store.string(forKey: Keys.fallback) ?? OllamaClient.defaultFallbackModel
        let rosterMap = (store.dictionary(forKey: Keys.roster) as? [String: String]) ?? [:]
        let savedPerson = PeopleDirectory.clean(store.string(forKey: Keys.personName) ?? "")
        #if os(macOS)
        // Round 2: an AI Mac nobody named shows as "Kyle's Mac" (first word of the macOS user name),
        // not the raw computer name. Not saved, so a name typed later (or already saved) always wins.
        let person = savedPerson.isEmpty ? MacName.suggested(fullUserName: NSFullUserName(), hostName: Host.current().localizedName) : savedPerson
        #else
        let person = savedPerson
        #endif
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
        // Rooms: data from before rooms moves into the Default room on first launch. Admins and
        // the clear watermark become the Default room's (and are kept per room from now on).
        let roomStore = RoomStore(baseURL: MeshService.storageURL("rooms.json")?.deletingLastPathComponent(),
                                  legacyFiles: ["org-memory.json", "org-cache.json", "timeline.json"],
                                  legacyAdmins: admins,
                                  legacyClearedAt: store.object(forKey: Keys.clearedAt) as? Date)
        // Device keys, and admin keys for rooms this device created before admin keys existed.
        let ident = DeviceIdentity.loadOrCreate(at: MeshService.storageURL("identity.json"))
        for old in roomStore.rooms {
            var copy = old
            if RoomGovernor.migrate(&copy, selfID: name, identity: ident, name: person.isEmpty ? name : person) != nil {
                roomStore.update(old.id) { $0.gov = copy.gov }
            }
        }
        let room = roomStore.active
        let cleared = room.clearedAt
        let away = store.object(forKey: Keys.awaySince) as? Date

        let fileName = MeshService.memoryFileName
        #if os(macOS)
        let limit = TimelineStore.macLimit   // the Mac keeps the long history (source of truth for backfill)
        let mediaCap = MediaLimits.macCacheBytes
        #else
        let limit = TimelineStore.phoneLimit
        let mediaCap = MediaLimits.phoneCacheBytes
        #endif
        let url = roomStore.fileURL("timeline.json")
        let saved = url.map { TimelineStore.load(from: $0, limit: limit) } ?? PersistedTimeline()
        for entry in saved.entries {
            if let sender = entry.message.senderName, !sender.isEmpty, entry.message.origin != name, dir[entry.message.origin] == nil {
                dir[entry.message.origin] = sender
            }
        }
        let mem = OrgMemory(fileURL: roomStore.fileURL(fileName), admins: room.adminDevices(selfID: name))
        let relay = RelayEngine(selfName: name, roles: ai ? [MeshDestination.aiRole] : [])
        relay.roomID = room.id
        relay.senderName = person.isEmpty ? nil : person
        if ai { relay.extraRoomIDs = Set(roomStore.rooms.filter(\.canSend).map(\.id)) }
        relay.restoreOutbox(saved.outbox)
        for entry in saved.entries.suffix(300) { relay.markSeen(entry.id) }

        displayName = name
        blocked = Set(storedBlocked)
        isAIPeer = ai
        aiEngine = engineChoice
        ollamaModel = model
        ollamaFallbackModel = fallback
        adminDevices = room.admins
        clearedAt = cleared
        rooms = roomStore
        activeRoom = room
        joinedRooms = roomStore.rooms
        awaySince = away
        roster = rosterMap
        memory = mem
        org = mem.snapshot
        engine = relay
        personName = person
        directory = dir
        timelineURL = url
        timelineLimit = limit
        mediaStore = MediaStore(directory: MeshService.storageURL("media"), capBytes: mediaCap)
        speechLocale = store.string(forKey: Keys.speechLocale) ?? "en-US"
        autoDescribePhotos = store.object(forKey: Keys.autoPhotos) as? Bool ?? true
        preferredVisionModel = store.string(forKey: Keys.visionPref)
        digestSchedule = DigestSchedule(enabled: store.object(forKey: Keys.digestEnabled) as? Bool ?? true,
                                        hour: store.object(forKey: Keys.digestHour) as? Int ?? 17,
                                        minute: store.object(forKey: Keys.digestMinute) as? Int ?? 0)
        // Existing users (a saved name, or rooms beyond Default) skip onboarding.
        onboardingDone = store.object(forKey: Keys.onboarded) as? Bool ?? (!savedPerson.isEmpty || roomStore.rooms.contains { !$0.isDefault })
        entries = TimelineStore.dropping(saved.entries, before: cleared)
        outboxCount = relay.outbox.count
        identity = ident
        pendingAsks = PendingAskBook(items: saved.pendingAsks ?? [])

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
        let ledgerURL = MeshService.storageURL("ai-ledger.json")
        if let url = ledgerURL, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([String: FairAskQueue<AIJob>.LedgerEntry].self, from: data) {
            askQueue.importLedger(saved)
        }
        #endif
        for item in pendingAsks.items { sentAsks[item.ask.id] = item.firstSentAt }
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

    #if os(macOS)
    static let memoryFileName = "org-memory.json"   // source of truth
    #else
    static let memoryFileName = "org-cache.json"    // read-only cache from the mesh
    #endif

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
        device == displayName || adminDevices.contains(device) || device == activeRoom.creator
    }

    // MARK: Room admin state (signed manifest)

    /// This device may sign admin actions in the active room (creator or co-admin).
    var isRoomAdmin: Bool { RoomGovernor.isAdmin(activeRoom, identity: identity) }
    /// This device holds the room admin key (it created the room).
    var isRoomCreatorAdmin: Bool { RoomGovernor.isCreatorAdmin(activeRoom) }
    var roomMembers: [RoomMember] { activeRoom.gov?.manifest?.members ?? [] }
    func isCoAdmin(_ member: RoomMember) -> Bool { activeRoom.gov?.manifest?.isCoAdmin(member.signKey) ?? false }
    func isMe(_ member: RoomMember) -> Bool { member.signKey == identity.signKey }
    /// Admin badge for a device in the active room, from the signed manifest only (device keys,
    /// never names). This device also knows it is the creator when it holds the admin key.
    func roomRole(forDevice device: String) -> RoomRole? {
        guard let m = activeRoom.gov?.manifest else { return nil }
        if device == displayName, isRoomCreatorAdmin { return .creator }
        return m.role(device: device)
    }
    func roomRole(of member: RoomMember) -> RoomRole {
        if isMe(member), isRoomCreatorAdmin { return .creator }
        return activeRoom.gov?.manifest?.role(of: member.signKey) ?? .member
    }
    /// "7/12" for the header, nil for rooms without a roster.
    var roomCountText: String? {
        guard let m = activeRoom.gov?.manifest else { return nil }
        return "\(m.members.count)/\(m.cap)"
    }

    /// True when every one of these asks is saved in the resend book (answered when a Mac is back).
    func asksQueued(_ ids: [UUID], now: Date = Date()) -> Bool {
        !ids.isEmpty && ids.allSatisfy { pendingAsks.isQueued($0, now: now) }
    }

    /// Text under an unanswered ask, by AI status.
    var waitingText: String {
        switch aiAvailability {
        case .asleep: return "AI Mac asleep. Your question will be answered when it wakes."
        case .notServing: return "The AI Mac nearby is not in this room. Ask the room admin to add it."
        case .awake:
            if let q = aiDetail?.queue, q > 1 { return "Waiting for the AI Mac (\(q) questions in line, rooms take turns)." }
            return "Waiting for the AI Mac..."
        case .offline, .unknown: return NoAIHost.queuedLine
        }
    }

    /// Rooms the AI Mac answers in: joined, holding the current key, not closed or removed.
    private var servedRoomIDs: [String] {
        guard isAIPeer else { return [] }
        return joinedRooms.filter(\.canSend).map(\.id)
    }

    /// Re-reads room records after a governance change and updates relay roles.
    private func refreshRoomState() {
        activeRoom = rooms.active
        joinedRooms = rooms.rooms
        engine.extraRoomIDs = isAIPeer ? Set(servedRoomIDs) : []
        memory.admins = activeRoom.adminDevices(selfID: displayName)
        refreshAIAvailability()
    }

    // MARK: Rooms

    /// Creates a room from a name and passcode (Wi-Fi style) and switches to it. This device is
    /// its pinned admin. The key derivation (PBKDF2, 600,000 rounds) runs off the main thread.
    /// The passcode is never stored. Returns the room, or nil for a bad name or passcode.
    @discardableResult
    func createRoom(name: String, passcode: String) async -> Room? {
        await passcodeRoom(name: name, passcode: passcode, creator: displayName)
    }

    /// Joins a room by typing its name and passcode. A typo lands in a different, empty room, so
    /// the UI shows the room's check code for teammates to compare.
    @discardableResult
    func joinRoom(name: String, passcode: String) async -> Room? {
        await passcodeRoom(name: name, passcode: passcode, creator: "")
    }

    private func passcodeRoom(name: String, passcode: String, creator: String) async -> Room? {
        guard !roomBusy else { return nil }
        roomBusy = true
        defer { roomBusy = false }
        let made = await Task.detached(priority: .userInitiated) {
            Room.fromPasscode(name: name, passcode: passcode, creator: creator)
        }.value
        guard var room = made else { return nil }
        let isNew = rooms.room(withID: room.id) == nil
        if isNew {
            if !creator.isEmpty {
                RoomGovernor.setUp(&room, identity: identity, device: displayName, name: personName.isEmpty ? displayName : personName)
            } else {
                room.gov = RoomGov(pending: true)
            }
        }
        switchRoom { rooms.join(room) }
        afterJoin(activeRoom.id)
        return activeRoom
    }

    /// Joins a Listed room from the Nearby list. The passcode is checked against the room tag
    /// in the beacon first, so a typo says "wrong passcode" instead of landing in an empty room.
    enum NearbyJoin { case joined(Room), wrongPasscode, failed }
    func joinNearby(_ beacon: RoomBeacon, passcode: String) async -> NearbyJoin {
        guard !roomBusy else { return .failed }
        roomBusy = true
        let name = beacon.label
        if let codeRoom = Room.fromCode(name: name, creator: ""), codeRoom.id == beacon.room {
            roomBusy = false
            switch await joinCodeRoom(name: name, code: passcode) {
            case .sent(let room): return .joined(room)
            case .badCode, .expired: return .wrongPasscode
            case .failed: return .failed
            }
        }
        let made = await Task.detached(priority: .userInitiated) {
            Room.fromPasscode(name: name, passcode: passcode, creator: "")
        }.value
        roomBusy = false
        guard var room = made else { return .failed }
        guard room.id == beacon.room else { return .wrongPasscode }
        if rooms.room(withID: room.id) == nil { room.gov = RoomGov(pending: true) }
        switchRoom { rooms.join(room) }
        afterJoin(activeRoom.id)
        return .joined(activeRoom)
    }

    /// After joining or creating: publish (admin) or ask for the manifest and admission.
    private func afterJoin(_ roomID: String) {
        guard let room = rooms.room(withID: roomID), !room.isDefault else { return }
        if let signed = room.gov?.signed, RoomGovernor.isAdmin(room, identity: identity) {
            publishManifest(signed, roomID: roomID, force: true)
        } else {
            lastWant[roomID] = nil
            lastJoinRequest[roomID] = nil
            requestManifest(roomID)
            sendJoinRequestIfNeeded(roomID)
        }
    }

    /// Joins a room from a pasted or scanned join string. False when the string is not valid.
    @discardableResult
    func joinRoom(_ joinString: String) -> Bool {
        guard let room = Room.parse(joinString: joinString) else { return false }
        switchRoom { rooms.join(room) }
        afterJoin(activeRoom.id)
        return true
    }

    func activateRoom(_ id: String) {
        guard id != activeRoom.id, rooms.room(withID: id) != nil else { return }
        switchRoom { rooms.activate(id) }
        if !activeRoom.isDefault, !isRoomAdmin { requestManifest(id) }
    }

    /// Leaves a room (not the last one). Its saved chat and memory stay on disk.
    func leaveRoom(_ id: String) {
        guard joinedRooms.count > 1 else { return }
        #if os(macOS)
        askQueue.drop(room: id)
        contexts.removeValue(forKey: id)?.save(limit: timelineLimit)
        #endif
        if id == activeRoom.id {
            switchRoom { rooms.leave(id) }
        } else {
            rooms.leave(id)
            refreshRoomState()
        }
    }

    /// Saves the current room, applies `change`, then loads the (new) active room's chat and
    /// memory. Outbox packets are already sealed for the room they were written in.
    private func switchRoom(_ change: () -> Void) {
        libraryListings = []
        answeredHint = nil
        saveNow()
        _ = memory.save()
        let oldID = activeRoom.id
        let oldMemory = memory
        let oldEntries = entries
        let oldURL = timelineURL
        change()
        let room = rooms.active
        activeRoom = room
        joinedRooms = rooms.rooms
        engine.roomID = room.id
        clearedAt = room.clearedAt
        adminDevices = room.admins
        timelineURL = rooms.fileURL("timeline.json")
        let saved = timelineURL.map { TimelineStore.load(from: $0, limit: timelineLimit) } ?? PersistedTimeline()
        var loadedEntries = saved.entries
        #if os(macOS)
        // The AI Mac keeps serving the room it leaves (as a background context) and adopts the
        // new room's live context if it has one, so each room has exactly one memory instance.
        if room.id != oldID, rooms.room(withID: oldID) != nil {
            contexts[oldID] = RoomContext(roomID: oldID, memory: oldMemory, entries: oldEntries, timelineURL: oldURL)
        }
        if let ctx = contexts.removeValue(forKey: room.id) {
            ctx.save(limit: timelineLimit)
            memory = ctx.memory
            memory.admins = room.adminDevices(selfID: displayName)
            loadedEntries = ctx.entries
        } else {
            memory = OrgMemory(fileURL: rooms.fileURL(MeshService.memoryFileName), admins: room.adminDevices(selfID: displayName))
        }
        #else
        _ = (oldID, oldMemory, oldEntries, oldURL)
        memory = OrgMemory(fileURL: rooms.fileURL(MeshService.memoryFileName), admins: room.adminDevices(selfID: displayName))
        #endif
        pendingAsks = PendingAskBook(items: saved.pendingAsks ?? [])
        sentAsks.removeAll()
        waitingAsks.removeAll()
        chunkQueue.removeAll()
        mediaProgress.removeAll()
        entries = TimelineStore.dropping(loadedEntries, before: clearedAt)
        for entry in entries.suffix(300) { engine.markSeen(entry.id) }
        for item in pendingAsks.items { sentAsks[item.ask.id] = item.firstSentAt }
        refreshOrg()
        refreshRoomState()
        #if os(macOS)
        assistant.serve(room: room.id, memory: memory, clearedAt: clearedAt)
        for (name, state) in peerStates where state == .connected && !blocked.contains(name) { syncMemory(to: name) }
        #endif
        lastBackfillRequest = .distantPast
        if connectedCount > 0 { requestBackfill() }
        expectMissingMedia(in: entries)
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
        observeSleep()
        if connectivity == nil {
            connectivity = ConnectivityMonitor { [weak self] state in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.internetState != state else { return }
                        self.internetState = state
                        if self.isAIPeer { self.sendAIStatus(asleep: self.macAsleep) }
                    }
                }
            }
        }
        #endif
        refreshRoomState()
    }

    func stop() {
        // Keep the old transport (and its browser and advertiser) alive for a few seconds after
        // stop, so MultipeerConnectivity finishes tearing down its CFNetService objects first.
        let old = transport
        old?.stop()
        transport = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { withExtendedLifetime(old) {} }
        peerStates.removeAll()
        housekeeping?.invalidate()
        housekeeping = nil
        #if os(macOS)
        ollamaTimer?.invalidate()
        ollamaTimer = nil
        endAwakeActivity()
        for o in sleepObservers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        sleepObservers.removeAll()
        connectivity?.cancel()
        connectivity = nil
        #endif
    }

    /// App came back to the foreground: restart discovery, send what is queued, catch up.
    func appBecameActive() {
        // macOS reports "active" every time the window gets focus: never restart a running
        // browser for that. iOS suspends Multipeer in the background, so after real time away a
        // (debounced) restart is asked for; otherwise found peers are only re-invited.
        #if os(iOS)
        let away = backgroundedAt.map { Date().timeIntervalSince($0) } ?? 0
        backgroundedAt = nil
        transport?.restartDiscovery(away >= 10 ? .wake : .foreground)
        #else
        transport?.restartDiscovery(.foreground)
        #endif
        refreshTransportStats()
        if connectedCount > 0 {
            flushOutbox()
            requestBackfill()
            isAway = false
        }
    }

    /// App left the foreground (iOS suspends it and drops links): remember when, for catch-ups.
    func appWentToBackground() {
        #if os(iOS)
        backgroundedAt = Date()
        #endif
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
        refreshTransportStats()
        let stale = peerStates.filter { pair in
            pair.value != .connected && now.timeIntervalSince(lastSeen[pair.key] ?? .distantPast) > MeshService.stalePeerAfter
        }.map { $0.key }
        for name in stale { peerStates.removeValue(forKey: name) }
        if !engine.outbox.isEmpty && connectedCount > 0 { flushOutbox() }
        refreshWaitingAsks(now: now)
        sendDueNacks()
        nackAnswered = nackAnswered.filter { now.timeIntervalSince($0.value) < 60 }
        roomTick(now: now)
    }

    // MARK: Multi-room housekeeping

    /// Every 5 s: beacons for Listed rooms this device administers (every 12 s), AI status on
    /// the AI Mac (every 10 s), join requests while waiting for admission, resending asks after
    /// the AI Mac woke, saving background rooms, and expiring Nearby rooms and AI status.
    private func roomTick(now: Date) {
        beacons.prune(now: now)
        let heard = beacons.nearby(now: now)
        if heard != nearbyRooms { nearbyRooms = heard }
        refreshAIAvailability(now: now)
        guard transport != nil else { return }
        if now.timeIntervalSince(lastBeaconAt) >= BeaconRegistry.sendEvery {
            lastBeaconAt = now
            sendBeacons(now: now)
        }
        #if os(macOS)
        if isAIPeer, now.timeIntervalSince(lastStatusAt) >= AIStatusTracker.sendEvery {
            sendAIStatus(asleep: macAsleep, now: now)
        }
        for ctx in contexts.values where ctx.dirty { ctx.save(limit: timelineLimit) }
        if now.timeIntervalSince(lastDigestCheck) >= 30 {
            lastDigestCheck = now
            checkDigests(now: now)
        }
        pumpAsks()
        #endif
        guard connectedCount > 0 else { return }
        for room in joinedRooms where !room.isDefault {
            sendJoinRequestIfNeeded(room.id, now: now)
            if room.gov?.pending == true, room.gov?.manifest == nil { requestManifest(room.id, now: now) }
        }
        resendDueAsks(now: now)
    }

    private func sendBeacons(now: Date) {
        for room in joinedRooms {
            guard let blob = RoomBeacon.make(for: room, now: now), let body = PasaJSON.string(blob) else { continue }
            beacons.ingest(blob, now: now)
            sendClear(engine.makeOutgoing(kind: .beacon, body: body, destination: nil, ttl: BeaconRegistry.ttl))
        }
        nearbyRooms = beacons.nearby(now: now)
    }

    /// Clear (unsealed) signals: beacons and AI status. Never queued, never stored.
    private func sendClear(_ message: MeshMessage) {
        guard let transport, let data = try? MeshCodec.encode(message) else { return }
        _ = transport.send(data, excluding: [])
    }

    private func refreshAIAvailability(now: Date = Date()) {
        var availability: AIAvailability
        var detail: AIStatus?
        if isAIPeer {
            availability = macAsleep ? .asleep : (activeRoom.canSend ? .awake : .notServing)
            detail = AIStatus(device: displayName, state: macAsleep ? .asleep : .awake, model: ollamaModel,
                              queue: aiQueueDepth, rooms: servedRoomIDs, at: now, internet: internetState)
        } else {
            availability = aiTracker.availability(room: activeRoom.id, now: now)
            detail = aiTracker.detail(room: activeRoom.id, now: now)
        }
        if availability != aiAvailability { aiAvailability = availability }
        if !NoAIHost.isAway(availability), aiNotice != nil { aiNotice = nil }
        if detail?.queue != aiDetail?.queue || detail?.model != aiDetail?.model || detail?.internet != aiDetail?.internet || (detail == nil) != (aiDetail == nil) { aiDetail = detail }
    }

    /// Phones: resend unanswered asks of the active room (new packet id, retryOf = original)
    /// when the AI Mac woke up, or every 90 s while it is awake. The Mac answers each once.
    private func resendDueAsks(now: Date = Date()) {
        guard !isAIPeer, activeRoom.canSend else { return }
        pendingAsks.prune(now: now)
        let due = pendingAsks.due(room: activeRoom.id, aiAwake: aiAvailability == .awake, wokeAt: aiTracker.wokeAt, now: now)
        for item in due {
            let retry = PendingAskBook.retry(of: item.ask, hops: [displayName], now: now)
            engine.markSeen(retry.id, now: now)
            transmit(retry, excluding: [])
            pendingAsks.markSent(item.ask.id, now: now)
        }
        if !due.isEmpty { scheduleSave() }
    }

    // MARK: Room governance (manifests, join requests, admin actions)

    private func publishManifest(_ blob: SignedBlob, roomID: String, force: Bool = false, now: Date = Date()) {
        guard let room = rooms.room(withID: roomID) else { return }
        if !force, let last = lastManifestSent[roomID], now.timeIntervalSince(last) < 3 { return }
        lastManifestSent[roomID] = now
        guard let body = RoomControl(type: .manifest, blob: blob).encoded() else { return }
        transmit(engine.makeOutgoing(kind: .roomControl, body: body, destination: nil), room: room, excluding: [])
    }

    /// A device just linked: admins and the AI Mac hand it the newest manifest of each room
    /// they hold (direct link only, ttl 1), so a member that was away learns about kicks,
    /// closes and cap changes. A device that is not in the room cannot open it.
    private func publishManifests(to peer: String) {
        let others = Set(peerStates.keys).subtracting([peer])
        for room in joinedRooms where !room.isDefault {
            guard let signed = room.gov?.signed, isAIPeer || RoomGovernor.isAdmin(room, identity: identity),
                  let body = RoomControl(type: .manifest, blob: signed).encoded() else { continue }
            transmit(engine.makeOutgoing(kind: .roomControl, body: body, destination: .peer(peer), ttl: 1),
                     room: room, excluding: others, queueIfUnsent: false)
        }
    }

    private func requestManifest(_ roomID: String, now: Date = Date()) {
        guard let room = rooms.room(withID: roomID), !room.isDefault, !room.isRemoved else { return }
        if let last = lastWant[roomID], now.timeIntervalSince(last) < 10 { return }
        lastWant[roomID] = now
        guard let body = RoomControl(type: .want, haveSeq: room.gov?.seq ?? 0).encoded() else { return }
        transmit(engine.makeOutgoing(kind: .roomControl, body: body, destination: nil), room: room, excluding: [], queueIfUnsent: false)
    }

    private func sendJoinRequestIfNeeded(_ roomID: String, now: Date = Date()) {
        guard let room = rooms.room(withID: roomID), RoomGovernor.wantsAdmission(room, identity: identity) else { return }
        if let last = lastJoinRequest[roomID], now.timeIntervalSince(last) < 15 { return }
        lastJoinRequest[roomID] = now
        guard let blob = RoomGovernor.joinRequest(room: room, identity: identity, device: displayName,
                                                  name: personName.isEmpty ? displayName : personName, now: now),
              let body = RoomControl(type: .join, blob: blob).encoded() else { return }
        transmit(engine.makeOutgoing(kind: .roomControl, body: body, destination: nil), room: room, excluding: [], queueIfUnsent: false)
    }

    /// A room control message (manifest, join request, manifest request) for any joined room,
    /// active or not, so a kick or rekey in a background room is never missed.
    private func handleRoomControl(_ message: MeshMessage, roomID: String) {
        guard let control = RoomControl.decode(message.body), var room = rooms.room(withID: roomID) else { return }
        switch control.type {
        case .manifest:
            guard let blob = control.blob else { return }
            let result = RoomGovernor.accept(blob, into: &room, identity: identity)
            guard case .applied(let change) = result else {
                if case .rejected(let why) = result, roomID == activeRoom.id {
                    lastProblem = why == "the room code does not match"
                        ? "That code does not match room \(room.displayName). Check the code and try again."
                        : "Ignored a room update for \(room.displayName): \(why)."
                }
                return
            }
            let gov = room.gov
            rooms.update(roomID) { $0.gov = gov }
            refreshRoomState()
            if change.removed {
                lastProblem = change.codeChanged
                    ? "The admin made a new code for \(room.displayName). Enter the new code to rejoin."
                    : "An admin removed this device from \(room.displayName)."
            }
            if change.admitted {
                if roomID == activeRoom.id { lastProblem = nil }
                if roomID == activeRoom.id, connectedCount > 0 { lastBackfillRequest = .distantPast; requestBackfill() }
            }
            #if os(macOS)
            if change.closed == true { askQueue.drop(room: roomID) }
            #endif
            if change.firstPin, roomID == activeRoom.id, let m = room.gov?.manifest {
                lastProblem = "Room admin \(m.adminName), fingerprint \(Fingerprint.of(m.adminKey)). Compare it with the admin's screen."
            }
            sendJoinRequestIfNeeded(roomID)
        case .join:
            guard let blob = control.blob, RoomGovernor.isAdmin(room, identity: identity) else { return }
            if room.gov?.manifest?.approval == true {
                // "Approve new members": a valid request waits for an admin's tap.
                switch RoomGovernor.vet(blob, room: room, identity: identity) {
                case .ok(let request):
                    var list = pendingJoins[roomID] ?? []
                    list.removeAll { $0.request.signKey == request.signKey }
                    list.append(PendingJoin(request: request, blob: blob))
                    pendingJoins[roomID] = list
                case .already, .refused:
                    if let signed = room.gov?.signed { publishManifest(signed, roomID: roomID) }
                case .invalid:
                    break
                }
                return
            }
            switch RoomGovernor.admit(blob, room: &room, identity: identity) {
            case .admitted(let manifest):
                let gov = room.gov
                rooms.update(roomID) { $0.gov = gov }
                refreshRoomState()
                publishManifest(manifest, roomID: roomID, force: true)
            case .already, .refused:
                // Re-send the current manifest: it carries the key box, or shows Full or Closed.
                if let signed = room.gov?.signed { publishManifest(signed, roomID: roomID) }
            case .invalid:
                break
            }
        case .want:
            guard let signed = room.gov?.signed, (control.haveSeq ?? 0) < room.gov?.seq ?? 0,
                  isAIPeer || RoomGovernor.isAdmin(room, identity: identity) else { return }
            publishManifest(signed, roomID: roomID)
        }
    }

    /// Admin actions on the active room. Each signs a new manifest, applies it here, and
    /// broadcasts it. Returns false when this device is not an admin or nothing changed.
    @discardableResult
    func kick(_ member: RoomMember) -> Bool {
        adminAction { room in RoomGovernor.kick(member.signKey, room: &room, identity: identity) }
    }

    @discardableResult
    func setRoomClosed(_ closed: Bool) -> Bool {
        adminAction { room in RoomGovernor.setClosed(closed, room: &room, identity: identity) }
    }

    @discardableResult
    func setRoomCap(_ cap: Int) -> Bool {
        adminAction { room in RoomGovernor.setCap(cap, room: &room, identity: identity) }
    }

    @discardableResult
    func setRoomListed(_ listed: Bool) -> Bool {
        adminAction { room in RoomGovernor.setListed(listed, room: &room, identity: identity) }
    }

    @discardableResult
    func setCoAdmin(_ member: RoomMember, _ on: Bool) -> Bool {
        adminAction { room in RoomGovernor.setCoAdmin(member.signKey, on: on, room: &room, identity: identity) }
    }

    // MARK: Code rooms (name + short code, QR join link)

    struct PendingJoin: Identifiable, Equatable {
        var id: String { RoomCrypto.base64url(request.signKey) }
        var request: JoinRequest
        var blob: SignedBlob
    }

    /// Mac onboarding "Create your room": a code room with this device as creator and first admin.
    @discardableResult
    func createCodeRoom(name: String, expiry: CodeExpiry = .off, approval: Bool = false) async -> Room? {
        guard !roomBusy, var room = Room.fromCode(name: name, creator: displayName) else { return nil }
        guard rooms.room(withID: room.id) == nil else {
            lastProblem = "A room called \(room.displayName) is already on this device. Pick another name."
            return nil
        }
        roomBusy = true
        defer { roomBusy = false }
        let code = JoinCode.generate()
        let label = room.label
        guard let key = await Task.detached(priority: .userInitiated, operation: { CodeRoom.codeKey(name: label, code: code) }).value else { return nil }
        guard RoomGovernor.setUp(&room, identity: identity, device: displayName, name: personName.isEmpty ? displayName : personName,
                                 code: code, codeKey: key, codeExpiresAt: expiry.date(from: Date()), approval: approval) != nil else { return nil }
        switchRoom { rooms.join(room) }
        afterJoin(activeRoom.id)
        return activeRoom
    }

    /// Join link for the active code room (creator only: it holds the code).
    var activeJoinLink: JoinLink? {
        guard activeRoom.usesCode, let code = activeRoom.gov?.joinCode else { return nil }
        return JoinLink(room: activeRoom.label, code: code, expiresAt: activeRoom.gov?.manifest?.codeExpiresAt)
    }

    /// Joins (or re-enters the code of) a code room by name and code. The admin checks the code.
    enum CodeJoin: Equatable { case sent(Room), badCode, expired, failed }
    func joinCodeRoom(name: String, code: String, expiresAt: Date? = nil) async -> CodeJoin {
        if let expiresAt, Date() >= expiresAt { return .expired }
        guard JoinCode.isValid(code), let fresh = Room.fromCode(name: name, creator: "") else { return .badCode }
        guard !roomBusy else { return .failed }
        roomBusy = true
        defer { roomBusy = false }
        let label = fresh.label
        guard let key = await Task.detached(priority: .userInitiated, operation: { CodeRoom.codeKey(name: label, code: code) }).value else { return .badCode }
        var room = rooms.room(withID: fresh.id) ?? fresh
        if RoomGovernor.isCreatorAdmin(room) { switchRoom { rooms.activate(room.id) }; return .sent(activeRoom) }
        RoomGovernor.enterCode(key, room: &room, identity: identity)
        if rooms.room(withID: room.id) != nil {
            let gov = room.gov
            rooms.update(room.id) { $0.gov = gov }
            if room.id != activeRoom.id { switchRoom { rooms.activate(room.id) } } else { refreshRoomState() }
        } else {
            switchRoom { rooms.join(room) }
        }
        lastJoinRequest[room.id] = nil
        afterJoin(activeRoom.id)
        return .sent(activeRoom)
    }

    /// pasa://join?... from a scanned QR code or a tapped link.
    func handleJoinURL(_ url: URL) {
        switch JoinLink.parse(url.absoluteString) {
        case .failure:
            lastProblem = "That link is not a Pasa room link."
        case .success(let link):
            if link.isExpired() { lastProblem = "That room code expired. Ask the admin for a new one."; return }
            Task {
                switch await joinCodeRoom(name: link.room, code: link.code, expiresAt: link.expiresAt) {
                case .sent(let room): lastProblem = "Joining \(room.displayName). The admin device lets you in when it is nearby."
                case .expired: lastProblem = "That room code expired. Ask the admin for a new one."
                case .badCode: lastProblem = "That room code is not valid."
                case .failed: lastProblem = "Could not join right now. Try again."
                }
            }
        }
    }

    /// "New code": members who are not admins must enter the new code.
    @discardableResult
    func newRoomCode(expiry: CodeExpiry) async -> Bool {
        guard activeRoom.usesCode, RoomGovernor.isCreatorAdmin(activeRoom), !roomBusy else { return false }
        roomBusy = true
        defer { roomBusy = false }
        let code = JoinCode.generate()
        let label = activeRoom.label
        guard let key = await Task.detached(priority: .userInitiated, operation: { CodeRoom.codeKey(name: label, code: code) }).value else { return false }
        pendingJoins[activeRoom.id] = nil
        return adminAction { room in RoomGovernor.rotateCode(code, codeKey: key, expiresAt: expiry.date(from: Date()), room: &room, identity: identity) }
    }

    @discardableResult
    func setCodeExpiry(_ expiry: CodeExpiry) -> Bool {
        adminAction { room in RoomGovernor.setCodeExpiry(expiry.date(from: Date()), room: &room, identity: identity) }
    }

    @discardableResult
    func setJoinApproval(_ on: Bool) -> Bool {
        adminAction { room in RoomGovernor.setApproval(on, room: &room, identity: identity) }
    }

    func approveJoin(_ pending: PendingJoin) {
        let id = activeRoom.id
        pendingJoins[id]?.removeAll { $0.id == pending.id }
        var room = activeRoom
        switch RoomGovernor.admit(pending.blob, room: &room, identity: identity) {
        case .admitted(let manifest):
            let gov = room.gov
            rooms.update(id) { $0.gov = gov }
            refreshRoomState()
            publishManifest(manifest, roomID: id, force: true)
        case .refused(let why):
            lastProblem = "Could not let \(pending.request.name) in: \(why)."
        case .already, .invalid:
            break
        }
    }

    func denyJoin(_ pending: PendingJoin) {
        pendingJoins[activeRoom.id]?.removeAll { $0.id == pending.id }
    }

    private func adminAction(_ action: (inout Room) -> SignedBlob?) -> Bool {
        var room = activeRoom
        guard let blob = action(&room) else { return false }
        let gov = room.gov
        let id = room.id
        rooms.update(id) { $0.gov = gov }
        refreshRoomState()
        #if os(macOS)
        if room.isClosed { askQueue.drop(room: id) }
        #endif
        publishManifest(blob, roomID: id, force: true)
        lastBeaconAt = .distantPast
        return true
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
        var snapshot = PersistedTimeline(entries: entries, outbox: engine.outbox)
        snapshot.pendingAsks = pendingAsks.items.isEmpty ? nil : pendingAsks.items
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
        memory.admins = activeRoom.adminDevices(selfID: clean)
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
        rooms.update(activeRoom.id) { $0.clearedAt = now }
        #if os(macOS)
        assistant.clearedAt = now
        if isAIPeer { pushManifestToLinkedPeers() }
        #endif
    }

    /// Phone side: adopt the AI Mac's team-wide clear (only ever moves the watermark forward).
    private func adoptClear(_ macClearedAt: Date?) {
        guard let macClearedAt, macClearedAt > (clearedAt ?? .distantPast) else { return }
        clearedAt = macClearedAt
        rooms.update(activeRoom.id) { $0.clearedAt = macClearedAt }
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

    /// Owner or admin may finish a task from its card (the AI Mac checks again on phones' asks).
    func canComplete(_ task: TaskItem) -> Bool {
        task.canComplete(by: displayName, names: [personName], isAdmin: isAIPeer || isRoomAdmin || adminDevices.contains(displayName), roster: roster)
    }

    /// Done button: the Mac marks it right away; a phone asks the Mac, which syncs it back.
    func completeTask(_ task: TaskItem) {
        guard canComplete(task) else { return }
        #if os(macOS)
        if isAIPeer {
            setTaskDone(task.id, done: true)
            return
        }
        #endif
        do {
            send("\(AssistantMention.primary) mark done: \(task.title) #\(task.shortID)")
        }
    }

    #if os(macOS)
    func setAIPeer(_ on: Bool) {
        isAIPeer = on
        defaults.set(on, forKey: Keys.aiPeer)
        engine.roles = on ? [MeshDestination.aiRole] : []
        updateAwakeActivity()
        refreshRoomState()
        if on { checkOllama() }
    }

    /// Ticks or unticks a device id as admin (Mac Settings). Names are never used.
    func setAdmin(_ device: String, _ on: Bool) {
        let clean = device.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != displayName else { return }
        var ids = adminDevices.filter { $0 != clean }
        if on { ids.append(clean) }
        adminDevices = ids.sorted()
        rooms.update(activeRoom.id) { $0.admins = ids.sorted() }
        activeRoom = rooms.active
        joinedRooms = rooms.rooms
        memory.admins = activeRoom.adminDevices(selfID: displayName)
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
                self?.installedModels = models
                self?.ollamaReachable = true
                self?.visionModel = VisionModels.pick(installed: models, preferred: self?.preferredVisionModel)
                let digests = (try? await client.installedModelDigests()) ?? [:]
                self?.modelDigest = digests[client.model] ?? digests[client.model + ":latest"] ?? ""
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
                self?.ollamaReachable = false
                self?.installedModels = []
                self?.visionModel = nil
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
                self?.refreshProof()
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

    // MARK: Backup

    func exportMemoryData() throws -> Data { try memory.exportData() }

    /// Replaces team memory with a backup file (Settings asks for confirmation first). Linked
    /// phones get the new rules and drop the old ones right away.
    func importMemory(_ data: Data) throws {
        let backup = try OrgMemory.decodeBackup(data)
        memory.replace(with: backup)
        refreshOrg()
        for (name, state) in peerStates where state == .connected && !blocked.contains(name) {
            syncMemory(to: name)
        }
    }

    private func pushManifestToLinkedPeers() {
        guard isAIPeer else { return }
        for (name, state) in peerStates where state == .connected && !blocked.contains(name) {
            sendManifest(to: name)
        }
    }

    private func sendManifest(to device: String, room roomID: String? = nil) {
        let id = roomID ?? activeRoom.id
        guard let room = rooms.room(withID: id), let mem = memoryFor(id) else { return }
        var manifest = mem.manifest(clearedAt: clearedAtFor(id))
        // Knowledge titles only, filtered by the phone's role (Admins-only titles go to admins).
        manifest.library = knowledge.index(for: id).listings(isAdmin: mem.isAdmin(device))
        guard let body = SyncPayload(manifest: manifest).encoded() else { return }
        transmit(engine.makeOutgoing(kind: .sync, body: body, destination: .peer(device)), room: room, excluding: [])
    }

    /// Knowledge changed on this Mac: phones get the new title list right away.
    func knowledgeChanged(room roomID: String) {
        for (name, state) in peerStates where state == .connected && !blocked.contains(name) {
            sendManifest(to: name, room: roomID)
        }
    }

    /// This Mac may change the room's Knowledge only as a room admin.
    func canEditKnowledge(room roomID: String) -> Bool {
        memoryFor(roomID)?.isAdmin(displayName) ?? false
    }
    #endif

    private func refreshOrg() {
        org = memory.snapshot
    }

    // MARK: Sending

    /// One chat for everything: a line starting with "@pasa" (or the old "@libre") is an ask for
    /// the AI peer, anything else is team chat.
    /// `force` skips the "Answered above" check (the composer's "Ask again").
    /// `attachments`: media ids of photos sent just before, for an @pasa caption.
    func send(_ rawText: String, force: Bool = false, attachments: [UUID]? = nil) {
        var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let blocker = activeRoom.sendBlocker {
            lastProblem = blocker
            return
        }

        var kind: MessageKind = .chat
        if let question = AssistantMention.strip(text) {
            kind = .ask
            text = question
            if text.isEmpty { return }
            // The same question is still waiting: do not queue it twice (a question about new
            // photos is never a repeat).
            if attachments == nil, AskCoalescer.pendingDuplicate(of: text, from: displayName, in: entries) != nil {
                composerNote = "You already asked that. It sends once and Pasa answers once."
                return
            }
            // Answered in the last 10 minutes: point at the answer instead of asking again.
            if !force, attachments == nil, let hit = AskCoalescer.recentAnswer(of: text, in: entries) {
                composerNote = nil
                answeredHint = AnsweredHint(question: text, answerID: hit.answer.id)
                return
            }
        }
        composerNote = nil
        answeredHint = nil

        let destination: MeshDestination? = kind == .ask ? .role(MeshDestination.aiRole) : nil
        var message = engine.makeOutgoing(kind: kind, body: text, destination: destination)
        if kind == .ask, let attachments, !attachments.isEmpty { message.attachments = attachments }
        if kind == .ask {
            sentAsks[message.id] = Date()
            // Phones tell the Mac since when they were away (or cleared), for "what did I miss".
            if !isAIPeer {
                message.since = CacheSync.latest(awaySince, clearedAt)
                pendingAsks.add(message, room: activeRoom.id)
            }
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
            enqueueAsk(message, roomID: activeRoom.id)
            return
        }
        #endif

        entry.sentTo = transmit(message, excluding: [])
        entries.append(entry)
    }

    /// Quick actions: "What did I miss?", "My tasks", "More". Sent as "@pasa ..." asks.
    /// An identical @pasa question from this device is still unanswered (quick buttons go gray).
    func isAskPending(_ question: String) -> Bool {
        AskCoalescer.pendingDuplicate(of: question, from: displayName, in: entries) != nil
    }

    /// This device's own messages in the active room that have not left yet.
    var queuedMineCount: Int {
        entries.filter { $0.direction == .sent && $0.sentTo.isEmpty && $0.backfilled != true }.count
    }

    func quickAsk(_ text: String) {
        send("\(AssistantMention.primary) \(text)")
    }

    /// Hands a message to the transport. Parks it in the outbox if nobody can take it.
    /// Everything this device writes is sealed for the active room here, before it is sent or
    /// queued, so the outbox never holds plaintext. Already sealed packets (relayed ones, or
    /// outbox items) pass through untouched. `foreign` marks another room's packet (capped).
    /// `queueIfUnsent: false` is for media chunks and NACKs: they are never parked in the outbox
    /// (whoever holds the file serves it again when asked).
    /// `room` picks the room to seal for (the AI Mac answers in many rooms); default is active.
    @discardableResult
    private func transmit(_ plain: MeshMessage, room: Room? = nil, excluding: Set<String>, foreign: Bool = false, queueIfUnsent: Bool = true) -> [String] {
        let message: MeshMessage
        if plain.kind == .sealed {
            message = plain
        } else {
            let target = room ?? activeRoom
            do {
                message = try RoomEnvelope.seal(plain, in: target)
            } catch RoomEnvelope.SealError.noKey {
                lastProblem = target.sendBlocker ?? "No key for \(target.label) yet."
                return []
            } catch {
                lastProblem = "Could not seal message: \(error.localizedDescription)"
                return []
            }
        }
        guard let transport else {
            guard queueIfUnsent else { return [] }
            engine.enqueue(message, excluding: excluding, foreign: foreign)
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
        if sentTo.isEmpty && queueIfUnsent {
            engine.enqueue(message, excluding: excluding, foreign: foreign)
            scheduleSave()
        }
        outboxCount = engine.outbox.count
        return sentTo
    }

    private func flushOutbox() {
        let items = engine.drainOutbox()
        outboxCount = 0
        for item in items {
            let sentTo = transmit(item.message, excluding: item.excluding, foreign: item.foreign == true)
            if !sentTo.isEmpty, let index = entries.firstIndex(where: { $0.id == item.message.id && $0.direction == .sent }) {
                entries[index].sentTo = sentTo
            }
        }
        outboxCount = engine.outbox.count
        scheduleSave()
    }

    // MARK: Media (photos and voice notes)

    /// True when the file is in this device's media cache.
    func hasMedia(_ id: UUID) -> Bool { mediaStore.has(id) }

    /// Bytes of a cached media file (marks it recently used).
    func mediaData(_ id: UUID) -> Data? { mediaStore.data(id) }

    /// Sends a photo or voice note: saves it in the cache, sends the manifest as a timeline
    /// message (queued like chat when nobody is linked), then the chunks, paced.
    /// Sends what was staged in the composer: each photo as before, then the caption. An @pasa
    /// caption becomes one ask that names the photos.
    func sendStaged(_ plan: ComposerDraft.Plan) {
        var ids: [UUID] = []
        for photo in plan.photos {
            if let id = sendMedia(photo.data, kind: .image, mime: photo.mime, width: photo.width, height: photo.height) { ids.append(id) }
        }
        guard let text = plan.text else { return }
        if plan.isAsk, !ids.isEmpty {
            send(text, force: true, attachments: ids)
        } else {
            send(text)
        }
    }

    @discardableResult
    func sendMedia(_ data: Data, kind: MediaKind, mime: String, durationSeconds: Double? = nil, width: Int? = nil, height: Int? = nil) -> UUID? {
        if let blocker = activeRoom.sendBlocker {
            lastProblem = blocker
            return nil
        }
        guard !data.isEmpty, data.count <= MediaLimits.maxBytes else {
            lastProblem = "That \(kind == .image ? "photo" : "voice note") is too large to send (\(data.count / 1024) KB, limit \(MediaLimits.maxBytes / 1024) KB)."
            return nil
        }
        let manifest = MediaChunker.manifest(for: data, kind: kind, mime: mime, durationSeconds: durationSeconds, width: width, height: height)
        guard mediaStore.put(manifest.mediaId, data: data, ext: manifest.fileExtension), let body = manifest.encoded() else {
            lastProblem = "Could not save the \(kind == .image ? "photo" : "voice note") on this device."
            return nil
        }
        mediaVersion += 1
        let message = engine.makeOutgoing(kind: .media, body: body, destination: nil)
        var entry = ChatEntry(id: message.id, message: message, direction: .sent, receivedAt: Date())
        entry.sentTo = transmit(message, excluding: [])
        entries.append(entry)
        mediaRoom[manifest.mediaId] = activeRoom.id
        queueChunks(of: data, manifest: manifest, indexes: Array(0..<manifest.chunkCount), outgoing: true, room: activeRoom.id)
        if kind == .audio, !isAIPeer, NoAIHost.isAway(aiAvailability) { aiNotice = NoAIHost.voiceLine }
        #if os(macOS)
        if kind == .audio { transcribeIfNeeded(manifest.mediaId) }
        if kind == .image { photoArrived(manifest.mediaId) }
        #endif
        return manifest.mediaId
    }

    private func queueChunks(of data: Data, manifest: MediaManifest, indexes: [Int], outgoing: Bool, room: String) {
        for i in indexes {
            guard let chunk = MediaChunker.chunk(of: data, manifest: manifest, index: i), let body = chunk.encoded() else { continue }
            let message = engine.makeOutgoing(kind: .chunk, body: body, destination: nil)
            chunkQueue.append(ChunkJob(message: message, mediaId: manifest.mediaId, index: i, count: manifest.chunkCount, outgoing: outgoing, room: room))
        }
        startChunkPump()
    }

    /// Sends queued chunks one at a time with a short pause, so a photo does not flood the links
    /// and chat keeps flowing in between.
    private func startChunkPump() {
        guard chunkPump == nil, !chunkQueue.isEmpty else { return }
        chunkPump = Task { [weak self] in
            while true {
                guard let service = self, !service.chunkQueue.isEmpty else { break }
                let job = service.chunkQueue.removeFirst()
                if let room = service.rooms.room(withID: job.room) {
                    service.transmit(job.message, room: room, excluding: [], queueIfUnsent: false)
                }
                if job.outgoing {
                    if job.index + 1 >= job.count {
                        service.mediaProgress.removeValue(forKey: job.mediaId)
                    } else {
                        service.mediaProgress[job.mediaId] = Double(job.index + 1) / Double(job.count)
                    }
                }
                try? await Task.sleep(nanoseconds: UInt64(MediaLimits.paceSeconds * 1_000_000_000))
            }
            self?.chunkPump = nil
        }
    }

    /// Manifest of a media message in this room's timeline.
    private func manifest(for mediaId: UUID) -> MediaManifest? {
        let room = mediaRoom[mediaId] ?? activeRoom.id
        for entry in entriesFor(room).reversed() where entry.message.kind == .media {
            if let m = MediaManifest.decode(entry.message.body), m.mediaId == mediaId { return m }
        }
        return nil
    }

    /// Registers media messages whose file is not here yet, so missing chunks get asked for.
    private func expectMissingMedia(in list: [ChatEntry], room: String? = nil) {
        let roomID = room ?? activeRoom.id
        for entry in list where entry.message.kind == .media {
            guard let m = MediaManifest.decode(entry.message.body) else { continue }
            mediaRoom[m.mediaId] = roomID
            guard !mediaStore.has(m.mediaId) else { continue }
            assembler.expect(m)
            if roomID == activeRoom.id { mediaProgress[m.mediaId] = assembler.progress(m.mediaId) ?? 0 }
        }
    }

    private func receiveChunk(_ message: MeshMessage) {
        guard let chunk = MediaChunk.decode(message.body), !mediaStore.has(chunk.mediaId) else { return }
        let known = assembler.manifest(chunk.mediaId) ?? manifest(for: chunk.mediaId)
        switch assembler.add(chunk) {
        case .ignored:
            break
        case .progress(let fraction):
            mediaProgress[chunk.mediaId] = fraction
        case .complete(let data):
            mediaProgress.removeValue(forKey: chunk.mediaId)
            if mediaStore.put(chunk.mediaId, data: data, ext: known?.fileExtension ?? "bin") {
                mediaVersion += 1
                #if os(macOS)
                if known?.kind == .audio { transcribeIfNeeded(chunk.mediaId) }
                if known?.kind == .image { photoArrived(chunk.mediaId) }
                #endif
            } else {
                lastProblem = "Could not save a received photo or voice note (cache full or disk error)."
            }
        case .corrupt:
            mediaProgress[chunk.mediaId] = 0
            lastProblem = "A photo or voice note arrived damaged (checksum mismatch). Asking for it again."
        }
    }

    /// Someone is missing chunks: send the ones this device has (from the cache, or from its own
    /// unfinished copy). At most once every 4 s per file and requester.
    private func answerNack(_ message: MeshMessage, room: String) {
        guard let nack = MediaNack.decode(message.body) else { return }
        let key = "\(nack.mediaId.uuidString)|\(message.origin)"
        let now = Date()
        if let last = nackAnswered[key], now.timeIntervalSince(last) < 4 { return }
        if let data = mediaStore.data(nack.mediaId) {
            nackAnswered[key] = now
            // Chunk layout only depends on size, chunk size and hash, so any holder rebuilds it.
            let layout = MediaChunker.manifest(for: data, kind: .image, mime: "application/octet-stream", mediaId: nack.mediaId)
            queueChunks(of: data, manifest: layout, indexes: nack.missing, outgoing: false, room: room)
            return
        }
        let parts = nack.missing.compactMap { assembler.part(nack.mediaId, index: $0) }
        guard !parts.isEmpty else { return }
        nackAnswered[key] = now
        for chunk in parts {
            guard let body = chunk.encoded() else { continue }
            let m = engine.makeOutgoing(kind: .chunk, body: body, destination: nil)
            chunkQueue.append(ChunkJob(message: m, mediaId: chunk.mediaId, index: chunk.index, count: chunk.count, outgoing: false, room: room))
        }
        startChunkPump()
    }

    /// Asks the room for chunks of stalled transfers (or all unfinished ones when a link came up).
    private func sendDueNacks(force: Bool = false) {
        assembler.prune()
        guard connectedCount > 0 else { return }
        for nack in assembler.dueForNack(force: force) {
            guard let body = nack.encoded(), let room = rooms.room(withID: mediaRoom[nack.mediaId] ?? activeRoom.id) else { continue }
            let m = engine.makeOutgoing(kind: .mediaNack, body: body, destination: nil, ttl: 4)
            transmit(m, room: room, excluding: [], queueIfUnsent: false)
        }
    }

    /// Chunks can finish before the manifest arrives (saved as .bin): rename with the real type.
    private func fixMediaExtension(_ media: MeshMessage) {
        guard let m = MediaManifest.decode(media.body), mediaStore.url(m.mediaId)?.pathExtension == "bin",
              let data = mediaStore.data(m.mediaId) else { return }
        mediaStore.remove(m.mediaId)
        mediaStore.put(m.mediaId, data: data, ext: m.fileExtension)
        #if os(macOS)
        if m.kind == .audio { transcribeIfNeeded(m.mediaId) }
        if m.kind == .image { photoArrived(m.mediaId) }
        #endif
    }

    /// A voice note transcript from the Mac: shown under the voice note bubble.
    private func applyTranscript(_ message: MeshMessage, room: String? = nil) {
        guard let target = message.replyTo, let payload = TranscriptPayload.decode(message.body) else { return }
        let line = payload.displayLine
        guard !line.isEmpty else { return }
        updateEntry(target, room: room ?? activeRoom.id) { entry in
            guard entry.transcript != line else { return false }
            entry.transcript = line
            return true
        }
    }

    // MARK: Per-room timelines (the AI Mac keeps background rooms in RoomContext)

    private func entriesFor(_ room: String) -> [ChatEntry] {
        if room == activeRoom.id { return entries }
        #if os(macOS)
        return context(room)?.entries ?? []
        #else
        return []
        #endif
    }

    private func appendEntry(_ entry: ChatEntry, room: String) {
        if room == activeRoom.id { entries.append(entry); return }
        #if os(macOS)
        guard let ctx = context(room) else { return }
        ctx.entries.append(entry)
        ctx.dirty = true
        #endif
    }

    /// Changes the newest entry with this id. `change` returns false when nothing changed.
    private func updateEntry(_ id: UUID, room: String, _ change: (inout ChatEntry) -> Bool) {
        if room == activeRoom.id {
            guard let index = entries.lastIndex(where: { $0.id == id }) else { return }
            var copy = entries[index]
            if change(&copy) { entries[index] = copy }
            return
        }
        #if os(macOS)
        guard let ctx = context(room), let index = ctx.entries.lastIndex(where: { $0.id == id }) else { return }
        if change(&ctx.entries[index]) { ctx.dirty = true }
        #endif
    }

    private func clearedAtFor(_ room: String) -> Date? {
        room == activeRoom.id ? clearedAt : rooms.room(withID: room)?.clearedAt
    }

    #if os(macOS)
    /// Background room context, loaded from disk the first time the AI Mac needs it.
    private func context(_ room: String) -> RoomContext? {
        guard room != activeRoom.id, let record = rooms.room(withID: room) else { return nil }
        if let ctx = contexts[room] { return ctx }
        let url = rooms.fileURL("timeline.json", roomID: room)
        let saved = url.map { TimelineStore.load(from: $0, limit: timelineLimit) } ?? PersistedTimeline()
        let mem = OrgMemory(fileURL: rooms.fileURL(MeshService.memoryFileName, roomID: room), admins: record.adminDevices(selfID: displayName))
        let ctx = RoomContext(roomID: room, memory: mem, entries: TimelineStore.dropping(saved.entries, before: record.clearedAt), timelineURL: url)
        for entry in ctx.entries.suffix(100) { engine.markSeen(entry.id) }
        contexts[room] = ctx
        return ctx
    }

    private func memoryFor(_ room: String) -> OrgMemory? {
        room == activeRoom.id ? memory : context(room)?.memory
    }
    #endif

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
    private func serveBackfill(to device: String, request: SyncRequest, room roomID: String) {
        guard let room = rooms.room(withID: roomID) else { return }
        let list = entriesFor(roomID)
        var missing = Backfill.select(from: list, for: device, request: request, macClearedAt: clearedAtFor(roomID))
        guard !missing.isEmpty else { return }
        // Voice note transcripts ride along as small .transcript messages.
        for m in missing where m.kind == .media {
            guard let text = list.last(where: { $0.id == m.id })?.transcript, !text.isEmpty else { continue }
            var t = engine.makeOutgoing(kind: .transcript, body: TranscriptPayload(text: text, locale: "").encoded() ?? "",
                                        destination: .peer(device), replyTo: m.id)
            t.createdAt = m.createdAt
            missing.append(t)
        }
        let chunks = Backfill.chunk(missing)
        for (index, chunk) in chunks.enumerated() {
            let batch = SyncBatch(messages: chunk, part: index + 1, parts: chunks.count)
            guard let body = SyncPayload(batch: batch).encoded() else { continue }
            transmit(engine.makeOutgoing(kind: .sync, body: body, destination: .peer(device)), room: room, excluding: [])
        }
    }

    /// Phone side: merge a backfill chunk (dedupe by id, keep time order, update caches).
    /// Messages older than the clear-timeline watermark are skipped. Rule and task cards only
    /// show when they changed the cache (the Mac's sync-on-link usually got there first).
    private func applyBackfill(_ batch: SyncBatch) {
        let now = Date()
        var incoming: [ChatEntry] = []
        var transcripts: [MeshMessage] = []
        for m in batch.messages {
            engine.markSeen(m.id, now: now)
            if let clearedAt, m.createdAt < clearedAt { continue }
            if m.kind == .transcript { transcripts.append(m); continue }
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
        for t in transcripts { applyTranscript(t) }
        expectMissingMedia(in: incoming)
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
                sendDueNacks(force: true)
                publishManifests(to: name)
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
            if text.contains("Local Network") { localNetworkDenied = true }
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

        // Clear signals (room beacons, AI status): relayed with their short ttl, never queued.
        if message.kind == .beacon || message.kind == .aiStatus {
            if let forward = decision.forward {
                sendClearForward(forward, excluding: decision.forwardExcluding)
            }
            if let d = decision.deliver { handleClearSignal(d) }
            return
        }

        // Which joined room (if any) this packet belongs to. Phones read only the active room's
        // content; every device handles room control of all its rooms; the AI Mac reads all.
        let packetRoom: Room? = message.kind == .sealed ? message.room.flatMap { rooms.room(withID: $0) } : nil
        let isActive = packetRoom?.id == activeRoom.id
        let notMine = message.kind == .sealed && !isActive
        var opened: MeshMessage?
        if let d = decision.deliver, d.kind == .sealed, let r = packetRoom {
            opened = RoomEnvelope.open(d, in: r)
            if opened == nil, RoomEnvelope.isAhead(d, of: r) { requestManifest(r.id) }
        }
        let transient = opened.map { $0.kind == .chunk || $0.kind == .mediaNack } ?? false
        if let forward = decision.forward {
            transmit(forward, excluding: decision.forwardExcluding, foreign: notMine, queueIfUnsent: !transient)
            relayedCount += 1
            if packetRoom == nil && message.kind == .sealed { foreignRelayedCount += 1 }
        }

        guard var delivered = decision.deliver else { return }
        var roomID = activeRoom.id
        if delivered.kind == .sealed {
            // Another room's packet (or one that fails authentication): relayed above, never
            // shown or stored here.
            guard let r = packetRoom, let opened else { return }
            delivered = opened
            roomID = r.id
            if delivered.kind == .sealed { return }
            if delivered.kind == .roomControl { handleRoomControl(delivered, roomID: r.id); return }
            // Joined by passcode, no manifest heard yet, and the room still talks with the
            // passcode key: it is a room from before admin keys. Stop waiting.
            if r.gov?.pending == true, r.gov?.manifest == nil, (opened.epoch ?? 0) == 0 {
                rooms.update(r.id) { $0.gov?.pending = false }
                refreshRoomState()
            }
            if !isActive && !isAIPeer { return }
        } else if !activeRoom.isDefault {
            // Plaintext from a build before rooms belongs to the Default room only.
            return
        } else if delivered.kind == .roomControl {
            return
        }
        handleDelivered(delivered, room: roomID)
    }

    /// Relays a beacon or AI status without sealing (they are clear by design).
    private func sendClearForward(_ forward: MeshMessage, excluding: Set<String>) {
        guard let transport, let data = try? MeshCodec.encode(forward) else { return }
        if !transport.send(data, excluding: excluding).isEmpty { relayedCount += 1 }
    }

    private func handleClearSignal(_ message: MeshMessage) {
        guard let blob = PasaJSON.value(SignedBlob.self, from: message.body) else { return }
        switch message.kind {
        case .beacon:
            if beacons.ingest(blob) { nearbyRooms = beacons.nearby() }
        case .aiStatus:
            let transition = aiTracker.ingest(blob)
            refreshAIAvailability()
            if case .woke = transition { resendDueAsks() }
        default:
            break
        }
    }

    /// A message of one of this device's rooms, opened. `room` is the active room on phones;
    /// on the AI Mac it can be any room it serves.
    private func handleDelivered(_ delivered: MeshMessage, room roomID: String) {
        let active = roomID == activeRoom.id
        if let name = delivered.senderName, delivered.origin != displayName {
            learn(device: delivered.origin, name: name)
        }

        switch delivered.kind {
        case .chunk: receiveChunk(delivered); return
        case .mediaNack: answerNack(delivered, room: roomID); return
        case .transcript: applyTranscript(delivered, room: roomID); return
        default: break
        }

        if delivered.kind == .sync {
            // Backfill traffic never shows in the timeline.
            guard let payload = SyncPayload.decode(delivered.body) else { return }
            if let request = payload.request, isAIPeer {
                serveBackfill(to: delivered.origin, request: request, room: roomID)
                #if os(macOS)
                // Background rooms get their rules and tasks here (the active room on link).
                if !active { syncMemory(to: delivered.origin, room: roomID) }
                #endif
            }
            guard active else { return }
            if let manifest = payload.manifest, !isAIPeer {
                // The Mac is the source of truth: drop cached rules and tasks it no longer has.
                CacheSync.applyManifest(manifest, to: memory)
                if let library = manifest.library { libraryListings = library }
                adoptClear(manifest.clearedAt)
                refreshOrg()
            }
            if let batch = payload.batch { applyBackfill(batch) }
            return
        }
        // Already in the timeline (for example restored from disk, or backfilled): do not repeat it.
        if entriesFor(roomID).contains(where: { $0.id == delivered.id }) { return }

        // Phones: a rule or task update only becomes a card when it changed the cached copy and
        // is not a silent sync-on-link update. Reconnects no longer flood the chat.
        if !isAIPeer && (delivered.kind == .task || delivered.kind == .rule) {
            let result = CacheSync.applyCard(delivered, to: memory)
            if result.changed { refreshOrg() }
            guard result.show else { return }
        }

        var entry = ChatEntry(id: delivered.id, message: delivered, direction: .received, receivedAt: Date())
        if delivered.kind == .answer, let askID = delivered.replyTo {
            // An answer re-delivered after a resend: show it once.
            if entriesFor(roomID).contains(where: { $0.message.kind == .answer && $0.message.replyTo == askID }) {
                pendingAsks.resolve(askID)
                return
            }
            pendingAsks.resolve(askID)
            if let askedAt = sentAsks.removeValue(forKey: askID) {
                entry.roundTripMs = Int((Date().timeIntervalSince(askedAt) * 1000).rounded())
                refreshWaitingAsks()
            }
            scheduleSave()
        }
        appendEntry(entry, room: roomID)

        switch delivered.kind {
        case .task, .rule:
            break   // phones handled above; the AI peer is the source of truth
        case .chat:
            #if os(macOS)
            memoryFor(roomID)?.recordChat(from: senderLabel(for: delivered), text: delivered.body, at: delivered.createdAt, device: delivered.origin)
            #endif
        case .ask:
            #if os(macOS)
            if isAIPeer { enqueueAsk(delivered, roomID: roomID) }
            #endif
        case .media:
            expectMissingMedia(in: [entry], room: roomID)
            fixMediaExtension(delivered)
            #if os(macOS)
            if let m = MediaManifest.decode(delivered.body), m.kind == .audio { transcribeIfNeeded(m.mediaId) }
            #endif
        case .answer, .ack, .sync, .sealed, .chunk, .mediaNack, .transcript, .roomControl, .beacon, .aiStatus:
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
    // MARK: Voice note transcripts (Mac, on-device speech recognition)

    func setSpeechLocale(_ id: String) {
        speechLocale = id
        defaults.set(id, forKey: Keys.speechLocale)
    }

    /// The AI Mac transcribes each voice note once, on the device (never a server), shows the
    /// text under the bubble, sends it to the room, and treats "@pasa ..." / "Pasa, ..." as an ask.
    /// Works in every room the Mac serves.
    private func transcribeIfNeeded(_ mediaId: UUID) {
        guard isAIPeer, !transcribing.contains(mediaId), let url = mediaStore.url(mediaId) else { return }
        let roomID = mediaRoom[mediaId] ?? activeRoom.id
        let list = entriesFor(roomID)
        guard let index = list.lastIndex(where: { $0.message.kind == .media && MediaManifest.decode($0.message.body)?.mediaId == mediaId }),
              list[index].transcript == nil else { return }
        let media = list[index].message
        let locale = speechLocale
        transcribing.insert(mediaId)
        Task { [weak self] in
            let payload = await VoiceTranscriber.transcribe(url: url, localeID: locale)
            self?.finishTranscript(payload, mediaId: mediaId, media: media, room: roomID)
        }
    }

    private func finishTranscript(_ payload: TranscriptPayload, mediaId: UUID, media: MeshMessage, room roomID: String) {
        transcribing.remove(mediaId)
        guard let room = rooms.room(withID: roomID) else { return }
        updateEntry(media.id, room: roomID) { entry in
            entry.transcript = payload.displayLine
            return true
        }
        if let body = payload.encoded() {
            transmit(engine.makeOutgoing(kind: .transcript, body: body, destination: nil, replyTo: media.id), room: room, excluding: [])
        }
        let text = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        memoryFor(roomID)?.recordChat(from: senderLabel(for: media), text: "(voice note) \(text)", at: media.createdAt, device: media.origin)
        if let question = VoiceAsk.extract(text) {
            // Same id as the voice note, so the answer's replyTo points at it.
            var ask = media
            ask.kind = .ask
            ask.body = question
            ask.destination = .role(MeshDestination.aiRole)
            ask.since = nil
            enqueueAsk(ask, roomID: roomID)
        }
    }

    // MARK: Multi-room ask queue (one model call at a time, rooms take turns)

    /// Queues an ask for the model. Repeats (a phone resending after the Mac woke) never get a
    /// second answer: the stored answer is re-delivered instead.
    private func enqueueAsk(_ ask: MeshMessage, roomID: String) {
        guard let room = rooms.room(withID: roomID), room.canSend else { return }
        switch askQueue.enqueue(room: roomID, askID: ask.askKey, payload: .ask(ask)) {
        case .queued:
            pumpAsks()
        case .duplicate:
            break
        case .alreadyAnswered(let answerID):
            redeliverAnswer(for: ask, answerID: answerID, room: roomID)
        case .roomFull:
            let reply = AIReply(text: "Too many questions are waiting in \(room.displayName) right now. Ask again in a minute.")
            sendAnswer(reply, to: ask, room: roomID, intent: "busy", error: "room queue full")
        }
        aiQueueDepth = askQueue.depth
    }

    /// Starts the next ask if the model is free and the Mac is awake.
    private func pumpAsks() {
        guard !askRunning, isAIPeer, let job = askQueue.next() else { return }
        askRunning = true
        aiQueueDepth = askQueue.depth
        Task { [weak self] in
            await self?.run(job)
            guard let self else { return }
            self.askRunning = false
            self.aiQueueDepth = self.askQueue.depth
            self.pumpAsks()
        }
    }

    private func run(_ job: AskJob<AIJob>) async {
        let roomID = job.room
        guard let room = rooms.room(withID: roomID), room.canSend, let mem = memoryFor(roomID) else {
            askQueue.finish(job.askID, answerID: nil)
            return
        }
        let ask: MeshMessage
        switch job.payload {
        case .ask(let a):
            ask = a
        case .photo(let media, let photoAsk):
            await runPhoto(media: media, ask: photoAsk, room: roomID, memory: mem)
            askQueue.finish(job.askID, answerID: nil)
            return
        case .digest(let due):
            await runDigest(due, room: room, memory: mem)
            askQueue.finish(job.askID, answerID: nil)
            return
        case .summaryNow:
            await runSummaryNow(room: room, memory: mem, replyTo: nil)
            askQueue.finish(job.askID, answerID: nil)
            return
        }
        // An @pasa caption sent with staged photos: answer about the first photo. If it has not
        // fully arrived yet, park the ask; photoArrived picks it up.
        if aiEngine == .assistant, let first = ask.attachments?.first {
            if let media = mediaMessage(first, in: roomID), mediaStore.data(first) != nil {
                await runPhoto(media: media, ask: ask, room: roomID, memory: mem)
            } else {
                photoAsks[first] = (ask, roomID)
            }
            askQueue.finish(job.askID, answerID: nil)
            saveLedger()
            return
        }
        // "@pasa what is this": check the newest photo in this room with the vision model.
        if aiEngine == .assistant, IntentParser.fastPath(ask.body)?.kind == .describePhoto {
            if let media = latestPhoto(in: roomID, preferFrom: ask.origin) {
                await runPhoto(media: media, ask: ask, room: roomID, memory: mem)
            } else {
                sendAnswer(AIReply(text: "I do not see a photo in \(room.displayName) from the last 30 minutes. Send one, then ask \(AssistantMention.primary) what is this."),
                           to: ask, room: roomID, intent: IntentKind.describePhoto.rawValue, error: nil)
            }
            askQueue.finish(job.askID, answerID: nil)
            saveLedger()
            return
        }
        switch aiEngine {
        case .assistant:
            assistant.serve(room: roomID, memory: mem, clearedAt: clearedAtFor(roomID))
            assistant.library = knowledge.index(for: roomID)
            assistant.embedder = knowledge.answerEmbedder
            assistant.roomLabel = room.displayName
            assistant.digestSchedule = digestSchedule
            let outcome = await assistant.handle(ask.body, from: ask.origin, since: ask.since, askID: ask.askKey)
            contextStats = assistant.contextStats
            if outcome.error != nil, askQueue.wasCutBySleep(job) {
                // The Mac slept during the model call: answer it after wake instead.
                askQueue.requeueInFlight()
                return
            }
            if let digest = outcome.digest {
                // "@pasa summary": one summary card for the whole room (answers the ask too).
                recordDigest(digest, room: roomID)
                let id = sendCard(digest.text, card: "summary", room: roomID, replyTo: ask.askKey, personal: digest.personal,
                                  proof: proof(model: digest.model, tps: digest.tokensPerSecond, ms: outcome.latencyMs), asker: ask)
                askQueue.finish(job.askID, answerID: id)
                saveLedger()
                return
            }
            var reply = AIReply(text: outcome.reply, compact: outcome.compact, model: outcome.model,
                                latencyMs: outcome.latencyMs, tokensPerSecond: outcome.tokensPerSecond,
                                checked: outcome.intent == .answer ? outcome.checked : nil,
                                rulesUsed: outcome.rulesUsed.isEmpty ? nil : outcome.rulesUsed,
                                unverifiedRules: outcome.unverifiedRules.isEmpty ? nil : outcome.unverifiedRules,
                                noRule: outcome.noRule)
            reply.docRefs = outcome.docRefs.isEmpty ? nil : outcome.docRefs
            let answerID = sendAnswer(reply, to: ask, room: roomID, intent: outcome.intent.rawValue, error: outcome.error,
                                      promptTokens: outcome.promptTokensEstimate, promptEval: outcome.promptEvalCount)
            askQueue.finish(job.askID, answerID: answerID)
            for task in outcome.taskUpdates { notifyTask(task, room: roomID, also: ask.origin) }
            for rule in outcome.ruleUpdates { broadcastRule(rule, room: roomID) }
            if roomID == activeRoom.id { refreshOrg() }
        case .plain, .echo:
            let responder: any AIResponder = aiEngine == .echo ? EchoResponder() : OllamaResponder(client: makeClient())
            let started = Date()
            var reply: AIReply
            var failure: String? = nil
            do {
                reply = try await responder.respond(to: ask.body, from: ask.origin)
            } catch {
                if askQueue.wasCutBySleep(job) { askQueue.requeueInFlight(); return }
                let message = (error as? LLMError)?.errorDescription ?? error.localizedDescription
                failure = message
                reply = AIReply(text: message)
            }
            if reply.latencyMs == 0 { reply.latencyMs = Int(Date().timeIntervalSince(started) * 1000) }
            let answerID = sendAnswer(reply, to: ask, room: roomID, intent: "answer", error: failure)
            askQueue.finish(job.askID, answerID: answerID)
        }
        saveLedger()
    }

    private func saveLedger() {
        guard let url = MeshService.storageURL("ai-ledger.json"),
              let data = try? JSONEncoder().encode(askQueue.exportLedger()) else { return }
        saveQueue.async { try? data.write(to: url, options: .atomic) }
    }

    /// Sends the stored answer again (new packet id, same replyTo) for an ask answered before.
    private func redeliverAnswer(for ask: MeshMessage, answerID: UUID?, room roomID: String) {
        guard ask.origin != displayName, let room = rooms.room(withID: roomID) else { return }
        let list = entriesFor(roomID)
        guard let stored = list.last(where: { $0.id == answerID && $0.message.kind == .answer })
                ?? list.last(where: { $0.message.kind == .answer && $0.message.replyTo == ask.askKey }) else { return }
        var copy = engine.makeOutgoing(kind: .answer, body: stored.message.body, destination: .peer(ask.origin),
                                       replyTo: ask.askKey, replyPath: ask.hops)
        copy.compact = stored.message.compact
        copy.model = stored.message.model
        copy.latencyMs = stored.message.latencyMs
        copy.tokensPerSecond = stored.message.tokensPerSecond
        copy.checked = stored.message.checked
        copy.rulesUsed = stored.message.rulesUsed
        copy.unverifiedRules = stored.message.unverifiedRules
        copy.noRule = stored.message.noRule
        copy.docRefs = stored.message.docRefs
        copy.proof = stored.message.proof
        copy.card = stored.message.card
        copy.personal = stored.message.personal
        copy.suggestions = stored.message.suggestions
        transmit(copy, room: room, excluding: [])
    }

    @discardableResult
    private func sendAnswer(_ reply: AIReply, to ask: MeshMessage, room roomID: String, intent: String, error: String?,
                            promptTokens: Int? = nil, promptEval: Int? = nil) -> UUID {
        var message = engine.makeOutgoing(
            kind: .answer,
            body: reply.text,
            destination: .peer(ask.origin),
            replyTo: ask.askKey,
            replyPath: ask.hops
        )
        message.compact = reply.compact
        message.model = reply.model
        message.latencyMs = reply.latencyMs
        message.tokensPerSecond = reply.tokensPerSecond
        message.checked = reply.checked
        message.rulesUsed = reply.rulesUsed
        message.unverifiedRules = reply.unverifiedRules
        message.noRule = reply.noRule
        message.docRefs = reply.docRefs
        message.proof = proof(model: reply.model, tps: reply.tokensPerSecond, ms: reply.latencyMs)
        logProof(message.proof!, room: roomID, kind: intent)

        var entry = ChatEntry(id: message.id, message: message, direction: .sent, receivedAt: Date())
        if ask.origin == displayName {
            // Local ask on the AI Mac: show the answer as received with a local round trip.
            entry.direction = .received
            if let askedAt = sentAsks.removeValue(forKey: ask.askKey) {
                entry.roundTripMs = Int((Date().timeIntervalSince(askedAt) * 1000).rounded())
                refreshWaitingAsks()
            }
        } else if let room = rooms.room(withID: roomID) {
            entry.sentTo = transmit(message, room: room, excluding: [])
        }
        appendEntry(entry, room: roomID)

        assistantLog.append(AssistantLogEntry(
            id: message.id, at: Date(), asker: ask.origin, question: ask.body, askHops: ask.hopCount,
            intent: intent, reply: reply.text, model: reply.model, latencyMs: reply.latencyMs,
            tokensPerSecond: reply.tokensPerSecond, compact: reply.compact, error: error,
            checked: reply.checked ?? [], promptTokensEstimate: promptTokens, promptEvalCount: promptEval,
            roomID: roomID, roomLabel: rooms.room(withID: roomID)?.displayName ?? ""
        ))
        if assistantLog.count > 200 { assistantLog.removeFirst(assistantLog.count - 200) }
        return message.id
    }

    /// Sends a task to its assignee's device (and its creator, when the task is finished).
    /// `also`: the device that finished it (an admin's Done button), so its copy updates too.
    private func notifyTask(_ task: TaskItem, room roomID: String? = nil, also: String? = nil) {
        let id = roomID ?? activeRoom.id
        guard let room = rooms.room(withID: id), let body = MeshPayload.encode(task) else { return }
        var targets: [String] = []
        if let device = task.assigneeDevice { targets.append(device) }
        if task.status == .done, !targets.contains(task.createdBy) { targets.append(task.createdBy) }
        if task.status == .done, let also, !targets.contains(also) { targets.append(also) }
        for device in targets where device != displayName {
            let message = engine.makeOutgoing(kind: .task, body: body, destination: .peer(device))
            var entry = ChatEntry(id: message.id, message: message, direction: .sent, receivedAt: Date())
            entry.sentTo = transmit(message, room: room, excluding: [])
            appendEntry(entry, room: id)
        }
    }

    /// Broadcasts a rule summary (no history) so every phone caches a read-only copy.
    private func broadcastRule(_ rule: RuleEntry, room roomID: String? = nil) {
        let id = roomID ?? activeRoom.id
        guard let room = rooms.room(withID: id), let body = MeshPayload.encode(rule.meshSummary) else { return }
        let message = engine.makeOutgoing(kind: .rule, body: body, destination: nil)
        var entry = ChatEntry(id: message.id, message: message, direction: .sent, receivedAt: Date())
        entry.sentTo = transmit(message, room: room, excluding: [])
        appendEntry(entry, room: id)
    }

    /// When a device links (active room) or asks for backfill (any room): send the manifest
    /// (so stale cached rules and tasks are dropped and a team-wide clear sticks), then the
    /// rules and its open tasks as silent updates that refresh the phone's cache without cards.
    private func syncMemory(to device: String, room roomID: String? = nil) {
        guard isAIPeer else { return }
        let id = roomID ?? activeRoom.id
        guard let room = rooms.room(withID: id), room.canSend, let mem = memoryFor(id) else { return }
        sendManifest(to: device, room: id)
        // allRules includes tombstones, so a phone still caching a deleted rule drops it.
        for rule in mem.allRules.suffix(60) {
            guard let body = MeshPayload.encode(rule.meshSummary) else { continue }
            var message = engine.makeOutgoing(kind: .rule, body: body, destination: .peer(device))
            message.silent = true
            transmit(message, room: room, excluding: [])
        }
        for task in mem.tasks(forDevice: device, roster: roster).prefix(30) {
            guard let body = MeshPayload.encode(task) else { continue }
            var message = engine.makeOutgoing(kind: .task, body: body, destination: .peer(device))
            message.silent = true
            transmit(message, room: room, excluding: [])
        }
    }

    // MARK: Mac sleep and wake

    /// willSleep: pause the queue and tell the mesh the AI is asleep (best effort: the radio may
    /// go down before it leaves). didWake: re-warm the model, re-announce, answer the backlog.
    private func observeSleep() {
        guard sleepObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.macWillSleep() }
        })
        sleepObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.macDidWake() }
        })
    }

    private func macWillSleep() {
        macAsleep = true
        askQueue.willSleep()
        if isAIPeer { sendAIStatus(asleep: true) }
        refreshAIAvailability()
    }

    private func macDidWake() {
        macAsleep = false
        askQueue.didWake()
        transport?.restartDiscovery(.wake)
        refreshTransportStats()
        if isAIPeer {
            sendAIStatus(asleep: false)
            checkOllama()
        }
        lastDigestCheck = .distantPast   // a digest the Mac slept through runs now
        refreshAIAvailability()
        pumpAsks()
    }

    private func sendAIStatus(asleep: Bool, now: Date = Date()) {
        lastStatusAt = now
        let status = AIStatus(device: displayName, state: asleep ? .asleep : .awake, model: ollamaModel,
                              queue: askQueue.depth, rooms: servedRoomIDs, at: now, internet: internetState)
        guard let blob = AIStatusTracker.make(status, identity: identity), let body = PasaJSON.string(blob) else { return }
        sendClear(engine.makeOutgoing(kind: .aiStatus, body: body, destination: nil, ttl: AIStatusTracker.ttl))
    }

    // MARK: Local proof (badge on every answer, Proof panel)

    /// Name the badge shows for this Mac: the chosen display name ("Site Office"), else the device id.
    var macProofName: String { personName.isEmpty ? displayName : personName }

    private func proof(model: String?, tps: Double?, ms: Int) -> AIProof {
        AIProof(mac: macProofName, model: model, internet: internetState, tokensPerSecond: tps, latencyMs: ms,
                digest: model != nil && model == ollamaModel && !modelDigest.isEmpty ? String(modelDigest.prefix(12)) : nil)
    }

    private func logProof(_ p: AIProof, room roomID: String, kind: String) {
        proofLog.add(.init(at: Date(), room: rooms.room(withID: roomID)?.displayName ?? "", kind: kind, proof: p))
    }

    /// Proof panel: what Ollama has loaded and how much memory it uses (local /api/ps).
    func refreshProof() {
        let client = makeClient()
        Task { [weak self] in
            let running = (try? await client.runningModels()) ?? []
            self?.ollamaRunning = running
        }
    }

    /// Sends an AI card (daily summary or photo check) to everyone in the room.
    @discardableResult
    private func sendCard(_ text: String, card: String, room roomID: String, replyTo: UUID?, personal: [String: String]? = nil,
                          suggestions: [String]? = nil, proof cardProof: AIProof, asker: MeshMessage? = nil) -> UUID {
        var message = engine.makeOutgoing(kind: .answer, body: text, destination: nil, replyTo: replyTo, replyPath: asker?.hops)
        message.card = card
        message.personal = personal
        message.suggestions = suggestions?.isEmpty == false ? suggestions : nil
        message.proof = cardProof
        message.model = cardProof.model
        message.latencyMs = cardProof.latencyMs
        message.tokensPerSecond = cardProof.tokensPerSecond
        var entry = ChatEntry(id: message.id, message: message, direction: .sent, receivedAt: Date())
        if let asker, asker.origin == displayName {
            entry.direction = .received
            if let askedAt = sentAsks.removeValue(forKey: asker.askKey) {
                entry.roundTripMs = Int((Date().timeIntervalSince(askedAt) * 1000).rounded())
                refreshWaitingAsks()
            }
        }
        if let room = rooms.room(withID: roomID) { entry.sentTo = transmit(message, room: room, excluding: []) }
        if asker?.origin == displayName { entry.direction = .received }
        appendEntry(entry, room: roomID)
        logProof(cardProof, room: roomID, kind: card)
        assistantLog.append(AssistantLogEntry(
            id: message.id, at: Date(), asker: asker?.origin ?? displayName, question: asker?.body ?? (card == "summary" ? "(scheduled summary)" : "(photo arrived)"),
            askHops: asker?.hopCount ?? 0, intent: card, reply: text, model: cardProof.model, latencyMs: cardProof.latencyMs,
            tokensPerSecond: cardProof.tokensPerSecond, compact: false, error: nil,
            roomID: roomID, roomLabel: rooms.room(withID: roomID)?.displayName ?? ""))
        if assistantLog.count > 200 { assistantLog.removeFirst(assistantLog.count - 200) }
        return message.id
    }

    // MARK: Daily digest

    private func digestURL(_ roomID: String) -> URL? { rooms.fileURL("digests.json", roomID: roomID) }

    private func recordDigest(_ digest: DailyDigest, room roomID: String) {
        var book = DigestBook.load(digestURL(roomID))
        book.record(digest)
        _ = book.save(digestURL(roomID))
        if !digest.skipped { lastDigest = digest }
    }

    /// Every 30 s (and right after wake): queue the scheduled digest of each served room that is due.
    private func checkDigests(now: Date) {
        guard isAIPeer, !macAsleep, aiEngine == .assistant else { return }
        for roomID in servedRoomIDs {
            let url = digestURL(roomID)
            var book = DigestBook.load(url)
            let due = DigestClock.due(now: now, schedule: digestSchedule, book: book, calendar: .current)
                .filter { !digestQueued.contains(roomID + "|" + $0.day) }
            if due.isEmpty {
                // Nothing pending for this room: remember that the Mac was awake and watching now.
                if !digestQueued.contains(where: { $0.hasPrefix(roomID + "|") }) {
                    book.lastCheckedAt = now
                    _ = book.save(url)
                }
                continue
            }
            for d in due {
                digestQueued.insert(roomID + "|" + d.day)
                _ = askQueue.enqueue(room: roomID, askID: UUID(), payload: .digest(d), now: now)
            }
        }
        aiQueueDepth = askQueue.depth
    }

    private func runDigest(_ due: DigestClock.Due, room: Room, memory mem: OrgMemory) async {
        defer { digestQueued.remove(room.id + "|" + due.day) }
        guard DigestBook.load(digestURL(room.id)).days[due.day] == nil else { return }
        let digest = await DigestWriter.make(room: room.id, label: room.displayName, snapshot: mem.snapshot, day: due.day, interval: due.interval,
                                             scheduled: true, late: due.late, llm: makeClient(), now: Date(), calendar: .current,
                                             directory: directory, schedule: digestSchedule)
        recordDigest(digest, room: room.id)
        guard !digest.skipped else { return }
        sendCard(digest.text, card: "summary", room: room.id, replyTo: nil, personal: digest.personal,
                 proof: proof(model: digest.model, tps: digest.tokensPerSecond, ms: digest.latencyMs))
    }

    private func runSummaryNow(room: Room, memory mem: OrgMemory, replyTo: UUID?) async {
        let now = Date()
        let digest = await DigestWriter.make(room: room.id, label: room.displayName, snapshot: mem.snapshot,
                                             day: DigestClock.dayKey(now, calendar: .current), interval: DigestClock.dayInterval(of: now, calendar: .current),
                                             scheduled: false, late: false, llm: makeClient(), now: now, calendar: .current,
                                             directory: directory, schedule: digestSchedule)
        recordDigest(digest, room: room.id)
        sendCard(digest.text, card: "summary", room: room.id, replyTo: replyTo, personal: digest.personal,
                 proof: proof(model: digest.model, tps: digest.tokensPerSecond, ms: digest.latencyMs))
    }

    /// Admin button on the Mac: send today's summary so far to a room now.
    func sendSummaryNow(roomID: String? = nil) {
        let id = roomID ?? activeRoom.id
        guard rooms.room(withID: id)?.canSend == true else { return }
        _ = askQueue.enqueue(room: id, askID: UUID(), payload: .summaryNow)
        aiQueueDepth = askQueue.depth
        pumpAsks()
    }

    func setDigestSchedule(_ schedule: DigestSchedule) {
        digestSchedule = schedule
        defaults.set(schedule.enabled, forKey: Keys.digestEnabled)
        defaults.set(schedule.hour, forKey: Keys.digestHour)
        defaults.set(schedule.minute, forKey: Keys.digestMinute)
    }

    // MARK: Photo checks (local vision model)

    func setAutoDescribePhotos(_ on: Bool) {
        autoDescribePhotos = on
        defaults.set(on, forKey: Keys.autoPhotos)
    }

    /// Newest photo in the room from the last 30 minutes (the asker's own first).
    private func latestPhoto(in roomID: String, preferFrom device: String) -> MeshMessage? {
        let cutoff = Date().addingTimeInterval(-1800)
        let photos = entriesFor(roomID).filter {
            $0.message.kind == .media && $0.receivedAt >= cutoff && MediaManifest.decode($0.message.body)?.kind == .image
        }
        return (photos.last { $0.message.origin == device } ?? photos.last)?.message
    }

    /// The media message (manifest) for a media id in a room.
    private func mediaMessage(_ mediaId: UUID, in roomID: String) -> MeshMessage? {
        entriesFor(roomID).last { $0.message.kind == .media && MediaManifest.decode($0.message.body)?.mediaId == mediaId }?.message
    }

    /// A photo is complete on the Mac: answer a parked caption ask about it, or check it once
    /// with the vision model, if on and installed.
    private func photoArrived(_ mediaId: UUID) {
        if isAIPeer, let parked = photoAsks.removeValue(forKey: mediaId), let media = mediaMessage(mediaId, in: parked.room) {
            _ = askQueue.enqueue(room: parked.room, askID: media.id, payload: .photo(media: media, ask: parked.ask))
            aiQueueDepth = askQueue.depth
            pumpAsks()
            return
        }
        guard isAIPeer, autoDescribePhotos, visionModel != nil, aiEngine == .assistant, visionCache[mediaId] == nil else { return }
        let roomID = mediaRoom[mediaId] ?? activeRoom.id
        guard let entry = entriesFor(roomID).last(where: { $0.message.kind == .media && MediaManifest.decode($0.message.body)?.mediaId == mediaId }),
              rooms.room(withID: roomID)?.canSend == true else { return }
        _ = askQueue.enqueue(room: roomID, askID: entry.message.id, payload: .photo(media: entry.message, ask: nil))
        aiQueueDepth = askQueue.depth
        pumpAsks()
    }

    private func runPhoto(media: MeshMessage, ask: MeshMessage?, room roomID: String, memory mem: OrgMemory) async {
        guard let manifest = MediaManifest.decode(media.body), manifest.kind == .image else { return }
        let replyTo = ask?.askKey ?? media.id
        func tell(_ text: String, error: String? = nil) {
            if let ask { sendAnswer(AIReply(text: text), to: ask, room: roomID, intent: IntentKind.describePhoto.rawValue, error: error) }
        }
        if let cached = visionCache[manifest.mediaId] {
            if ask != nil {
                sendCard(cached.text, card: "vision", room: roomID, replyTo: replyTo, suggestions: cached.suggestions,
                         proof: proof(model: visionModel, tps: nil, ms: 0), asker: ask)
            }
            return
        }
        guard let model = visionModel else { tell(VisionModels.notInstalledMessage); return }
        guard let data = mediaStore.data(manifest.mediaId) else {
            tell("That photo has not fully reached the AI Mac yet. Ask again in a moment.")
            return
        }
        let jpeg = VisionImage.downscale(data) ?? data
        let memoryBytes = ProcessInfo.processInfo.physicalMemory
        let client = VisionClient(model: model, keepAlive: VisionPolicy.keepAlive(physicalMemory: memoryBytes))
        let started = Date()
        do {
            let result = try await client.analyze(jpeg: jpeg, caption: ask?.body)
            let ms = Int((Date().timeIntervalSince(started) * 1000).rounded())
            guard let finding = VisionPrompt.parse(result.text) else {
                tell("The vision model could not read that photo.")
                return
            }
            let related = VisionCard.relatedRules(finding, rules: mem.rules)
            let text = VisionCard.text(finding, sender: senderLabel(for: media), related: related)
            visionCache[manifest.mediaId] = (text, finding.tasks)
            mem.recordChat(from: senderLabel(for: media), text: VisionCard.logLine(finding), at: Date(), device: media.origin)
            sendCard(text, card: "vision", room: roomID, replyTo: replyTo, suggestions: finding.tasks,
                     proof: proof(model: result.model, tps: result.tokensPerSecond, ms: ms), asker: ask)
        } catch LLMError.modelMissing {
            visionModel = nil
            tell(VisionModels.notInstalledMessage)
        } catch {
            let why = (error as? LLMError)?.errorDescription ?? error.localizedDescription
            tell("Photo check failed: \(why)", error: why)
        }
        // Tight memory: the vision model unloads after 30 s; load the chat model back now.
        if VisionPolicy.rewarmTextModel(physicalMemory: memoryBytes), !ollamaBusy { refreshWarm() }
        refreshProof()
    }
    #endif

    // MARK: Onboarding

    /// Mic and photo primers show once, on first use.
    func primerNeeded(_ kind: String) -> Bool {
        !(defaults.stringArray(forKey: Keys.primers) ?? []).contains(kind)
    }

    func markPrimerShown(_ kind: String) {
        var shown = defaults.stringArray(forKey: Keys.primers) ?? []
        if !shown.contains(kind) { shown.append(kind) }
        defaults.set(shown, forKey: Keys.primers)
    }

    /// Local network step: starts the advertiser and browser right after the primer, so the
    /// iOS permission prompt appears in context. Clears an old denial flag to check again.
    func startFromOnboarding() {
        localNetworkDenied = false
        start()
    }

    #if os(macOS)
    /// Set up AI finished: use the planned models and make this Mac the AI peer.
    func applySetup(chat: String, vision: String?) {
        updateAssistantSettings(engine: aiEngine, model: chat, fallback: ollamaFallbackModel, rosterText: rosterText)
        preferredVisionModel = vision
        if let vision { defaults.set(vision, forKey: Keys.visionPref) } else { defaults.removeObject(forKey: Keys.visionPref) }
        if !isAIPeer { setAIPeer(true) }
        checkOllama()
    }
    #endif

    func finishOnboarding() {
        onboardingDone = true
        defaults.set(true, forKey: Keys.onboarded)
        showStarterChips = true
        start()   // no-op when the Local Network step already started the mesh
    }

    func hideStarterChips() { showStarterChips = false }

    func replayOnboarding() {
        onboardingDone = false
        defaults.set(false, forKey: Keys.onboarded)
    }
}
