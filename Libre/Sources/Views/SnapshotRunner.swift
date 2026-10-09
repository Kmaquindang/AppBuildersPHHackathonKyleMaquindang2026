// SnapshotRunner.swift (macOS only, developer aid)
// When launched with the environment variable PASA_SNAPSHOT_DIR, the Mac app saves PNGs of its own
// windows for each sidebar place at a wide and a narrow width, plus Settings and Advanced, then
// quits. Used for the UI audit because the build machine's shell has no screen recording
// permission. Does nothing in normal use.

#if os(macOS)
import AppKit
import SwiftUI

extension Notification.Name {
    static let pasaSnapshotSettings = Notification.Name("pasa.snapshot.settings")
}

@MainActor
enum SnapshotRunner {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["PASA_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func run(select: @escaping (MacSection) -> Void) async {
        guard let dir = directory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        for width in [1000.0, 720.0] {
            if let w = mainWindow() {
                var f = w.frame
                f.size = NSSize(width: width, height: 700)
                w.setFrame(f, display: true)
            }
            for section in MacSection.allCases {
                select(section)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                capture(name: "mac-\(Int(width))-\(section.rawValue)", dir: dir)
            }
        }
        select(.chat)
        try? await Task.sleep(nanoseconds: 800_000_000)
        NotificationCenter.default.post(name: .pasaSnapshotSettings, object: nil)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        capture(name: "mac-settings", dir: dir)
        NSApp.terminate(nil)
    }

    static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.sheetParent == nil && $0.frame.width > 300 }
    }

    static func capture(name: String, dir: URL) {
        var n = 0
        for w in NSApp.windows where w.isVisible {
            guard let view = w.contentView, view.bounds.width > 100 else { continue }
            let suffix = n == 0 ? "" : "-\(n)"
            // Layer render first (draws SwiftUI lists and scroll views), cacheDisplay as a fallback.
            if let layer = view.layer {
                let scale = w.backingScaleFactor
                let size = view.bounds.size
                if let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                       bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    ctx.scaleBy(x: scale, y: scale)
                    if !view.isFlipped { } else { ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1) }
                    NSColor.windowBackgroundColor.setFill()
                    ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
                    ctx.fill(CGRect(origin: .zero, size: size))
                    layer.render(in: ctx)
                    if let img = ctx.makeImage() {
                        let rep = NSBitmapImageRep(cgImage: img)
                        if let png = rep.representation(using: .png, properties: [:]) {
                            try? png.write(to: dir.appendingPathComponent("\(name)\(suffix)-layer.png"))
                        }
                    }
                }
            }
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: dir.appendingPathComponent("\(name)\(suffix).png"))
                }
            }
            n += 1
        }
    }
}
#endif

#if os(iOS)
import UIKit
import SwiftUI

extension Notification.Name {
    static let pasaSnapshotSettings = Notification.Name("pasa.snapshot.settings")
}

/// iOS twin (Simulator UI audit): with PASA_SNAPSHOT=1 the app saves each tab and Settings into
/// Documents/snapshots, named by the current text size, then exits. Does nothing in normal use.
@MainActor
enum SnapshotRunner {
    static var enabled: Bool { ProcessInfo.processInfo.environment["PASA_SNAPSHOT"] == "1" }

    static func run(select: @escaping (Int) -> Void) async {
        guard enabled else { return }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("snapshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let size = UIApplication.shared.preferredContentSizeCategory.rawValue.replacingOccurrences(of: "UICTContentSizeCategory", with: "")
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        for (i, name) in ["chat", "tasks", "knowledge"].enumerated() {
            select(i)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            capture("ios-\(size)-\(name)", dir: dir)
        }
        select(0)
        try? await Task.sleep(nanoseconds: 800_000_000)
        NotificationCenter.default.post(name: .pasaSnapshotSettings, object: nil)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        capture("ios-\(size)-settings", dir: dir)
        exit(0)
    }

    static func capture(_ name: String, dir: URL) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first else { return }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try? image.pngData()?.write(to: dir.appendingPathComponent("\(name).png"))
    }
}
#endif
