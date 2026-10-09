// KnowledgeView.swift
// Pasa Knowledge (room library, RAG) screens.
// - Mac: the Knowledge tab (room admins only). Drop files or pick them (PDF, txt, md, docx,
//   images), choose who can get answers from each (Everyone in room / Admins only), see pages,
//   passages, version and search mode, re-index, remove, export and import per room.
// - iPhone: a read-only list of document titles in the Rules tab.

import SwiftUI
import UniformTypeIdentifiers

/// iPhone: titles only (the Mac keeps the files). Admins-only titles are listed for admins only.
struct PhoneKnowledgeSection: View {
    let listings: [LibraryListing]

    var body: some View {
        Section {
            if listings.isEmpty {
                Text("No documents yet. A room admin adds them on the AI Mac.")
                    .foregroundStyle(.secondary)
            }
            ForEach(listings, id: \.self) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text("📄 " + item.title).font(.body)
                    Text("v\(item.version), \(item.pages) page\(item.pages == 1 ? "" : "s")\(item.visibility == .admins ? ", Admins only" : "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Knowledge")
        } footer: {
            Text("Ask @pasa about these documents. Answers show the page they came from; tap it to read the quoted passage.")
        }
    }
}

#if os(macOS)
struct KnowledgeView: View {
    @EnvironmentObject private var mesh: MeshService
    @ObservedObject var knowledge: KnowledgeService
    @State private var showImporter = false
    @State private var showBackupImporter = false
    @State private var exportDoc: KnowledgeBackupFile?
    @State private var newVisibility: LibraryVisibility = .everyone
    @State private var dropTargeted = false
    @State private var confirmRemove: LibraryDocument?

    private var room: String { mesh.activeRoom.id }
    private var canEdit: Bool { mesh.canEditKnowledge(room: room) }
    private var index: LibraryIndex { knowledge.indexes[room] ?? knowledge.index(for: room) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    dropZone
                    Picker("New documents", selection: $newVisibility) {
                        ForEach(LibraryVisibility.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    if let progress = knowledge.progress {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: progress.fraction) {
                                Text("\(progress.fileName): \(progress.step)")
                            }
                            if progress.slow {
                                Text("Scans and photos use OCR, the slow path (several seconds per page).")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if let message = knowledge.lastMessage {
                        Text(message).font(.callout)
                    }
                } header: {
                    Text("Add to \(mesh.activeRoom.displayName)")
                } footer: {
                    Text("PDF, txt, md, docx and images (OCR). Files stay on this Mac. \(knowledge.usageLine). Re-adding the same title or file makes a new version.")
                }

                Section {
                    if index.documents.isEmpty {
                        Text("No documents in this room yet.").foregroundStyle(.secondary)
                    }
                    ForEach(index.documents.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }) { doc in
                        row(doc)
                    }
                } header: {
                    Text("Documents")
                } footer: {
                    searchModeFooter
                }

                Section("Backup") {
                    Button("Export this room's Knowledge...") {
                        if let data = try? knowledge.exportData(room: room) { exportDoc = KnowledgeBackupFile(data: data) }
                    }
                    Button("Import Knowledge (replaces this room's)...") { showBackupImporter = true }
                        .disabled(!canEdit)
                    Text("The backup holds titles, passages and vectors, not the original files.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Knowledge")
        }
        .task { await knowledge.checkEmbedModel() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.types, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { add(urls) }
        }
        .fileImporter(isPresented: $showBackupImporter, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                try knowledge.importData(try Data(contentsOf: url), room: room, isAdmin: canEdit)
                mesh.knowledgeChanged(room: room)
            } catch {
                knowledge.lastMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
        .fileExporter(isPresented: Binding(get: { exportDoc != nil }, set: { if !$0 { exportDoc = nil } }),
                      document: exportDoc, contentType: .json, defaultFilename: "Pasa Knowledge \(mesh.activeRoom.displayName)") { _ in exportDoc = nil }
        .confirmationDialog("Remove \(confirmRemove?.title ?? "")? Its passages and vectors are deleted from this Mac.",
                            isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }),
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let doc = confirmRemove { knowledge.remove(doc.id, room: room); mesh.knowledgeChanged(room: room) }
                confirmRemove = nil
            }
        }
    }

    static let types: [UTType] = [.pdf, .plainText, .text, UTType(filenameExtension: "md") ?? .plainText,
                                  UTType(filenameExtension: "docx") ?? .data, .image]

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down").font(.title)
            Text(canEdit ? "Drop files here" : "Only a room admin can add documents")
                .font(.headline)
            Button("Choose files...") { showImporter = true }
                .disabled(!canEdit || knowledge.progress != nil)
        }
        .frame(maxWidth: .infinity, minHeight: 110)
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
            .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5)))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard canEdit else { return false }
            Task { @MainActor in
                var urls: [URL] = []
                for p in providers {
                    if let url = await Self.fileURL(from: p) { urls.append(url) }
                }
                add(urls)
            }
            return true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Add documents")
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in cont.resume(returning: url) }
        }
    }

    private func add(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let room = room, visibility = newVisibility, me = mesh.displayName, admin = canEdit
        Task {
            await knowledge.add(urls: urls, room: room, visibility: visibility, by: me, isAdmin: admin)
            mesh.knowledgeChanged(room: room)
        }
    }

    private func row(_ doc: LibraryDocument) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("📄 " + doc.title).font(.body.weight(.semibold))
                Text("v\(doc.version)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("Who can get answers", selection: Binding(get: { doc.visibility }, set: { v in
                    knowledge.setVisibility(doc.id, v, room: room); mesh.knowledgeChanged(room: room)
                })) {
                    ForEach(LibraryVisibility.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 170)
                .disabled(!canEdit)
            }
            Text("\(doc.pages) page\(doc.pages == 1 ? "" : "s"), \(doc.chunkCount) passages, \(LibraryLimits.mb(doc.bytes)), \(doc.kind.rawValue)\(doc.ocr ? ", OCR" : "")\(doc.embedded ? ", hybrid search" : ", keyword only")")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Re-index") { Task { await knowledge.reindex(doc.id, room: room) } }
                    .disabled(!canEdit || knowledge.progress != nil)
                Button("Remove", role: .destructive) { confirmRemove = doc }
                    .disabled(!canEdit)
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var searchModeFooter: some View {
        switch knowledge.embedModelReady {
        case .some(true):
            Text("Search: keywords (BM25) plus meaning (\(EmbedModel.name) on this Mac).")
        case .some(false):
            Text("Search: keywords only. For search by meaning, run \(EmbedModel.pullCommand) (274 MB), then Re-index.")
        case .none:
            Text("Checking the embedding model...")
        }
    }
}

struct KnowledgeBackupFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
#endif
