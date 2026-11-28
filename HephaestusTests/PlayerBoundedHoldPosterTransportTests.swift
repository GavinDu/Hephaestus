import Foundation
import Testing
@testable import Hephaestus

@MainActor
struct PlayerBoundedHoldPosterTransportTests {
    private let backend = URL(string: "https://games.example.test")!
    private let original = URL(string: "https://cdn.example.test/poster.png")!

    @Test func redirectOwnershipAndRebuiltRequestRejectStaleOrFourthHop() throws {
        let delegate = try #require(PlayerHoldPosterRedirectDelegate(original: original, backendOrigin: backend))
        var from = original
        for i in 1...3 {
            let next = URL(string: "https://cdn.example.test/poster-\(i).png?sig=opaque%2Bvalue")!
            var proposed = URLRequest(url: next)
            proposed.httpMethod = "GET"
            proposed.setValue("Bearer never-forward", forHTTPHeaderField: "Authorization")
            proposed.setValue("private-cookie", forHTTPHeaderField: "Cookie")
            let request = try #require(delegate.admit(status: 302, from: from, proposed: proposed))
            #expect(request.url == next)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            #expect(request.value(forHTTPHeaderField: "Accept-Encoding") == "identity")
            #expect(!request.httpShouldHandleCookies)
            #expect(delegate.acceptsTerminalURL(next))
            #expect(!delegate.acceptsTerminalURL(from))
            from = next
        }
        let fourth = delegate.admit(status: 302, from: from, proposed: URLRequest(url: original))
        #expect(fourth == nil)
        #expect(delegate.denied)
        #expect(!delegate.acceptsTerminalURL(from))
    }

    @Test func hostileRedirectPermanentlyDeniesTransferAcross160Cases() throws {
        for i in 0..<160 {
            let delegate = try #require(PlayerHoldPosterRedirectDelegate(original: original, backendOrigin: backend))
            let hostile = URL(string: "https://outside-\(i).example.test/poster.png")!
            let rejected = delegate.admit(status: 302, from: original, proposed: URLRequest(url: hostile))
            #expect(rejected == nil)
            let revival = delegate.admit(status: 302, from: original, proposed: URLRequest(url: original))
            #expect(revival == nil)
            #expect(!delegate.acceptsTerminalURL(original))
        }
        let stale = try #require(PlayerHoldPosterRedirectDelegate(original: original, backendOrigin: backend))
        let staleResult = stale.admit(status: 302, from: backend, proposed: URLRequest(url: original))
        #expect(staleResult == nil)
        let wrongMethod = try #require(PlayerHoldPosterRedirectDelegate(original: original, backendOrigin: backend))
        var post = URLRequest(url: original)
        post.httpMethod = "POST"
        let postResult = wrongMethod.admit(status: 307, from: original, proposed: post)
        #expect(postResult == nil)
    }

    @Test func transferNeverReleasesPartialOverflowOrCancelledBytes() throws {
        let response = try #require(HTTPURLResponse(url: original, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "image/png", "Content-Length": "2"]))
        var transfer = try #require(PlayerHoldPosterTransfer(response: response))
        let first = transfer.append(1)
        #expect(first)
        let second = transfer.append(2)
        #expect(second)
        let overflow = transfer.append(3)
        #expect(!overflow)
        #expect(transfer.bufferedBytes == 0)
        let result = transfer.finish(transportSucceeded: true)
        #expect(result == nil)
        var cancelled = try #require(PlayerHoldPosterTransfer(response: response))
        let partial = cancelled.append(1)
        #expect(partial)
        cancelled.discard()
        #expect(cancelled.bufferedBytes == 0)
        let revived = cancelled.append(2)
        #expect(!revived)
        let final = cancelled.finish(transportSucceeded: true)
        #expect(final == nil)
    }

    @Test func actualURLSessionRejectsNonImageAndOverflowHeaders() async {
        for path in ["bad-mime", "oversized", "not-found", "corrupt"] {
            let url = URL(string: "https://cdn.example.test/\(path)")!
            let data = await PlayerBoundedHoldPosterTransport.fetch(
                original: url, backendOrigin: backend,
                testProtocolClasses: [PosterTransportFixtureProtocol.self])
            #expect(data == nil)
        }
    }

    @Test func actualURLSessionReturnsOnlyCompleteEncodedPNG() async throws {
        let url = URL(string: "https://cdn.example.test/valid")!
        let data = await PlayerBoundedHoldPosterTransport.fetch(
            original: url, backendOrigin: backend,
            testProtocolClasses: [PosterTransportFixtureProtocol.self])
        let accepted = try #require(data)
        #expect(accepted.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]))
        #expect(accepted.count < 1000)
    }

    @Test func preCancelledTaskCannotReturnImage() async {
        let url = URL(string: "https://cdn.example.test/valid")!
        let task = Task { @MainActor in
            await PlayerBoundedHoldPosterTransport.fetch(
                original: url, backendOrigin: backend,
                testProtocolClasses: [PosterTransportFixtureProtocol.self])
        }
        task.cancel()
        let result = await task.value
        #expect(result == nil)
    }
}

/// Local in-memory transport fixture, not a published game or native UI proof.
private final class PosterTransportFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "cdn.example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jR9sAAAAASUVORK5CYII=")!
        let data = url.path == "/corrupt" ? Data([0, 1, 2, 3]) : png
        let status = url.path == "/not-found" ? 404 : 200
        let mime = url.path == "/bad-mime" ? "text/html" : "image/png"
        let length = url.path == "/oversized" ? 2 * 1024 * 1024 + 1 : data.count
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mime, "Content-Length": String(length)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
