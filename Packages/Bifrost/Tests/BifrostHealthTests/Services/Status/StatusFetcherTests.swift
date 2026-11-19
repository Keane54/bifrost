// The request of a status page (docs/behaviour/health.md, "Service status"). Safety: each session
// of these tests has the stub below as its first protocol, so no request reaches the network, and
// the sandbox of the tests refuses each outbound connection.
import Foundation
import Synchronization
import Testing

@testable import BifrostHealth

private let pageURL = URL(string: "https://status.example.com/api/v2/status.json")!
private let otherURL = "https://example.com/other"

private enum StubAnswer: Sendable {
    case answer(status: Int, headers: [String: String], body: Data)
    // A redirect to the URL, with status 302.
    case redirect(to: String)
    // The request fails before an answer.
    case failure
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

private func stubbedConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    return configuration
}

private func fetch(_ answer: StubAnswer) async -> Data? {
    StubProtocol.reset(answer)
    return await SessionStatusFetcher(configuration: stubbedConfiguration).fetch(pageURL)
}

@Suite("status fetcher", .serialized)
struct StatusFetcherTests {
    @Test func aGoodAnswerComesBack() async {
        let body = Data("{\"status\":{}}".utf8)
        #expect(await fetch(.answer(status: 200, headers: [:], body: body)) == body)
    }

    @Test func aRedirectIsRefused() async {
        #expect(await fetch(.redirect(to: otherURL)) == nil)
        // The fetcher never asks the second URL.
        #expect(StubProtocol.seen.map(\.url) == [pageURL.absoluteString])
    }

    @Test(arguments: [404, 429, 500, 503])
    func aStatusThatIsNot2xxIsNoAnswer(status: Int) async {
        #expect(await fetch(.answer(status: status, headers: [:], body: Data("{}".utf8))) == nil)
    }

    @Test func aFetchErrorIsNoAnswer() async {
        #expect(await fetch(.failure) == nil)
    }

    @Test func aBodyOverTheCapIsNoAnswer() async {
        let cap = StatusPage.maxBytes
        // The cap itself is an answer. One byte over is not.
        let atCap = Data(repeating: UInt8(ascii: "a"), count: cap)
        #expect(await fetch(.answer(status: 200, headers: [:], body: atCap))?.count == cap)
        let over = Data(repeating: UInt8(ascii: "a"), count: cap + 1)
        #expect(await fetch(.answer(status: 200, headers: [:], body: over)) == nil)
        // A length over the cap in the header stops the read before it starts.
        let header = ["Content-Length": "\(cap + 1)"]
        #expect(await fetch(.answer(status: 200, headers: header, body: Data("{}".utf8))) == nil)
    }

    // The configuration of the test has one cookie store that accepts each cookie and holds a
    // cookie of the status host. A stub protocol gets no cookie from a store, so the test checks
    // that the fetcher takes the store and the cookie rules out of that configuration, and that
    // each request sends no cookie, also after an answer that sets one.
    @Test func noCookieIsSentOrKept() async throws {
        let storage = HTTPCookieStorage()
        storage.cookieAcceptPolicy = .always
        let cookie = try #require(
            HTTPCookie(properties: [
                .domain: "status.example.com", .path: "/", .name: "session",
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
        let fetcher = SessionStatusFetcher { configuration }
        _ = await fetcher.fetch(pageURL)
        _ = await fetcher.fetch(pageURL)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.urlCache == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(StubProtocol.seen.count == 2)
        #expect(StubProtocol.seen.allSatisfy { $0.headers["Cookie"] == nil && !$0.handlesCookies })
    }

    @Test func eachRequestHasTheFiveSecondLimit() async {
        let configuration = stubbedConfiguration()
        StubProtocol.reset(.answer(status: 200, headers: [:], body: Data("{}".utf8)))
        _ = await SessionStatusFetcher { configuration }.fetch(pageURL)
        #expect(StubProtocol.seen.map(\.timeout) == [5])
        // The limit holds for the whole read too.
        #expect(configuration.timeoutIntervalForRequest == 5)
        #expect(configuration.timeoutIntervalForResource == 5)
    }

    @Test func aRequestCarriesNoTokenAndNoUserData() async throws {
        _ = await fetch(.answer(status: 200, headers: [:], body: Data("{}".utf8)))
        let seen = try #require(StubProtocol.seen.first)
        #expect(seen.method == "GET")
        #expect(seen.headers["Accept"] == "application/json")
        #expect(seen.headers["Authorization"] == nil)
        #expect(seen.headers["Cookie"] == nil)
    }
}
