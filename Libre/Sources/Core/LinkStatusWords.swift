// LinkStatusWords.swift
// Libre: plain words for link status in the connection sheet and chat notices (Oct 12, 2026).
// Pure Swift, tested on Linux. Our own design.
//
// - How each device is linked: Wi-Fi, Bluetooth, or both.
// - How far the AI Mac is: linked directly, or how many devices a question hops through.
// - What is waiting to send: own messages not handed to anyone yet, while some devices are
//   linked (the "nobody nearby" case keeps its own banner).
// Words are short and whole; the views wrap them instead of truncating.

import Foundation

public enum LinkStatusWords {
    public enum Link: Equatable, Sendable { case wifi, bluetooth, both }

    /// Second line under a linked device: "Wi-Fi", "Bluetooth", "Wi-Fi and Bluetooth".
    public static func linkWord(_ link: Link) -> String {
        switch link {
        case .wifi: return "Wi-Fi"
        case .bluetooth: return "Bluetooth"
        case .both: return "Wi-Fi and Bluetooth"
        }
    }

    /// SF Symbol for the link (purely decorative; the word carries the meaning).
    public static func linkSymbol(_ link: Link) -> String {
        link == .bluetooth ? "dot.radiowaves.left.and.right" : "wifi"
    }

    /// `hops`: relays the AI status crossed (0 = linked directly). Nil when unknown or on the AI Mac.
    public static func aiDistance(hops: Int?) -> String? {
        guard let hops, hops >= 0 else { return nil }
        switch hops {
        case 0: return "Linked directly to the AI Mac"
        case 1: return "1 hop to the AI Mac (through 1 device)"
        default: return "\(hops) hops to the AI Mac (through \(hops) devices)"
        }
    }

    /// Notice when own messages wait while some devices are linked. Nil when nothing waits or
    /// nobody is linked (StatusWords.offlineBanner covers that).
    public static func waitingToSend(queued: Int, linked: Int, heldForWifi: Int = 0) -> String? {
        guard linked > 0 else { return nil }
        var parts: [String] = []
        if queued > 0 {
            parts.append(queued == 1 ? "1 message waiting to send." : "\(queued) messages waiting to send.")
        }
        if heldForWifi > 0 {
            parts.append(heldForWifi == 1 ? "1 photo or voice note waits for Wi-Fi." : "\(heldForWifi) photos or voice notes wait for Wi-Fi.")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " ") + (queued > 0 ? " They go out when a path to their room opens." : "")
    }
}
