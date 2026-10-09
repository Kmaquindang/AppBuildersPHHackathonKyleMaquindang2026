// ChatTimelineView.swift
// Chat timeline. Every row shows the hop path and measured timing.

import SwiftUI

struct ChatTimelineView: View {
    @EnvironmentObject private var mesh: MeshService

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if mesh.entries.isEmpty {
                        Text("No messages yet. Say hi, or switch to Ask AI.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                    ForEach(mesh.entries) { entry in
                        MessageRow(entry: entry, me: mesh.displayName)
                            .id(entry.id)
                    }
                }
                .padding()
            }
            .onChange(of: mesh.entries.count) { _, _ in
                if let last = mesh.entries.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }
}

struct MessageRow: View {
    let entry: ChatEntry
    let me: String

    private var message: MeshMessage { entry.message }
    private var isMine: Bool { entry.direction == .sent }

    var body: some View {
        HStack {
            if isMine { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(isMine ? "You" : message.origin)
                        .font(.caption.weight(.semibold))
                    KindBadge(kind: message.kind)
                    if let destination = message.destination {
                        Text("to \(destination.label)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(MeshPayload.displayText(for: message))
                    .font(.body)
                    .textSelection(.enabled)
                if let meta = answerMeta {
                    Text(meta)
                        .font(.caption2)
                        .foregroundStyle(.purple)
                }
                Text(pathLine)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                if let replyPath = message.replyPath, !replyPath.isEmpty {
                    Text("Ask path: \(replyPath.joined(separator: " -> ")), \(hopWord(replyPath.count - 1))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                if let rtt = entry.roundTripMs {
                    Text("Round trip \(rtt) ms (measured on this device)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }
            .padding(10)
            .background(bubbleColor, in: RoundedRectangle(cornerRadius: 12))
            if !isMine { Spacer(minLength: 40) }
        }
    }

    /// "qwen3:8b, 1840 ms, 22.4 tok/s, compact" for AI answers.
    private var answerMeta: String? {
        guard message.kind == .answer, message.model != nil || message.latencyMs != nil else { return nil }
        var parts: [String] = [message.model ?? "no model call"]
        if let ms = message.latencyMs { parts.append("\(ms) ms") }
        if let tps = message.tokensPerSecond { parts.append(String(format: "%.1f tok/s", tps)) }
        if message.compact == true { parts.append("compact") }
        return parts.joined(separator: ", ")
    }

    private var bubbleColor: Color {
        if message.kind == .answer { return Color.purple.opacity(0.15) }
        if message.kind == .task { return Color.green.opacity(0.15) }
        if message.kind == .rule { return Color.teal.opacity(0.15) }
        return isMine ? Color.accentColor.opacity(0.18) : Color.gray.opacity(0.15)
    }

    private var pathLine: String {
        if isMine {
            if entry.sentTo.isEmpty {
                return "Queued: will send when a peer links"
            }
            return "Sent to \(entry.sentTo.joined(separator: ", "))"
        }
        let ms = entry.oneWayMs
        let timing = ms >= 0 ? "\(ms) ms" : "clock skew"
        if message.hopCount == 0 { return "Local, \(timing)" }
        return "\(message.pathDescription), \(hopWord(message.hopCount)), \(timing)"
    }

    private func hopWord(_ n: Int) -> String {
        n == 1 ? "1 hop" : "\(n) hops"
    }
}

struct KindBadge: View {
    let kind: MessageKind

    var body: some View {
        Text(kind.rawValue.uppercased())
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.25), in: Capsule())
    }

    private var color: Color {
        switch kind {
        case .chat: return .blue
        case .ask: return .orange
        case .answer: return .purple
        case .ack: return .gray
        case .rule: return .teal
        case .task: return .green
        }
    }
}
