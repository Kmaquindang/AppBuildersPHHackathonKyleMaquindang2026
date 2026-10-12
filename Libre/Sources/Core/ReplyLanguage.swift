// ReplyLanguage.swift
// Libre: which language a short text is in, English, Tagalog or Cebuano (issue #11, Oct 2026).
// Our own design. Pure, tested on Linux. Used to score reply language in the benchmark and to check
// an answer before it is sent. It counts function words that mark each language and skips words
// Tagalog and Cebuano share (ang, sa, mga, na, wala, siya...). Content words like "site" or
// "cement" are ignored, so Taglish ("Bawal pumasok sa site") still counts as Tagalog.

import Foundation

public enum ReplyLanguage {
    static let english: Set<String> = ["the", "is", "are", "was", "were", "a", "an", "to", "of", "and", "you", "it", "in", "for", "on",
                                       "with", "that", "this", "not", "be", "have", "has", "can", "will", "from", "after", "before",
                                       "your", "we", "they", "there", "only", "do", "does", "don't", "should", "must", "please", "or", "but", "if"]
    static let tagalog: Set<String> = ["ng", "ay", "hindi", "ito", "iyan", "iyon", "natin", "namin", "rin", "din", "mayroon", "meron", "po", "opo",
                                       "dahil", "kasi", "nang", "ngayon", "doon", "dito", "saan", "kailan", "paano", "bakit", "ano", "anong",
                                       "sino", "akin", "iyong", "inyong", "ating", "lamang", "hanggang", "mula", "tayo", "kanila", "bawal",
                                       "huwag", "wag", "pumunta", "pumasok", "puwede", "pwedeng", "puwedeng", "kailangan", "maaari", "lahat", "bang"]
    static let cebuano: Set<String> = ["nga", "ug", "og", "dili", "kini", "kana", "kadto", "mao", "gyud", "jud", "naa", "adunay", "karon",
                                       "unya", "usab", "pud", "sab", "bisan", "kaayo", "imong", "akong", "atong", "ani", "ana", "ra", "diha",
                                       "didto", "dinhi", "asa", "unsa", "pila", "kanus-a", "nimo", "nako", "kinsa", "ayaw", "mosulod", "moadto",
                                       "kinahanglan", "pwedi", "walay", "wa", "lagi", "man"]

    /// "en", "tl" or "ceb", or nil when there are fewer than `minMarkers` marker words to tell
    /// (1 is enough for a short question, 2 for a reply).
    public static func detect(_ text: String, minMarkers: Int = 2) -> String? {
        let words = text.lowercased().split { !$0.isLetter && $0 != "-" && $0 != "'" }.map(String.init)
        let en = words.filter(english.contains).count
        let tl = words.filter(tagalog.contains).count
        let ceb = words.filter(cebuano.contains).count
        guard en + tl + ceb >= max(1, minMarkers) else { return nil }
        if en > tl + ceb { return "en" }
        if tl == ceb { return tl == 0 ? "en" : nil }
        return tl > ceb ? "tl" : "ceb"
    }

    /// Plain name for a prompt or a report.
    public static func name(_ code: String) -> String {
        switch code {
        case "tl": return "Tagalog (Filipino)"
        case "ceb": return "Cebuano (Bisaya)"
        default: return "English"
        }
    }
}
