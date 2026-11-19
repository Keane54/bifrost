import BifrostApp
import BifrostFoundation
import BifrostHealth
import BifrostLayout
import BifrostLive
import BifrostSessions
import BifrostTestSupport
import BifrostWindows
import Foundation
import Testing

// The lines of the debug test port: one JSON object in, one JSON line out.
// The parse is strict, because the port can type into a session: a field that the form does not
// have, a bad value or a line that is not one JSON object is no request.

private let fixture = "5a0e0001-0000-4000-8000-000000000001"
private let chat = "chat:\(fixture)"

@Suite("test port message")
struct TestPortMessageTests {
    @Test func aStateRequest() {
        #expect(TestPortMessage.request(#"{"op":"state"}"#) == .state)
        // JSON allows white space around the values.
        #expect(TestPortMessage.request(#" { "op" : "state" } "#) == .state)
    }

    @Test func anOpenRequestNamesAPanel() throws {
        let panel = try #require(PanelID(chat))
        #expect(TestPortMessage.request(#"{"op":"open","panel":"\#(chat)"}"#) == .open(panel))
        let overview = try #require(PanelID("overview:1"))
        #expect(
            TestPortMessage.request(#"{"panel":"overview:1","op":"open"}"#) == .open(overview))
        // A text that is not a panel ID, no panel, or a panel that is not a string.
        #expect(TestPortMessage.request(#"{"op":"open","panel":"chat:5a0e0001"}"#) == nil)
        #expect(TestPortMessage.request(#"{"op":"open"}"#) == nil)
        #expect(TestPortMessage.request(#"{"op":"open","panel":1}"#) == nil)
    }

    // The text is printable ASCII: the keys of a US keyboard type it.
    @Test func aTypeRequestHasPrintableASCIIText() {
        #expect(TestPortMessage.request(#"{"op":"type","text":"hello"}"#) == .type("hello"))
        let all = (0x20...0x7e).compactMap(Unicode.Scalar.init).map(String.init).joined()
        let line = #"{"op":"type","text":"\#(jsonEscaped(all))"}"#
        #expect(TestPortMessage.request(line) == .type(all))
        for bad in [#""héllo""#, #""a\nb""#, #""a\u001bb""#, #""""#, "1", "null"] {
            #expect(TestPortMessage.request(#"{"op":"type","text":\#(bad)}"#) == nil, "\(bad)")
        }
    }

    @Test func aKeyRequestNamesAKey() {
        let keys: [(String, TestKey)] = [
            ("enter", .enter), ("shift-enter", .shiftEnter), ("escape", .escape),
            ("interrupt", .interrupt),
        ]
        for (name, key) in keys {
            #expect(TestPortMessage.request(#"{"op":"key","key":"\#(name)"}"#) == .key(key))
        }
        for bad in [#""tab""#, #""Enter""#, #""""#, "true", #""Interrupt""#, #""cmd-.""#] {
            #expect(TestPortMessage.request(#"{"op":"key","key":\#(bad)}"#) == nil, "\(bad)")
        }
    }

    @Test func aQuitRequest() {
        #expect(TestPortMessage.request(#"{"op":"quit"}"#) == .quit)
    }

    // A sort of the active tab of an Overview: the panel is the ID of an Overview, and the sort
    // is the ID of a column, as the saved config writes it.
    @Test func anOverviewRequestNamesAnOverviewAndAColumn() throws {
        let overview = try #require(PanelID("overview:2"))
        #expect(
            TestPortMessage.request(#"{"op":"overview","panel":"overview:2","sort":"name"}"#)
                == .overview(overview, sort: .name))
        let reordered = #"{"sort":"activity","panel":"overview:2","op":"overview"}"#
        #expect(TestPortMessage.request(reordered) == .overview(overview, sort: .activity))
        for column in OverviewColumn.allCases {
            let line = #"{"op":"overview","panel":"overview:2","sort":"\#(column.rawValue)"}"#
            #expect(TestPortMessage.request(line) == .overview(overview, sort: column))
        }
        let bad = [
            // A panel that is not an Overview.
            #"{"op":"overview","panel":"\#(chat)","sort":"name"}"#,
            #"{"op":"overview","panel":"overview-settings:2","sort":"name"}"#,
            #"{"op":"overview","panel":"overview","sort":"name"}"#,
            // A column that is not an ID, or a value that is not a string.
            #"{"op":"overview","panel":"overview:2","sort":"Name"}"#,
            #"{"op":"overview","panel":"overview:2","sort":"title"}"#,
            #"{"op":"overview","panel":"overview:2","sort":""}"#,
            #"{"op":"overview","panel":"overview:2","sort":1}"#,
            #"{"op":"overview","panel":"overview:2","sort":null}"#,
            #"{"op":"overview","panel":2,"sort":"name"}"#,
            // A missing field or a field of another form.
            #"{"op":"overview","panel":"overview:2"}"#,
            #"{"op":"overview","sort":"name"}"#,
            #"{"op":"overview","panel":"overview:2","sort":"name","desc":true}"#,
            #"{"op":"overview","panel":"overview:2","sort":"name","text":"a"}"#,
        ]
        for line in bad {
            #expect(TestPortMessage.request(line) == nil, "\(line)")
        }
    }

    // A change of the settings: the patch is one JSON object, the one raw value of a request. The
    // change checks its fields (SettingsPatch), so the parse keeps each field and each value.
    @Test func aSettingRequestHasOnePatchObject() {
        let scale = #"{"op":"setting","patch":{"interfaceScale":120}}"#
        #expect(TestPortMessage.request(scale) == .setting(["interfaceScale": 120]))
        let keys = #"{"patch":{"keys":{"close-panel:mod":"Mod+Shift+K"},"x":null},"op":"setting"}"#
        #expect(
            TestPortMessage.request(keys)
                == .setting(["keys": ["close-panel:mod": "Mod+Shift+K"], "x": .null]))
        #expect(TestPortMessage.request(#"{"op":"setting","patch":{}}"#) == .setting([:]))
        let bad = [
            // A patch that is not an object, or no patch.
            #"{"op":"setting","patch":[]}"#, #"{"op":"setting","patch":null}"#,
            #"{"op":"setting","patch":"interfaceScale"}"#, #"{"op":"setting","patch":120}"#,
            #"{"op":"setting"}"#,
            // A field of another form.
            #"{"op":"setting","patch":{},"text":"a"}"#,
            #"{"op":"setting","patch":{},"panel":"settings"}"#,
        ]
        for line in bad {
            #expect(TestPortMessage.request(line) == nil, "\(line)")
        }
    }

    // An action of Live details or of the skills: the action is one of the four actions of a
    // section, by its name.
    @Test func aLiveOrSkillsRequestNamesAnAction() {
        let actions: [(String, LiveAction)] = [
            ("install", .install), ("enable", .enable), ("disable", .disable),
            ("uninstall", .uninstall),
        ]
        for (name, action) in actions {
            #expect(
                TestPortMessage.request(#"{"op":"live","action":"\#(name)"}"#) == .live(action))
            #expect(
                TestPortMessage.request(#"{"action":"\#(name)","op":"skills"}"#)
                    == .skills(action))
        }
        let bad = [
            // An action that is not one of the four, of another case, or not a string.
            #"{"op":"live","action":"remove"}"#, #"{"op":"live","action":"Install"}"#,
            #"{"op":"skills","action":""}"#, #"{"op":"skills","action":1}"#,
            #"{"op":"live","action":null}"#,
            // No action, or a field of another form.
            #"{"op":"live"}"#, #"{"op":"skills","action":"install","panel":"settings"}"#,
            #"{"op":"state","action":"install"}"#,
        ]
        for line in bad {
            #expect(TestPortMessage.request(line) == nil, "\(line)")
        }
    }

    @Test func aReleaseNotesRequestHasNoOtherField() {
        #expect(TestPortMessage.request(#"{"op":"releaseNotes"}"#) == .releaseNotes)
        #expect(TestPortMessage.request(#"{"op":"releaseNotes","panel":"settings"}"#) == nil)
        #expect(TestPortMessage.request(#"{"op":"release-notes"}"#) == nil)
    }

    // Refresh has no area, and Mark as sent needs the ID of an area.
    @Test func aDailyRequestNamesItsActionAndAnArea() {
        #expect(TestPortMessage.request(#"{"op":"daily","action":"refresh"}"#) == .daily(.refresh))
        #expect(
            TestPortMessage.request(#"{"op":"daily","action":"mark-sent","area":"a-1"}"#)
                == .daily(.markSent("a-1")))
        let bad = [
            #"{"op":"daily"}"#, #"{"op":"daily","action":"refresh","area":"a-1"}"#,
            #"{"op":"daily","action":"mark-sent"}"#,
            #"{"op":"daily","action":"mark-sent","area":""}"#,
            #"{"op":"daily","action":"mark-sent","area":7}"#,
            #"{"op":"daily","action":"send","area":"a-1"}"#,
            #"{"op":"daily","action":"refresh","session":"x"}"#,
        ]
        for line in bad { #expect(TestPortMessage.request(line) == nil, "\(line)") }
    }

    // A click on a row of the Reviews panel: review or pause, and the key of a pull request. The
    // request keeps the key as its text.
    @Test func aReviewsRequestNamesAnActionAndAPullRequest() {
        #expect(
            TestPortMessage.request(#"{"op":"reviews","action":"review","pr":"owner-a/repo-a#7"}"#)
                == .reviews(.review, pr: "owner-a/repo-a#7"))
        #expect(
            TestPortMessage.request(#"{"op":"reviews","action":"pause","pr":"Owner-A/Repo.b#12"}"#)
                == .reviews(.pause, pr: "Owner-A/Repo.b#12"))
        let bad = [
            #"{"op":"reviews"}"#, #"{"op":"reviews","action":"review"}"#,
            #"{"op":"reviews","pr":"owner-a/repo-a#7"}"#,
            #"{"op":"reviews","action":"approve","pr":"owner-a/repo-a#7"}"#,
            #"{"op":"reviews","action":"remove","pr":"owner-a/repo-a#7"}"#,
            #"{"op":"reviews","action":"Review","pr":"owner-a/repo-a#7"}"#,
            #"{"op":"reviews","action":"review","pr":"owner-a/repo-a"}"#,
            #"{"op":"reviews","action":"review","pr":"repo-a#7"}"#,
            #"{"op":"reviews","action":"review","pr":"owner-a/repo-a#0"}"#,
            #"{"op":"reviews","action":"review","pr":"owner-a/repo-a#07"}"#,
            #"{"op":"reviews","action":"review","pr":"owner-a/../repo-a#7"}"#,
            #"{"op":"reviews","action":"review","pr":7}"#,
            #"{"op":"reviews","action":"review","pr":"owner-a/repo-a#7","confirm":true}"#,
            #"{"op":"reviews","action":"review","pr":"owner-a/repo-a#7","session":"x"}"#,
        ]
        for line in bad { #expect(TestPortMessage.request(line) == nil, "\(line)") }
    }

    // A resume of a session: the session is a session ID.
    @Test func aResumeRequestNamesASessionId() {
        let id = "5a0e0005-0000-4000-8000-000000000005"
        #expect(TestPortMessage.request(#"{"op":"resume","session":"\#(id)"}"#) == .resume(id))
        let bad = [
            #"{"op":"resume","session":"5a0e0005"}"#, #"{"op":"resume","session":""}"#,
            #"{"op":"resume","session":1}"#, #"{"op":"resume"}"#,
            #"{"op":"resume","session":"\#(id)","text":"a"}"#,
        ]
        for line in bad {
            #expect(TestPortMessage.request(line) == nil, "\(line)")
        }
    }

    // A hold of the dictation key: the key is "space", and the
    // time is a whole number of milliseconds from 1 to 10,000.
    @Test func aHoldRequestNamesSpaceAndATime() {
        #expect(TestPortMessage.request(#"{"op":"hold","key":"space","ms":800}"#) == .hold(ms: 800))
        #expect(TestPortMessage.request(#"{"ms":1,"op":"hold","key":"space"}"#) == .hold(ms: 1))
        let longest = #"{"op":"hold","key":"space","ms":10000}"#
        #expect(TestPortMessage.request(longest) == .hold(ms: 10_000))
        let bad = [
            #"{"op":"hold","key":"space","ms":0}"#, #"{"op":"hold","key":"space","ms":10001}"#,
            #"{"op":"hold","key":"space","ms":-5}"#, #"{"op":"hold","key":"space","ms":1.5}"#,
            #"{"op":"hold","key":"space","ms":"800"}"#, #"{"op":"hold","key":"space"}"#,
            #"{"op":"hold","ms":800}"#, #"{"op":"hold","key":"Space","ms":800}"#,
            #"{"op":"hold","key":"enter","ms":800}"#, #"{"op":"hold","key":"space","ms":null}"#,
            #"{"op":"hold","key":"space","ms":800,"text":"a"}"#,
        ]
        for line in bad {
            #expect(TestPortMessage.request(line) == nil, "\(line)")
        }
    }

    // A bench run: a plan name, 1 to 8 chats and a file
    // name of 1 to 40 characters from a to z, 0 to 9 and "-". The request never names a path.
    @Test func aBenchRequestNamesAPlanChatsAndAFileName() {
        let gate = #"{"op":"bench","plan":"gate","chats":8,"name":"run-1"}"#
        #expect(
            TestPortMessage.request(gate)
                == .bench(TestBench(plan: .gate, chats: 8, name: "run-1", variant: .init())))
        let short = #"{"name":"a","chats":1,"plan":"short","op":"bench"}"#
        #expect(
            TestPortMessage.request(short)
                == .bench(TestBench(plan: .short, chats: 1, name: "a", variant: .init())))
        let longest = String(repeating: "z9-", count: 13) + "x"
        let line = #"{"op":"bench","plan":"gate","chats":2,"name":"\#(longest)"}"#
        #expect(
            TestPortMessage.request(line)
                == .bench(TestBench(plan: .gate, chats: 2, name: longest, variant: .init())))
        let names = [
            #""""#, #""Run""#, #""run.jsonl""#, #""../run""#, #""a/b""#, #""run 1""#,
            #""run_1""#, #""é""#, "1", "null", #""\#(longest)a""#,
        ]
        for name in names {
            let bad = #"{"op":"bench","plan":"gate","chats":8,"name":\#(name)}"#
            #expect(TestPortMessage.request(bad) == nil, "\(name)")
        }
        let others = [
            #"{"op":"bench","plan":"soak","chats":8,"name":"run"}"#,
            #"{"op":"bench","plan":"Gate","chats":8,"name":"run"}"#,
            #"{"op":"bench","plan":"gate","chats":0,"name":"run"}"#,
            #"{"op":"bench","plan":"gate","chats":9,"name":"run"}"#,
            #"{"op":"bench","plan":"gate","chats":2.5,"name":"run"}"#,
            #"{"op":"bench","plan":"gate","chats":"8","name":"run"}"#,
            #"{"op":"bench","plan":"gate","chats":8}"#,
            #"{"op":"bench","plan":"gate","name":"run"}"#,
            #"{"op":"bench","chats":8,"name":"run"}"#,
            #"{"op":"bench","plan":"gate","chats":8,"name":"run","path":"/tmp/x"}"#,
            #"{"op":"bench","plan":"gate","chats":8,"name":"run","output":"run.jsonl"}"#,
        ]
        for bad in others {
            #expect(TestPortMessage.request(bad) == nil, "\(bad)")
        }
        // The one rule of the name, for the request and for the results file of the runner.
        #expect(TestPortMessage.isBenchName("run-1"))
        #expect(TestPortMessage.isBenchName(longest))
        #expect(!TestPortMessage.isBenchName(longest + "a"))
        #expect(!TestPortMessage.isBenchName("run.jsonl"))
        #expect(!TestPortMessage.isBenchName(""))
    }

    // The variant fields of a bench run are optional: the blur, the background and the
    // session list (true or false), the minimised chats (0 to chats - 1), the streaming chats and
    // the Metal chats (0 to chats), and the scrollback lines (0 to 10,000).
    @Test func aBenchRequestTakesTheVariantFields() {
        let fields =
            #""blur":false,"background":false,"list":false,"minimised":4,"streaming":1,"#
            + #""metal":1,"scrollback":200"#
        let line = #"{"op":"bench","plan":"short","chats":8,"name":"b",\#(fields)}"#
        let variant = BenchVariant(
            blur: false, background: false, list: false, minimised: 4, streaming: 1, metal: 1,
            scrollback: 200)
        #expect(
            TestPortMessage.request(line)
                == .bench(TestBench(plan: .short, chats: 8, name: "b", variant: variant)))
        // The defaults: effects on, the list open, no minimised chat, each chat streams with
        // Metal, and the scrollback of the app.
        #expect(BenchVariant() == BenchVariant(blur: true, background: true, list: true))
        #expect(BenchVariant().streaming == nil)
        #expect(BenchVariant().metal == nil)
        #expect(BenchVariant().scrollback == nil)
        let good = [
            #""minimised":7"#, #""streaming":0"#, #""streaming":8"#, #""metal":0"#,
            #""scrollback":0"#, #""scrollback":10000"#, #""blur":true"#,
        ]
        for field in good {
            let request = #"{"op":"bench","plan":"gate","chats":8,"name":"r",\#(field)}"#
            #expect(TestPortMessage.request(request) != nil, "\(field)")
        }
        let bad = [
            #""minimised":8"#, #""minimised":-1"#, #""streaming":9"#, #""metal":9"#,
            #""scrollback":10001"#, #""scrollback":-1"#, #""blur":"no""#, #""blur":0"#,
            #""list":null"#, #""metal":1.5"#, #""effects":false"#,
        ]
        for field in bad {
            let request = #"{"op":"bench","plan":"gate","chats":8,"name":"r",\#(field)}"#
            #expect(TestPortMessage.request(request) == nil, "\(field)")
        }
        // The counts depend on the chats: with 2 chats, 1 minimised chat is the most.
        let two = #"{"op":"bench","plan":"gate","chats":2,"name":"r","#
        #expect(TestPortMessage.request(two + #""minimised":1}"#) != nil)
        #expect(TestPortMessage.request(two + #""minimised":2}"#) == nil)
        #expect(TestPortMessage.request(two + #""streaming":3}"#) == nil)
        #expect(TestPortMessage.request(two + #""metal":3}"#) == nil)
    }

    // The run of a session action: the ID of the action and the ID of the session. The
    // confirmations of the run answer yes only with "confirm":true. Rename takes the new local
    // name. An action that needs the choice of a menu (a priority, an app or a colour), acts
    // outside the test home or only moves the focus is no request.
    @Test func anActionRequestNamesAnActionAndASession() throws {
        let session = try #require(SessionID(fixture))
        #expect(
            TestPortMessage.request(#"{"op":"action","id":"stop","session":"\#(fixture)"}"#)
                == .action(TestAction(.session(.stop, session))))
        let delete = #"{"confirm":true,"session":"\#(fixture)","id":"delete","op":"action"}"#
        #expect(
            TestPortMessage.request(delete)
                == .action(TestAction(.session(.delete, session), confirm: true)))
        let no = #"{"op":"action","id":"stop","session":"\#(fixture)","confirm":false}"#
        #expect(TestPortMessage.request(no) == .action(TestAction(.session(.stop, session))))
        let rename = #"{"op":"action","id":"rename","session":"\#(fixture)","name":"smoke"}"#
        #expect(
            TestPortMessage.request(rename)
                == .action(TestAction(.session(.rename, session), name: "smoke")))
        // The session ID keeps its lower-case form.
        let upper = fixture.uppercased()
        #expect(
            TestPortMessage.request(#"{"op":"action","id":"interrupt","session":"\#(upper)"}"#)
                == .action(TestAction(.session(.interrupt, session))))
        let bad = [
            // No session, a session that is not a session ID, or no ID.
            #"{"op":"action","id":"stop"}"#,
            #"{"op":"action","id":"stop","session":"5a0e0001"}"#,
            #"{"op":"action","id":"stop","session":1}"#,
            #"{"op":"action","session":"\#(fixture)"}"#,
            // An ID that is not an action, or an action that needs a choice of a menu.
            #"{"op":"action","id":"Stop","session":"\#(fixture)"}"#,
            #"{"op":"action","id":"set-priority","session":"\#(fixture)"}"#,
            #"{"op":"action","id":"open-project","session":"\#(fixture)"}"#,
            #"{"op":"action","id":"watch-colour","session":"\#(fixture)"}"#,
            // An action with an effect outside the test home, or one that only moves the focus.
            #"{"op":"action","id":"copy-id","session":"\#(fixture)"}"#,
            #"{"op":"action","id":"open-in-terminal","session":"\#(fixture)"}"#,
            #"{"op":"action","id":"take-control","session":"\#(fixture)","confirm":true}"#,
            #"{"op":"action","id":"run-slash","session":"\#(fixture)"}"#,
            #"{"op":"action","id":"send-message","session":"\#(fixture)"}"#,
            // A confirm that is not true or false.
            #"{"op":"action","id":"stop","session":"\#(fixture)","confirm":"yes"}"#,
            #"{"op":"action","id":"stop","session":"\#(fixture)","confirm":null}"#,
            // Rename with no name or an empty name, and a name or a folder of another action.
            #"{"op":"action","id":"rename","session":"\#(fixture)"}"#,
            #"{"op":"action","id":"rename","session":"\#(fixture)","name":""}"#,
            #"{"op":"action","id":"stop","session":"\#(fixture)","name":"smoke"}"#,
            #"{"op":"action","id":"rename","session":"\#(fixture)","name":"a","folder":"/a"}"#,
            // A field of another form.
            #"{"op":"action","id":"stop","session":"\#(fixture)","text":"a"}"#,
        ]
        for line in bad {
            #expect(TestPortMessage.request(line) == nil, "\(line)")
        }
    }

    // A global action needs no row, so it has no session. New session takes its folder, and a
    // name or nil for the suggested name. Resume all takes no other field.
    @Test func aGlobalActionRequestHasNoSession() {
        let start = #"{"op":"action","id":"new-session","folder":"/tmp/a"}"#
        #expect(
            TestPortMessage.request(start)
                == .action(TestAction(.global(.newSession), folder: "/tmp/a")))
        let named = #"{"op":"action","id":"new-session","folder":"/tmp/a","name":"n"}"#
        #expect(
            TestPortMessage.request(named)
                == .action(TestAction(.global(.newSession), name: "n", folder: "/tmp/a")))
        #expect(
            TestPortMessage.request(#"{"op":"action","id":"resume-all","confirm":true}"#)
                == .action(TestAction(.global(.resumeAll), confirm: true)))
        let bad = [
            #"{"op":"action","id":"new-session"}"#,
            #"{"op":"action","id":"new-session","folder":""}"#,
            #"{"op":"action","id":"new-session","folder":"/tmp/a","session":"\#(fixture)"}"#,
            #"{"op":"action","id":"resume-all","session":"\#(fixture)"}"#,
            #"{"op":"action","id":"resume-all","folder":"/tmp/a"}"#,
            #"{"op":"action","id":"resume-all","name":"n"}"#,
        ]
        for line in bad {
            #expect(TestPortMessage.request(line) == nil, "\(line)")
        }
    }

    // A send types the text into the session through the session input. The text has at least
    // one character, and the input rules check the rest.
    @Test func aSendRequestNamesASessionAndAText() throws {
        let session = try #require(SessionID(fixture))
        #expect(
            TestPortMessage.request(#"{"op":"send","session":"\#(fixture)","text":"hello"}"#)
                == .send(session, text: "hello"))
        let lines = #"{"text":"héllo\nworld","session":"\#(fixture)","op":"send"}"#
        #expect(TestPortMessage.request(lines) == .send(session, text: "h\u{E9}llo\nworld"))
        let bad = [
            #"{"op":"send","session":"\#(fixture)"}"#,
            #"{"op":"send","session":"\#(fixture)","text":""}"#,
            #"{"op":"send","session":"\#(fixture)","text":1}"#,
            #"{"op":"send","text":"hello"}"#,
            #"{"op":"send","session":"5a0e0001","text":"hello"}"#,
            #"{"op":"send","session":"\#(fixture)","text":"hello","confirm":true}"#,
        ]
        for line in bad {
            #expect(TestPortMessage.request(line) == nil, "\(line)")
        }
    }

    // A line that is not one JSON object, an unknown op, no op and a field that the form does not
    // have are no request.
    @Test func aBadLineIsNoRequest() {
        let lines = [
            "", "state", "{", #"["state"]"#, #""state""#, "{}", #"{"op":1}"#, #"{"op":"stop"}"#,
            #"{"op":"state","panel":"overview:1"}"#, #"{"op":"quit","now":true}"#,
            #"{"op":"type","text":"a","key":"enter"}"#, #"{"op":"state"}{"op":"quit"}"#,
        ]
        for line in lines {
            #expect(TestPortMessage.request(line) == nil, "\(line)")
        }
    }

    // A request is a Decodable value: the op picks the form. A field of another form, or a value
    // of the wrong type, is a decoding error, and no request.
    @Test func aRequestDecodesByItsOp() throws {
        let decoder = JSONDecoder()
        let open = try decoder.decode(
            TestPortRequest.self, from: Data(#"{"op":"open","panel":"overview:1"}"#.utf8))
        #expect(open == .open(try #require(PanelID("overview:1"))))
        let lines = [
            #"{"op":"open","text":"a"}"#, #"{"op":"hold","key":"space","ms":true}"#,
            #"{"op":"bench","plan":"gate","chats":8,"name":"r","list":null}"#,
        ]
        for line in lines {
            #expect(throws: DecodingError.self) {
                try decoder.decode(TestPortRequest.self, from: Data(line.utf8))
            }
        }
    }

    // One line: compact JSON with the keys in order, then a line break.
    @Test func anAnswerIsOneLine() {
        let value: JSONValue = [
            "b": 1, "a": "x/y", "c": ["d": [true, .null, 1.5]], "e": "line\nbreak",
        ]
        #expect(
            TestPortMessage.answer(value)
                == #"{"a":"x/y","b":1,"c":{"d":[true,null,1.5]},"e":"line\nbreak"}"# + "\n")
        #expect(TestPortMessage.answer(.object([:])) == "{}\n")
        // A number that is not finite has no JSON form.
        #expect(TestPortMessage.answer(["x": .double(.nan)]) == #"{"error":"bad answer"}"# + "\n")
        #expect(TestPortMessage.badRequest == #"{"error":"bad request"}"# + "\n")
    }

    // The Event log of the state: the number of entries, and the texts of the newest 5 in the
    // order of the log. A text is the text of its row: the name and the tool, or the notice.
    @Test func theEventsStateGivesTheCountAndTheLastFiveTexts() {
        #expect(TestPortMessage.events([]) == ["count": 0, "last": []])
        let one = LogEntry(seq: 1, at: 10, sessionId: "s1", name: .sessionStart)
        #expect(TestPortMessage.events([one]) == ["count": 1, "last": ["SessionStart"]])
        var entries = (1...6).map { n in
            LogEntry(seq: n, at: n, sessionId: "s1", name: .preToolUse, tool: "Tool\(n)")
        }
        entries.append(
            LogEntry(seq: 7, at: 7, notice: EventLog.notificationRefused))
        #expect(
            TestPortMessage.events(entries) == [
                "count": 7,
                "last": [
                    "PreToolUse (Tool3)", "PreToolUse (Tool4)", "PreToolUse (Tool5)",
                    "PreToolUse (Tool6)", .string(EventLog.notificationRefused),
                ],
            ])
    }

    // The Usage HUD of the state: each bar with its label, percent (null with no data), level
    // and detail, then the source line.
    @Test func theUsageStateGivesTheBarsAndTheSource() {
        let bars = [
            UsageBar(
                label: "5-hour limit", percent: 92, level: .high, detail: "Resets at 14:00"),
            UsageBar(label: "7-day limit", percent: nil, level: .normal, detail: "No data"),
        ]
        #expect(
            TestPortMessage.usage(bars: bars, source: "From your sessions.") == [
                "bars": [
                    [
                        "label": "5-hour limit", "percent": 92, "level": "high",
                        "detail": "Resets at 14:00",
                    ],
                    [
                        "label": "7-day limit", "percent": .null, "level": "normal",
                        "detail": "No data",
                    ],
                ],
                "source": "From your sessions.",
            ])
        #expect(TestPortMessage.usage(bars: [], source: "") == ["bars": [], "source": ""])
    }

    // The rows of a list of the state: the ID and the name of each row, in their order.
    @Test func theRowsStateGivesTheIDAndTheNameOfEachRow() {
        let rows = [
            SessionRow.test(sessionId: "s2", name: "beta"),
            SessionRow.test(sessionId: "s1", name: "alpha"),
        ]
        #expect(
            TestPortMessage.rows(rows) == [
                ["id": "s2", "name": "beta"], ["id": "s1", "name": "alpha"],
            ])
        #expect(TestPortMessage.rows([]) == [])
    }

    // The PR line of Show Info: null while the lookup runs, then the PR, no PR or the reason.
    @Test func thePRStateGivesEachFormOfTheLookup() throws {
        let url = try #require(URL(string: "https://example.invalid/pr/7"))
        #expect(TestPortMessage.pr(nil) == .null)
        #expect(
            TestPortMessage.pr(.pr(number: 7, title: "Fix it", url: url, state: "OPEN")) == [
                "number": 7, "title": "Fix it", "url": "https://example.invalid/pr/7",
                "state": "OPEN",
            ])
        #expect(TestPortMessage.pr(PRInfo.none) == ["none": true])
        #expect(
            TestPortMessage.pr(.unavailable(.failed))
                == ["unavailable": .string("GitHub CLI (gh) couldn't check for a PR.")])
    }

    // The Performance monitor: "checking" before the first level, then the level, and the number
    // of reasons.
    @Test func thePerformanceStateGivesTheLevelAndTheReasonCount() {
        var snapshot = PerformanceSnapshot.checking
        #expect(TestPortMessage.performance(snapshot) == ["level": "checking", "reasons": 0])
        snapshot.level = .warning
        snapshot.reasons = [
            HealthReason(level: .warning, text: "A"), HealthReason(level: .warning, text: "B"),
        ]
        #expect(TestPortMessage.performance(snapshot) == ["level": "warning", "reasons": 2])
        snapshot.level = .ok
        snapshot.reasons = []
        #expect(
            TestPortMessage.answer(TestPortMessage.performance(snapshot))
                == #"{"level":"ok","reasons":0}"# + "\n")
    }
}

// The JSON string form of printable ASCII text: a backslash and a quote get a backslash.
private func jsonEscaped(_ text: String) -> String {
    text.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"")
}
