// TownSquareTests.swift: the open room is shown as "Town Square" (Kyle, Oct 9 2026, 10:41 PM
// PHT). Display only: the internal label, key and tag stay the same for older builds.

import Foundation

func runTownSquareTests() {
    let open = Room.makeDefault()
    check(open.displayName == "Town Square", "town square: open room shows as Town Square")
    check(open.subtitle == "Open to everyone nearby. No code needed.", "town square: subtitle")
    check(open.label == "DEFAULT" && open.key == RoomCrypto.defaultKey, "town square: internal label and key unchanged")
    check(open.id == "a229470a9c620b6a", "town square: room tag pinned (same tag as builds before the rename, so old phones still match)")
    let decoded = try? JSONDecoder().decode(Room.self, from: JSONEncoder().encode(open))
    check(decoded?.displayName == "Town Square" && decoded?.id == open.id, "town square: a saved open room still decodes and shows the new name")
    let other = Room.fromCode(name: "Grade 7 Rizal", creator: "MAC")!
    check(other.displayName == "GRADE-7-RIZAL" && other.subtitle == nil, "town square: other rooms keep their own name, no subtitle")
    check(Room.displayName(forLabel: "DEFAULT") == "Town Square" && Room.displayName(forLabel: "BOHOL-7") == "BOHOL-7", "town square: raw labels map for display")
    check(Room.fromCode(name: "Town Square", creator: "MAC") == nil && Room.fromCode(name: "default", creator: "MAC") == nil, "town square: name reserved for new code rooms")
    check(Room.fromPasscode(name: "town  square", passcode: "tubig sa bohol 77", creator: "MAC", rounds: 1000) == nil, "town square: name reserved for new passcode rooms")
    if case .failure(.badRoom) = JoinLink.parse("pasa://join?room=Town%20Square&code=7KQMR4TX&v=1") {
        check(true, "town square: a join link cannot name the open room")
    } else { check(false, "town square: a join link cannot name the open room") }
    for word in [Room.townSquareName, Room.townSquareSubtitle] {
        check(!word.contains("Default") && !word.contains("\u{2014}"), "town square: no 'Default' or em dash in \(word)")
    }
}

