// ChatTimelineView.swift
// iMessage-style timeline (Oct 9 night redesign, after Kyle's 8:33 PM screenshot):
// - Your bubbles on the right in blue, other people on the left in gray, Pasa AI on the left in
//   soft purple with a small sparkle avatar.
// - Consecutive messages from one sender are grouped; other people's name shows once above their
//   group, never yours. Pasa's name shows only when someone else spoke since its last answer, and
//   its avatar sits on the last bubble of a group. Centered timestamps only after 15 minutes or on
//   a new day.
// - One status word ("Queued", "Delivered", "Answered") under your last message only.
// - No meta lines in bubbles. Model, speed, hops, path, internet state and checked rules live in
//   the Details sheet (long-press, or the VoiceOver "Details" action) and on the Mac Proof panel.
// - Rules an answer relied on show as small tappable chips under Pasa's bubble.
// - Pasa's typing dots while your question is on its way and the AI Mac is awake.
// Layout decisions are pure and unit tested (Core/ChatLayout.swift, AI/AnswerStyle.swift).

import SwiftUI

struct ChatTimelineView: View {
    @EnvironmentObject private var mesh: MeshService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var detailsEntry: ChatEntry?
    @State private var openChip: String?
    @State private var openDoc: DocRef?

    private let bottomID = "timeline-bottom"

    var body: some View {
        let entries = mesh.entries
        let answered = AskCoalescer.answered(entries)
        let statuses = Dictionary(uniqueKeysWithValues: entries.map {
            ($0.id, BubbleStatus.of($0, answered: answered, waiting: mesh.waitingAsks.contains($0.id)))
        })
        let layout = ChatLayout.layout(entries, statuses: statuses)
        let pending = ChatLayout.pendingAsks(entries, device: mesh.displayName).count
        let waiting = ChatLayout.unansweredAsks(entries, device: mesh.displayName)
        let typing = TypingState.of(pending: pending, isAIPeer: mesh.isAIPeer, ai: mesh.aiAvailability,
                                    waiting: waiting.count, queued: mesh.asksQueued(waiting.map(\.id)))
        let names = nameMap

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if entries.isEmpty {
                        ChatEmptyState()
                    }
                    ForEach(entries) { entry in
                        let row = layout[entry.id] ?? ChatRowLayout(timestamp: nil, showName: true, firstInGroup: true, lastInGroup: true, statusWord: nil)
                        MessageRow(entry: entry, layout: row, sender: mesh.senderLabel(for: entry.message), names: names,
                                   role: entry.message.kind == .answer ? nil : mesh.roomRole(forDevice: entry.message.origin),
                                   status: statuses[entry.id] ?? .received, myDevice: mesh.displayName,
                                   canAccept: mesh.isAdminDevice(mesh.displayName) || mesh.isRoomAdmin,
                                   onAccept: { title in mesh.send("\(AssistantMention.primary) accept task: \(title)") },
                                   onDetails: { detailsEntry = entry },
                                   onChip: { openChip = $0 },
                                   onDoc: { openDoc = $0 })
                            .id(entry.id)
                    }
                    switch typing {
                    case .typing:
                        TypingBubble().padding(.top, 8)
                    case .note(let line):
                        SystemLine(text: line).padding(.top, 10)
                    case .none:
                        EmptyView()
                    }
                    Color.clear.frame(height: 4).id(bottomID)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            // Stays pinned to the newest message when the keyboard or composer changes the height.
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: entries.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: typing) { _, _ in scrollToBottom(proxy) }
            .onAppear { proxy.scrollTo(bottomID, anchor: .bottom) }
            // "Answered above" in the composer: jump to that answer.
            .onChange(of: mesh.scrollRequest) { _, request in
                guard let request else { return }
                if reduceMotion {
                    proxy.scrollTo(request.id, anchor: .center)
                } else {
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(request.id, anchor: .center) }
                }
            }
        }
        .sheet(item: $detailsEntry) { entry in
            MessageDetailsSheet(entry: entry, names: names)
                .environmentObject(mesh)
        }
        .sheet(item: Binding(get: { openChip.map(ChipID.init) }, set: { openChip = $0?.citation })) { chip in
            RuleDetailSheet(citation: chip.citation)
                .environmentObject(mesh)
        }
        .sheet(item: Binding(get: { openDoc.map(DocChipID.init) }, set: { openDoc = $0?.ref })) { chip in
            DocExcerptSheet(ref: chip.ref)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if reduceMotion {
            proxy.scrollTo(bottomID, anchor: .bottom)
        } else {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomID, anchor: .bottom) }
        }
    }

    /// Device id -> chosen name, including this device.
    private var nameMap: [String: String] {
        var names = mesh.directory
        if !mesh.personName.isEmpty { names[mesh.displayName] = mesh.personName }
        return names
    }
}

struct ChipID: Identifiable {
    let citation: String
    var id: String { citation }
}

// MARK: - Colors

enum BubbleStyle {
    /// Deep blue so white text stays above 4.5:1 (system blue on white is about 4.0:1).
    static let mine = Color(red: 0.0, green: 0.37, blue: 0.80)
    /// Other people: an opaque system gray (iMessage's received bubble), not a translucent fill
    /// that disappears on a black background.
    static var other: Color {
        #if os(iOS)
        Color(uiColor: .systemGray5)
        #else
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 1)
                : NSColor(srgbRed: 0.90, green: 0.90, blue: 0.92, alpha: 1)
        })
        #endif
    }
    /// Pasa AI (round 2: the old 14% purple was nearly black on black). An opaque purple tint:
    /// dark RGB(69, 51, 97), white text about 11:1, and 1.9:1 against the black background so the
    /// bubble edge is visible; light RGB(232, 222, 250), black text about 16:1.
    static var pasa: Color {
        #if os(iOS)
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.27, green: 0.20, blue: 0.38, alpha: 1)
                : UIColor(red: 0.91, green: 0.87, blue: 0.98, alpha: 1)
        })
        #else
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.27, green: 0.20, blue: 0.38, alpha: 1)
                : NSColor(srgbRed: 0.91, green: 0.87, blue: 0.98, alpha: 1)
        })
        #endif
    }
    static var card: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemBackground)
        #else
        Color.gray.opacity(0.10)
        #endif
    }
    static let radius: CGFloat = 18
    static let avatar: CGFloat = 26
}

// MARK: - Row

struct MessageRow: View {
    let entry: ChatEntry
    let layout: ChatRowLayout
    let sender: String
    /// Device id -> chosen display name.
    let names: [String: String]
    /// Admin badge from the room's signed manifest (nil in rooms without one, like Default).
    var role: RoomRole? = nil
    var status: BubbleStatus = .received
    /// This device's id (for its own line on a summary card).
    var myDevice: String = ""
    /// Admin devices see "Add task" on photo suggestions (the Mac checks again).
    var canAccept: Bool = false
    var onAccept: (String) -> Void = { _ in }
    var onDetails: () -> Void = {}
    var onChip: (String) -> Void = { _ in }
    var onDoc: (DocRef) -> Void = { _ in }
    @State private var accepted: Set<String> = []

    private var message: MeshMessage { entry.message }
    private var isMine: Bool { ChatLayout.isMine(entry) }
    private var isPasa: Bool { message.kind == .answer }
    /// Photo answers ("vision") are plain Libre bubbles like any other answer; only the daily summary is a card.
    private var isCard: Bool { message.kind == .rule || message.kind == .task || (message.card != nil && message.card != "vision") }
    private var plainAnswer: Bool { isPasa && (message.card == nil || message.card == "vision") }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let stamp = layout.timestamp {
                Text(stamp)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                    .accessibilityAddTraits(.isHeader)
            }
            if layout.showName {
                HStack(spacing: 3) {
                    Text(sender)
                    if let role { AdminBadge(role: role) }
                }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, (isPasa ? BubbleStyle.avatar + 6 : 0) + 12)
                    .padding(.top, layout.timestamp == nil ? 8 : 0)
                    .accessibilityHidden(true)
            }
            HStack(alignment: .bottom, spacing: 6) {
                if isMine { Spacer(minLength: 56) }
                if isPasa {
                    if layout.lastInGroup { PasaAvatar() } else { Color.clear.frame(width: BubbleStyle.avatar, height: 1) }
                }
                VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
                    content
                    chips
                    cardExtras
                }
                if !isMine { Spacer(minLength: 40) }
            }
            if let word = layout.statusWord {
                Text(word)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 6)
                    .accessibilityHidden(true)   // read as part of the bubble
            }
        }
        .padding(.top, layout.firstInGroup && layout.timestamp == nil && !layout.showName ? 8 : 0)
    }

    // MARK: Bubble content

    @ViewBuilder
    private var content: some View {
        if message.kind == .media {
            MediaBubble(entry: entry, isMine: isMine)
                .contextMenu { detailsButton }
                .accessibilityAction(named: "Details", onDetails)
        } else {
            bubble
                .contextMenu {
                    detailsButton
                    Button {
                        copyToPasteboard(plainText)
                    } label: { Label("Copy", systemImage: "doc.on.doc") }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spokenLabel)
                .accessibilityHint("Actions available: Details")
                .accessibilityAction(named: "Details", onDetails)
        }
    }

    private var detailsButton: some View {
        Button(action: onDetails) { Label("Details", systemImage: "info.circle") }
    }

    @ViewBuilder
    private var bubble: some View {
        if isCard {
            CardView(message: message, text: plainText, names: names)
        } else {
            Text(bodyText)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .foregroundStyle(isMine ? Color.white : Color.primary)
                .background(isMine ? BubbleStyle.mine : (isPasa ? BubbleStyle.pasa : BubbleStyle.other),
                            in: RoundedRectangle(cornerRadius: BubbleStyle.radius, style: .continuous))
        }
    }

    /// Rule chips under Pasa's answer (tap for the rule), plus a warning chip for any tag that
    /// named nothing saved.
    @ViewBuilder
    private var chips: some View {
        if plainAnswer, !(styled.rulesUsed.isEmpty && styled.unverifiedRules.isEmpty) {
            FlowChips(used: styled.rulesUsed, unverified: styled.unverifiedRules, onTap: onChip)
        }
        if plainAnswer, let refs = message.docRefs, !refs.isEmpty {
            DocChips(refs: refs, onTap: onDoc)
        }
    }

    /// Summary card: this person's own open tasks. Photo card: suggested tasks an admin can add.
    @ViewBuilder
    private var cardExtras: some View {
        if isPasa, message.card == "summary", let personal = message.personal {
            Label(personal[myDevice] ?? "You have no open tasks.", systemImage: "person.crop.circle.badge.checkmark")
                .font(.footnote)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: 320, alignment: .leading)
                .background(BubbleStyle.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        if isPasa, message.card == "vision", let suggestions = message.suggestions, !suggestions.isEmpty, canAccept {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(suggestions, id: \.self) { title in
                    Button {
                        accepted.insert(title)
                        onAccept(title)
                    } label: {
                        Label(accepted.contains(title) ? "Sent: \(title)" : "Add task: \(title)",
                              systemImage: accepted.contains(title) ? "checkmark.circle.fill" : "plus.circle")
                            .font(.footnote)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .disabled(accepted.contains(title))
                    .accessibilityHint("Asks the AI Mac to add this task")
                }
            }
        }
    }

    // MARK: Text

    /// Answers: citation tags and old preambles removed (new Macs already send clean text).
    private var styled: StyledAnswer {
        AnswerStyle.display(body: MeshPayload.displayText(for: message), rulesUsed: message.rulesUsed, unverified: message.unverifiedRules)
    }

    private var plainText: String {
        isPasa ? MarkdownLite.plain(styled.text) : MeshPayload.displayText(for: message)
    }

    /// AI replies render bold, italics and inline code. Anything that does not parse is plain.
    private var bodyText: AttributedString {
        guard isPasa else { return AttributedString(MeshPayload.displayText(for: message)) }
        let raw = styled.text
        let prepared = MarkdownLite.prepare(raw)
        if let rich = try? AttributedString(markdown: prepared, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return rich
        }
        return AttributedString(MarkdownLite.plain(raw))
    }

    /// VoiceOver: sender, text, rules, time, status.
    private var spokenLabel: String {
        var parts = [isMine ? "You" : (isPasa ? "Libre" : sender)]
        if !isPasa, let spoken = role?.spoken { parts.append(spoken) }
        if message.kind == .task { parts.append("Task") }
        if message.kind == .rule { parts.append("Rule") }
        if let card = message.card { parts.append(card == "summary" ? "Daily summary" : "Photo check") }
        parts.append(plainText)
        if isPasa, !styled.rulesUsed.isEmpty {
            parts.append("Based on " + styled.rulesUsed.map { AnswerStyle.title(in: $0) }.joined(separator: ", "))
        }
        if isPasa, !styled.unverifiedRules.isEmpty { parts.append("Warning: cites a rule that is not saved") }
        if isPasa, let refs = message.docRefs, !refs.isEmpty { parts.append("From " + refs.map(\.spoken).joined(separator: ", ")) }
        parts.append(message.createdAt.formatted(date: .omitted, time: .shortened))
        if isMine, status != .received { parts.append(status.accessibilityLabel) }
        return parts.joined(separator: ". ")
    }
}

func copyToPasteboard(_ text: String) {
    #if os(iOS)
    UIPasteboard.general.string = text
    #else
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #endif
}

// MARK: - Pieces

/// Small crown (room creator) or shield (co-admin) next to a name. Read as "admin" by VoiceOver.
struct AdminBadge: View {
    let role: RoomRole
    var showWord = false

    var body: some View {
        if let symbol = role.symbol {
            HStack(spacing: 2) {
                Image(systemName: symbol)
                    .foregroundStyle(role == .creator ? Color.orange : Color.accentColor)
                if showWord {
                    Text(role == .creator ? "Creator" : "Admin").foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(role.spoken ?? "admin")
        }
    }
}

struct PasaAvatar: View {
    var body: some View {
        Image(systemName: "sparkles")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: BubbleStyle.avatar, height: BubbleStyle.avatar)
            .background(Color(red: 0.42, green: 0.20, blue: 0.62), in: Circle())
            .accessibilityHidden(true)
    }
}

/// Rule, task, summary and photo cards: a clean rounded card with an icon, a short title and the text.
struct CardView: View {
    let message: MeshMessage
    let text: String
    /// Device id -> chosen name, for the task owner.
    var names: [String: String] = [:]

    private var title: String {
        switch message.kind {
        case .task: return MeshPayload.decodeTask(message.body)?.status == .done ? "Task done" : "Task"
        case .rule:
            if let rule = MeshPayload.decodeRule(message.body) { return rule.isRetired ? "\(rule.kind.label) deleted" : rule.kind.label }
            return "Rule"
        default: return message.card == "summary" ? "Daily summary" : "Photo check"
        }
    }

    private var symbol: String {
        switch message.kind {
        case .task: return "checklist"
        case .rule: return "book.closed"
        default: return message.card == "summary" ? "sun.horizon" : "camera.viewfinder"
        }
    }

    /// Rule cards: the rule title as the headline, its body as the text.
    private var lines: (String?, String) {
        if message.kind == .rule, let rule = MeshPayload.decodeRule(message.body), !rule.isRetired {
            return (rule.title + (rule.locked ? " (locked)" : ""), rule.body)
        }
        if message.kind == .task, let task = MeshPayload.decodeTask(message.body) {
            // Compact: title, owner, due (the status pill sits next to the title).
            let owner = task.assigneeDevice.flatMap { names[$0] } ?? task.assignee
            return (task.title, [owner, task.due.map { "due \($0)" }].compactMap { $0 }.joined(separator: " · "))
        }
        return (nil, text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let headline = lines.0 {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(headline).font(.subheadline.weight(.semibold))
                    if message.kind == .task, let task = MeshPayload.decodeTask(message.body) {
                        TaskStatusPill(status: task.displayStatus())
                    }
                }
            }
            if !lines.1.isEmpty {
                Text(lines.1)
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: 320, alignment: .leading)
        .background(BubbleStyle.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))
    }
}

/// Small rule chips that wrap onto more lines at large text sizes.
struct FlowChips: View {
    let used: [String]
    let unverified: [String]
    let onTap: (String) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { chipViews }
            VStack(alignment: .leading, spacing: 6) { chipViews }
        }
    }

    @ViewBuilder
    private var chipViews: some View {
        ForEach(used, id: \.self) { citation in
            Button { onTap(citation) } label: {
                Label(AnswerStyle.title(in: citation), systemImage: AnswerStyle.kind(in: citation) == "Note" ? "note.text" : "book.closed")
                    .font(.caption)
                    .lineLimit(2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(BubbleStyle.card, in: Capsule())
                    .overlay(Capsule().stroke(Color.purple.opacity(0.35), lineWidth: 0.5))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, -8)   // 44 pt target without a tall gap
            .accessibilityLabel("Rule: \(AnswerStyle.title(in: citation))")
            .accessibilityHint("Shows the saved rule")
        }
        ForEach(unverified, id: \.self) { tag in
            Label("Not a saved rule: \(AnswerStyle.title(in: tag))", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.orange.opacity(0.15), in: Capsule())
                .accessibilityLabel("Warning. \(AnswerStyle.title(in: tag)) is not a saved rule.")
        }
    }
}

/// Pasa is typing: three dots in a purple bubble. Static dots with Reduce Motion.
struct TypingBubble: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            PasaAvatar()
            Group {
                if reduceMotion {
                    dots(phase: -1)
                } else {
                    TimelineView(.periodic(from: .now, by: 0.35)) { context in
                        dots(phase: Int(context.date.timeIntervalSinceReferenceDate / 0.35) % 3)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(BubbleStyle.pasa, in: RoundedRectangle(cornerRadius: BubbleStyle.radius, style: .continuous))
            Spacer(minLength: 40)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Libre is typing")
    }

    private func dots(phase: Int) -> some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 8, height: 8)
                    .opacity(phase < 0 ? 0.6 : (i == phase ? 1 : 0.35))
            }
        }
    }
}

/// A small centered line for system notes ("Pasa is asleep...").
struct SystemLine: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
    }
}

// MARK: - Details sheet

/// Everything that used to clutter the bubble: where and how the answer was made, the hop path,
/// timing, internet state and the rules Pasa checked.
struct MessageDetailsSheet: View {
    @EnvironmentObject private var mesh: MeshService
    @Environment(\.dismiss) private var dismiss
    let entry: ChatEntry
    let names: [String: String]

    private var message: MeshMessage { entry.message }

    var body: some View {
        NavigationStack {
            Form {
                if message.kind == .answer {
                    Section("Libre") {
                        if let proof = message.proof {
                            row("Answered on \(proof.mac)", symbol: "laptopcomputer")
                            row(proof.model ?? "No model call needed", symbol: "cpu")
                            if let digest = proof.digest { row("Model digest \(digest)", symbol: "number") }
                            if let tps = proof.tokensPerSecond, tps.isFinite, tps > 0 {
                                row(String(format: "%.1f tokens per second", tps), symbol: "speedometer")
                            }
                            row("\(proof.latencyMs) ms on the Mac", symbol: "timer")
                            row(proof.internet.detailsLabel, symbol: proof.internet == .offline ? "wifi.slash" : "wifi")
                        } else if let model = message.model {
                            row(model, symbol: "cpu")
                            if let ms = message.latencyMs { row("\(ms) ms on the Mac", symbol: "timer") }
                        }
                        if message.compact == true { row("Shortened. Ask \(AssistantMention.primary) more for the rest.", symbol: "text.append") }
                        if message.card == "vision" { row(VisionCard.caution, symbol: "exclamationmark.circle") }
                    }
                    let shown = AnswerStyle.display(body: message.body, rulesUsed: message.rulesUsed, unverified: message.unverifiedRules)
                    Section("Rules") {
                        if !shown.rulesUsed.isEmpty {
                            ForEach(shown.rulesUsed, id: \.self) { row("Used: \($0)", symbol: "book.closed") }
                        }
                        ForEach(shown.unverifiedRules, id: \.self) { row("Not a saved rule: \($0)", symbol: "exclamationmark.triangle") }
                        if let checked = message.checked {
                            row(checked.isEmpty ? "Checked: no saved rule matched" : "Checked: \(checked.joined(separator: "; "))", symbol: "magnifyingglass")
                        }
                        if shown.rulesUsed.isEmpty && shown.unverifiedRules.isEmpty && message.checked == nil {
                            row("No saved rule used", symbol: "book.closed")
                        }
                    }
                }
                Section("Delivery") {
                    let role = message.kind == .answer ? nil : mesh.roomRole(forDevice: message.origin)
                    Label {
                        HStack(spacing: 4) {
                            Text("From \(label(message.origin))")
                            if let role { AdminBadge(role: role, showWord: true) }
                        }
                    } icon: {
                        Image(systemName: "person").foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    row(message.createdAt.formatted(date: .abbreviated, time: .standard), symbol: "clock")
                    if entry.direction == .sent {
                        row(entry.sentTo.isEmpty ? "Queued. Sends when a teammate is in range." : "Handed to \(entry.sentTo.map(label).joined(separator: ", "))\(entry.link.map { " via \($0)" } ?? "")",
                            symbol: entry.sentTo.isEmpty ? "clock.badge.exclamationmark" : "paperplane")
                    }
                    if entry.direction == .received, let link = entry.link {
                        row(link == "Bluetooth" ? "Arrived via Bluetooth (slow link, used when there is no Wi-Fi link)" : "Arrived via \(link)",
                            symbol: link == "Bluetooth" ? "antenna.radiowaves.left.and.right" : "wifi")
                    }
                    if message.hops.count > 1 {
                        row("Path: \(message.hops.map(label).joined(separator: " → ")) (\(hopWord(message.hopCount)))", symbol: "point.3.connected.trianglepath.dotted")
                    } else if entry.direction == .received {
                        row("Direct, no hops", symbol: "point.3.connected.trianglepath.dotted")
                    }
                    if let replyPath = message.replyPath, !replyPath.isEmpty {
                        row("Question path: \(replyPath.map(label).joined(separator: " → ")) (\(hopWord(replyPath.count - 1)))", symbol: "arrow.uturn.left")
                    }
                    if let rtt = entry.roundTripMs { row("Round trip \(rtt) ms (measured on this device)", symbol: "arrow.triangle.2.circlepath") }
                    if entry.backfilled == true { row("Synced from the AI Mac after this device missed it", symbol: "arrow.triangle.2.circlepath") }
                }
            }
            .navigationTitle(message.kind == .answer ? "Answer details" : "Message details")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
    }

    private func row(_ text: String, symbol: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
    }

    private func label(_ device: String) -> String {
        if device == "this Mac (AI peer)" { return device }
        return PeopleDirectory.label(for: device, directory: names)
    }

    private func hopWord(_ n: Int) -> String { n == 1 ? "1 hop" : "\(n) hops" }
}

/// Tapping a rule chip: the saved rule as this device has it.
struct RuleDetailSheet: View {
    @EnvironmentObject private var mesh: MeshService
    @Environment(\.dismiss) private var dismiss
    let citation: String

    var body: some View {
        let title = AnswerStyle.title(in: citation)
        let key = NameMatcher.normalize(title)
        let rule = mesh.org.activeRules.first { NameMatcher.normalize($0.title) == key }
        let note = mesh.org.notes.first { NameMatcher.normalize($0.title) == key }
        NavigationStack {
            Form {
                if let rule {
                    Section {
                        Text(rule.body).textSelection(.enabled)
                    } header: {
                        Text(rule.citation)
                    } footer: {
                        Text(rule.locked ? "Locked by an admin." : "Saved by \(mesh.label(for: rule.updatedBy)).")
                    }
                } else if let note {
                    Section(note.citation) {
                        Text(note.summary).textSelection(.enabled)
                        ForEach(note.decisions, id: \.self) { Text("Decision: \($0)") }
                    }
                } else {
                    Section(citation) {
                        Text("This device does not have a copy of that rule yet. It arrives when the AI Mac is in range.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 260)
        #endif
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
            .background(Color.secondary.opacity(0.2), in: Capsule())
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
                 ? "Say hi now. It sends by itself when a teammate with \(AppBrand.name) open comes near. No signal or internet needed. Start with @libre to ask the AI."
                 : "Say hi to the team, or start a message with @libre to ask the AI.")
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


struct DocChipID: Identifiable {
    let ref: DocRef
    var id: String { ref.chipLabel + ref.excerpt.prefix(40) }
}

/// Knowledge chips under Pasa's answer: "📄 Title, p.N, vN". Tap for the quoted passage (at most
/// 600 characters; the phone never gets the whole file).
struct DocChips: View {
    let refs: [DocRef]
    let onTap: (DocRef) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { chips }
            VStack(alignment: .leading, spacing: 6) { chips }
        }
    }

    @ViewBuilder
    private var chips: some View {
        ForEach(refs, id: \.self) { ref in
            Button { onTap(ref) } label: {
                Text("📄 " + ref.chipLabel)
                    .font(.caption)
                    .lineLimit(2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(BubbleStyle.card, in: Capsule())
                    .overlay(Capsule().stroke(Color.blue.opacity(0.35), lineWidth: 0.5))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, -8)
            .accessibilityLabel(ref.spoken)
            .accessibilityHint("Shows the quoted passage")
        }
    }
}

struct DocExcerptSheet: View {
    let ref: DocRef
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Label(ref.chipLabel, systemImage: "doc.text")
                        .font(.headline)
                    Text(ref.excerpt)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(BubbleStyle.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Text("Quoted passage from the team's Knowledge on the AI Mac (at most \(DocRef.maxExcerpt) characters). The full file stays on the Mac.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("From Knowledge")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 320)
        #endif
    }
}
