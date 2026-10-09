// RulesView.swift
// Team knowledge base: rules and skills with versions. The Mac can lock or unlock;
// phones show the read-only copy cached from the mesh.

import SwiftUI

struct RulesView: View {
    @EnvironmentObject private var mesh: MeshService

    private var rules: [RuleEntry] {
        mesh.org.rules.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
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
                    }
                } footer: {
                    #if os(macOS)
                    Text("This Mac is the source of truth. Anyone can add a rule; only admin devices (\(mesh.adminNames.joined(separator: ", ")) and this Mac) can edit, lock or unlock. Every change keeps the older version.")
                    #else
                    Text("Read-only copy from the AI peer. Add one with \"@pasa save rule: ...\".")
                    #endif
                }
            }
            .navigationTitle("Rules")
        }
    }
}

struct RuleRow: View {
    let rule: RuleEntry
    @EnvironmentObject private var mesh: MeshService

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(rule.kind.label.uppercased())
                    .font(.system(size: 9, weight: .bold))
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
                }
                Spacer()
                #if os(macOS)
                Button(rule.locked ? "Unlock" : "Lock") {
                    mesh.setRuleLocked(rule, locked: !rule.locked)
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
