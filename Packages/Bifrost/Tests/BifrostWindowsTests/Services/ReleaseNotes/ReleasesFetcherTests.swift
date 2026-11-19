// The requests of the release notes (docs/behaviour/updates.md, "Release notes"). Safety: each
// session of these tests has the stub below as its first protocol, so no request reaches the
// network, and the sandbox of the tests refuses each outbound connection.
import BifrostTestSupport
import Foundation
import Synchronization
import Testing

@testable import BifrostWindows

private let apiURL = URL(string: "https://api.example.invalid/releases?per_page=10") ?? releasesPage
private let otherURL = "https://example.invalid/other"

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
        guard url == apiURL else {
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
    return await SessionReleasesFetcher(api: apiURL, configuration: stubbedConfiguration).fetch()
}

@Suite("releases fetcher", .serialized)
struct ReleasesFetcherTests {
    @Test func aGoodAnswerComesBack() async {
        let body = Data("[]".utf8)
        #expect(await fetch(.answer(status: 200, headers: [:], body: body)) == body)
    }

    @Test func aRedirectIsRefused() async {
        #expect(await fetch(.redirect(to: otherURL)) == nil)
        // The fetcher never asks the second URL.
        #expect(StubProtocol.seen.map(\.url) == [apiURL.absoluteString])
    }

    @Test(arguments: [403, 404, 429, 500])
    func aStatusThatIsNot2xxIsNoAnswer(status: Int) async {
        #expect(await fetch(.answer(status: status, headers: [:], body: Data("[]".utf8))) == nil)
    }

    @Test func aFetchErrorIsNoAnswer() async {
        #expect(await fetch(.failure) == nil)
    }

    @Test func aBodyOver2MBCouldNotLoad() async {
        let cap = ReleaseNotesSource.maxBytes
        // The cap itself is an answer. One byte over is not.
        let atCap = Data(repeating: UInt8(ascii: "a"), count: cap)
        #expect(await fetch(.answer(status: 200, headers: [:], body: atCap))?.count == cap)
        let over = Data(repeating: UInt8(ascii: "a"), count: cap + 1)
        #expect(await fetch(.answer(status: 200, headers: [:], body: over)) == nil)
        // A length over the cap in the header stops the read before it starts.
        let header = ["Content-Length": "\(cap + 1)"]
        #expect(await fetch(.answer(status: 200, headers: header, body: Data("[]".utf8))) == nil)
    }

    @Test func theRequestHasNoTokenAndTheTenSecondLimit() async throws {
        let configuration = stubbedConfiguration()
        StubProtocol.reset(.answer(status: 200, headers: [:], body: Data("[]".utf8)))
        _ = await SessionReleasesFetcher(api: apiURL) { configuration }.fetch()
        let seen = try #require(StubProtocol.seen.first)
        #expect(seen.timeout == 10)
        #expect(configuration.timeoutIntervalForRequest == 10)
        #expect(configuration.timeoutIntervalForResource == 10)
        #expect(seen.method == "GET")
        #expect(seen.headers["Accept"] == "application/vnd.github+json")
        #expect(seen.headers["Authorization"] == nil)
        #expect(seen.headers["Cookie"] == nil)
        #expect(!seen.handlesCookies)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.urlCache == nil)
        #expect(configuration.urlCredentialStorage == nil)
    }

    @Test func theApiAddressComesFromTheReleasesPage() throws {
        let page = try #require(URL(string: "https://github.com/example/bifrost/releases"))
        #expect(SessionReleasesFetcher(releasesPage: page) != nil)
        for text in [
            "http://github.com/example/bifrost/releases", "https://example.invalid/a/b/releases",
            "https://github.com/example/bifrost", "https://github.com/example/bifrost/pulls",
            "https://github.com/a/b/c/releases",
        ] {
            let other = try #require(URL(string: text))
            #expect(SessionReleasesFetcher(releasesPage: other) == nil, "\(text)")
        }
    }
}

@Suite("file releases fetcher")
struct FileReleasesFetcherTests {
    @Test func theFileOfATestHomeIsTheAnswer() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = folder.url.appending(path: "github-releases.json")
        #expect(await FileReleasesFetcher(file: file).fetch() == nil)
        let data = releasesAnswer(releaseJSON(tag: "v1.0.0"))
        try data.write(to: file)
        #expect(await FileReleasesFetcher(file: file).fetch() == data)
    }
}
