// TasksView.swift
// Mac: the team task board (source of truth, can mark done or reopen).
// Phones: tasks received over the mesh (read-only cache) plus a quick "My tasks" ask.

import SwiftUI

struct TasksView: View {
    @EnvironmentObject private var mesh: MeshService

    private var open: [TaskItem] {
        mesh.org.tasks.filter { $0.status == .open }.sorted { $0.createdAt > $1.createdAt }
    }

    private var done: [TaskItem] {
        mesh.org.tasks.filter { $0.status == .done }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Tasks")
        }
    }

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        HStack(alignment: .top, spacing: 16) {
            TaskColumn(title: "Open (\(open.count))", tasks: open)
            TaskColumn(title: "Done (\(done.count))", tasks: done)
        }
        .padding()
        #else
        List {
            Section {
                Button("Ask the AI peer: my tasks") { mesh.quickAsk("my tasks") }
                Button("Ask the AI peer: team tasks") { mesh.quickAsk("team tasks") }
            }
            Section {
                if open.isEmpty {
                    Text("No open tasks cached yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(open) { task in
                    TaskCard(task: task, me: mesh.displayName)
                }
            } header: {
                Text("Open")
            } footer: {
                Text("Read-only copy. Tasks arrive from the AI peer over the mesh. Say \"@pasa done with ...\" to finish one.")
            }
            if !done.isEmpty {
                Section("Done") {
                    ForEach(done) { task in
                        TaskCard(task: task, me: mesh.displayName)
                    }
                }
            }
        }
        #endif
    }
}

#if os(macOS)
struct TaskColumn: View {
    let title: String
    let tasks: [TaskItem]
    @EnvironmentObject private var mesh: MeshService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if tasks.isEmpty {
                        Text("Nothing here.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(tasks) { task in
                        HStack(alignment: .top) {
                            TaskCard(task: task, me: mesh.displayName)
                            Spacer()
                            Button(task.status == .open ? "Mark done" : "Reopen") {
                                mesh.setTaskDone(task.id, done: task.status == .open)
                            }
                            .controlSize(.small)
                        }
                        .padding(10)
                        .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
#endif

struct TaskCard: View {
    let task: TaskItem
    let me: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: task.status == .done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.status == .done ? Color.green : Color.secondary)
                Text(task.title)
                    .font(.body.weight(.medium))
                    .strikethrough(task.status == .done)
            }
            Text(details)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var details: String {
        var parts: [String] = []
        if let assignee = task.assignee { parts.append("for \(assignee)") }
        if let device = task.assigneeDevice, device != task.assignee { parts.append("on \(device)") }
        if let due = task.due { parts.append("due \(due)") }
        parts.append("by \(task.createdBy == me ? "you" : task.createdBy)")
        if let doneBy = task.completedBy, task.status == .done { parts.append("done by \(doneBy)") }
        return parts.joined(separator: ", ")
    }
}
