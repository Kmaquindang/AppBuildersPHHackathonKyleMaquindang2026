// MacSetupTests.swift: hardware-aware model plan, disk gate, Ollama presence, pull progress,
// download host checks and the Mac setup checklist. Pure logic, no network.

import Foundation

private let GiB: UInt64 = 1_073_741_824
private func hw(_ gb: UInt64, arm: Bool = true, chip: String = "Apple M3", free: Int64? = 40_000_000_000) -> HardwareProfile {
    HardwareProfile(memoryBytes: gb * GiB, appleSilicon: arm, chip: chip, cores: 8, freeDiskBytes: free)
}

func runMacSetupTests() {
    // Tiers
    check(ModelPlanner.tier(for: hw(8)) == .small, "8 GB is the small tier")
    check(ModelPlanner.tier(for: hw(12)) == .standard && ModelPlanner.tier(for: hw(16)) == .standard && ModelPlanner.tier(for: hw(18)) == .standard, "12 to 18 GB is standard")
    check(ModelPlanner.tier(for: hw(24)) == .large && ModelPlanner.tier(for: hw(64)) == .large, "24 GB and up is large")
    check(ModelPlanner.tier(for: hw(32, arm: false, chip: "Intel(R) Core(TM) i9-9880H CPU @ 2.30GHz")) == .intel, "Intel is its own tier whatever the RAM")

    let small = ModelPlanner.plan(hardware: hw(8))
    check(small.chat == "qwen3:4b-instruct" && small.vision == nil, "small tier: 4B chat, no vision by default")
    check(small.totalBytes == 2_774_000_000, "small tier downloads the chat model plus the 274 MB Knowledge embedding model")
    let smallVision = ModelPlanner.plan(hardware: hw(8), wantVision: true)
    check(smallVision.vision == "qwen3-vl:2b-instruct", "small tier can opt in to the 2B vision model")

    let m3 = ModelPlanner.plan(hardware: hw(16))
    check(m3.chat == "qwen3:8b" && m3.vision == "qwen3-vl:4b-instruct", "16 GB: qwen3:8b + qwen3-vl:4b-instruct")
    check(m3.reason == "16 GB RAM, Apple M3, 40.0 GB free: using qwen3:8b + qwen3-vl:4b-instruct", "reasoning line: \(m3.reason)")
    check(m3.totalBytes == 8_774_000_000 && m3.requiredFreeBytes == 10_774_000_000 && m3.blocked == nil, "16 GB plan total and margin")
    check(ModelPlanner.plan(hardware: hw(12)).vision == "qwen3-vl:2b-instruct", "12 GB gets the 2B vision model")

    let big = ModelPlanner.plan(hardware: hw(36, chip: "Apple M3 Pro"))
    check(big.chat == "qwen3:14b" && big.vision == "qwen3-vl:8b-instruct", "36 GB: qwen3:14b + qwen3-vl:8b-instruct")

    let intel = ModelPlanner.plan(hardware: hw(32, arm: false, chip: "Intel(R) Core(TM) i9-9880H CPU @ 2.30GHz"))
    check(intel.chat == "qwen3:4b-instruct" && intel.vision == nil && (intel.warning ?? "").contains("Intel Mac"), "Intel: smallest tier with a warning")
    check(intel.reason.hasPrefix("32 GB RAM, Intel Core i9-9880H,"), "Intel chip label is short: \(intel.reason)")

    // Installed models download nothing; Ollama adds its own download.
    let have = ModelPlanner.plan(hardware: hw(16), installed: ["qwen3:8b"])
    check(have.totalBytes == 3_574_000_000 && have.downloads.first?.installed == true, "installed chat model is not downloaded again")
    let none = ModelPlanner.plan(hardware: hw(16), installed: ["qwen3:8b", "qwen3-vl:4b-instruct", "nomic-embed-text:latest"])
    check(none.totalBytes == 0 && none.blocked == nil, "nothing to download is never blocked, even on a full disk")
    check(ModelPlanner.plan(hardware: hw(16, free: 1_000_000_000), installed: ["qwen3:8b", "qwen3-vl:4b-instruct", "nomic-embed-text:latest"]).blocked == nil, "full disk with everything installed is fine")
    let noOllama = ModelPlanner.plan(hardware: hw(16), ollamaInstalled: false)
    check(noOllama.needsOllama && noOllama.totalBytes == 8_774_000_000 + ModelCatalog.ollamaAppBytes, "missing Ollama adds the app download")

    // Disk gate: download + 2 GB margin.
    let tight = ModelPlanner.plan(hardware: hw(16, free: 10_000_000_000))
    check(tight.blocked != nil && (tight.blocked ?? "").contains("10.8 GB"), "10 GB free blocks an 8.8 GB download (needs 10.8 GB)")
    check(ModelPlanner.plan(hardware: hw(16, free: 10_774_000_000)).blocked == nil, "exactly download + margin is allowed")
    let noKnowledge = ModelPlanner.plan(hardware: hw(16), withKnowledge: false)
    check(noKnowledge.totalBytes == 8_500_000_000 && noKnowledge.embed == nil, "Knowledge model can be left out of the plan")
    check(m3.embed == "nomic-embed-text" && m3.downloads.last?.model == "nomic-embed-text" && m3.downloads.last?.bytes == 274_000_000, "plan: every tier includes nomic-embed-text")
    check(small.embed == "nomic-embed-text" && intel.embed == "nomic-embed-text", "plan: small and Intel tiers too")
    check(ModelPlanner.plan(hardware: hw(16, free: nil)).blocked == nil && ModelPlanner.plan(hardware: hw(16, free: nil)).reason.contains("free disk unknown"), "unknown free space does not block but says so")

    // Manual override
    let over = ModelPlanner.plan(hardware: hw(16), wantVision: false, chatOverride: "qwen3:14b")
    check(over.chat == "qwen3:14b" && over.vision == nil && (over.warning ?? "").contains("large for 16 GB"), "override to 14b on 16 GB warns")
    let custom = ModelPlanner.plan(hardware: hw(16), chatOverride: " mistral:7b ", visionOverride: "qwen3-vl:2b-instruct")
    check(custom.chat == "mistral:7b" && custom.vision == "qwen3-vl:2b-instruct" && (custom.warning ?? "").contains("size unknown"), "custom override is trimmed and flagged unknown size")
    check(ModelPlanner.plan(hardware: hw(16), chatOverride: "  ").chat == "qwen3:8b", "blank override keeps the recommendation")

    // Presence
    check(!OllamaPresence(appInstalled: false, cliPath: nil, serverUp: false).installed, "nothing found: not installed")
    check(OllamaPresence(appInstalled: false, cliPath: "/opt/homebrew/bin/ollama", serverUp: false).summary.contains("ollama serve"), "CLI without server says ollama serve")
    check(OllamaPresence(appInstalled: true, cliPath: nil, serverUp: true, version: "0.40.2").summary == "Ollama is running on 127.0.0.1:11434 (version 0.40.2)", "running summary")

    // Download hosts
    check(OllamaDownload.isAllowed(OllamaDownload.url), "official URL allowed")
    check(OllamaDownload.isAllowed(URL(string: "https://release-assets.githubusercontent.com/x")), "GitHub release asset host allowed")
    check(!OllamaDownload.isAllowed(URL(string: "http://ollama.com/download/Ollama-darwin.zip")), "plain http refused")
    check(!OllamaDownload.isAllowed(URL(string: "https://ollama.com.evil.example/x")), "look-alike host refused")
    check(OllamaDownload.looksLikeZip(Data([0x50, 0x4B, 0x03, 0x04, 0])) && !OllamaDownload.looksLikeZip(Data("<html>".utf8)), "zip magic check")

    // Pull progress
    let p = PullProgress.parse(#"{"status":"pulling 6e4c38e1172f","digest":"sha256:6e4c","total":5200000000,"completed":1300000000}"#)
    check(p?.fraction == 0.25 && p?.status.hasPrefix("pulling") == true, "pull progress fraction")
    check(PullProgress.parse(#"{"status":"success"}"#)?.isSuccess == true, "pull success line")
    check(PullProgress.parse(#"{"error":"pull model manifest: file does not exist"}"#)?.error != nil, "pull error line")
    check(PullProgress.parse("not json") == nil, "garbage line ignored")
    let body = String(data: PullProgress.requestBody(model: "qwen3:8b"), encoding: .utf8)
    check(body == #"{"model":"qwen3:8b","stream":true}"#, "pull request body: \(body ?? "")")

    // Checklist
    let running = OllamaPresence(appInstalled: true, cliPath: nil, serverUp: true)
    var items = SetupChecklist.items(presence: running, chatModel: "qwen3:8b", installed: ["qwen3:8b"], visionModel: nil,
                                     wantVision: false, warmed: true, adminCount: 0, internet: .offline)
    check(SetupChecklist.ready(items), "ready with chat model and warm, vision optional")
    check(items.first { $0.id == "internet" }?.detail.contains("Internet: none") == true, "internet item shows none")
    items = SetupChecklist.items(presence: OllamaPresence(appInstalled: true, cliPath: nil, serverUp: false), chatModel: "qwen3:8b",
                                 installed: [], visionModel: "qwen3-vl:4b-instruct", wantVision: true, warmed: false, adminCount: 1, internet: .connected)
    check(!SetupChecklist.ready(items), "not ready when Ollama is down")
    check(items.first { $0.id == "ollama" }?.fix == "open -a Ollama", "fix for installed but stopped Ollama")
    check(items.first { $0.id == "chat" }?.fix == "ollama pull qwen3:8b", "fix for missing chat model")
    check(items.first { $0.id == "vision" }?.fix == "ollama pull qwen3-vl:4b-instruct", "fix for missing vision model when wanted")
    let embedItem = items.first { $0.id == "embed" }
    check(embedItem?.optional == true && embedItem?.fix == "ollama pull nomic-embed-text", "checklist offers ollama pull nomic-embed-text (optional)")
    let withEmbed = SetupChecklist.items(presence: running, chatModel: "qwen3:8b", installed: ["qwen3:8b", "nomic-embed-text:latest"], visionModel: nil,
                                         wantVision: false, warmed: true, adminCount: 0, internet: .offline)
    check(withEmbed.first { $0.id == "embed" }?.ok == true && withEmbed.first { $0.id == "embed" }?.fix == nil, "checklist: embedding model installed is green")
}
