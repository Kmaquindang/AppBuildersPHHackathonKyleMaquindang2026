// LocalAIViews.swift
// Mac only: the Proof panel (where answers are made), daily summary and photo check settings.

import SwiftUI

#if os(macOS)
/// Proof that answers are made on this Mac: model, digest, Ollama memory (/api/ps),
/// the last 20 answers, and whether the internet is even connected.
struct LocalProofPanel: View {
    @EnvironmentObject private var mesh: MeshService

    private var items: [ProofLog.Item] { Array(mesh.proofLog.items.reversed()) }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 16) {
                    TintedLabel(text: mesh.internetState.label, symbol: mesh.internetState == .offline ? "wifi.slash" : "wifi",
                                tint: mesh.internetState == .offline ? .green : .secondary, font: .caption.monospaced())
                    Text("Model: \(mesh.ollamaModel)\(mesh.modelDigest.isEmpty ? "" : " (\(String(mesh.modelDigest.prefix(12))))")")
                    Text("Vision: \(mesh.visionModel ?? "not installed")")
                    Spacer()
                    Button("Refresh") {
                        mesh.checkOllama()
                        mesh.refreshProof()
                    }
                }
                .font(.caption.monospaced())
                if mesh.ollamaRunning.isEmpty {
                    Text("Ollama memory: no model loaded right now (local /api/ps)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(mesh.ollamaRunning, id: \.name) { running in
                        Text("Loaded: \(running.name), \(RunningModel.gigabytes(running.size)) in memory (local /api/ps)")
                            .font(.caption.monospaced())
                    }
                }
                HStack(spacing: 16) {
                    Text("Last \(items.count) answers: avg \(mesh.proofLog.averageLatencyMs.map { "\($0) ms" } ?? "-"), \(mesh.proofLog.averageTokensPerSecond.map { String(format: "%.1f tok/s", $0) } ?? "-")")
                    if !items.isEmpty {
                        TintedLabel(text: mesh.proofLog.allOffline ? "all made with no internet" : "internet was connected for some (never used)",
                                    symbol: mesh.proofLog.allOffline ? "checkmark.seal.fill" : "wifi", tint: mesh.proofLog.allOffline ? .green : .secondary)
                    }
                }
                .font(.caption)
                conversationLine
                Text("Link layer: \(mesh.discoveryRestarts) discovery restarts, \(mesh.discoveryRestartsCoalesced) folded or deferred (at most one per 15 s)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if !items.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .bottom, spacing: 3) {
                            ForEach(items.reversed()) { item in
                                let ms = max(item.proof.latencyMs, 1)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(item.proof.internet == .offline ? Color.green : Color.blue)
                                    .frame(width: 10, height: max(4, min(48, CGFloat(ms) / 400)))
                                    .help("\(item.room) \(item.kind): \(item.proof.badge)")
                            }
                        }
                        .frame(height: 50, alignment: .bottom)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Proof: answers are made on this Mac", systemImage: "lock.shield")
        }
        .onAppear { mesh.refreshProof() }
    }

    /// Conversation memory for the room on screen: context fill of the last answer, turns kept
    /// verbatim, recalled lines, last compaction and summary size.
    @ViewBuilder
    private var conversationLine: some View {
        let stats = mesh.contextStats[mesh.activeRoom.id]
        let summary = mesh.org.roomSummary
        let turns = mesh.org.thread?.count ?? 0
        VStack(alignment: .leading, spacing: 2) {
            if let stats {
                let pct = Int((stats.fill * 100).rounded())
                TintedLabel(text: "Context \(pct)% of \(stats.contextTokens) tokens (compacts above 75%), \(stats.verbatimTurns) turns verbatim, \(stats.recalledLines) older lines recalled",
                            symbol: "text.line.first.and.arrowtriangle.forward", tint: stats.fill > ConversationMemory.compactFraction ? .orange : .green,
                            font: .caption.monospaced())
            } else {
                Text("Context: no answer in \(mesh.activeRoom.displayName) since this Mac started")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text(summary.map { "Room summary: \(PromptBudget.tokens($0.text)) tokens, covers \($0.turnCount) of \(turns) turns, last compaction \($0.updatedAt.formatted(date: .abbreviated, time: .shortened))" }
                 ?? "Room summary: none yet (\(turns) turns saved, all kept)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }
}

/// Settings: daily summary time and photo checks.
struct LocalAISettingsSection: View {
    @EnvironmentObject private var mesh: MeshService

    private var timeBinding: Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: mesh.digestSchedule.hour, minute: mesh.digestSchedule.minute, second: 0, of: Date()) ?? Date()
        }, set: { date in
            var s = mesh.digestSchedule
            s.hour = Calendar.current.component(.hour, from: date)
            s.minute = Calendar.current.component(.minute, from: date)
            mesh.setDigestSchedule(s)
        })
    }

    var body: some View {
        Section {
            Toggle("Send a daily summary to each room", isOn: Binding(
                get: { mesh.digestSchedule.enabled },
                set: { var s = mesh.digestSchedule; s.enabled = $0; mesh.setDigestSchedule(s) }
            ))
            DatePicker("Summary time (this Mac's clock)", selection: timeBinding, displayedComponents: .hourAndMinute)
                .disabled(!mesh.digestSchedule.enabled)
            Button("Send \(mesh.activeRoom.displayName) summary now") { mesh.sendSummaryNow() }
                .disabled(!mesh.isAIPeer)
            if let last = mesh.lastDigest {
                Text("Last summary: \(last.roomLabel), \(last.day)\(last.late ? " (made late)" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Check photos with the vision model when they arrive", isOn: Binding(
                get: { mesh.autoDescribePhotos },
                set: { mesh.setAutoDescribePhotos($0) }
            ))
            if let vision = mesh.visionModel {
                Text("Vision model: \(vision). Memory policy: unloads after \(VisionPolicy.keepAlive(physicalMemory: ProcessInfo.processInfo.physicalMemory)) idle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                TintedLabel(text: VisionModels.notInstalledMessage, symbol: "eye.slash", tint: .orange, font: .caption.monospaced())
                    .textSelection(.enabled)
            }
        } header: {
            Text("Daily summary and photos")
        } footer: {
            Text("The summary goes to everyone in the room at \(mesh.digestSchedule.clockLabel), once a day. If this Mac was asleep then, it is sent when it wakes. Anyone can also type \"@pasa summary\". Photo checks and summaries run on this Mac only.")
        }
    }
}
#endif
