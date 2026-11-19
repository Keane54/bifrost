import Foundation
import Testing

@testable import BifrostFoundation

// The texts of the errors (final review, item 1). The log lines of the stores are in the tests of
// their modules (SettingsErrorTextTests, RegistryErrorTextTests). Error texts are native Swift
// texts (user decision, 2026-11-15). A system error gives the action of the call, the path and the
// text of the system, for example "Cannot save /a: Permission denied.". The text never has a POSIX
// error name (EACCES) or the debug text of an NSError (a memory address or a curly-quoted name).

// True when the text has a part of the debug text of an NSError.
private func hasDebugText(_ text: String) -> Bool {
    ["Error Domain", "0x", "UserInfo", "\u{201C}", "\u{201D}"].contains { text.contains($0) }
}

// An error with its own text, for the form "another error".
private struct DiskFull: LocalizedError {
    var errorDescription: String? { "The disk is full." }
}

// True when the text has a word of the form of a POSIX error name, for example "EACCES".
private func hasErrorName(_ text: String) -> Bool {
    text.split { !$0.isLetter && !$0.isNumber }.contains { word in
        word.count > 2 && word.first == "E"
            && word.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
    }
}

@Suite("ErrorText")
struct ErrorTextTests {
    @Test func aPOSIXErrorGivesTheActionThePathAndTheReason() {
        let text = ErrorText.of(POSIXError(.EACCES), call: .read, path: "/tmp/a")
        #expect(text == "Cannot read /tmp/a: Permission denied.")
        // An NSError in the POSIX domain is the same error.
        let bridged = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        #expect(
            ErrorText.of(bridged, call: .read, path: "/tmp/a")
                == "Cannot read /tmp/a: No such file or directory.")
    }

    // Data(contentsOf:) gives a Cocoa error with the POSIX error EISDIR for a folder.
    @Test func aCocoaErrorWithAPOSIXErrorGivesTheReasonOfTheSystem() throws {
        let folder = "/usr"
        let error = #expect(throws: CocoaError.self) {
            try Data(contentsOf: URL(fileURLWithPath: folder))
        }
        let cocoa = try #require(error)
        let text = ErrorText.of(cocoa, call: .read, path: "/x/settings.json")
        #expect(text == "Cannot read /x/settings.json: Is a directory.")
        #expect(!hasDebugText(text))
    }

    @Test func anotherErrorGivesItsLocalizedDescription() {
        #expect(ErrorText.of(DiskFull(), call: .save, path: "/tmp/a") == "The disk is full.")
        #expect(ErrorText.of(DiskFull()) == "The disk is full.")
        // A Cocoa error with no POSIX error gives the text of Foundation, with no debug text.
        let cocoa = CocoaError(.fileWriteOutOfSpace)
        let text = ErrorText.of(cocoa, call: .save, path: "/tmp/a")
        #expect(text == cocoa.localizedDescription)
        #expect(!hasDebugText(text))
    }

    @Test func aSystemErrorWithNoCallGivesTheReasonOfTheSystem() {
        #expect(ErrorText.of(POSIXError(.EACCES)) == "Permission denied.")
        #expect(ErrorText.of(POSIXError(.EIO)) == "Input/output error.")
    }

    @Test func aCallWithTwoPathsGivesBothPaths() {
        #expect(
            ErrorText.of(POSIXError(.EISDIR), call: .copy(to: "/b"), path: "/a")
                == "Cannot copy /a to /b: Is a directory.")
        #expect(
            ErrorText.system(EIO, call: .copy(to: "/b"), path: "/a")
                == "Cannot copy /a to /b: Input/output error.")
        #expect(
            ErrorText.system(EACCES, call: .rename(to: "/b"), path: "/a")
                == "Cannot rename /a to /b: Permission denied.")
    }

    // A program that fails: an exit code, a signal, or a start that fails. A start error with
    // no POSIX error gives the text of the error, with one full stop.
    @Test func aProgramTextNamesTheProgram() {
        #expect(ErrorText.stopped("claude", code: 2) == "claude stopped with code 2.")
        #expect(ErrorText.stopped("/bin/sh", signal: SIGTERM) == "/bin/sh stopped with signal 15.")
        #expect(
            ErrorText.notStarted("/x/claude", code: ENOENT)
                == "Cannot start /x/claude: No such file or directory.")
        #expect(
            ErrorText.notStarted("/bin/sh", in: "/nowhere", code: ENOTDIR)
                == "Cannot start /bin/sh in /nowhere: Not a directory.")
        #expect(
            ErrorText.notStarted("/x/claude", error: POSIXError(.ETXTBSY))
                == "Cannot start /x/claude: Text file busy.")
        #expect(
            ErrorText.notStarted("/x/claude", error: DiskFull())
                == "Cannot start /x/claude: The disk is full.")
    }

    // The time limit stopped the program. The limit is in
    // seconds, with at most three decimals and no zero at the end.
    @Test func aTimedOutProgramNamesTheLimit() {
        #expect(
            ErrorText.timedOut("/x/claude", limit: .seconds(5))
                == "/x/claude did not finish within 5 s.")
        #expect(
            ErrorText.timedOut("/bin/sleep", limit: .milliseconds(100))
                == "/bin/sleep did not finish within 0.1 s.")
        #expect(ErrorText.seconds(.milliseconds(2500)) == "2.5")
        #expect(ErrorText.seconds(.milliseconds(1250)) == "1.25")
        #expect(ErrorText.seconds(.milliseconds(30_005)) == "30.005")
        #expect(ErrorText.seconds(.seconds(30)) == "30")
        #expect(ErrorText.seconds(.zero) == "0")
    }

    // The one native form (user decision, 2026-11-15): for each call and each error number, the
    // text is the action, the path, ": ", the text of the system and a full stop. The helper adds
    // no POSIX name of the error. (The text of the system for the two reserved numbers EMULTIHOP
    // and ENOLINK is that name, for example "EMULTIHOP (Reserved)".)
    @Test func eachTextHasTheNativeFormAndNoErrorName() {
        let calls: [SystemCall] = [
            .read, .save, .copy(to: "/b"), .rename(to: "/b"), .createFolder, .setPermissions,
            .check, .remove, .listen, .connect, .createSocket, .setUpSocket, .waitForAnswer,
        ]
        var bad: [String] = []
        for call in calls {
            for code in Int32(1)...Int32(ELAST) {
                let text = ErrorText.system(code, call: call, path: "/a")
                let reason = ErrorText.reason(code)
                let form = text.hasPrefix("Cannot ") && text.hasSuffix(": \(reason).")
                let added = text.dropLast(reason.count + 1)
                if !form || hasErrorName(String(added)) { bad.append(text) }
            }
        }
        #expect(bad == [])
    }

    // The reason comes from strerror_r with a local buffer, so many threads can ask at once.
    @Test func theReasonIsTheTextOfTheSystemAlsoOnManyThreads() async {
        #expect(ErrorText.reason(EACCES) == "Permission denied")
        #expect(ErrorText.reason(9999) == "Unknown error: 9999")
        let texts = await withTaskGroup(of: String.self) { group in
            for index in 0..<64 {
                group.addTask { ErrorText.reason(index.isMultiple(of: 2) ? ENOENT : 9998) }
            }
            return await group.reduce(into: Set<String>()) { $0.insert($1) }
        }
        #expect(texts == ["No such file or directory", "Unknown error: 9998"])
    }
}
