// The key editor and the menus name each session action the same way: the label of the key slot
// of an action is the title of that action, with the text that the key adds after it.
import BifrostFoundation
import BifrostKeyboard
import BifrostSessions
import Testing

@Suite("the labels of the keys and of the actions")
struct ActionKeyLabelTests {
    @Test func eachKeyOfASessionActionHasTheTitleOfTheAction() throws {
        // The command of the key, its action, and the text after the title.
        let shared: [(KeyCommand, ActionID, String)] = [
            (.newSession, .newSession, ""), (.open, .open, ""), (.sendMessage, .sendMessage, ""),
            (.runSlash, .runSlash, ""), (.interrupt, .interrupt, ""), (.rename, .rename, ""),
            (.showInfo, .showInfo, ""), (.copyId, .copyId, ""),
            (.openProject, .openProject, " in the default app"),
            (.openInTerminal, .openInTerminal, ""), (.takeControl, .takeControl, ""),
            (.resume, .resume, ""), (.resumeAll, .resumeAll, ""),
            (.setPriority(1), .setPriority, " 1"), (.stop, .stop, ""), (.delete, .delete, ""),
        ]
        #expect(shared.count == 16)
        for (command, id, after) in shared {
            let slot = try #require(KeySlot.all.first { $0.command == command })
            for labels in LabelSet.allCases {
                #expect(slot.label(labels) == id.title(labels) + after)
            }
        }
    }
}
