// MacSetupView.swift
// Mac only: setup checklist and the done-for-you "Set up AI" button with a hardware-aware plan.
// Nothing downloads until the user taps the button after seeing what downloads and how big it is.

import SwiftUI

#if os(macOS)
import AppKit

struct MacSetupView: View {
    @EnvironmentObject private var mesh: MeshService
    @StateObject private var setup = MacSetupService()
    var onDone: (() -> Void)?
    @State private var showOverride = false

    private var plan: ModelPlan { setup.plan }

    private var items: [SetupItem] {
        SetupChecklist.items(presence: setup.presence, chatModel: mesh.ollamaModel, installed: setup.installed,
                             visionModel: mesh.visionModel ?? plan.vision, wantVision: plan.vision != nil,
                             warmed: mesh.modelWarm, adminCount: mesh.adminDevices.count, internet: mesh.internetState)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set up the AI Mac").font(.title.weight(.bold)).padding(.top, 8)
            Text("This Mac answers \"@pasa\" for the team, offline. One-time downloads need internet; after that Pasa runs with none.")
                .foregroundStyle(.secondary)

            checklist

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label(plan.reason, systemImage: "cpu").font(.callout.weight(.semibold)).textSelection(.enabled)
                    if let warning = plan.warning {
                        TintedLabel(text: warning, symbol: "exclamationmark.triangle", tint: .orange)
                    }
                    Toggle("Also read photos (vision model)", isOn: Binding(
                        get: { plan.vision != nil },
                        set: { setup.wantVision = $0 }
                    ))
                    DisclosureGroup("Choose models yourself", isExpanded: $showOverride) {
                        modelOverride
                    }
                    .font(.callout)
                    Divider()
                    if plan.needsOllama {
                        downloadRow("Ollama for macOS (from ollama.com)", ModelCatalog.ollamaAppBytes, done: false)
                    }
                    ForEach(plan.downloads, id: \.model) { d in
                        downloadRow(d.model, d.bytes, done: d.installed)
                    }
                    HStack {
                        Text(plan.totalBytes == 0 ? "Nothing to download." : "Total download: \(ModelCatalog.label(plan.totalBytes)). Needs \(ModelCatalog.label(plan.requiredFreeBytes)) free (2 GB margin).")
                            .font(.caption.weight(.semibold))
                        Spacer()
                    }
                    if let blocked = plan.blocked {
                        TintedLabel(text: blocked, symbol: "externaldrive.badge.xmark", tint: .red)
                    }
                    if plan.totalBytes > 0 && mesh.internetState == .offline {
                        TintedLabel(text: "Connect to internet once for setup, then Pasa runs offline.", symbol: "wifi.slash", tint: .orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("Plan for this Mac")
            }

            progress

            HStack {
                if setup.phase.busy {
                    Button("Cancel", role: .cancel) { setup.cancel() }
                } else {
                    Button {
                        setup.start(internet: mesh.internetState) { chat, vision in mesh.applySetup(chat: chat, vision: vision) }
                    } label: {
                        Text(retryLabel).frame(minWidth: 160)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(plan.blocked != nil || (plan.totalBytes > 0 && mesh.internetState == .offline))
                }
                Button("Check again") {
                    Task { await setup.detect() }
                    mesh.checkOllama()
                }
                .disabled(setup.phase.busy)
                Spacer()
                if let onDone {
                    Button(SetupChecklist.ready(items) ? "Continue" : "Later") { onDone() }
                }
            }
            Text("Pasa stays sandboxed. It saves the Ollama download in your Downloads folder and opens it, so macOS shows its usual security and Move to Applications prompts. Models download through Ollama on this Mac (127.0.0.1).")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .task { await setup.detect() }
    }

    private var retryLabel: String {
        switch setup.phase {
        case .failed, .cancelled: return "Retry"
        case .finished: return "Run setup again"
        default: return plan.totalBytes == 0 ? "Set up AI (warm up and test)" : "Set up AI (download \(ModelCatalog.label(plan.totalBytes)))"
        }
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: item.ok ? "checkmark.circle.fill" : (item.optional ? "circle.dashed" : "xmark.circle"))
                        .foregroundStyle(item.ok ? Color.green : (item.optional ? Color.secondary : Color.orange))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.callout.weight(.semibold))
                        Text(item.detail).font(.caption).foregroundStyle(.secondary)
                        if let fix = item.fix {
                            HStack(spacing: 6) {
                                Text(fix).font(.caption.monospaced()).textSelection(.enabled)
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(fix, forType: .string)
                                } label: { Image(systemName: "doc.on.doc").frame(minWidth: 44, minHeight: 44) }
                                .buttonStyle(.borderless)
                                .help("Copy")
                                .accessibilityLabel("Copy command")
                                .accessibilityHint(fix)
                            }
                        }
                    }
                }
            }
        }
    }

    private var modelOverride: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Chat model", selection: $setup.chatOverride) {
                Text("Recommended (\(ModelPlanner.recommended(ModelPlanner.tier(for: setup.hardware), memoryBytes: setup.hardware.memoryBytes).chat))").tag("")
                ForEach(ModelCatalog.chatChoices, id: \.self) { m in
                    Text("\(m) (\(ModelCatalog.label(ModelCatalog.size(m) ?? 0)))").tag(m)
                }
            }
            Picker("Vision model", selection: $setup.visionOverride) {
                Text("Recommended").tag("")
                ForEach(ModelCatalog.visionChoices, id: \.self) { m in
                    Text("\(m) (\(ModelCatalog.label(ModelCatalog.size(m) ?? 0)))").tag(m)
                }
            }
            .disabled(plan.vision == nil)
            Text("\(setup.hardware.cores) CPU cores. Vision models are Qwen3-VL (Apache 2.0).")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private func downloadRow(_ title: String, _ bytes: Int64, done: Bool) -> some View {
        HStack {
            Image(systemName: done ? "checkmark.circle.fill" : "arrow.down.circle").foregroundStyle(done ? Color.green : Color.accentColor)
            Text(title).font(.callout.monospaced())
            Spacer()
            Text(done ? "installed" : (bytes > 0 ? ModelCatalog.label(bytes) : "size unknown")).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var progress: some View {
        switch setup.phase {
        case .idle:
            EmptyView()
        case .downloadingOllama(let done, let total):
            ProgressView(value: Double(done), total: Double(max(total, 1))) {
                Text("Downloading Ollama: \(ModelCatalog.label(done)) of \(ModelCatalog.label(total))").font(.caption)
            }
        case .openingOllama(let text):
            HStack { ProgressView().controlSize(.small); Text(text).font(.caption) }
        case .waitingForServer(let left):
            HStack { ProgressView().controlSize(.small); Text("Waiting for Ollama to start (\(left) s)...").font(.caption) }
        case .pulling(let model, let status, let fraction):
            if let fraction {
                ProgressView(value: fraction) { Text("\(model): \(status) \(Int(fraction * 100))%").font(.caption) }
            } else {
                HStack { ProgressView().controlSize(.small); Text("\(model): \(status)").font(.caption) }
            }
        case .warming(let model):
            HStack { ProgressView().controlSize(.small); Text("Warming up \(model)...").font(.caption) }
        case .selfTest:
            HStack { ProgressView().controlSize(.small); Text("Self-test: asking one question...").font(.caption) }
        case .finished(let text):
            TintedLabel(text: text, symbol: "checkmark.seal.fill", tint: .green)
        case .failed(let text):
            TintedLabel(text: text, symbol: "exclamationmark.triangle.fill", tint: .orange).textSelection(.enabled)
        case .cancelled:
            Label("Cancelled. Retry resumes model downloads where they stopped.", systemImage: "stop.circle").font(.caption)
        }
    }
}
#endif
