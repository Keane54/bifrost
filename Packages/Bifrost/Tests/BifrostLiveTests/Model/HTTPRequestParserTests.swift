import BifrostLive
import Testing

// The parser of the one request that the Live details mod sends on a connection: POST /v1/event
// with a Content-Length and a JSON body. The parser refuses each other form.

private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

// The result of one feed of all the bytes.
private func parse(_ text: String) -> HTTPParse {
    var parser = HTTPRequestParser()
    return parser.feed(bytes(text))
}

// The results of a feed of each byte alone.
private func parseByteByByte(_ text: String) -> [HTTPParse] {
    var parser = HTTPRequestParser()
    return bytes(text).map { parser.feed([$0]) }
}

private func event(_ body: String) -> HTTPParse { .event(bytes(body)) }

private let line = #"{"v":1,"kind":"turn.start"}"#
private let head = "POST /v1/event HTTP/1.1\r\nHost: bifrost\r\n"
// The request of the mod: a fetch with a Content-Type and a Content-Length.
private let modRequest =
    head + "Content-Type: application/json\r\nContent-Length: 27\r\n\r\n" + line

@Suite("HTTP request parser")
struct HTTPRequestParserTests {
    @Test func theRequestOfTheModGivesItsBody() {
        #expect(parse(modRequest) == event(line))
        let results = parseByteByByte(modRequest)
        #expect(results.dropLast().allSatisfy { $0 == .needMore })
        #expect(results.last == event(line))
    }

    // The names compare with no case. The spaces and tabs at the ends of a value go. The parser
    // reads no other header value.
    @Test func headerNamesHaveNoCaseAndValuesLoseTheirBlanks() {
        let text = "POST /v1/event HTTP/1.1\r\nhOsT:\r\nCONTENT-LENGTH: \t2 \t\r\n"
            + "X-A: é\u{1}\u{7F}\r\n\r\nhi"
        #expect(parse(text) == event("hi"))
    }

    // The bytes after the body are not read: one request for each connection.
    @Test func noContentLengthGivesAnEmptyBody() {
        #expect(parse(head + "\r\n") == event(""))
        #expect(parse(head + "\r\n" + line) == event(""))
        #expect(parse(head + "Content-Length: 2\r\n\r\nhi and more") == event("hi"))
    }

    @Test func anIncompleteRequestNeedsMore() {
        #expect(parse(head) == .needMore)
        #expect(parse(head + "\r") == .needMore)
        #expect(parse(head + "Content-Length: 27\r\n\r\n" + line.dropLast()) == .needMore)
    }

    // The server answers 404 at the end of the head. The parser does not wait for the body, and
    // the size of the body does not matter.
    @Test(arguments: [
        "GET /v1/event HTTP/1.1\r\nHost: b\r\nContent-Length: 500\r\n\r\n",
        "POST /other HTTP/1.1\r\nHost: b\r\nContent-Length: 70000\r\n\r\n",
        "post /v1/event HTTP/1.1\r\nHost: b\r\n\r\n",
        "POST /v1/event?x=1 HTTP/1.1\r\nHost: b\r\n\r\n",
        " /v1/event HTTP/1.1\r\nHost: b\r\n\r\n",
    ])
    func anotherMethodOrTargetIsNotFoundAtTheEndOfTheHead(request: String) {
        #expect(parse(request) == .refused(.notFound))
    }

    // The head alone gives the result. The parser does not wait for the body.
    @Test func aContentLengthOverTheLimitIsTooLarge() {
        #expect(HTTPRequestParser.bodyLimit == 65_536)
        #expect(parse(head + "Content-Length: 65537\r\n\r\n") == .refused(.tooLarge))
        let huge = head + "Content-Length: 99999999999999999999999\r\n\r\n"
        #expect(parse(huge) == .refused(.tooLarge))
        #expect(parse(head + "Content-Length: 65536\r\n\r\n") == .needMore)
        let full = String(repeating: "x", count: 65_536)
        #expect(parse(head + "Content-Length: 65536\r\n\r\n" + full) == event(full))
    }

    // Node answers 400 to an HTTP/1.1 request with no Host line. A Host line with an
    // empty value is a Host line.
    @Test func aRequestWithNoHostLineIsRefused() {
        #expect(parse("POST /v1/event HTTP/1.1\r\nContent-Length: 2\r\n\r\n") == .refused(.noHost))
        #expect(parse("GET /other HTTP/1.1\r\n\r\n") == .refused(.noHost))
        #expect(parse("POST /v1/event HTTP/1.1\r\nHost:\r\n\r\n") == event(""))
    }

    // At the end of the head: the framing, then the Host line, then the method and the target,
    // then the size.
    @Test func theChecksAtTheEndOfTheHeadHaveAnOrder() {
        #expect(parse("GET /x HTTP/1.1\r\nContent-Length: 2a\r\n\r\n") == .refused(.bad))
        #expect(parse("GET /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n") == .refused(.bad))
        #expect(parse("GET /x HTTP/1.1\r\nContent-Length: 70000\r\n\r\n") == .refused(.noHost))
        let other = "GET /x HTTP/1.1\r\nHost: b\r\nContent-Length: 70000\r\n\r\n"
        #expect(parse(other) == .refused(.notFound))
    }

    @Test(arguments: [
        // A bare LF or a bare CR.
        "POST /v1/event HTTP/1.1\nHost: b\n\n",
        head + "X-A: b\nContent-Length: 0\r\n\r\n",
        "POST /v1/event HTTP/1.1\rHost: b\r\n\r\n",
        head + "X-A: b\r\r\n\r\n",
        // An empty line before the request line.
        "\r\n" + head + "\r\n",
        // A request line that the mod does not send.
        "POST  /v1/event HTTP/1.1\r\nHost: b\r\n\r\n",
        "POST /v1/event  HTTP/1.1\r\nHost: b\r\n\r\n",
        "POST /v1/event HTTP/1.1 \r\nHost: b\r\n\r\n",
        "POST\t/v1/event HTTP/1.1\r\nHost: b\r\n\r\n",
        "POST /v1/event\r\nHost: b\r\n\r\n",
        "POST /v1/event HTTP/1.0\r\nHost: b\r\n\r\n",
        "POST /v1/event HTTP/2.0\r\nHost: b\r\n\r\n",
        "POST /v1/event http/1.1\r\nHost: b\r\n\r\n",
        // A header line that is not name ":" value.
        head + "X-A\r\n\r\n",
        head + ": x\r\n\r\n",
        head + "X A: b\r\n\r\n",
        head + "Content-Length : 2\r\n\r\nhi",
        head + "X-A: a\r\n b\r\n\r\n",
        // Two Content-Length lines, also with the same value.
        head + "Content-Length: 2\r\nContent-Length: 3\r\n\r\nabc",
        head + "Content-Length: 2\r\ncontent-length: 2\r\n\r\nhi",
        // A transfer coding: the mod sends no chunks.
        head + "Transfer-Encoding: chunked\r\n\r\n2\r\nhi\r\n0\r\n\r\n",
        head + "Content-Length: 2\r\nTransfer-Encoding: chunked\r\n\r\nhi",
    ])
    func aFormThatTheModDoesNotSendIsBad(request: String) {
        #expect(parse(request) == .refused(.bad))
        #expect(parseByteByByte(request).last == .refused(.bad))
    }

    @Test(arguments: ["+2", "2, 2", "", "0x2", "2a", "-2", "２", "2 2"])
    func aContentLengthMustBeDigits(value: String) {
        #expect(parse(head + "Content-Length: \(value)\r\n\r\nhi") == .refused(.bad))
    }

    // The parser does not wait for more bytes after a bad line end.
    @Test func aBadLineEndIsBadAtOnce() {
        #expect(parse("POST / HTTP/1.1\n") == .refused(.bad))
        #expect(parse("POST / HTTP/1.1\r\r") == .refused(.bad))
        #expect(parse("\n") == .refused(.bad))
    }

    // A head of exactly 16,384 bytes is good. One more byte is bad. A head with no end is bad
    // when it has more than 16,384 bytes.
    @Test func aHeadOverTheLimitIsBad() {
        #expect(HTTPRequestParser.headLimit == 16_384)
        let start = head + "X-Pad: "
        let end = "\r\nContent-Length: 0\r\n\r\n"
        let pad = 16_384 - start.utf8.count - end.utf8.count
        let fits = start + String(repeating: "a", count: pad) + end
        #expect(fits.utf8.count == 16_384)
        #expect(parse(fits) == event(""))
        #expect(parseByteByByte(fits).last == event(""))
        let over = start + String(repeating: "a", count: pad + 1) + end
        #expect(parse(over) == .refused(.bad))
        #expect(parseByteByByte(over).last == .refused(.bad))
        let open = start + String(repeating: "a", count: 16_384 - start.utf8.count)
        #expect(parse(open) == .needMore)
        #expect(parse(open + "a") == .refused(.bad))
    }

    @Test func theResultStaysAfterTheEnd() {
        var parser = HTTPRequestParser()
        #expect(parser.feed(bytes(head + "Content-Length: 2\r\n\r\nhi")) == event("hi"))
        #expect(parser.feed(bytes("GET / HTTP/1.1\r\n\r\n")) == event("hi"))
        var bad = HTTPRequestParser()
        #expect(bad.feed(bytes("POST / HTTP/1.1\n")) == .refused(.bad))
        #expect(bad.feed(bytes("Host: b\r\n\r\n")) == .refused(.bad))
    }
}
