// MacSetup.swift
// Pasa: pure logic behind the Mac's "Set up AI" button (tested on Linux).
// - Hardware-aware model plan: RAM, chip, cores and free disk pick the chat and vision models.
// - Disk gate: the total download plus a 2 GB margin must fit before anything starts.
// - Ollama presence (app, command line tool, local server) and /api/pull progress lines.
// - The setup checklist (each item green or with a copyable fix command).
// Nothing here downloads; MacSetupService does that only after an explicit tap.

import Foundation

/// What this Mac has, read once from the OS (ProcessInfo, sysctl, volume capacity).
public struct HardwareProfile: Equatable, Sendable {
    public var memoryBytes: UInt64
    public var appleSilicon: Bool
    /// "Apple M3", "Intel(R) Core(TM) i7-8850H CPU @ 2.60GHz".
    public var chip: String
    public var cores: Int
    /// volumeAvailableCapacityForImportantUsage of the home volume (nil: unknown).
    public var freeDiskBytes: Int64?

    public init(memoryBytes: UInt64, appleSilicon: Bool, chip: String, cores: Int, freeDiskBytes: Int64?) {
        self.memoryBytes = memoryBytes
        self.appleSilicon = appleSilicon
        self.chip = chip
        self.cores = cores
        self.freeDiskBytes = freeDiskBytes
    }

    /// Whole gigabytes as macOS shows them (16 GB, not 17.2).
    public var memoryGB: Int { Int((Double(memoryBytes) / 1_073_741_824).rounded()) }

    /// "Apple M3" from the brand string; "Intel" Macs keep a short name.
    public var chipLabel: String {
        let trimmed = chip.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return appleSilicon ? "Apple silicon" : "Intel" }
        if !appleSilicon, trimmed.lowercased().contains("intel") {
            let cleaned = trimmed.replacingOccurrences(of: "(R)", with: "").replacingOccurrences(of: "(TM)", with: "")
            if let at = cleaned.range(of: " CPU") { return String(cleaned[..<at.lowerBound]).trimmingCharacters(in: .whitespaces) }
            return cleaned
        }
        return trimmed
    }
}

/// Download sizes from the Ollama library (q4_K_M builds, checked 2026-10-09).
public enum ModelCatalog {
    public static let sizes: [String: Int64] = [
        "qwen3:4b-instruct": 2_500_000_000,
        "qwen3:8b": 5_200_000_000,
        "qwen3:14b": 9_300_000_000,
        "qwen3-vl:2b-instruct": 1_900_000_000,
        "qwen3-vl:4b-instruct": 3_300_000_000,
        "qwen3-vl:8b-instruct": 6_100_000_000,
        // Knowledge embeddings (nomic-embed-text:latest, digest 0a109f422b47, Apache 2.0).
        "nomic-embed-text": 274_000_000,
    ]
    /// Ollama for macOS (Ollama-darwin.zip, about 206 MB).
    public static let ollamaAppBytes: Int64 = 210_000_000
    public static let chatChoices = ["qwen3:4b-instruct", "qwen3:8b", "qwen3:14b"]
    public static let visionChoices = ["qwen3-vl:2b-instruct", "qwen3-vl:4b-instruct", "qwen3-vl:8b-instruct"]

    public static func size(_ model: String) -> Int64? { sizes[model] }

    /// "5.2 GB", "210 MB".
    public static func label(_ bytes: Int64) -> String {
        if bytes >= 1_000_000_000 { return String(format: "%.1f GB", Double(bytes) / 1_000_000_000) }
        return "\(max(1, bytes / 1_000_000)) MB"
    }
}

public enum ModelTier: String, Equatable, Sendable {
    /// Under 12 GB: small chat model, no vision unless asked.
    case small
    /// 12 to under 24 GB: qwen3:8b plus a small vision model.
    case standard
    /// 24 GB and up (Apple silicon): qwen3:14b plus the 8B vision model.
    case large
    /// Intel Macs: no Metal acceleration for Ollama, so the smallest tier with a warning.
    case intel
}

public struct ModelDownload: Equatable, Sendable {
    public var model: String
    public var bytes: Int64
    public var installed: Bool
}

public struct ModelPlan: Equatable, Sendable {
    public var tier: ModelTier
    public var chat: String
    public var vision: String?
    /// Embedding model for Knowledge search (small, every tier); nil when turned off.
    public var embed: String? = nil
    /// Models in the plan (installed ones download nothing).
    public var downloads: [ModelDownload]
    /// Ollama itself must be downloaded first.
    public var needsOllama: Bool
    /// Bytes still to download.
    public var totalBytes: Int64
    /// Download plus the 2 GB margin.
    public var requiredFreeBytes: Int64
    /// "16 GB RAM, Apple M3, 40 GB free: using qwen3:8b + qwen3-vl:4b-instruct"
    public var reason: String
    public var warning: String?
    /// Set when the disk cannot fit the download plus margin: Start stays disabled.
    public var blocked: String?
}

public enum ModelPlanner {
    public static let marginBytes: Int64 = 2_000_000_000
    static let gib: UInt64 = 1_073_741_824

    public static func tier(for hw: HardwareProfile) -> ModelTier {
        if !hw.appleSilicon { return .intel }
        if hw.memoryBytes < 12 * gib { return .small }
        if hw.memoryBytes < 24 * gib { return .standard }
        return .large
    }

    /// Recommended models for a tier. 12 to 15 GB Macs get the 2B vision model (the chat model
    /// already takes about 6 GB); 16 GB and up get the 4B one.
    public static func recommended(_ tier: ModelTier, memoryBytes: UInt64) -> (chat: String, vision: String?) {
        switch tier {
        case .intel, .small: return ("qwen3:4b-instruct", nil)
        case .standard: return ("qwen3:8b", memoryBytes < 16 * gib ? "qwen3-vl:2b-instruct" : "qwen3-vl:4b-instruct")
        case .large: return ("qwen3:14b", "qwen3-vl:8b-instruct")
        }
    }

    /// Small tiers do not suggest vision; this is the one to offer if the user turns it on.
    public static func optionalVision(_ tier: ModelTier) -> String {
        tier == .large ? "qwen3-vl:8b-instruct" : "qwen3-vl:2b-instruct"
    }

    /// - Parameters:
    ///   - wantVision: nil keeps the tier default (on for standard and large, off for small and Intel).
    ///   - chatOverride / visionOverride: manual picks from Settings (any Ollama model name).
    ///   - installed: models Ollama already has (they download nothing).
    ///   - ollamaInstalled: false adds the Ollama app download.
    public static func plan(hardware hw: HardwareProfile, wantVision: Bool? = nil, chatOverride: String? = nil,
                            visionOverride: String? = nil, installed: [String] = [], ollamaInstalled: Bool = true,
                            withKnowledge: Bool = true) -> ModelPlan {
        let t = tier(for: hw)
        let rec = recommended(t, memoryBytes: hw.memoryBytes)
        let chat = clean(chatOverride) ?? rec.chat
        let visionOn = wantVision ?? (rec.vision != nil)
        let vision: String? = visionOn ? (clean(visionOverride) ?? rec.vision ?? optionalVision(t)) : nil

        var downloads: [ModelDownload] = []
        // Knowledge search by meaning: nomic-embed-text is 274 MB and runs on every tier.
        let embed: String? = withKnowledge ? EmbedModel.name : nil
        for model in [chat] + (vision.map { [$0] } ?? []) + (embed.map { [$0] } ?? []) {
            let have = installed.contains(model) || installed.contains(model + ":latest")
            downloads.append(ModelDownload(model: model, bytes: ModelCatalog.size(model) ?? 0, installed: have))
        }
        let total = downloads.filter { !$0.installed }.reduce(Int64(0)) { $0 + $1.bytes }
            + (ollamaInstalled ? 0 : ModelCatalog.ollamaAppBytes)
        let required = total + marginBytes

        let free = hw.freeDiskBytes.map { "\(ModelCatalog.label($0)) free" } ?? "free disk unknown"
        let reason = "\(hw.memoryGB) GB RAM, \(hw.chipLabel), \(free): using \(chat)\(vision.map { " + \($0)" } ?? "")"

        var warnings: [String] = []
        if t == .intel {
            warnings.append("Intel Mac: Ollama runs on the CPU only, so answers are slow. Using the smallest models.")
        }
        if chatOverride != nil, let size = ModelCatalog.size(chat), Double(size) > Double(hw.memoryBytes) * 0.5 {
            warnings.append("\(chat) is large for \(hw.memoryGB) GB of memory. Expect slow answers or swapping.")
        }
        if downloads.contains(where: { ModelCatalog.size($0.model) == nil && !$0.installed }) {
            warnings.append("Download size unknown for a manual pick; check the free space yourself.")
        }

        var blocked: String?
        if total > 0, let free = hw.freeDiskBytes, free < required {
            blocked = "Not enough disk: \(ModelCatalog.label(total)) to download plus a 2 GB margin needs \(ModelCatalog.label(required)), and only \(ModelCatalog.label(free)) is free. Free up space or pick smaller models."
        }
        var plan = ModelPlan(tier: t, chat: chat, vision: vision, downloads: downloads, needsOllama: !ollamaInstalled,
                             totalBytes: total, requiredFreeBytes: required, reason: reason,
                             warning: warnings.isEmpty ? nil : warnings.joined(separator: " "), blocked: blocked)
        plan.embed = embed
        return plan
    }

    static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}

/// Where Ollama is on this Mac.
public struct OllamaPresence: Equatable, Sendable {
    public var appInstalled: Bool
    public var cliPath: String?
    public var serverUp: Bool
    public var version: String?

    public init(appInstalled: Bool, cliPath: String?, serverUp: Bool, version: String? = nil) {
        self.appInstalled = appInstalled
        self.cliPath = cliPath
        self.serverUp = serverUp
        self.version = version
    }

    public var installed: Bool { appInstalled || cliPath != nil || serverUp }

    public var summary: String {
        if serverUp { return "Ollama is running on 127.0.0.1:11434\(version.map { " (version \($0))" } ?? "")" }
        if appInstalled { return "Ollama is installed but not running. Open it from Applications." }
        if let cliPath { return "Ollama command line tool found at \(cliPath), server not running. Run: ollama serve" }
        return "Ollama is not installed."
    }

    /// Where a Mac keeps the app and the command line tool.
    public static let appPaths = ["/Applications/Ollama.app"]
    public static let cliPaths = ["/usr/local/bin/ollama", "/opt/homebrew/bin/ollama"]
}

/// The official macOS download and the hosts it may redirect through (https only).
public enum OllamaDownload {
    public static let url = URL(string: "https://ollama.com/download/Ollama-darwin.zip")!
    public static let allowedHosts: Set<String> = ["ollama.com", "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"]
    public static let fileName = "Ollama-darwin.zip"

    public static func isAllowed(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return allowedHosts.contains(host)
    }

    /// A zip starts with "PK\u{3}\u{4}".
    public static func looksLikeZip(_ head: Data) -> Bool {
        head.count >= 4 && head.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04])
    }
}

/// One line of Ollama's streaming /api/pull reply.
public struct PullProgress: Equatable, Sendable {
    public var status: String
    public var digest: String?
    public var total: Int64?
    public var completed: Int64?
    public var error: String?

    public var fraction: Double? {
        guard let total, total > 0, let completed else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }
    public var isSuccess: Bool { status == "success" }

    public static func parse(_ line: String) -> PullProgress? {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func int(_ k: String) -> Int64? { (obj[k] as? NSNumber)?.int64Value }
        let error = obj["error"] as? String
        guard let status = obj["status"] as? String ?? (error != nil ? "error" : nil) else { return nil }
        return PullProgress(status: status, digest: obj["digest"] as? String, total: int("total"), completed: int("completed"), error: error)
    }

    /// Request body for a streaming pull (Ollama resumes partial downloads on retry).
    public static func requestBody(model: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["model": model, "stream": true], options: [.sortedKeys])) ?? Data()
    }
}

/// Mac setup checklist: each item green, or with a fix command the user can copy.
public struct SetupItem: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var ok: Bool
    public var optional: Bool
    public var detail: String
    public var fix: String?
}

public enum SetupChecklist {
    public static func items(presence: OllamaPresence, chatModel: String, installed: [String], visionModel: String?,
                             wantVision: Bool, warmed: Bool, adminCount: Int, internet: InternetState) -> [SetupItem] {
        let chatOK = installed.contains(chatModel) || installed.contains(chatModel + ":latest")
        let visionOK = visionModel.map { installed.contains($0) } ?? false
        let pick = visionModel ?? VisionModels.primary
        return [
            SetupItem(id: "ollama", title: "Ollama running", ok: presence.serverUp, optional: false, detail: presence.summary,
                      fix: presence.serverUp ? nil : (presence.appInstalled ? "open -a Ollama" : (presence.cliPath != nil ? "ollama serve" : "Use Set up AI, or download from https://ollama.com/download"))),
            SetupItem(id: "chat", title: "Chat model installed", ok: chatOK, optional: false,
                      detail: chatOK ? chatModel : "\(chatModel) is not installed", fix: chatOK ? nil : "ollama pull \(chatModel)"),
            SetupItem(id: "vision", title: "Vision model (optional)", ok: visionOK, optional: true,
                      detail: visionOK ? pick : (wantVision ? "\(pick) is not installed" : "Off. Photos are shared but not read."),
                      fix: visionOK || !wantVision ? nil : "ollama pull \(pick)"),
            SetupItem(id: "embed", title: "Knowledge search model (optional)", ok: embedOK(installed), optional: true,
                      detail: embedOK(installed) ? "\(EmbedModel.name): documents are searched by keywords and meaning" : "Not installed: Knowledge uses keyword search only",
                      fix: embedOK(installed) ? nil : EmbedModel.pullCommand),
            SetupItem(id: "warm", title: "Model warmed up", ok: warmed, optional: false,
                      detail: warmed ? "Loaded and answering" : "First answer loads the model (about 10 to 30 s)", fix: warmed ? nil : "ollama run \(chatModel) \"Reply OK\""),
            SetupItem(id: "admins", title: "Admin devices set", ok: adminCount > 0, optional: true,
                      detail: adminCount > 0 ? "\(adminCount) admin device\(adminCount == 1 ? "" : "s") besides this Mac" : "Only this Mac can edit rules. Tick phones in Settings > Admins.", fix: nil),
            SetupItem(id: "internet", title: "Internet state", ok: true, optional: true,
                      detail: internet == .offline ? "Internet: none. Pasa runs fully offline." : (internet == .connected ? "Internet: connected (not used by Pasa answers)" : internet.label), fix: nil),
        ]
    }

    static func embedOK(_ installed: [String]) -> Bool {
        installed.contains { $0 == EmbedModel.name || $0.hasPrefix(EmbedModel.name + ":") }
    }

    /// Ready means every required item is green.
    public static func ready(_ items: [SetupItem]) -> Bool { items.allSatisfy { $0.ok || $0.optional } }
}
