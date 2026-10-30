//
// TJ fork: the Artifacts / Dev log REST client (iOS Workshop, Element card).
// Based on Element X iOS. SPDX-License-Identifier: AGPL-3.0-only
//
// Spec: WatchLab/Element/03_ARTIFACTS_SPEC.md rev 3, D4, §5.1 ("401 handling"), §5.4 ("Token").
// - The access token and homeserver URL are read fresh from upstream's session keychain on every call (read only:
//   never a setter, never the refresh token). They are never stored beyond the call, logged or handed to a web view.
// - Requests go only to the session's own homeserver host (pinned on the first read); anything else is refused, redirects
//   included (`ForkRedirectGuard`), so the Bearer header never follows a 3xx to another host.
// - Writes: `sendMessage` (the §3.3 request in unencrypted rooms), `join` (Dev Log invite) and `putState`, which writes only the
//   two schedule types (04_VOICE_SCHEDULE_SPEC.md rev 2 §B6; `ForkScheduleWrite` holds the allowlist and the 8 KiB cap).
//   Nothing else.
//

import Foundation

nonisolated struct ForkSessionCredentials: Sendable, Equatable {
    let accessToken: String
    let homeserverURL: URL
}

actor ForkMatrixREST {
    enum RESTError: Error, Equatable {
        /// No restoration token for this user (signed out, or a fresh install).
        case noSession
        case hostMismatch
        /// 401 twice, or 401 with an unchanged token: "Session expired: reopen TJ Element".
        case sessionExpired
        /// 403 / M_FORBIDDEN (e.g. not joined to the Dev Log room).
        case forbidden
        case notFound
        case http(Int)
        case badResponse
    }

    typealias CredentialsProvider = @Sendable (String) -> ForkSessionCredentials?

    let userID: String
    private let credentialsProvider: CredentialsProvider
    private let session: URLSession
    private var pinnedHost: String?
    private(set) var isExpired = false

    static var userAgent: String {
        "TJElement/\(ForkBuildInfo.bundleVersion) (iOS; artifacts)"
    }

    /// `protocolClasses` is a test seam (a stub `URLProtocol`); production passes nil.
    init(userID: String, credentialsProvider: CredentialsProvider? = nil, protocolClasses: [AnyClass]? = nil) {
        self.userID = userID
        self.credentialsProvider = credentialsProvider ?? { Self.keychainCredentials(userID: $0) }
        let configuration = URLSessionConfiguration.ephemeral
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 120
        session = URLSession(configuration: configuration, delegate: ForkRedirectGuard(), delegateQueue: nil)
    }

    /// Upstream's session keychain, read only (`KeychainController(service: .sessions, …)`).
    static func keychainCredentials(userID: String) -> ForkSessionCredentials? {
        let keychain = KeychainController(service: .sessions, accessGroup: InfoPlistReader.main.keychainAccessGroupIdentifier)
        guard let session = keychain.restorationTokenForUsername(userID)?.session,
              let url = URL(string: session.homeserverUrl), url.host() != nil else {
            return nil
        }
        return ForkSessionCredentials(accessToken: session.accessToken, homeserverURL: url)
    }

    /// The user IDs that still have a restoration token (logout deletes it). Read only.
    static func signedInUserIDs() -> Set<String> {
        let keychain = KeychainController(service: .sessions, accessGroup: InfoPlistReader.main.keychainAccessGroupIdentifier)
        return Set(keychain.restorationTokens().map(\.userID))
    }

    /// The homeserver host this client is pinned to (nil before the first credentials read). For messages only.
    func currentHost() -> String? {
        pinnedHost
    }

    // MARK: - API

    func state(roomID: String) async throws -> [ForkJSON] {
        let data = try await perform("GET", path: "/_matrix/client/v3/rooms/\(Self.segment(roomID))/state")
        guard let events = try? ForkJSON.decode(data).array else { throw RESTError.badResponse }
        return events
    }

    func resolveAlias(_ alias: String) async throws -> String {
        let data = try await perform("GET", path: "/_matrix/client/v3/directory/room/\(Self.segment(alias))")
        guard let roomID = try? ForkJSON.decode(data)["room_id"]?.string else { throw RESTError.badResponse }
        return roomID
    }

    func join(_ roomIDOrAlias: String) async throws -> String {
        let data = try await perform("POST", path: "/_matrix/client/v3/join/\(Self.segment(roomIDOrAlias))", body: Data("{}".utf8))
        guard let roomID = try? ForkJSON.decode(data)["room_id"]?.string else { throw RESTError.badResponse }
        return roomID
    }

    /// Authenticated media (`/_matrix/client/v1/media/download/{server}/{mediaId}`).
    func downloadMedia(mxc: String) async throws -> Data {
        guard mxc.hasPrefix("mxc://") else { throw RESTError.badResponse }
        let parts = mxc.dropFirst("mxc://".count).split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { throw RESTError.badResponse }
        return try await perform("GET", path: "/_matrix/client/v1/media/download/\(Self.segment(parts[0]))/\(Self.segment(parts[1]))", timeout: 90)
    }

    /// `PUT /rooms/{roomID}/send/m.room.message/{txnID}`: idempotent for the same txn id. Returns the event id.
    func sendMessage(roomID: String, content: Data, txnID: String) async throws -> String {
        let path = "/_matrix/client/v3/rooms/\(Self.segment(roomID))/send/m.room.message/\(Self.segment(txnID))"
        let data = try await perform("PUT", path: path, body: content)
        guard let eventID = try? ForkJSON.decode(data)["event_id"]?.string else { throw RESTError.badResponse }
        return eventID
    }

    /// `PUT /rooms/{roomID}/state/{type}/{stateKey}` for `ai.autopute.schedule` / `ai.autopute.schedule.kill` only (B6). Any other
    /// type, or content over 8 KiB, is refused before a request is made. Returns the event id. Callers: ForkSchedule*.swift only.
    func putState(roomID: String, type: String, stateKey: String, content: Data) async throws -> String {
        try ForkScheduleWrite.check(type: type, content: content)
        let path = "/_matrix/client/v3/rooms/\(Self.segment(roomID))/state/\(Self.segment(type))/\(Self.segment(stateKey))"
        let data = try await perform("PUT", path: path, body: content)
        guard let eventID = try? ForkJSON.decode(data)["event_id"]?.string else { throw RESTError.badResponse }
        return eventID
    }

    // MARK: - Transport

    static func isRetryableTransport(_ error: URLError) -> Bool {
        [.networkConnectionLost, .cannotConnectToHost, .secureConnectionFailed].contains(error.code)
    }

    static func segment(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func credentials() throws -> ForkSessionCredentials {
        guard let credentials = credentialsProvider(userID) else { throw RESTError.noSession }
        guard let host = credentials.homeserverURL.host()?.lowercased() else { throw RESTError.noSession }
        if let pinnedHost, pinnedHost != host { throw RESTError.hostMismatch }
        pinnedHost = host
        return credentials
    }

    private func perform(_ method: String, path: String, body: Data? = nil, timeout: TimeInterval = 20) async throws -> Data {
        guard !isExpired else { throw RESTError.sessionExpired }
        var credentials = try credentials()
        var retried401 = false
        var attempts429 = 0
        var retriedTransport = false

        while true {
            let request = try makeRequest(method, path: path, body: body, credentials: credentials, timeout: timeout)
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch let error as URLError where method == "GET" && !retriedTransport && Self.isRetryableTransport(error) {
                // A pooled connection the network silently dropped fails the first request after idle or a resume from
                // the background (-1005); one immediate retry on a fresh connection is what the user would do.
                retriedTransport = true
                continue
            }
            guard let http = response as? HTTPURLResponse else { throw RESTError.badResponse }
            switch http.statusCode {
            case 200..<300:
                return data
            case 401:
                // The SDK may already have refreshed and saved a new token (e.g. a MAS login): re-read once. Not a refresh.
                guard !retried401 else { isExpired = true; throw RESTError.sessionExpired }
                retried401 = true
                let fresh = try self.credentials()
                guard fresh.accessToken != credentials.accessToken else { isExpired = true; throw RESTError.sessionExpired }
                credentials = fresh
            case 429:
                attempts429 += 1
                guard attempts429 <= 3 else { throw RESTError.http(429) }
                let retryMS = (try? ForkJSON.decode(data)["retry_after_ms"]?.int) ?? nil
                let headerSeconds = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                let delay = min(max(Double(retryMS ?? 0) / 1000, headerSeconds ?? 1, 0.5), 10)
                try await Task.sleep(for: .seconds(delay))
            case 403:
                throw RESTError.forbidden
            case 404:
                throw RESTError.notFound
            default:
                throw RESTError.http(http.statusCode)
            }
        }
    }

    private func makeRequest(_ method: String, path: String, body: Data?, credentials: ForkSessionCredentials, timeout: TimeInterval) throws -> URLRequest {
        var base = credentials.homeserverURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + path), url.host()?.lowercased() == pinnedHost, url.scheme == "https" || Self.allowsHTTP(url) else {
            throw RESTError.hostMismatch
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    /// Plain http only for a localhost homeserver (developer harness); the operator's server is https.
    private static func allowsHTTP(_ url: URL) -> Bool {
        url.scheme == "http" && (url.host() == "localhost" || url.host() == "127.0.0.1")
    }
}

/// Follows a redirect only to the same host and never from https down to http; otherwise the 3xx itself comes back
/// (and `perform` reports it as `.http`), because URLSession would carry the Authorization header to the new URL.
nonisolated final class ForkRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    static func allows(from source: URL?, to target: URL?) -> Bool {
        guard let sourceHost = source?.host()?.lowercased(), let targetHost = target?.host()?.lowercased(), sourceHost == targetHost else {
            return false
        }
        return target?.scheme == source?.scheme || target?.scheme == "https"
    }

    // The completion-handler form: the async form crashes the Xcode 27.1 compiler in SILGen (NonisolatedNonsendingByDefault).
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(Self.allows(from: task.originalRequest?.url, to: request.url) ? request : nil)
    }
}
