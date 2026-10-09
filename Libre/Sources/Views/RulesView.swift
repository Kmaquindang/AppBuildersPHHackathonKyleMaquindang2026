// RulesView.swift
// Team knowledge base: rules and skills with versions. The Mac can lock, unlock and delete;
// phones show the read-only copy cached from the mesh and can ask the Mac to delete a rule
// (admin devices only, the Mac checks). Deleted rules (tombstones) are hidden.

import SwiftUI

struct RulesView: View {
    @EnvironmentObject private var mesh: MeshService

    private var rules: [RuleEntry] {
        mesh.org.activeRules.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if rules.isEmpty {
                        Text("No rules yet. Try \"@pasa save rule: No site visits after 5 PM\".")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(rules) { rule in
                        RuleRow(rule: rule)
                            #if os(iOS)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    mesh.deleteRule(rule)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    mesh.setRuleLocked(rule, locked: !rule.locked)
                                } label: {
                                    Label(rule.locked ? "Unlock" : "Lock", systemImage: rule.locked ? "lock.open" : "lock")
                                }
                                .tint(.orange)
                            }
                            #endif
                    }
                } footer: {
                    #if os(macOS)
                    Text("This Mac is the source of truth. Anyone can add a rule; only admin devices (\(adminList)) can edit, lock, unlock or delete. Pick admins in Settings by device. Every change keeps the older version, and a deleted rule is removed from every phone.")
                    #else
                    Text("Read-only copy from the AI peer. Add one with \"@pasa save rule: ...\". Swipe left to delete, lock or unlock (admin devices only; the Mac checks and replies in the chat).")
                    #endif
                }
            }
            .navigationTitle("Rules")
        }
    }

    private var adminList: String {
        (["this Mac"] + mesh.adminDevices.map { device in
            let name = mesh.label(for: device)
            return name == device ? device : "\(name) (\(device))"
        }).joined(separator: ", ")
    }
}

struct RuleRow: View {
    let rule: RuleEntry
    @EnvironmentObject private var mesh: MeshService

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(rule.kind.label.uppercased())
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.teal.opacity(0.25), in: Capsule())
                Text(rule.title)
                    .font(.body.weight(.semibold))
                Text("v\(rule.version)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if rule.locked {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Locked by an admin")
                }
                Spacer()
                #if os(macOS)
                Button(rule.locked ? "Unlock" : "Lock") {
                    mesh.setRuleLocked(rule, locked: !rule.locked)
                }
                .controlSize(.small)
                Button("Delete", role: .destructive) {
                    mesh.deleteRule(rule)
                }
                .controlSize(.small)
                #endif
            }
            Text(rule.body)
                .font(.callout)
                .textSelection(.enabled)
            Text("Added by \(rule.addedBy). Last change by \(rule.updatedBy), \(rule.updatedAt.formatted(date: .abbreviated, time: .shortened)).")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if !rule.history.isEmpty {
                DisclosureGroup("History (\(rule.history.count))") {
                    ForEach(Array(rule.history.reversed()), id: \.version) { old in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("v\(old.version) by \(old.editedBy)")
                                .font(.caption.weight(.semibold))
                            Text(old.body)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }
}
