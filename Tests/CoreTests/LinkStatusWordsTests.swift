// LinkStatusWordsTests.swift: link status words for the connection sheet.
import Foundation

func runLinkStatusWordsTests() {
    check(LinkStatusWords.linkWord(.wifi) == "Wi-Fi", "link words: wifi")
    check(LinkStatusWords.linkWord(.both) == "Wi-Fi and Bluetooth", "link words: both")
    check(LinkStatusWords.linkSymbol(.bluetooth) != LinkStatusWords.linkSymbol(.wifi), "link words: symbols differ")
    check(LinkStatusWords.aiDistance(hops: nil) == nil, "link words: unknown distance hidden")
    check(LinkStatusWords.aiDistance(hops: 0) == "Linked directly to the AI Mac", "link words: direct")
    check(LinkStatusWords.aiDistance(hops: 1) == "1 hop to the AI Mac (through 1 device)", "link words: one hop singular")
    check(LinkStatusWords.aiDistance(hops: 3)?.hasPrefix("3 hops") == true, "link words: plural hops")
    check(LinkStatusWords.waitingToSend(queued: 2, linked: 0) == nil, "link words: offline banner owns nobody linked")
    check(LinkStatusWords.waitingToSend(queued: 0, linked: 3) == nil, "link words: nothing waiting")
    check(LinkStatusWords.waitingToSend(queued: 1, linked: 1)?.hasPrefix("1 message waiting to send.") == true, "link words: singular waiting")
    check(LinkStatusWords.waitingToSend(queued: 0, linked: 1, heldForWifi: 2) == "2 photos or voice notes wait for Wi-Fi.", "link words: held media")
    for s in [LinkStatusWords.waitingToSend(queued: 4, linked: 2, heldForWifi: 1), LinkStatusWords.aiDistance(hops: 2)].compactMap({ $0 }) {
        check(!s.contains("\u{2014}") && !s.contains("..."), "link words: no em dash or ellipsis")
    }
}
