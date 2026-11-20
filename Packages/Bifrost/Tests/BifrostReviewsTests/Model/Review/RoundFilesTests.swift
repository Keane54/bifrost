// The names of the files of one round in the round folder of a PR (docs/behaviour/reviews.md,
// "Request rounds"). Each name carries the round ID, so a file of an earlier round never counts.
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

@Suite("the files of a round", .testTimeLimit)
struct RoundFilesTests {
    // The round ID is the first 12 hex digits of the token, and each name of the round has it.
    // Only the hex digits of the token count, so a name never holds a path character.
    @Test func namesCarryTheRoundIDOfTheToken() {
        let folder = URL(filePath: "/tmp/io/7", directoryHint: .isDirectory)
        let files = RoundFiles(folder: folder, token: "0f8a2c1e-5b7d-4c3a-9e21-6d4b8f0a1c2e")
        #expect(files.folder == folder)
        #expect(files.id == "0f8a2c1e5b7d")
        #expect(files.input.path(percentEncoded: false) == "/tmp/io/7/input-0f8a2c1e5b7d.json")
        #expect(files.result.path(percentEncoded: false) == "/tmp/io/7/result-0f8a2c1e5b7d.json")
        #expect(
            files.file("log-101", "txt").path(percentEncoded: false)
                == "/tmp/io/7/log-101-0f8a2c1e5b7d.txt")
        #expect(RoundFiles(folder: folder, token: "../ab/cd-ef").id == "abcdef")
    }
}
