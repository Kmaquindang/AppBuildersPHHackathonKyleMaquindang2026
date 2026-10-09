// LibraryModels.swift
// Pasa Knowledge (room library, RAG): the small types that travel over the mesh.
// The AI Mac keeps the files, text, chunks and vectors (see AI/Library.swift). Phones only ever
// get document titles (in the memory manifest) and short quoted passages under an answer.

import Foundation

/// Who in the room may get answers from a document.
public enum LibraryVisibility: String, Codable, CaseIterable, Hashable, Sendable {
    case everyone
    case admins

    public var label: String { self == .everyone ? "Everyone in room" : "Admins only" }
}

/// A document's line in a phone's read-only Knowledge list (titles only, never content).
public struct LibraryListing: Codable, Hashable, Sendable {
    public var title: String
    public var version: Int
    public var pages: Int
    public var visibility: LibraryVisibility

    public init(title: String, version: Int, pages: Int, visibility: LibraryVisibility) {
        self.title = title
        self.version = version
        self.pages = pages
        self.visibility = visibility
    }
}

/// A document passage an answer used: the chip under Pasa's bubble. The excerpt is capped
/// (`maxExcerpt` characters), so a phone never receives a whole file.
public struct DocRef: Codable, Hashable, Sendable {
    public static let maxExcerpt = 600

    public var title: String
    public var page: Int?
    public var version: Int
    public var excerpt: String

    public init(title: String, page: Int?, version: Int, excerpt: String) {
        self.title = title
        self.page = page
        self.version = version
        self.excerpt = DocRef.cap(excerpt)
    }

    /// "Photosynthesis basics, p.2, v1"
    public var chipLabel: String {
        var parts = [title]
        if let page { parts.append("p.\(page)") }
        parts.append("v\(version)")
        return parts.joined(separator: ", ")
    }

    /// VoiceOver: "Document Photosynthesis basics, page 2, version 1"
    public var spoken: String {
        "Document \(title)" + (page.map { ", page \($0)" } ?? "") + ", version \(version)"
    }

    /// Cuts at a word boundary at or below `max` characters and marks the cut with "...".
    public static func cap(_ text: String, max: Int = DocRef.maxExcerpt) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > max else { return clean }
        let limit = max - 3
        var cut = String(clean.prefix(limit))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            cut = String(cut[..<space])
        }
        return cut.trimmingCharacters(in: .whitespaces) + "..."
    }
}
