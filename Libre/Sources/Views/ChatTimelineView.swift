// ChatTimelineView.swift
// One timeline, messenger style: your messages on the right, others on the left, sender name and
// time on every bubble. AI replies are purple and render basic Markdown. Rules and tasks show as
// cards. The hop path and timing sit in a small caption you can tap to expand.

import SwiftUI

struct ChatTimelineView: View {
    @EnvironmentObject private var mesh: MeshService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if mesh.entries.isEmpty {
                        ChatEmptyState()
                    }
                    let names = nameMap
                    let answered = AskCoalescer.answered(mesh.entries)
                    ForEach(mesh.entries) { entry in
                        MessageRow(entry: entry, sender: mesh.senderLabel(for: entry.message), names: names,
                                   waiting: mesh.waitingAsks.contains(entry.id), waitingNote: mesh.waitingText,
                                   status: BubbleStatus.of(entry, answered: answered, waiting: mesh.waitingAsks.contains(entry.id)),
                                   myDevice: mesh.displayName, canAccept: mesh.isAdminDevice(mesh.displayName) || mesh.isRoomAdmin,
                                   onAccept: { title in mesh.send("\(AssistantMention.primary) accept task: \(title)") })
                            .id(entry.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            // Stays pinned to the newest message when the keyboard or composer changes the height.
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: mesh.entries.count) { _, _ in
                if let last = mesh.entries.last {
                    if reduceMotion {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    } else {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
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
    /// An ask of ours with no answer after 20 s.
    var waiting: Bool = false
    /// What to say while waiting (AI Mac asleep, offline, not in this room, or queue depth).
    var waitingNote: String = "Waiting for the AI Mac... It answers when it is in range."
    /// Delivery state, shown as an icon with a VoiceOver label.
    var status: BubbleStatus = .received
    /// This device's id (for its own line on a summary card).
    var myDevice: String = ""
    /// Admin devices see "Add task" on photo suggestions (the Mac checks again).
    var canAccept: Bool = false
    var onAccept: (String) -> Void = { _ in }
    @State private var showDetails = false
    @State private var accepted: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var message: MeshMessage { entry.message }
    private var isMine: Bool { entry.direction == .sent && message.kind != .answer }
    private var isCard: Bool { message.kind == .rule || message.kind == .task }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if isMine { Spacer(minLength: 48) }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 3) {
                if message.kind == .media {
                    header
                    bubble
                } else {
                    // VoiceOver reads sender, time, text, then status, as one element.
                    VStack(alignment: isMine ? .trailing : .leading, spacing: 3) {
                        header
                        bubble
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(spokenLabel)
                    .accessibilityHint(hasDetails ? "Double tap the details button below for hop path and timing" : "")
                }
                cardExtras
                proofBadge
                detailsCaption
            }
            if !isMine { Spacer(minLength: 48) }
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 6) {
            if message.kind == .answer {
                Image(systemName: "sparkles").font(.caption).foregroundStyle(.purple)
            }
            Text(isMine ? "You" : sender)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
            if message.kind == .ask {
                Text("to Pasa AI").font(.caption).foregroundStyle(.secondary)
            } else if case .peer(let device)? = message.destination, message.kind != .answer {
                Text("to \(labelFor(device))").font(.caption).foregroundStyle(.secondary)
            }
            Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
            if !status.symbol.isEmpty {
                Image(systemName: status.symbol)
                    .font(.caption)
                    .foregroundStyle(status == .queued ? Color.orange : Color.secondary)
            }
        }
    }

    @ViewBuilder
    private var bubble: some View {
        if message.kind == .media {
            MediaBubble(entry: entry, isMine: isMine)
        } else if isCard {
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
        } else if message.kind == .answer, let card = message.card {
            VStack(alignment: .leading, spacing: 4) {
                Text(card == "summary" ? "DAILY SUMMARY" : "PHOTO CHECK")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.purple.opacity(0.25), in: Capsule())
                Text(bodyText)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            .padding(10)
            .frame(maxWidth: 340, alignment: .leading)
            .background(Color.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.purple.opacity(0.4), lineWidth: 1))
        } else {
            Text(bodyText)
                .font(.body)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(isMine || message.kind == .ask ? Color.white : Color.primary)
                .background(bubbleColor, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    /// Summary card: this person's own open tasks. Photo card: suggested tasks an admin can add.
    @ViewBuilder
    private var cardExtras: some View {
        if message.kind == .answer, message.card == "summary", let personal = message.personal {
            Label(personal[myDevice] ?? "You have no open tasks.", systemImage: "person.crop.circle.badge.checkmark")
                .font(.caption)
                .padding(8)
                .frame(maxWidth: 320, alignment: .leading)
                .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }
        if message.kind == .answer, message.card == "vision", let suggestions = message.suggestions, !suggestions.isEmpty, canAccept {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(suggestions, id: \.self) { title in
                    Button {
                        accepted.insert(title)
                        onAccept(title)
                    } label: {
                        Label(accepted.contains(title) ? "Sent: \(title)" : "Add task: \(title)",
                              systemImage: accepted.contains(title) ? "checkmark.circle.fill" : "plus.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
                    .disabled(accepted.contains(title))
                    .accessibilityHint("Asks the AI Mac to add this task")
                }
            }
        }
    }

    /// Always visible under AI answers: where and how it was made.
    @ViewBuilder
    private var proofBadge: some View {
        if message.kind == .answer, let proof = message.proof {
            Label {
                Text(proof.badge)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: proof.internet == .offline ? "wifi.slash" : "cpu")
                    .font(.caption2)
                    .foregroundStyle(proof.internet == .offline ? Color.green : Color.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(proof.badge.replacingOccurrences(of: " · ", with: ", "))
        }
    }

    private var detailsCaption: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 2) {
            if waiting && message.kind == .ask {
                Label {
                    Text(waitingText).font(.caption).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "hourglass").foregroundStyle(.orange)
                }
                .accessibilityElement(children: .combine)
            }
            if hasDetails {
                Button {
                    if reduceMotion { showDetails.toggle() } else { withAnimation(.easeInOut(duration: 0.15)) { showDetails.toggle() } }
                } label: {
                    HStack(spacing: 3) {
                        if !summaryLine.isEmpty { Text(summaryLine) }
                        Image(systemName: showDetails ? "chevron.up" : "chevron.down")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44, alignment: isMine ? .trailing : .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, -8)   // keeps the 44 pt target without a tall gap between bubbles
                .accessibilityLabel(showDetails ? "Hide details" : "Details\(summaryLine.isEmpty ? "" : ": \(summaryLine)")")
                .accessibilityHint("Hop path and timing")
            } else {
                Color.clear.frame(height: 6)
            }
            if showDetails {
                ForEach(detailLines, id: \.self) { line in
                    Text(line)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(isMine ? .trailing : .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Text

    /// On the AI Mac itself the ask is local, so it is the model that is slow, not the mesh.
    private var waitingText: String {
        entry.sentTo == ["this Mac (AI peer)"]
            ? "Pasa is still thinking..."
            : waitingNote
    }

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

    /// What VoiceOver reads for the bubble: sender, time, text, status.
    private var spokenLabel: String {
        var parts = [isMine ? "You" : sender]
        if message.kind == .ask { parts[0] += ", to Pasa AI" }
        if message.kind == .answer { parts[0] = "Pasa AI answer" }
        parts.append(message.createdAt.formatted(date: .omitted, time: .shortened))
        if isCard { parts.append(message.kind == .task ? "Task" : "Rule") }
        if let card = message.card { parts.append(card == "summary" ? "Daily summary" : "Photo check") }
        parts.append(String(bodyText.characters))
        if status != .received { parts.append(status.accessibilityLabel) }
        return parts.joined(separator: ". ")
    }

    /// Mine and still queued: the clock icon says it, so no caption.
    private var hasDetails: Bool {
        !(entry.direction == .sent && entry.sentTo.isEmpty && entry.backfilled != true) || message.kind == .answer
    }

    /// Short caption: "2 hops, 522 ms" or "Round trip 6664 ms". Empty for our own sent messages
    /// (the status icon in the header shows queued, sent or answered).
    private var summaryLine: String {
        if entry.backfilled == true { return "synced" }
        if isMine || (entry.direction == .sent && message.kind == .answer) { return "" }
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
        if message.kind == .answer, let checked = message.checked {
            lines.append(checked.isEmpty ? "Checked: no saved rule matched" : "Checked: \(checked.joined(separator: "; "))")
        }
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
        // Deep fills so white text stays above 4.5:1 (system blue and purple are about 4.0 and 3.6).
        if message.kind == .ask { return Color(red: 0.42, green: 0.20, blue: 0.62) }
        return isMine ? Color(red: 0.0, green: 0.37, blue: 0.80) : Color.gray.opacity(0.18)
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
            .font(.caption2.weight(.bold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.25), in: Capsule())
    }

    private var color: Color {
        switch kind {
        case .chat: return .blue
        case .ask: return .orange
        case .answer: return .purple
        case .ack, .sync, .sealed, .chunk, .mediaNack, .transcript, .roomControl, .beacon, .aiStatus: return .gray
        case .media: return .blue
        case .rule: return .teal
        case .task: return .green
        }
    }
}

/// Empty chat: what to do next, not just "nothing here".
struct ChatEmptyState: View {
    @EnvironmentObject private var mesh: MeshService
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("No messages yet")
                .font(.headline)
            Text(mesh.connectedCount == 0
                 ? "Say hi now: it sends when a teammate is in range. Ask a teammate to open Pasa nearby with Wi-Fi on."
                 : "Say hi to the team, or start a message with @pasa to ask the AI.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 40)
        .accessibilityElement(children: .combine)
    }
}
