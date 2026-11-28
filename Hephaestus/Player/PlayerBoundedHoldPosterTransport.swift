import Foundation

/// Per-request, native-only redirect ownership. Never forwards a redirected
/// request's cookies, authorization or arbitrary headers. No UI/lease authority.
@MainActor
final class PlayerHoldPosterRedirectDelegate: NSObject, URLSessionTaskDelegate {
    private let original: URL
    private let backendOrigin: URL
    private(set) var currentURL: URL
    private(set) var followed = 0
    private(set) var denied = false

    init?(original: URL, backendOrigin: URL) {
        guard PlayerPosterRedirectHopPolicy.admittedHop(
            original: original, from: original, to: original,
            alreadyFollowed: 0, backendOrigin: backendOrigin
        ) == original else { return nil }
        self.original = original
        self.backendOrigin = backendOrigin
        self.currentURL = original
        super.init()
    }

    static func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 12)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("image/png, image/jpeg", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }

    func admit(status: Int, from: URL?, proposed: URLRequest) -> URLRequest? {
        guard !denied, [301, 302, 303, 307, 308].contains(status),
              from == currentURL, proposed.httpMethod == "GET",
              let next = proposed.url,
              let accepted = PlayerPosterRedirectHopPolicy.admittedHop(
                original: original, from: currentURL, to: next,
                alreadyFollowed: followed, backendOrigin: backendOrigin
              ) else {
            denied = true
            return nil
        }
        followed += 1
        currentURL = accepted
        return Self.request(for: accepted)
    }

    func acceptsTerminalURL(_ url: URL?) -> Bool {
        !denied && url == currentURL
    }

    nonisolated func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        await admit(status: response.statusCode, from: response.url, proposed: request)
    }
}

/// Single bounded transfer state. Failure and cancellation discard bytes;
/// successful EOF plus encoded-header admission is required to release data.
@MainActor
struct PlayerHoldPosterTransfer {
    private var budget: PlayerHoldPosterResponseBudget
    private var data = Data()
    private var terminal = false

    init?(response: HTTPURLResponse) {
        guard let budget = PlayerHoldPosterResponseBudget(
            statusCode: response.statusCode, mimeType: response.mimeType,
            expectedLength: response.expectedContentLength,
            contentEncoding: response.value(forHTTPHeaderField: "Content-Encoding")
        ) else { return nil }
        self.budget = budget
    }

    var bufferedBytes: Int { data.count }

    mutating func append(_ byte: UInt8) -> Bool {
        guard !terminal, budget.admitChunk(byteCount: 1) else {
            discard()
            return false
        }
        data.append(byte)
        return true
    }

    mutating func discard() {
        terminal = true
        data = Data()
    }

    mutating func finish(transportSucceeded: Bool) -> Data? {
        guard !terminal, budget.finish(transportSucceeded: transportSucceeded),
              budget.admitsEncodedHeader(data) else {
            discard()
            return nil
        }
        let accepted = data
        discard()
        return accepted
    }
}

/// A cancellable, anonymous transport seam. Returns only bounded encoded
/// data; no raster decode, view mutation, or first-scene authority.
@MainActor
enum PlayerBoundedHoldPosterTransport {
    static func fetch(
        original: URL, backendOrigin: URL, testProtocolClasses: [AnyClass]? = nil
    ) async -> Data? {
        guard !Task.isCancelled,
              let redirects = PlayerHoldPosterRedirectDelegate(
                original: original, backendOrigin: backendOrigin
              ) else { return nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 15
        if let testProtocolClasses { configuration.protocolClasses = testProtocolClasses }
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        do {
            let (bytes, rawResponse) = try await session.bytes(
                for: PlayerHoldPosterRedirectDelegate.request(for: original),
                delegate: redirects
            )
            guard !Task.isCancelled,
                  let response = rawResponse as? HTTPURLResponse,
                  redirects.acceptsTerminalURL(response.url),
                  var transfer = PlayerHoldPosterTransfer(response: response) else {
                return nil
            }
            for try await byte in bytes {
                guard !Task.isCancelled, transfer.append(byte) else {
                    transfer.discard()
                    return nil
                }
                // Avoid monopolizing the main actor even if bytes are buffered.
                if transfer.bufferedBytes.isMultiple(of: 8192) { await Task.yield() }
            }
            guard !Task.isCancelled else {
                transfer.discard()
                return nil
            }
            return transfer.finish(transportSucceeded: true)
        } catch {
            // No URL, token, response content or user-specific detail logged.
            return nil
        }
    }
}
