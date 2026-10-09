// LocalProof.swift
// Pasa: proof that every AI answer was made on the Mac, offline. Pure Swift, tested on Linux.
//
// - InternetState: what the Mac's network path monitor (NWPathMonitor, no network calls out)
//   says about internet routes. "connected (not used)" means a route exists (Wi-Fi network or
//   Ethernet joined); Pasa still never sends anything to it. It is not a ping.
// - AIProof: rides on every AI answer and summary or photo card. The phone shows it as a compact
//   badge: "On-device: Site Office · qwen3:8b · offline · 16.6 tok/s · 6470 ms".
// - ProofLog: the last 20 answers on the Mac dashboard's Proof panel (latency and tok/s).

import Foundation

public enum InternetState: String, Codable, Hashable, Sendable {
    /// No usable route (airplane mode, or Wi-Fi on but not joined to any network, no Ethernet).
    case offline = "none"
    /// A route exists (a Wi-Fi network or Ethernet is joined). Pasa does not use it.
    case connected
    /// Not checked yet (or the platform has no path monitor).
    case unknown

    /// Dashboard and AI status wording.
    public var label: String {
        switch self {
        case .offline: return "Internet: none"
        case .connected: return "Internet: connected (not used)"
        case .unknown: return "Internet: not checked yet"
        }
    }

    /// Short word for the answer badge.
    public var badgeWord: String {
        switch self {
        case .offline: return "offline"
        case .connected: return "internet on, not used"
        case .unknown: return "local"
        }
    }

    /// From NWPath: status satisfied and at least one real interface (Wi-Fi, Ethernet, cellular).
    /// Peer-to-peer links (AWDL, loopback) do not count as internet.
    public static func from(satisfied: Bool, realInterfaces: Int) -> InternetState {
        satisfied && realInterfaces > 0 ? .connected : .offline
    }
}

public struct AIProof: Codable, Hashable, Sendable {
    /// The AI Mac's display name ("Site Office"), or its device id when no name is set.
    public var mac: String
    /// Model that wrote the reply, nil for fast paths with no model call.
    public var model: String?
    public var internet: InternetState
    public var tokensPerSecond: Double?
    public var latencyMs: Int

    public init(mac: String, model: String?, internet: InternetState, tokensPerSecond: Double?, latencyMs: Int) {
        self.mac = mac
        self.model = model
        self.internet = internet
        self.tokensPerSecond = tokensPerSecond
        self.latencyMs = latencyMs
    }

    /// "On-device: Site Office · qwen3:8b · offline · 16.6 tok/s · 6470 ms"
    public var badge: String {
        var parts = ["On-device: \(mac)", model ?? "no model call", internet.badgeWord]
        if let tps = tokensPerSecond, tps.isFinite, tps > 0 { parts.append(String(format: "%.1f tok/s", tps)) }
        parts.append("\(max(0, latencyMs)) ms")
        return parts.joined(separator: " · ")
    }
}

/// Last answers for the Proof panel. Newest last.
public struct ProofLog: Equatable, Sendable {
    public static let capacity = 20

    public struct Item: Equatable, Sendable, Identifiable {
        public var id: UUID
        public var at: Date
        public var room: String
        public var kind: String
        public var proof: AIProof

        public init(id: UUID = UUID(), at: Date, room: String, kind: String, proof: AIProof) {
            self.id = id
            self.at = at
            self.room = room
            self.kind = kind
            self.proof = proof
        }
    }

    public private(set) var items: [Item] = []

    public init() {}

    public mutating func add(_ item: Item) {
        items.append(item)
        if items.count > ProofLog.capacity { items.removeFirst(items.count - ProofLog.capacity) }
    }

    /// Items that used the model (fast paths have no speed).
    public var modelItems: [Item] { items.filter { $0.proof.model != nil } }

    public var averageLatencyMs: Int? {
        let m = modelItems
        guard !m.isEmpty else { return nil }
        return m.reduce(0) { $0 + $1.proof.latencyMs } / m.count
    }

    public var averageTokensPerSecond: Double? {
        let speeds = modelItems.compactMap { $0.proof.tokensPerSecond }.filter { $0.isFinite && $0 > 0 }
        guard !speeds.isEmpty else { return nil }
        return speeds.reduce(0, +) / Double(speeds.count)
    }

    /// True when every logged answer was made while the Mac had no internet route.
    public var allOffline: Bool { !items.isEmpty && items.allSatisfy { $0.proof.internet == .offline } }
}

/// Ollama /api/ps entry: what is loaded in memory right now (local call only).
public struct RunningModel: Codable, Equatable, Sendable {
    public var name: String
    public var digest: String?
    /// Bytes the loaded model takes (Ollama "size").
    public var size: Int64?
    /// Of which in GPU memory (Ollama "size_vram"). On Apple silicon this is unified memory.
    public var sizeVRAM: Int64?
    public var expiresAt: String?

    public init(name: String, digest: String? = nil, size: Int64? = nil, sizeVRAM: Int64? = nil, expiresAt: String? = nil) {
        self.name = name
        self.digest = digest
        self.size = size
        self.sizeVRAM = sizeVRAM
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case name, digest, size
        case sizeVRAM = "size_vram"
        case expiresAt = "expires_at"
    }

    /// "5.9 GB"
    public static func gigabytes(_ bytes: Int64?) -> String {
        guard let bytes, bytes > 0 else { return "-" }
        return String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }

    public static func decodeList(_ data: Data) -> [RunningModel]? {
        struct PS: Decodable { var models: [RunningModel] }
        return (try? JSONDecoder().decode(PS.self, from: data))?.models
    }
}
