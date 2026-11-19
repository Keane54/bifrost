import BifrostFoundation
import Testing

// The token mask (docs/behaviour/panels.md, The token mask). Each token of a test is a fake that
// the test makes from a known start and repeated characters. No test holds a real token.

private func fake(_ start: String, _ count: Int, _ character: Character = "A") -> String {
    start + String(repeating: character, count: count)
}

// One fake token of each known form, at the shortest length of its form.
private let knownForms = [
    fake("ghp_", 20), fake("gho_", 24, "b"), fake("ghs_", 30, "7"), fake("ghu_", 20, "z"),
    fake("github_pat_", 20, "B"), fake("github_pat_", 40, "_"), fake("sk-ant-", 20, "a"),
    fake("sk-ant-api03-", 40, "x"), fake("sk-ant-oat01-", 40, "-"), fake("AKIA", 16),
    fake("AKIA", 16, "7"), fake("xoxb-", 10, "1"), fake("xoxa-", 12, "-"), fake("xoxp-", 20, "q"),
    fake("xoxr-", 10, "Z"),
]

@Suite("token mask")
struct TokenMaskTests {
    @Test(arguments: knownForms)
    func eachKnownFormOfATokenIsHidden(_ token: String) {
        #expect(TokenMask.mask("bad \(token) end", token: nil) == "bad *** end")
        #expect(TokenMask.mask(token, token: nil) == "***")
    }

    @Test func aTokenThatIsTooShortForItsFormStays() {
        let short = [
            fake("ghp_", 19), fake("github_pat_", 19), fake("sk-ant-", 19), fake("AKIA", 15),
            fake("xoxb-", 9, "1"), fake("ghx_", 30), fake("xoxz-", 20, "1"),
        ]
        for text in short { #expect(TokenMask.mask(text, token: nil) == text) }
    }

    // The forms end at the first character that they do not allow.
    @Test func aTokenNextToOtherTextIsHiddenAndTheTextStays() {
        let token = fake("ghp_", 24)
        #expect(TokenMask.mask("x\(token)-y", token: nil) == "x***-y")
        #expect(TokenMask.mask("(\(token)),\(token).", token: nil) == "(***),***.")
        // An AWS key ID has exactly 16 characters after AKIA, so a 17th stays.
        #expect(TokenMask.mask(fake("AKIA", 17), token: nil) == "***A")
    }

    @Test func theKnownTokenIsHiddenEachTime() {
        #expect(TokenMask.mask("a tok-1 b tok-1", token: "tok-1") == "a *** b ***")
        // The token is plain text, not a pattern.
        #expect(TokenMask.mask("xa.b*cx axbbc", token: "a.b*c") == "x***x axbbc")
        #expect(TokenMask.mask("abc", token: "") == "abc")
        #expect(TokenMask.mask("abc", token: nil) == "abc")
    }

    @Test func theKnownTokenAndTheKnownFormsAreBothHidden() {
        let text = "one \(fake("ghp_", 24)) two secret-value"
        #expect(TokenMask.mask(text, token: "secret-value") == "one *** two ***")
    }

    // The word stays, so the text keeps its sense.
    @Test func theValueOfABearerHeaderIsHiddenAndTheWordStays() {
        let value = fake("abc.DEF-ghi_jkl~", 8, "m")
        #expect(
            TokenMask.mask("Authorization: Bearer \(value)", token: nil)
                == "Authorization: Bearer ***")
        #expect(TokenMask.mask("bearer  \(value)== end", token: nil) == "bearer  *** end")
        #expect(TokenMask.mask("BEARER \(fake("a+b/", 12))", token: nil) == "BEARER ***")
        // A value of fewer than 16 characters is not a token.
        let short = "Bearer " + fake("", 15, "a")
        #expect(TokenMask.mask(short, token: nil) == short)
    }

    @Test func aTextWithNoSecretStaysTheSame() {
        let texts = [
            "", "Stop", "PostToolUse (mcp__github__create_pull_request)",
            "macOS didn't show a notification.", "ghp_ AKIA xoxb- sk-ant- Bearer",
        ]
        for text in texts { #expect(TokenMask.mask(text, token: nil) == text) }
    }

    // The mask reads Unicode scalars, so a combining mark after a token does not join the last
    // character of the token into one Character that the form does not allow.
    @Test func aCombiningMarkAfterATokenDoesNotStopTheMask() {
        let token = fake("ghp_", 24)
        #expect(TokenMask.mask("\(token)\u{301} end", token: nil) == "***\u{301} end")
        #expect(TokenMask.mask("x tok\u{301}", token: "tok") == "x ***\u{301}")
    }
}
