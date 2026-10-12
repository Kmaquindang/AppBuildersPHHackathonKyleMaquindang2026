// ReplyLanguageTests.swift: English, Tagalog or Cebuano detection (issue #11). Synthetic text only.
import Foundation

func runReplyLanguageTests() {
    // Every benchmark question is detected as its labeled language.
    for q in BenchmarkSuite.questions {
        check(ReplyLanguage.detect(q.text, minMarkers: 1) == q.language, "reply language: question #\(q.id) is \(q.language)")
    }
    check(ReplyLanguage.detect("No, site visits end at 5 PM. After that you need the foreman with you.") == "en", "reply language: English reply")
    check(ReplyLanguage.detect("Hindi po puwede. Bawal pumasok sa site pagkalipas ng 5 PM kung walang foreman.") == "tl", "reply language: Tagalog reply (Taglish nouns ignored)")
    check(ReplyLanguage.detect("Dili pwede. Ayaw og sulod sa site human sa alas singko kung wala ang foreman.") == "ceb", "reply language: Cebuano reply")
    check(ReplyLanguage.detect("Ang tanghalian ay mula 12:00 hanggang 1:00 PM.") == "tl", "reply language: Tagalog with times")
    check(ReplyLanguage.detect("Ang paniudto kay 12:00 hangtod 1:00 PM, unya walay trabaho sa scaffolding.") == "ceb", "reply language: Cebuano with times")
    check(ReplyLanguage.detect("OK.") == nil && ReplyLanguage.detect("12:00") == nil, "reply language: too short to tell")
    check(ReplyLanguage.name("tl") == "Tagalog (Filipino)" && ReplyLanguage.name("ceb") == "Cebuano (Bisaya)", "reply language: names")
}
