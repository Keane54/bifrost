import Foundation

// One GET or HEAD request with the rules that every network read of Bifrost follows. Each request
// has its own ephemeral URLSession with no cookies, no cache and no stored credentials, a time
// limit for the whole request, and a delegate that refuses each redirect, so a header never goes
// to another address. The read of the body stops one byte over the cap, so a large answer never
// fills the memory. The helper logs nothing and keeps no error text, because an error text can
// hold request data. The app uses the ephemeral configuration. A test adds its stub protocol.
package struct GuardedGet: Sendable {
    // The answer: the status, and the body of at most maxBytes + 1 bytes. body is nil when the
    // read of the body failed after the response came, so the status stays for the caller.
    // tooLarge is true when the answer has more than maxBytes bytes, by its declared length or by
    // the read. A declared length over the cap gives an empty body.
    package struct Answer: Sendable, Equatable {
        package var status: Int
        package var body: Data?
        package var tooLarge: Bool

        package var isSuccess: Bool { (200..<300).contains(status) }
    }

    // The end of one HEAD request.
    package enum HeadAnswer: Sendable, Equatable {
        // The server answered with this status. Each status counts, also a redirect status.
        case status(Int)
        // No answer came before the time limit.
        case timedOut
        // The request failed before an answer: for example a DNS error, a refused connection or
        // no network.
        case failed
    }

    private let makeConfiguration: @Sendable () -> URLSessionConfiguration

    package init(
        configuration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }
    ) {
        makeConfiguration = configuration
    }

    // nil: no answer (a fetch error, a timeout, a redirect or a body that failed to read).
    package func get(
        _ url: URL, headers: [String: String], timeout: Duration, maxBytes: Int
    ) async -> Answer? {
        let session = makeSession(timeout: timeout)
        // The invalidation also releases the delegate.
        defer { session.invalidateAndCancel() }
        let request = Self.request(url, method: "GET", headers: headers, timeout: timeout)
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            if http.expectedContentLength > maxBytes {
                return Answer(status: http.statusCode, body: Data(), tooLarge: true)
            }
            let body = await Self.read(bytes, maxBytes: maxBytes)
            return Answer(
                status: http.statusCode, body: body, tooLarge: (body?.count ?? 0) > maxBytes)
        } catch {
            // The error text can hold request data, so it goes nowhere.
            return nil
        }
    }
}

extension GuardedGet {
    // One HEAD request with no extra header. The answer comes with the headers of the response,
    // and the body is never read. A redirect is refused, so its status is the answer.
    package func head(_ url: URL, timeout: Duration) async -> HeadAnswer {
        let session = makeSession(timeout: timeout)
        defer { session.invalidateAndCancel() }
        let request = Self.request(url, method: "HEAD", headers: [:], timeout: timeout)
        do {
            let (_, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed }
            return .status(http.statusCode)
        } catch let error as URLError where error.code == .timedOut {
            return .timedOut
        } catch {
            // The error text can hold request data, so it goes nowhere.
            return .failed
        }
    }

    // A session of one request: no cookies, no cache, no stored credentials, the time limit for
    // the whole request, and the refusal of each redirect.
    private func makeSession(timeout: Duration) -> URLSession {
        let seconds = timeout / .seconds(1)
        let configuration = makeConfiguration()
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = seconds
        configuration.timeoutIntervalForResource = seconds
        return URLSession(
            configuration: configuration, delegate: RedirectRefusal(), delegateQueue: nil)
    }

    // The request: the method, the headers and the user agent of Bifrost, and no cookie.
    private static func request(
        _ url: URL, method: String, headers: [String: String], timeout: Duration
    ) -> URLRequest {
        var request = URLRequest(
            url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: timeout / .seconds(1))
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("Bifrost", forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    // The body, up to one byte over the cap, or nil when the read fails. The read stops at the
    // first byte over the cap, so a large answer never fills the memory.
    static func read(_ bytes: some AsyncSequence<UInt8, any Error>, maxBytes: Int) async -> Data? {
        var body = Data()
        do {
            for try await byte in bytes {
                body.append(byte)
                if body.count > maxBytes { break }
            }
        } catch {
            return nil
        }
        return body
    }
}

// Refuses each redirect. The request then ends with the redirect answer, which is no success. The
// method has the completion handler form: the Swift 6.3 compiler crashes on the async form of
// this delegate method.
private final class RedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
