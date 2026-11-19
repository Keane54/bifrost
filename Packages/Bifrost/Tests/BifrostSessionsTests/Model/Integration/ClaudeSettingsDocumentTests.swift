import Foundation
import Testing

@testable import BifrostSessions

private typealias Document = ClaudeSettingsDocument

@Suite("the Claude Code settings document", .timeLimit(.minutes(1)))
struct ClaudeSettingsDocumentTests {
    // Each object keeps the order of its keys, and each number keeps its text.
    @Test func theKeyOrderAndTheNumberTextsStayInTheText() throws {
        let text =
            #"{"zeta":1.0,"alpha":{"b":1e3,"a":-0},"mid":[0.10,1E+2,12345678901234567890,-1.5e-7]}"#
        #expect(
            try settings(text).text == """
                {
                  "zeta": 1.0,
                  "alpha": {
                    "b": 1e3,
                    "a": -0
                  },
                  "mid": [
                    0.10,
                    1E+2,
                    12345678901234567890,
                    -1.5e-7
                  ]
                }

                """)
    }

    // Two spaces of indent for each level, ": " after a key, {} and [] for an empty object or
    // array, and a newline at the end.
    @Test func theTextHasTwoSpacesForEachLevelAndANewlineAtTheEnd() throws {
        #expect(try settings("{}").text == "{}\n")
        #expect(
            try settings(#"{"a":{},"b":[],"c":[{"d":true},false,null,[[]]],"e":"x"}"#).text == """
                {
                  "a": {},
                  "b": [],
                  "c": [
                    {
                      "d": true
                    },
                    false,
                    null,
                    [
                      []
                    ]
                  ],
                  "e": "x"
                }

                """)
    }

    // A string keeps its text between the quotes. Its value decodes each escape.
    @Test func aStringKeepsItsEscapes() throws {
        let document = try settings(#"{"a":"\u00e9\/\n\"x\\","\u0062":"é\t"}"#)
        #expect(
            document.text == #"""
                {
                  "a": "\u00e9\/\n\"x\\",
                  "\u0062": "é\t"
                }

                """#)
        #expect(document["a"]?.text?.is("é/\n\"x\\") == true)
        #expect(document["b"]?.text?.is("é\t") == true)
    }

    // A lone surrogate stays in the text and in the code units of the value.
    @Test func aLoneSurrogateStays() throws {
        let document = try settings(#"{"a":"x\ud83d","\uDC00":1}"#)
        #expect(document.text == "{\n  \"a\": \"x\\ud83d\",\n  \"\\uDC00\": 1\n}\n")
        #expect(document["a"]?.text?.units == [0x78, 0xD83D])
        #expect(document.members[1].key.units == [0xDC00])
    }

    // A key that the object has already keeps its first place and gets the last value.
    @Test func aRepeatedKeyKeepsItsFirstPlaceAndItsLastValue() throws {
        #expect(try settings(#"{"a":1,"b":2,"a":3}"#).text == "{\n  \"a\": 3,\n  \"b\": 2\n}\n")
        #expect(try settings(#"{"a":1,"\u0061":[2]}"#) == settings(#"{"a":[2]}"#))
    }

    // Two keys are one key only when their code units are the same.
    @Test func aPrecomposedKeyAndADecomposedKeyAreTwoKeys() throws {
        let document = try settings("{\"\u{E9}\":1,\"e\u{301}\":2}")
        #expect(document.members.count == 2)
        #expect(document["\u{E9}"] == .number("1"))
        #expect(document["e\u{301}"] == .number("2"))
    }

    @Test func aByteOrderMarkAtTheStartIsSkipped() throws {
        let document = try Document.parse(Data([0xEF, 0xBB, 0xBF] + Array(#"{"a":1}"#.utf8)))
        #expect(document.text == "{\n  \"a\": 1\n}\n")
    }

    @Test func theWhiteSpaceOfJSONIsAccepted() throws {
        let document = try settings(" \t\r\n{ \"a\" :\t[ 1 ,\r\n2 ] }\n ")
        #expect(document == (try settings(#"{"a":[1,2]}"#)))
    }

    @Test(arguments: [
        "", " ", "{", "{ not json", #"{"a":1,}"#, #"{"a":01}"#, #"{"a":.5}"#, #"{"a":+1}"#,
        #"{"a":1.}"#, #"{"a":1e}"#, #"{"a":1e+}"#, #"{"a":-}"#, #"{"a":tru}"#, #"{"a":NaN}"#,
        #"{"a":Infinity}"#, "{'a':1}", "{a:1}", #"{"a":"\x"}"#, #"{"a":"\u12"}"#,
        #"{"a":"\u12g4"}"#, "{\"a\":\"\t\"}", "{\"a\":\"\u{1F}\"}", "{} {}", #"{"a":1} x"#,
        "{/* c */}", "// c\n{}", #"{"a":[1,]}"#, #"{"a" 1}"#, #"{"a":1 "b":2}"#, #"{"a":"x}"#,
        #"{"a":[1 2]}"#, #"{,}"#, "\u{FEFF}\u{FEFF}{}",
    ])
    func textThatIsNotJSONIsRefused(_ text: String) {
        #expect(throws: Document.ParseError.notJSON) { try settings(text) }
    }

    // A byte that is not UTF-8, an overlong form and an encoded surrogate.
    @Test(arguments: [
        [0x7B, 0x22, 0x61, 0x22, 0x3A, 0x22, 0xE9, 0x22, 0x7D],
        [0x7B, 0x22, 0x61, 0x22, 0x3A, 0x22, 0xC0, 0xAF, 0x22, 0x7D],
        [0x7B, 0x22, 0x61, 0x22, 0x3A, 0x22, 0xED, 0xA0, 0x80, 0x22, 0x7D],
    ] as [[UInt8]])
    func bytesThatAreNotUTF8AreRefused(_ bytes: [UInt8]) {
        #expect(throws: Document.ParseError.notJSON) { try Document.parse(Data(bytes)) }
    }

    @Test(arguments: ["[]", "null", "\"x\"", "7", "true", " [{}] "])
    func aValueThatIsNotAnObjectIsRefused(_ text: String) throws {
        #expect(throws: Document.ParseError.notObject) { try settings(text) }
        _ = try jsonValue(text)
    }

    // The object is level 1, and each array adds a level.
    @Test func moreThanMaxDepthLevelsAreRefused() throws {
        func nested(_ arrays: Int) -> String {
            #"{"a":"# + String(repeating: "[", count: arrays)
                + String(repeating: "]", count: arrays) + "}"
        }
        #expect(Document.maxDepth == 64)
        _ = try settings(nested(63))
        #expect(throws: Document.ParseError.tooDeep) { try settings(nested(64)) }
        // A hostile file stops at the limit, with no deep recursion.
        let hostile = "{\"a\":" + String(repeating: "[{\"b\":", count: 100_000)
        #expect(throws: Document.ParseError.tooDeep) { try settings(hostile) }
    }

    // A key of the object keeps its place. A new key goes at the end, with the escapes of JSON.
    @Test func setValueAndRemoveValueKeepThePlaces() throws {
        var document = try settings(#"{"a":1,"b":2,"c":3}"#)
        document.setValue(.bool(true), forKey: "b")
        document.setValue(.null, forKey: "new \"key\"\n")
        document.removeValue(forKey: "a")
        document.removeValue(forKey: "missing")
        #expect(
            document.text == "{\n  \"b\": true,\n  \"c\": 3,\n  \"new \\\"key\\\"\\n\": null\n}\n")
        #expect(document["new \"key\"\n"] == .null)
    }

    // A quote, a backslash and each control character get an escape. Each other character stays,
    // also DEL and the line separator.
    @Test func theTextOfAStringHasTheEscapesOfJSON() {
        let text = Document.Text("\"\\\u{8}\u{C}\n\r\t\u{1}\u{1F}\u{7F}é\u{2028}/")
        #expect(text.raw == "\\\"\\\\\\b\\f\\n\\r\\t\\u0001\\u001f\u{7F}é\u{2028}/")
        #expect(text.is("\"\\\u{8}\u{C}\n\r\t\u{1}\u{1F}\u{7F}é\u{2028}/"))
    }
}
