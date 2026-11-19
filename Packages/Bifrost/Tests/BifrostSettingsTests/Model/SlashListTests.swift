// The edits of the list of slash commands in Settings > Slash commands
// (docs/behaviour/settings.md, "The slash list").
import Testing

@testable import BifrostSettings

@Suite("the slash list")
struct SlashListTests {
    @Test func addPutsTheTrimmedCommandAtTheEnd() {
        #expect(SlashList.add(["/a"], " /b ") == .success(["/a", "/b"]))
        #expect(SlashList.add([], "/a") == .success(["/a"]))
    }

    @Test func addRefusesACopyABadCommandAndAFullList() {
        #expect(SlashList.add(["/a"], "/a") == .failure(.slashCopy))
        #expect(SlashList.add(["/a"], " /a ") == .failure(.slashCopy))
        #expect(SlashList.add(["/a"], "b") == .failure(.slashStart))
        #expect(SlashList.add(["/a"], "/a\nb") == .failure(.slashLines))
        let full = (0..<12).map { "/c\($0)" }
        #expect(SlashList.add(full, "/new") == .failure(.slashFull))
        let eleven = Array(full.prefix(11))
        #expect(SlashList.add(eleven, "/new") == .success(eleven + ["/new"]))
    }

    // The check of the command comes first, then the copy, then the size of the list.
    @Test func theFirstReasonInTheOrderOfTheChecksShows() {
        let full = (0..<12).map { "/c\($0)" }
        #expect(SlashList.add(full, "b") == .failure(.slashStart))
        #expect(SlashList.add(full, "/c0") == .failure(.slashCopy))
    }

    @Test func eachRefusalOfTheListHasItsText() {
        #expect(SettingsRefusal.slashCopy.message == "That command is already in the list.")
        #expect(SettingsRefusal.slashFull.message == "You can keep up to 12 commands.")
    }

    @Test func removeAndMoveChangeTheOrderAndKeepTheListAtAnEdge() {
        let list = ["/a", "/b", "/c"]
        #expect(SlashList.remove(list, at: 1) == ["/a", "/c"])
        #expect(SlashList.remove(list, at: 3) == list)
        #expect(SlashList.remove(list, at: -1) == list)
        #expect(SlashList.move(list, at: 1, by: -1) == ["/b", "/a", "/c"])
        #expect(SlashList.move(list, at: 1, by: 1) == ["/a", "/c", "/b"])
        #expect(SlashList.move(list, at: 0, by: -1) == list)
        #expect(SlashList.move(list, at: 2, by: 1) == list)
        #expect(SlashList.move(list, at: 5, by: -1) == list)
        #expect(SlashList.move(list, at: -1, by: 1) == list)
    }
}
