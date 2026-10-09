// ChatTimelineView.swift
// One timeline, messenger style: your messages on the right, others on the left, sender name and
// time on every bubble. AI replies are purple and render basic Markdown. Rules and tasks show as
// cards. The hop path and timing sit in a small caption you can tap to expand.

import SwiftUI

struct ChatTimelineView: View {
    @EnvironmentObject private var mesh: MeshService

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if mesh.entries.isEmpty {
                        Text("No messages yet. Say hi, or start a message with @pasa to ask the AI.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                    let names = nameMap
                    ForEach(mesh.entries) { entry in
                        MessageRow(entry: entry, sender: mesh.senderLabel(for: entry.message), names: names)
                            .id(entry.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: mesh.entries.count) { _, _ in
                if let last = mesh.entries.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onAppear {
                if let last = mesh.entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    /// Device id -> chosen name, including this device.
    private var nameMap: [String: String] {
        var names = mesh.directory
        if !mesh.personName.isEmpty { names[mesh.displayName] = mesh.personName }
        return names
    }
}

struct MessageRow: View {
    let entry: ChatEntry
    let sender: String
    /// Device id -> chosen display name.
    let names: [String: String]
    @State private var showDetails = false

    private var message: MeshMessage { entry.message }
    private var isMine: Bool { entry.direction == .sent && message.kind != .answer }
    private var isCard: Bool { message.kind == .rule || message.kind == .task }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if isMine { Spacer(minLength: 48) }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 3) {
                header
                bubble
                detailsCaption
            }
            if !isMine { Spacer(minLength: 48) }
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 6) {
            if message.kind == .answer {
                Image(systemName: "sparkles").font(.caption2).foregroundStyle(.purple)
            }
            Text(isMine ? "You" : sender)
                .font(.caption.weight(.semibold))
            if message.kind == .ask {
                Text("to Pasa AI").font(.caption2).foregroundStyle(.purple)
            } else if case .peer(let device)? = message.destination, message.kind != .answer {
                Text("to \(labelFor(device))").font(.caption2).foregroundStyle(.secondary)
            }
            Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var bubble: some View {
        if isCard {
            VStack(alignment: .leading, spacing: 4) {
                KindBadge(kind: message.kind)
                Text(MeshPayload.displayText(for: message))
                    .font(.callout)
                    .textSelection(.enabled)
            }
            .padding(10)
            .frame(maxWidth: 320, alignment: .leading)
            .background(cardColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(cardColor.opacity(0.5), lineWidth: 1))
        } else {
            Text(bodyText)
                .font(.body)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(isMine ? Color.white : Color.primary)
                .background(bubbleColor, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var detailsCaption: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 2) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showDetails.toggle() }
            } label: {
                HStack(spacing: 3) {
                    Text(summaryLine)
                    Image(systemName: showDetails ? "chevron.up" : "chevron.down")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if showDetails {
                ForEach(detailLines, id: \.self) { line in
                    Text(line)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(isMine ? .trailing : .leading)
                }
            }
        }
    }

    // MARK: Text

    /// AI replies render bold, italics, inline code and bullets. Anything that does not parse
    /// shows as plain text.
    private var bodyText: AttributedString {
        let raw = MeshPayload.displayText(for: message)
        guard message.kind == .answer else { return AttributedString(raw) }
        let prepared = MarkdownLite.prepare(raw)
        if let rich = try? AttributedString(markdown: prepared, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return rich
        }
        return AttributedString(MarkdownLite.plain(raw))
    }

    /// Short caption: "2 hops, 522 ms" or "Round trip 6664 ms".
    private var summaryLine: String {
        if entry.backfilled == true { return "synced from the AI peer" }
        if isMine || (entry.direction == .sent && message.kind == .answer) {
            if entry.sentTo.isEmpty { return "queued, sends when a peer links" }
            return "sent"
        }
        var parts: [String] = []
        parts.append(message.hopCount == 0 ? "local" : hopWord(message.hopCount))
        if let rtt = entry.roundTripMs {
            parts.append("round trip \(rtt) ms")
        } else if let ms = timingMs {
            parts.append("\(ms) ms")
        }
        return parts.joined(separator: ", ")
    }

    private var detailLines: [String] {
        var lines: [String] = []
        if entry.direction == .sent && !entry.sentTo.isEmpty {
            lines.append("Sent to \(entry.sentTo.map(labelFor).joined(separator: ", "))")
        }
        if message.hops.count > 1 {
            lines.append("Path: \(message.hops.map(labelFor).joined(separator: " -> ")), \(hopWord(message.hopCount))")
        }
        if let replyPath = message.replyPath, !replyPath.isEmpty {
            lines.append("Ask path: \(replyPath.map(labelFor).joined(separator: " -> ")), \(hopWord(replyPath.count - 1))")
        }
        if let meta = answerMeta { lines.append(meta) }
        if let rtt = entry.roundTripMs { lines.append("Round trip \(rtt) ms (measured on this device)") }
        if lines.isEmpty { lines.append("From \(message.origin)") }
        return lines
    }

    /// One-way time, only when it looks real. Device clocks differ, so a negative or huge value
    /// is not shown at all (no "clock skew" label).
    private var timingMs: Int? {
        let ms = entry.oneWayMs
        return (0...120_000).contains(ms) ? ms : nil
    }

    /// "qwen3:8b, 1840 ms, 22.4 tok/s, compact" for AI answers.
    private var answerMeta: String? {
        guard message.kind == .answer, message.model != nil || message.latencyMs != nil else { return nil }
        var parts: [String] = [message.model ?? "no model call"]
        if let ms = message.latencyMs { parts.append("\(ms) ms") }
        if let tps = message.tokensPerSecond { parts.append(String(format: "%.1f tok/s", tps)) }
        if message.compact == true { parts.append("compact, say @pasa more") }
        return parts.joined(separator: ", ")
    }

    private var bubbleColor: Color {
        if message.kind == .answer { return Color.purple.opacity(0.15) }
        if message.kind == .ask { return Color.purple.opacity(0.85) }
        return isMine ? Color.accentColor : Color.gray.opacity(0.18)
    }

    private var cardColor: Color {
        message.kind == .task ? .green : .teal
    }

    private func labelFor(_ device: String) -> String {
        PeopleDirectory.label(for: device, directory: names)
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
        case .ack, .sync: return .gray
        case .rule: return .teal
        case .task: return .green
        }
    }
}
