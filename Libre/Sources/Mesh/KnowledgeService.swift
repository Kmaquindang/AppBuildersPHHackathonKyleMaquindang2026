// KnowledgeService.swift
// Pasa Knowledge on the AI Mac: per-room document library (RAG). Files, text, passages and
// vectors stay in Application Support on this Mac (Libre/Knowledge/<room>/). Nothing is uploaded.
// Adding reads the file (PDFKit, docx, Vision OCR), cuts passages, embeds them with
// nomic-embed-text through local Ollama when it is installed (keyword-only otherwise), and saves.

import Foundation

#if os(macOS)
@MainActor
final class KnowledgeService: ObservableObject {
    struct Progress: Equatable {
        var fileName: String
        var step: String
        var fraction: Double
        /// OCR is the slow path: the UI says so.
        var slow: Bool
    }

    @Published private(set) var indexes: [String: LibraryIndex] = [:]
    @Published private(set) var progress: Progress?
    @Published var lastMessage: String?
    /// nil = not checked yet; false = nomic-embed-text missing (keyword-only search).
    @Published private(set) var embedModelReady: Bool?

    var limits = LibraryLimits.standard
    let embedder = OllamaEmbedder()
    private let root: URL?

    init() {
        root = MeshService.storageURL("Knowledge")
    }

    // MARK: Storage

    private func folder(_ room: String) -> URL? {
        let safe = String(room.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }).prefix(80)
        return root?.appendingPathComponent(String(safe), isDirectory: true)
    }

    private func filesFolder(_ room: String) -> URL? { folder(room)?.appendingPathComponent("files", isDirectory: true) }

    func index(for room: String) -> LibraryIndex {
        if let cached = indexes[room] { return cached }
        var loaded = LibraryIndex()
        if let url = folder(room)?.appendingPathComponent("index.json"), let data = try? Data(contentsOf: url),
           let decoded = try? LibraryIndex.decode(data) {
            loaded = decoded
        }
        indexes[room] = loaded
        return loaded
    }

    private func save(_ index: LibraryIndex, room: String) {
        indexes[room] = index
        guard let dir = folder(room) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? index.exportData() { try? data.write(to: dir.appendingPathComponent("index.json"), options: .atomic) }
    }

    /// Totals across every room on this Mac (limits are per Mac).
    private func usage(excluding replacedID: UUID? = nil) -> (bytes: Int, chunks: Int) {
        var bytes = 0, chunks = 0
        guard let root, let rooms = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return (0, 0) }
        for dir in rooms {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("index.json")),
                  let idx = try? LibraryIndex.decode(data) else { continue }
            for d in idx.documents where d.id != replacedID { bytes += d.bytes; chunks += d.chunkCount }
        }
        return (bytes, chunks)
    }

    var usageLine: String {
        let u = usage()
        return "\(LibraryLimits.mb(u.bytes)) of \(LibraryLimits.mb(limits.maxBytes)), \(u.chunks) of \(limits.maxChunks) passages on this Mac"
    }

    // MARK: Embedding model

    func checkEmbedModel() async {
        let installed = (try? await OllamaClient().installedModels()) ?? []
        embedModelReady = installed.contains { $0 == EmbedModel.name || $0.hasPrefix(EmbedModel.name + ":") }
    }

    /// Embedder for answers: nil when the model is known to be missing (keyword-only).
    var answerEmbedder: (any Embedder)? { embedModelReady == false ? nil : embedder }

    private func embedAll(_ passages: [(page: Int?, text: String)], file: String) async -> [[Float]]? {
        guard embedModelReady != false, !passages.isEmpty else { return nil }
        var vectors: [[Float]] = []
        let batch = 16
        var start = 0
        while start < passages.count {
            let slice = passages[start..<min(passages.count, start + batch)].map { LibrarySearch.documentPrefix + $0.text }
            progress = Progress(fileName: file, step: "Embedding passages \(start + 1) to \(start + slice.count) of \(passages.count)",
                                fraction: 0.5 + 0.5 * Double(start) / Double(passages.count), slow: progress?.slow ?? false)
            do {
                vectors += try await embedder.embed(slice)
            } catch {
                if case LLMError.modelMissing = error { embedModelReady = false }
                lastMessage = "Saved with keyword search only: \(EmbedModel.name) is not available (\(EmbedModel.pullCommand) adds it)."
                return nil
            }
            start += batch
        }
        embedModelReady = true
        return vectors
    }

    // MARK: Admin actions

    /// Adds files to a room. Only a room admin (this Mac) may add; the caller checks the role.
    func add(urls: [URL], room: String, visibility: LibraryVisibility, by device: String, isAdmin: Bool) async {
        guard isAdmin else { lastMessage = LibraryError.notAdmin.errorDescription; return }
        if embedModelReady == nil { await checkEmbedModel() }
        var added: [String] = []
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let name = url.lastPathComponent
            guard let kind = LibraryKind.from(fileName: name) else {
                lastMessage = LibraryError.unsupported(name).errorDescription
                continue
            }
            progress = Progress(fileName: name, step: kind.isSlow ? "Reading text with OCR (slow)" : "Reading text", fraction: 0.05, slow: kind.isSlow || kind == .pdf)
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let extracted: LibraryText.Extracted
            do {
                extracted = try await Task.detached(priority: .userInitiated) { try LibraryText.extract(url: url, kind: kind) }.value
            } catch {
                lastMessage = (error as? LocalizedError)?.errorDescription ?? "\(name): could not read (\(error.localizedDescription))."
                continue
            }
            let passages = LibraryChunker.chunk(pages: extracted.pages, paged: extracted.paged)
            let title = Self.title(for: url, kind: kind)
            var idx = index(for: room)
            let replaced = idx.existing(title: title, fileName: name)
            let used = usage(excluding: replaced?.id)
            if let full = limits.check(addingBytes: bytes, addingChunks: passages.count, usedBytes: used.bytes, usedChunks: used.chunks) {
                lastMessage = full.errorDescription
                continue
            }
            progress = Progress(fileName: name, step: "Cut \(passages.count) passages", fraction: 0.4, slow: progress?.slow ?? false)
            let vectors = await embedAll(passages, file: name)
            let doc = LibraryDocument(title: title, fileName: name, kind: kind, visibility: replaced?.visibility ?? visibility,
                                      pages: extracted.paged ? extracted.pages.count : 1, bytes: bytes, addedBy: device,
                                      ocr: extracted.ocr)
            idx = index(for: room)
            let result = idx.add(doc, passages: passages, embeddings: vectors)
            // Keep the original file (for re-index), drop the replaced version's file.
            if let dir = filesFolder(room) {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let dest = dir.appendingPathComponent(result.doc.id.uuidString + "." + url.pathExtension.lowercased())
                try? FileManager.default.copyItem(at: url, to: dest)
                if let old = result.replaced { removeFile(old, room: room) }
            }
            save(idx, room: room)
            added.append("\(result.doc.title) v\(result.doc.version) (\(result.doc.chunkCount) passages\(result.doc.embedded ? "" : ", keyword only"))")
        }
        progress = nil
        if !added.isEmpty { lastMessage = "Added " + added.joined(separator: "; ") + "." }
    }

    /// "photosynthesis_basics.pdf" -> "Photosynthesis basics"; a PDF title in its metadata wins.
    static func title(for url: URL, kind: LibraryKind) -> String {
        let base = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard let first = base.first else { return url.lastPathComponent }
        return first.uppercased() + base.dropFirst()
    }

    private func removeFile(_ id: UUID, room: String) {
        guard let dir = filesFolder(room), let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.lastPathComponent.hasPrefix(id.uuidString) { try? FileManager.default.removeItem(at: f) }
    }

    /// Deletes the document, its passages and vectors, and its stored file.
    func remove(_ id: UUID, room: String) {
        var idx = index(for: room)
        let title = idx.document(id)?.title ?? "Document"
        idx.remove(id)
        removeFile(id, room: room)
        save(idx, room: room)
        lastMessage = "Removed \(title) with its passages and vectors."
    }

    func setVisibility(_ id: UUID, _ visibility: LibraryVisibility, room: String) {
        var idx = index(for: room)
        idx.setVisibility(id, visibility)
        save(idx, room: room)
    }

    /// Reads the stored file again and rebuilds passages and vectors (for example after
    /// installing nomic-embed-text).
    func reindex(_ id: UUID, room: String) async {
        guard let doc = index(for: room).document(id), let dir = filesFolder(room),
              let file = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?.first(where: { $0.lastPathComponent.hasPrefix(id.uuidString) }) else {
            lastMessage = "Re-index needs the original file; add it again."
            return
        }
        await checkEmbedModel()
        progress = Progress(fileName: doc.fileName, step: doc.kind.isSlow ? "Reading text with OCR (slow)" : "Reading text", fraction: 0.05, slow: doc.kind.isSlow || doc.kind == .pdf)
        do {
            let kind = doc.kind
            let extracted = try await Task.detached(priority: .userInitiated) { try LibraryText.extract(url: file, kind: kind) }.value
            let passages = LibraryChunker.chunk(pages: extracted.pages, paged: extracted.paged)
            let vectors = await embedAll(passages, file: doc.fileName)
            var idx = index(for: room)
            idx.reindex(id, passages: passages, embeddings: vectors, pages: extracted.paged ? extracted.pages.count : 1)
            save(idx, room: room)
            lastMessage = "Re-indexed \(doc.title): \(passages.count) passages\(vectors == nil ? ", keyword only" : "")."
        } catch {
            lastMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        progress = nil
    }

    // MARK: Backup (per room)

    func exportData(room: String) throws -> Data { try index(for: room).exportData() }

    /// Replaces this room's Knowledge with a backup (documents, passages, vectors). Original files
    /// are not in the backup, so re-index needs the file added again.
    func importData(_ data: Data, room: String, isAdmin: Bool) throws {
        guard isAdmin else { throw LibraryError.notAdmin }
        let imported = try LibraryIndex.decode(data)
        let current = index(for: room)
        let used = usage()
        let currentBytes = current.totalBytes, currentChunks = current.chunks.count
        if let full = limits.check(addingBytes: imported.totalBytes, addingChunks: imported.chunks.count,
                                   usedBytes: used.bytes - currentBytes, usedChunks: used.chunks - currentChunks) {
            throw full
        }
        for doc in current.documents { removeFile(doc.id, room: room) }
        save(imported, room: room)
        lastMessage = "Imported \(imported.documents.count) documents."
    }
}
#endif
