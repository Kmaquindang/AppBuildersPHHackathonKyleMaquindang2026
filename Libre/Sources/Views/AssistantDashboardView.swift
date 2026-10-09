// AssistantDashboardView.swift
// Mac only: the AI peer dashboard. Incoming asks, replies with model name, measured latency and
// tokens per second (from Ollama eval_count / eval_duration), plus Ollama health.

import SwiftUI

#if os(macOS)
struct AssistantDashboardView: View {
    @EnvironmentObject private var mesh: MeshService
    /// Room filter: "" shows every room the Mac answers in.
    @State private var roomFilter = ""

    private var log: [AssistantLogEntry] {
        Array(mesh.assistantLog.filter { roomFilter.isEmpty || $0.roomID == roomFilter }.reversed())
    }

    private var modelEntries: [AssistantLogEntry] { mesh.assistantLog.filter { $0.model != nil && $0.error == nil } }

    private var avgLatency: String {
        guard !modelEntries.isEmpty else { return "-" }
        let total = modelEntries.reduce(0) { $0 + $1.latencyMs }
        return "\(total / modelEntries.count) ms"
    }

    private var avgSpeed: String {
        let speeds = modelEntries.compactMap { $0.tokensPerSecond }
        guard !speeds.isEmpty else { return "-" }
        return String(format: "%.1f tok/s", speeds.reduce(0, +) / Double(speeds.count))
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mesh.isAIPeer ? mesh.aiResponderName : "AI peer is off (turn it on in Settings)")
                            .font(.headline)
                        Text(mesh.ollamaStatus)
                            .font(.caption)
                            .foregroundStyle(mesh.modelWarm ? Color.green : Color.orange)
                            .textSelection(.enabled)
                        if !mesh.modelDigest.isEmpty {
                            Text("Model digest \(String(mesh.modelDigest.prefix(12)))\(mesh.modelDigest == OllamaClient.testedModelDigest ? " (the build we tested)" : " (differs from the tested 500a1f067a9f)"), context \(PromptBudget.contextTokens) tokens")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer()
                    Button("Check Ollama") { mesh.checkOllama() }
                }

                HStack(spacing: 12) {
                    StatTile(label: "Requests", value: "\(mesh.assistantLog.count)")
                    StatTile(label: "Avg latency (model)", value: avgLatency)
                    StatTile(label: "Avg speed", value: avgSpeed)
                    StatTile(label: "Open tasks", value: "\(mesh.org.tasks.filter { $0.status == .open }.count)")
                    StatTile(label: "Rules", value: "\(mesh.org.activeRules.count)")
                    StatTile(label: "Chat lines seen", value: "\(mesh.org.chatLog.count)")
                }

                LocalProofPanel()

                HStack(spacing: 8) {
                    Picker("Room", selection: $roomFilter) {
                        Text("All rooms (\(mesh.joinedRooms.filter(\.canSend).count))").tag("")
                        ForEach(mesh.joinedRooms) { room in
                            Text(room.displayName).tag(room.id)
                        }
                    }
                    .frame(maxWidth: 280)
                    Text(mesh.macAsleep ? "Asleep: asks wait until the Mac wakes" : "Queue: \(mesh.aiQueueDepth) waiting, one model call at a time, rooms take turns")
                        .font(.caption)
                        .foregroundStyle(mesh.macAsleep ? Color.orange : Color.secondary)
                    Spacer()
                }

                Divider()

                if log.isEmpty {
                    Text("No asks yet. From a phone, type \"@pasa ...\" in the chat. You can also ask from this Mac's Chat tab.")
                        .foregroundStyle(.secondary)
                    Spacer()
                } else {
                    List(log) { entry in
                        AssistantLogRow(entry: entry)
                    }
                }
            }
            .padding()
            .navigationTitle("Assistant")
        }
    }
}

struct StatTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(minWidth: 90, alignment: .leading)
        .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct AssistantLogRow: View {
    let entry: AssistantLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if !entry.roomLabel.isEmpty {
                    Text(entry.roomLabel)
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.green.opacity(0.2), in: Capsule())
                }
                Text(entry.asker)
                    .font(.caption.weight(.semibold))
                Text(entry.askHops == 1 ? "1 hop" : "\(entry.askHops) hops")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(entry.intent)
                    .font(.system(size: 9, weight: .bold).monospaced())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.2), in: Capsule())
                Spacer()
                Text(entry.at.formatted(date: .omitted, time: .standard))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text("Q: \(entry.question)")
                .font(.callout)
                .lineLimit(3)
            Text("A: \(entry.reply)")
                .font(.callout)
                .foregroundStyle(entry.error == nil ? Color.primary : Color.red)
                .textSelection(.enabled)
            Text(meta)
                .font(.caption2.monospaced())
                .foregroundStyle(.purple)
        }
        .padding(.vertical, 4)
    }

    private var meta: String {
        var parts: [String] = [entry.model ?? "no model call"]
        parts.append("\(entry.latencyMs) ms")
        if let tps = entry.tokensPerSecond { parts.append(String(format: "%.1f tok/s", tps)) }
        if entry.compact { parts.append("compact") }
        if let est = entry.promptTokensEstimate {
            var prompt = "prompt ~\(est) tok est"
            if let real = entry.promptEvalCount { prompt += ", \(real) read" }
            prompt += " of \(PromptBudget.contextTokens)"
            if PromptBudget.isNearLimit(max(est, entry.promptEvalCount ?? 0)) { prompt += " WARNING: over 80% of context" }
            parts.append(prompt)
        }
        if entry.intent == "answer" {
            parts.append(entry.checked.isEmpty ? "checked: no matching rule" : "checked: " + entry.checked.joined(separator: "; "))
        }
        return parts.joined(separator: ", ")
    }
}
#endif
