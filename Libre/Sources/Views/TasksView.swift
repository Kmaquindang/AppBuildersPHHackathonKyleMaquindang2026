// TasksView.swift
// Mac: the team task board (source of truth, can mark done or reopen).
// Phones: tasks received over the mesh (cached copy). Owners and admins can mark one done; the
// phone asks the AI Mac ("@pasa mark done: ... #id"), which checks and syncs it back.
// Order: Overdue, Open (soonest due first), Done (collapsed).

import SwiftUI

struct TasksView: View {
    @EnvironmentObject private var mesh: MeshService
    @State private var showDone = false
    @State private var asked: Set<UUID> = []

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                content(board: TaskBoard(mesh.org.tasks, now: context.date), now: context.date)
            }
            .navigationTitle("Tasks")
        }
    }

    @ViewBuilder
    private func content(board: TaskBoard, now: Date) -> some View {
        List {
            if !board.overdue.isEmpty {
                Section {
                    rows(board.overdue, now: now)
                } header: {
                    Text("Overdue (\(board.overdue.count))")
                }
            }
            Section {
                if board.open.isEmpty && board.overdue.isEmpty {
                    Text(mesh.isAIPeer
                         ? "No open tasks. Phones add them with \"@libre remind Ana to ...\"."
                         : "No open tasks yet. Tasks for you arrive from the AI Mac. Try \"@libre remind me to check the generator Friday\" in the chat.")
                        .foregroundStyle(.secondary)
                }
                rows(board.open, now: now)
            } header: {
                Text("Open (\(board.open.count))")
            } footer: {
                if !mesh.isAIPeer {
                    Text("Copy from the AI Mac. The owner of a task or an admin can mark it done.")
                }
            }
            if !board.done.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showDone) {
                        rows(board.done, now: now)
                    } label: {
                        Text("Done (\(board.done.count))")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rows(_ tasks: [TaskItem], now: Date) -> some View {
        ForEach(tasks) { task in
            let canDone = mesh.canComplete(task) && !asked.contains(task.id)
            TaskDetailCard(task: task, now: now, room: mesh.activeRoom.displayName,
                           canMarkDone: canDone, waiting: asked.contains(task.id) && task.status == .open,
                           onDone: { markDone(task) },
                           onReopen: reopenAction(task))
                #if os(iOS)
                .swipeActions(edge: .trailing) {
                    if canDone {
                        Button { markDone(task) } label: { Label("Done", systemImage: "checkmark") }
                            .tint(.green)
                    }
                }
                #endif
        }
    }

    /// Only the AI Mac can reopen (it holds the source of truth).
    private func reopenAction(_ task: TaskItem) -> (() -> Void)? {
        #if os(macOS)
        guard mesh.isAIPeer, task.status == .done else { return nil }
        return { mesh.setTaskDone(task.id, done: false) }
        #else
        return nil
        #endif
    }

    private func markDone(_ task: TaskItem) {
        if !mesh.isAIPeer { asked.insert(task.id) }
        mesh.completeTask(task)
    }
}

/// Full task card: title, status pill, owner (with admin badge), assigned by, age, due, room,
/// and who finished it and when.
struct TaskDetailCard: View {
    let task: TaskItem
    let now: Date
    let room: String
    var canMarkDone = false
    var waiting = false
    var onDone: () -> Void = {}
    var onReopen: (() -> Void)? = nil
    @EnvironmentObject private var mesh: MeshService

    private var status: TaskDisplayStatus { task.displayStatus(now: now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(task.title)
                    .font(.body.weight(.semibold))
                    .strikethrough(task.status == .done)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                TaskStatusPill(status: status)
            }
            owner
            detail("Assigned by", who(task.createdBy))
            detail("Opened", TaskAge.short(from: task.createdAt, now: now))
            if let due = task.due, !due.isEmpty {
                detail("Due", due, emphasis: status == .overdue)
            }
            detail("Room", room)
            if task.status == .done {
                detail("Done by", [task.completedBy.map(who), task.doneAt.map { $0.formatted(date: .abbreviated, time: .shortened) }]
                    .compactMap { $0 }.joined(separator: ", "))
            }
            actions
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken)
        .modifier(DoneAction(enabled: canMarkDone, action: onDone))
    }

    @ViewBuilder
    private var owner: some View {
        HStack(spacing: 4) {
            Text("Owner").foregroundStyle(.secondary)
            Text(ownerName)
            if let device = task.assigneeDevice, let role = mesh.roomRole(forDevice: device), role.isAdmin {
                AdminBadge(role: role)
            }
        }
        .font(.subheadline)
    }

    private func detail(_ label: String, _ value: String, emphasis: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(emphasis ? Color.red : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
    }

    @ViewBuilder
    private var actions: some View {
        if waiting {
            Label("Asked the AI Mac to mark it done", systemImage: "clock")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if canMarkDone {
            Button(action: onDone) {
                Label("Mark done", systemImage: "checkmark.circle")
                    .frame(minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityHint(mesh.isAIPeer ? "Marks this task done" : "Asks the AI Mac to mark this task done")
        } else if let onReopen {
            Button("Reopen", action: onReopen)
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
        }
    }

    private var ownerName: String {
        if let device = task.assigneeDevice, !device.isEmpty { return who(device) }
        if let a = task.assignee, !a.isEmpty { return a }
        return "Anyone"
    }

    private func who(_ device: String) -> String {
        device == mesh.displayName ? "You" : mesh.label(for: device)
    }

    private var spoken: String {
        var parts = ["Task: \(task.title)", status.label, "Owner \(ownerName)"]
        if let device = task.assigneeDevice, let spokenRole = mesh.roomRole(forDevice: device)?.spoken { parts.append(spokenRole) }
        parts.append("Assigned by \(who(task.createdBy))")
        parts.append("Opened \(TaskAge.spoken(from: task.createdAt, now: now))")
        if let due = task.due, !due.isEmpty { parts.append("Due \(due)") }
        parts.append("Room \(room)")
        if task.status == .done, let by = task.completedBy { parts.append("Done by \(who(by))") }
        if waiting { parts.append("Waiting for the AI Mac") }
        return parts.joined(separator: ". ")
    }
}

/// VoiceOver "Mark done" action on the combined card.
private struct DoneAction: ViewModifier {
    let enabled: Bool
    let action: () -> Void
    func body(content: Content) -> some View {
        if enabled {
            content.accessibilityAction(named: "Mark done", action)
        } else {
            content
        }
    }
}

/// Status pill with a text label (Overdue is red text, not color only).
struct TaskStatusPill: View {
    let status: TaskDisplayStatus

    private var color: Color {
        switch status {
        case .overdue: return .red
        case .open: return .secondary
        case .done: return .green
        }
    }

    private var symbol: String {
        switch status {
        case .overdue: return "exclamationmark.circle.fill"
        case .open: return "circle"
        case .done: return "checkmark.circle.fill"
        }
    }

    var body: some View {
        Label(status.label, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(status.label)
    }
}
