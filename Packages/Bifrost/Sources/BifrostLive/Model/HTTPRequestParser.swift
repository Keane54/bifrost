// The parser of the one HTTP request that the Live details mod sends on a connection: POST
// /v1/event with a Content-Length and a JSON body. The parser refuses each other form
// (docs/behaviour/live.md, "The HTTP rules").
//
// - Each line of the head ends with CR LF. A bare LF or a bare CR is bad at once.
// - The head (the request line, the header lines and the empty line) has at most headLimit
//   bytes, or it is bad.
// - The request line is METHOD SP target SP HTTP/1.1. A header line is name ":" value. The name
//   is printable ASCII with no space, and it compares with no case.
// - Content-Length is ASCII digits in one line, with spaces or tabs at its ends. With no
//   Content-Length the body is empty. A Transfer-Encoding line is bad: the mod sends no chunks.
// - At the end of the head the checks have this order: the framing (bad), the Host line of
//   HTTP/1.1 (noHost), the method and the target (notFound), then the size (tooLarge). These
//   results come before the body.
//
// After the first result that is not needMore, each later feed gives the same result. The bytes
// after the body are not read: the server takes one request for each connection.

package enum HTTPParse: Sendable, Equatable {
    // The request is not complete.
    case needMore
    // The body of POST /v1/event.
    case event([UInt8])
    case refused(HTTPRefusal)
}

// Why the parser refuses a request.
package enum HTTPRefusal: Error, Equatable {
    // A form that the mod does not send.
    case bad
    // A request with no Host line. The answer is 400 (docs/behaviour/live.md, The HTTP rules).
    case noHost
    // Another method or target.
    case notFound
    // A Content-Length over bodyLimit.
    case tooLarge
}

package struct HTTPRequestParser: Sendable {
    package static let headLimit = 16_384
    package static let bodyLimit = 65_536

    private var buffer: [UInt8] = []
    // The bytes of the head that the check of the line ends saw.
    private var scanned = 0
    // The place of the body in the buffer, from the end of the head.
    private var body: Range<Int>?
    private var result: HTTPParse?

    package init() {}

    // Add the bytes that came, and give the result: needMore until the request is complete.
    package mutating func feed(_ bytes: [UInt8]) -> HTTPParse {
        if let result { return result }
        buffer.append(contentsOf: bytes)
        let next: HTTPParse
        do throws(HTTPRefusal) {
            guard let body = try parse() else { return .needMore }
            next = .event(body)
        } catch {
            next = .refused(error)
        }
        result = next
        buffer = []
        return next
    }

    // The body when the request is complete, else nil.
    private mutating func parse() throws(HTTPRefusal) -> [UInt8]? {
        while body == nil, scanned < buffer.count {
            let byte = buffer[scanned]
            // A CR comes before each LF, and an LF comes after each CR.
            let afterCarriageReturn = scanned > 0 && buffer[scanned - 1] == carriageReturn
            guard afterCarriageReturn == (byte == lineFeed) else { throw .bad }
            scanned += 1
            guard scanned <= Self.headLimit else { throw .bad }
            if byte == lineFeed, buffer[..<scanned].suffix(4).elementsEqual(endOfHead) {
                let length = try Self.bodyLength(head: buffer[..<(scanned - 4)])
                body = scanned..<(scanned + length)
            }
        }
        guard let body, body.upperBound <= buffer.count else { return nil }
        return Array(buffer[body])
    }

    // The checks at the end of the head, with no line end in the head. The result is the length
    // of the body.
    private static func bodyLength(head: ArraySlice<UInt8>) throws(HTTPRefusal) -> Int {
        let lines = head.split(separator: lineEnd, omittingEmptySubsequences: false)
        let parts = lines[0].split(separator: space, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2].elementsEqual("HTTP/1.1".utf8) else { throw .bad }
        var lengths: [ArraySlice<UInt8>] = []
        var hasHost = false
        for line in lines.dropFirst() {
            guard let mark = line.firstIndex(of: colon) else { throw .bad }
            let name = line[..<mark]
            guard !name.isEmpty, name.allSatisfy({ (0x21...0x7E).contains($0) }) else {
                throw .bad
            }
            switch String(decoding: name, as: UTF8.self).lowercased() {
            case "content-length": lengths.append(line[(mark + 1)...])
            case "transfer-encoding": throw .bad
            case "host": hasHost = true
            default: break
            }
        }
        guard lengths.count <= 1 else { throw .bad }
        var length = 0
        if let value = lengths.first { length = try decimal(value) }
        guard hasHost else { throw .noHost }
        guard parts[0].elementsEqual("POST".utf8), parts[1].elementsEqual("/v1/event".utf8) else {
            throw .notFound
        }
        guard length <= bodyLimit else { throw .tooLarge }
        return length
    }

    // The value of ASCII digits with spaces or tabs at their ends. A value over bodyLimit gives
    // bodyLimit + 1, so a long number cannot overflow.
    private static func decimal(_ value: ArraySlice<UInt8>) throws(HTTPRefusal) -> Int {
        let isBlank = { (byte: UInt8) in byte == space || byte == tab }
        guard let first = value.firstIndex(where: { !isBlank($0) }),
            let last = value.lastIndex(where: { !isBlank($0) })
        else { throw .bad }
        var result = 0
        for byte in value[first...last] {
            guard (zero...nine).contains(byte) else { throw .bad }
            result = min(result * 10 + Int(byte - zero), bodyLimit + 1)
        }
        return result
    }
}

private let lineFeed = UInt8(ascii: "\n")
private let carriageReturn = UInt8(ascii: "\r")
private let lineEnd = [carriageReturn, lineFeed]
private let endOfHead = lineEnd + lineEnd
private let space = UInt8(ascii: " ")
private let tab = UInt8(ascii: "\t")
private let colon = UInt8(ascii: ":")
private let zero = UInt8(ascii: "0")
private let nine = UInt8(ascii: "9")
