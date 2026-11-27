import Foundation
import Testing

@testable import BifrostModuleHostCore

// The lines between the module host and its parent. The parent parses them as JSON, but the hello
// is pinned byte for byte anyway, so a change to its shape can't slip through.

private func decode(_ text: String) throws -> HostMessage {
    try JSONDecoder().decode(HostMessage.self, from: Data(text.utf8))
}

private func line(_ reply: HostReply) throws -> String {
    String(decoding: try reply.encoded(), as: UTF8.self)
}

@Suite("Host protocol")
struct HostProtocolTests {
    @Test func aCodeLineDecodes() throws {
        #expect(try decode(#"{"type":"code","source":"x"}"#) == .code("x"))
    }

    // An event's value is any JSON, null included.
    @Test func aPingAndAnEventDecode() throws {
        #expect(try decode(#"{"type":"ping","id":7}"#) == .ping(7))
        let event = try decode(
            #"{"type":"event","handler":3,"value":{"text":"abc","list":[true,null,1.5]}}"#)
        let value: JSONValue = .object([
            "text": .string("abc"), "list": .array([.bool(true), .null, .number(1.5)]),
        ])
        #expect(event == .event(handler: 3, value: value))
        #expect(try decode(#"{"type":"event","handler":4,"value":null}"#)
            == .event(handler: 4, value: .null))
    }

    // A line with a type the host doesn't know, or with no type at all, is refused rather than
    // skipped, so a parent that speaks another version finds out on its first line.
    @Test func anUnknownTypeIsRefused() {
        for text in [#"{"type":"eval","source":"x"}"#, #"{"source":"x"}"#] {
            #expect(throws: DecodingError.self) { try decode(text) }
        }
    }

    @Test func theHelloLineIsExact() throws {
        let result = SelfTestResult(fds: .closed, read: .denied, socket: .denied, spawn: .denied)
        let expected =
            #"{"protocol":0,"selfTest":{"fds":"closed","read":"denied","socket":"denied","#
            + #""spawn":"denied"},"type":"hello"}"#
        #expect(try line(.hello(result)) == expected)
    }

    // A whole number goes out without a fraction, and a newline in a log stays escaped, so every
    // reply is one line.
    @Test func theOtherRepliesKeepTheirShapes() throws {
        let op: JSONValue = .array([.string("create"), .number(1), .string("Text"), .object([:])])
        #expect(try line(.batch([op])) == #"{"ops":[["create",1,"Text",{}]],"type":"batch"}"#)
        #expect(try line(.pong(12)) == #"{"id":12,"type":"pong"}"#)
        #expect(try line(.log("a \"b\"\nc")) == #"{"text":"a \"b\"\nc","type":"log"}"#)
    }
}
