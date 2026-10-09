// LibraryText.swift
// Pasa Knowledge: reads text out of the files an admin adds on the AI Mac.
// - txt and md: plain text (markdown marks stripped). Works everywhere, tested on Linux.
// - pdf: PDFKit, one entry per page. A page with no text layer (a scan) is rendered and read
//   with Vision OCR (slow path).
// - docx: NSAttributedString (Office Open XML reader built into macOS).
// - images (png, jpg, heic...): Vision OCR (slow path).
// PDF, docx and OCR are macOS only; the Mac test build checks them with generated files.

import Foundation
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(Vision)
import Vision
#endif
#if canImport(ImageIO)
import ImageIO
#endif
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

public enum LibraryText {
    public struct Extracted: Equatable, Sendable {
        public var pages: [String]
        /// True for PDFs (passages carry page numbers).
        public var paged: Bool
        /// True when any text came from OCR.
        public var ocr: Bool
        public var characters: Int { pages.reduce(0) { $0 + $1.count } }
    }

    public static func plain(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) { return s.replacingOccurrences(of: "\u{FEFF}", with: "") }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    /// Drops markdown marks so passages read as prose: headings, emphasis, code ticks, link URLs.
    public static func markdown(_ text: String) -> String {
        var s = text
        let rules: [(String, String)] = [
            (#"(?m)^\s{0,3}#{1,6}\s*"#, ""),          // headings
            (#"!\[([^\]]*)\]\([^)]*\)"#, "$1"),         // images
            (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),          // links
            (#"(\*\*|__)(.+?)\1"#, "$2"),               // bold
            (#"(?<![\w*])\*(?!\s)(.+?)\*(?!\w)"#, "$1"), // italics
            (#"`{1,3}"#, ""),                           // code ticks
            (#"(?m)^\s{0,3}>\s?"#, ""),                 // quotes
            (#"(?m)^\s*[-*+]\s+"#, "- "),               // bullets
        ]
        for (pattern, template) in rules {
            if let re = try? NSRegularExpression(pattern: pattern) {
                s = re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
            }
        }
        return s
    }

    public static func extract(url: URL, kind: LibraryKind) throws -> Extracted {
        let name = url.lastPathComponent
        let result: Extracted
        switch kind {
        case .txt:
            result = Extracted(pages: [plain(try Data(contentsOf: url))], paged: false, ocr: false)
        case .md:
            result = Extracted(pages: [markdown(plain(try Data(contentsOf: url)))], paged: false, ocr: false)
        case .pdf:
            result = try pdf(url)
        case .docx:
            result = Extracted(pages: [try docx(url)], paged: false, ocr: false)
        case .image:
            result = Extracted(pages: [try ocrImage(url)], paged: false, ocr: true)
        }
        if result.pages.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { throw LibraryError.empty(name) }
        return result
    }

    static func pdf(_ url: URL) throws -> Extracted {
        #if canImport(PDFKit)
        guard let doc = PDFDocument(url: url) else { throw LibraryError.empty(url.lastPathComponent) }
        var pages: [String] = []
        var usedOCR = false
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { pages.append(""); continue }
            let text = page.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 20 {
                pages.append(text)
            } else if let image = render(page), let ocr = try? recognize(image), !ocr.isEmpty {
                pages.append(ocr)
                usedOCR = true
            } else {
                pages.append(text)
            }
        }
        return Extracted(pages: pages, paged: true, ocr: usedOCR)
        #else
        throw LibraryError.unsupported(url.lastPathComponent)
        #endif
    }

    static func docx(_ url: URL) throws -> String {
        #if os(macOS)
        let attributed = try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
                                                documentAttributes: nil)
        return attributed.string
        #else
        throw LibraryError.unsupported(url.lastPathComponent)
        #endif
    }

    static func ocrImage(_ url: URL) throws -> String {
        #if canImport(Vision) && canImport(ImageIO)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw LibraryError.empty(url.lastPathComponent) }
        return try recognize(image)
        #else
        throw LibraryError.unsupported(url.lastPathComponent)
        #endif
    }

    #if canImport(Vision)
    /// Vision text recognition (accurate mode). Latin-script text such as English, Tagalog and
    /// Cebuano reads with the English model; accents and rare words may come out wrong.
    static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }
    #endif

    #if canImport(PDFKit) && os(macOS)
    static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2
        let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = page.thumbnail(of: size, for: .mediaBox)
        var rect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
    #elseif canImport(PDFKit)
    static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        return page.thumbnail(of: CGSize(width: bounds.width * 2, height: bounds.height * 2), for: .mediaBox).cgImage
    }
    #endif
}
