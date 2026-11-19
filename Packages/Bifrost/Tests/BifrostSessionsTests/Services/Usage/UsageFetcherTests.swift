// The request of the account usage (docs/behaviour/usage.md, "The account values"). Safety: each
// session of these tests has the stub below as its first protocol, so no request reaches the
// network, and the sandbox of the tests refuses each outbound connection. Each token is fake.
import BifrostSessions
import Foundation
import Synchronization
import Testing

private let fakeToken = "fake-access-token-for-tests"
private let usageURL = "https://api.anthropic.com/api/oauth/usage"
private let otherURL = "https://example.com/other"

// What the stub does with a request to the usage URL. A request to each other URL gets 200 and
// the body "other".
private enum StubAnswer: Sendable {
    case answer(status: Int, headers: [String: String], body: Data)
    // A redirect to the URL, with status 302.
    case redirect(to: String)
    // The request fails before an answer.
    case failure
}

// A request that the stub saw. The stub of a test may keep the fake token.
private struct SeenRequest: Sendable {
    var url: String
    var method: String?
    var headers: [String: String]
    var timeout: TimeInterval
    // True when the request lets the loading system add the cookies of a store.
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

    static func reset(_ answer: StubAnswer) {
        state.withLock { $0 = State(answer: answer) }
    }

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
        guard url.absoluteString == usageURL else {
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

// The fetcher with the stub as the first protocol of an ephemeral session.
private func stubbedFetcher() -> SessionUsageFetcher {
    SessionUsageFetcher {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return configuration
    }
}

private func fetch(_ answer: StubAnswer) async -> UsageResponse? {
    StubProtocol.reset(answer)
    return await stubbedFetcher().fetch(token: fakeToken, timeout: .seconds(10))
}

@Suite("usage fetcher", .serialized)
struct UsageFetcherTests {
    @Test func theTokenGoesOnlyToTheUsageURL() async throws {
        let body = Data("{\"five_hour\":null}".utf8)
        let response = await fetch(.answer(status: 200, headers: [:], body: body))
        #expect(response == UsageResponse(status: 200, body: body))
        let seen = StubProtocol.seen
        try #require(seen.count == 1)
        #expect(seen[0].url == usageURL)
        #expect(seen[0].method == "GET")
        #expect(seen[0].headers["Authorization"] == "Bearer \(fakeToken)")
        #expect(seen[0].headers["anthropic-beta"] == "oauth-2025-04-20")
        #expect(seen[0].headers["User-Agent"] == "Bifrost")
        #expect(seen[0].headers["Cookie"] == nil)
        #expect(seen[0].timeout == 10)
        #expect(SessionUsageFetcher.url.absoluteString == usageURL)
    }

    @Test func aRedirectIsRefused() async {
        let response = await fetch(.redirect(to: otherURL))
        // The answer is the redirect itself, which the poller treats as a bad status.
        #expect(response?.status == 302)
        #expect(StubProtocol.seen.map(\.url) == [usageURL])
    }

    // The configuration of the test has one cookie store that accepts each cookie and holds a
    // cookie of the usage host. A stub protocol gets no cookie from a store, so the test checks
    // that the fetcher takes the store and the cookie rules out of that configuration, and that
    // each request sends no cookie, also after an answer that sets one.
    @Test func noCookieGoesBack() async throws {
        let storage = HTTPCookieStorage()
        storage.cookieAcceptPolicy = .always
        let cookie = try #require(
            HTTPCookie(properties: [
                .domain: "api.anthropic.com", .path: "/", .name: "session",
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
        let fetcher = SessionUsageFetcher { configuration }
        _ = await fetcher.fetch(token: fakeToken, timeout: .seconds(10))
        _ = await fetcher.fetch(token: fakeToken, timeout: .seconds(10))
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(!configuration.httpShouldSetCookies)
        #expect(StubProtocol.seen.count == 2)
        #expect(StubProtocol.seen.allSatisfy { $0.headers["Cookie"] == nil && !$0.handlesCookies })
    }

    @Test(arguments: [401, 403, 429, 500])
    func theStatusOfEachAnswerComesBack(status: Int) async {
        let body = Data("{\"error\":\"fake\"}".utf8)
        let response = await fetch(.answer(status: status, headers: [:], body: body))
        #expect(response == UsageResponse(status: status, body: body))
    }

    @Test func aFetchErrorGivesNoAnswer() async {
        #expect(await fetch(.failure) == nil)
    }

    // A length over the limit in the header gives an empty body, which the parse refuses as a bad
    // answer, as the read of one byte over the limit does.
    @Test func aLengthOverTheLimitInTheHeaderIsABadAnswer() async throws {
        let header = ["Content-Length": "\(AccountAnswer.maxBytes + 1)"]
        let response = await fetch(.answer(status: 200, headers: header, body: Data("{}".utf8)))
        #expect(response?.status == 200)
        let body = try #require(response?.body)
        #expect(AccountAnswer.parse(body, fetchedAt: 0) == nil)
    }

    // The read stops after one byte over the limit, so a large answer never fills the memory.
    @Test func theReadStopsAfterOneByteOverTheLimit() async {
        let body = Data(repeating: UInt8(ascii: "a"), count: 1_500_000)
        let response = await fetch(.answer(status: 200, headers: [:], body: body))
        #expect(response?.status == 200)
        #expect(response?.body?.count == 1_000_001)
    }

    @Test func theTimeoutOfTheCallIsTheTimeoutOfTheRequest() async {
        StubProtocol.reset(.answer(status: 200, headers: [:], body: Data("{}".utf8)))
        _ = await stubbedFetcher().fetch(token: fakeToken, timeout: .seconds(4))
        #expect(StubProtocol.seen.map(\.timeout) == [4])
    }
}
