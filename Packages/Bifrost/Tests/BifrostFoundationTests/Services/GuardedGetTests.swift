// The shared rules of the network reads (GuardedGet). Safety: each session of these tests has the
// stub below as its first protocol, so no request reaches the network, and the sandbox of the
// tests refuses each outbound connection.
import Foundation
import Synchronization
import Testing

@testable import BifrostFoundation

private let pageURL = URL(string: "https://example.invalid/data") ?? URL(filePath: "/")
private let otherURL = "https://example.invalid/other"

private enum StubAnswer: Sendable {
    case answer(status: Int, headers: [String: String], body: Data)
    case redirect(to: String)
    case failure
    // No answer at all, so the request waits until its time limit.
    case silent
}

private struct SeenRequest: Sendable {
    var url: String
    var method: String?
    var headers: [String: String]
    var timeout: TimeInterval
    var handlesCookies: Bool
}

// The stub of the URL loading system. Its state is shared, so the suite runs its tests one at a
// time.
private final class StubProtocol: URLProtocol {
    private struct State {
        var answer = StubAnswer.answer(status: 200, headers: [:], body: Data())
        var seen: [SeenRequest] = []
    }

    private static let state = Mutex(State())

    static func reset(_ answer: StubAnswer) { state.withLock { $0 = State(answer: answer) } }
    static var seen: [SeenRequest] { state.withLock { $0.seen } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        let seen = SeenRequest(
            url: url.absoluteString, method: request.httpMethod,
            headers: request.allHTTPHeaderFields ?? [:], timeout: request.timeoutInterval,
            handlesCookies: request.httpShouldHandleCookies)
        let answer = Self.state.withLock { s in
            s.seen.append(seen)
            return s.answer
        }
        guard url == pageURL else {
            send(status: 200, headers: [:], body: Data("other".utf8), url: url, to: client)
            return
        }
        switch answer {
        case .answer(let status, let headers, let body):
            send(status: status, headers: headers, body: body, url: url, to: client)
        case .redirect(let target):
            guard let targetURL = URL(string: target),
                let response = HTTPURLResponse(
                    url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                    headerFields: ["Location": target])
            else { return }
            client.urlProtocol(
                self, wasRedirectedTo: URLRequest(url: targetURL), redirectResponse: response)
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocolDidFinishLoading(self)
        case .failure:
            client.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case .silent:
            break
        }
    }

    override func stopLoading() {}

    private func send(
        status: Int, headers: [String: String], body: Data, url: URL,
        to client: any URLProtocolClient
    ) {
        guard
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
        else { return }
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: body)
        client.urlProtocolDidFinishLoading(self)
    }
}

private func stubbed() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    return configuration
}

private let cap = 1000

private func get(
    _ answer: StubAnswer, headers: [String: String] = [:], timeout: Duration = .seconds(5)
) async -> GuardedGet.Answer? {
    StubProtocol.reset(answer)
    return await GuardedGet(configuration: stubbed).get(
        pageURL, headers: headers, timeout: timeout, maxBytes: cap)
}

@Suite("guarded get", .serialized)
struct GuardedGetTests {
    @Test func aGoodAnswerComesBackWithItsStatus() async {
        let body = Data("{}".utf8)
        let answer = await get(.answer(status: 200, headers: [:], body: body))
        #expect(answer == GuardedGet.Answer(status: 200, body: body, tooLarge: false))
        #expect(answer?.isSuccess == true)
    }

    @Test func aStatusThatIsNot2xxComesBackAsNoSuccess() async {
        let answer = await get(.answer(status: 404, headers: [:], body: Data("x".utf8)))
        #expect(answer?.status == 404)
        #expect(answer?.isSuccess == false)
    }

    @Test func aRedirectIsRefused() async {
        let answer = await get(.redirect(to: otherURL))
        #expect(answer?.isSuccess != true)
        // The helper never asks the second URL.
        #expect(StubProtocol.seen.map(\.url) == [pageURL.absoluteString])
    }

    @Test func aFetchErrorIsNoAnswer() async {
        #expect(await get(.failure) == nil)
    }

    // A failed read of the body gives no body, so the caller keeps the status it already has. The
    // stream stands in for the bytes of a response that fails after its headers.
    @Test func aFailedReadOfTheBodyGivesNoBody() async {
        let failing = AsyncThrowingStream<UInt8, any Error> { continuation in
            continuation.yield(UInt8(ascii: "{"))
            continuation.finish(throwing: URLError(.networkConnectionLost))
        }
        #expect(await GuardedGet.read(failing, maxBytes: cap) == nil)
        let good = AsyncThrowingStream<UInt8, any Error> { continuation in
            continuation.yield(UInt8(ascii: "a"))
            continuation.yield(UInt8(ascii: "b"))
            continuation.finish()
        }
        #expect(await GuardedGet.read(good, maxBytes: cap) == Data("ab".utf8))
    }

    @Test func theBodyIsReadUpToOneByteOverTheCap() async {
        let atCap = Data(repeating: UInt8(ascii: "a"), count: cap)
        let first = await get(.answer(status: 200, headers: [:], body: atCap))
        #expect(first?.body?.count == cap)
        #expect(first?.tooLarge == false)
        let over = Data(repeating: UInt8(ascii: "a"), count: cap * 3)
        let second = await get(.answer(status: 200, headers: [:], body: over))
        #expect(second?.body?.count == cap + 1)
        #expect(second?.tooLarge == true)
    }

    @Test func aLengthOverTheCapInTheHeaderStopsTheRead() async {
        let header = ["Content-Length": "\(cap + 1)"]
        let answer = await get(.answer(status: 200, headers: header, body: Data("{}".utf8)))
        #expect(answer?.tooLarge == true)
        #expect(answer?.body?.isEmpty == true)
    }

    // The configuration of the test has one cookie store that accepts each cookie and holds a
    // cookie of the host. A stub protocol gets no cookie from a store, so the test checks that the
    // helper takes the store and the cookie rules out of that configuration, and that each request
    // sends no cookie, also after an answer that sets one.
    @Test func noCookieIsSentOrKept() async throws {
        let storage = HTTPCookieStorage()
        storage.cookieAcceptPolicy = .always
        let cookie = try #require(
            HTTPCookie(properties: [
                .domain: "example.invalid", .path: "/", .name: "session",
                .value: "fake-cookie", .secure: "TRUE",
            ]))
        storage.setCookie(cookie)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        configuration.httpCookieStorage = storage
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        let headers = ["Set-Cookie": "other=fake-cookie-2; Path=/; Secure"]
        StubProtocol.reset(.answer(status: 200, headers: headers, body: Data("{}".utf8)))
        let helper = GuardedGet { configuration }
        for _ in 0..<2 {
            _ = await helper.get(pageURL, headers: [:], timeout: .seconds(5), maxBytes: cap)
        }
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.urlCache == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(StubProtocol.seen.count == 2)
        #expect(StubProtocol.seen.allSatisfy { $0.headers["Cookie"] == nil && !$0.handlesCookies })
    }

    @Test func theTimeLimitHoldsForTheWholeRequest() async {
        let configuration = stubbed()
        StubProtocol.reset(.answer(status: 200, headers: [:], body: Data("{}".utf8)))
        _ = await GuardedGet { configuration }.get(
            pageURL, headers: [:], timeout: .seconds(7), maxBytes: cap)
        #expect(StubProtocol.seen.map(\.timeout) == [7])
        #expect(configuration.timeoutIntervalForRequest == 7)
        #expect(configuration.timeoutIntervalForResource == 7)
    }

    @Test func theRequestIsAGetWithTheHeadersAndNothingElse() async throws {
        _ = await get(
            .answer(status: 200, headers: [:], body: Data("{}".utf8)),
            headers: ["Accept": "application/json", "X-Test": "1"])
        let seen = try #require(StubProtocol.seen.first)
        #expect(seen.method == "GET")
        #expect(seen.headers["Accept"] == "application/json")
        #expect(seen.headers["X-Test"] == "1")
        #expect(seen.headers["User-Agent"] == "Bifrost")
        #expect(seen.headers["Authorization"] == nil)
        #expect(seen.headers["Cookie"] == nil)
    }

    @Test func aHeadRequestGivesTheStatusOfEachAnswer() async throws {
        StubProtocol.reset(.answer(status: 404, headers: [:], body: Data("x".utf8)))
        let answer = await GuardedGet(configuration: stubbed).head(pageURL, timeout: .seconds(5))
        #expect(answer == .status(404))
        let seen = try #require(StubProtocol.seen.first)
        #expect(seen.method == "HEAD")
        #expect(seen.headers["User-Agent"] == "Bifrost")
        #expect(seen.headers["Authorization"] == nil)
        #expect(seen.headers["Cookie"] == nil)
    }

    @Test func aHeadRequestRefusesARedirect() async {
        StubProtocol.reset(.redirect(to: otherURL))
        let answer = await GuardedGet(configuration: stubbed).head(pageURL, timeout: .seconds(5))
        #expect(answer == .status(302))
        #expect(StubProtocol.seen.map(\.url) == [pageURL.absoluteString])
    }

    @Test func aHeadRequestTellsATimeoutFromAFailure() async {
        StubProtocol.reset(.failure)
        let helper = GuardedGet(configuration: stubbed)
        #expect(await helper.head(pageURL, timeout: .seconds(5)) == .failed)
        StubProtocol.reset(.silent)
        #expect(await helper.head(pageURL, timeout: .milliseconds(200)) == .timedOut)
    }
}
