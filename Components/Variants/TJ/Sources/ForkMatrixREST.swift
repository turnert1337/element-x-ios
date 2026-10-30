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
import Network
import Observation

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
        // E6 D1: fail at once when there's no network (the default for an ephemeral session, stated so nobody flips it): the Dev
        // log learns "offline" from `ForkNetworkPath`, not from a request that waits and then times out.
        configuration.waitsForConnectivity = false
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

    /// What the live session does without a network (read from the session itself, for the tests).
    func connectivityPolicy() -> (waitsForConnectivity: Bool, requestTimeout: TimeInterval) {
        (session.configuration.waitsForConnectivity, session.configuration.timeoutIntervalForRequest)
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

// MARK: - Network path (E6 D1)

nonisolated enum ForkNetworkReach {
    /// Why requests can't go out right now, if they can't.
    enum State: Equatable, Sendable {
        case online
        case offline
        /// Settings → TJ Element → Mobile Data is off (`NWPath.UnsatisfiedReason.cellularDenied`): the iPhone itself may be online.
        case cellularDenied
        /// Per-app Wi-Fi (WLAN) access denied.
        case wifiDenied

        var isOffline: Bool { self != .online }

        var message: String {
            switch self {
            case .online: ""
            case .offline: "This iPhone is offline."
            case .cellularDenied: "TJ Element isn't allowed to use mobile data. Check Settings → TJ Element."
            case .wifiDenied: "TJ Element isn't allowed to use Wi-Fi. Check Settings → TJ Element."
            }
        }

        var waitLine: String {
            switch self {
            case .online, .offline: "Retries when this iPhone is back online."
            case .cellularDenied, .wifiDenied: "Retries when TJ Element is allowed to use the network."
            }
        }
    }

    /// `.requiresConnection` (e.g. VPN on demand) isn't offline: a request may bring the link up.
    static func isOffline(_ status: NWPath.Status) -> Bool {
        status == .unsatisfied
    }

    /// E6 stage fix D1: a path that's unsatisfied because this app is denied mobile data or Wi-Fi says so, not "offline".
    static func state(status: NWPath.Status, reason: NWPath.UnsatisfiedReason) -> State {
        guard isOffline(status) else { return .online }
        switch reason {
        case .cellularDenied: return .cellularDenied
        case .wifiDenied: return .wifiDenied
        default: return .offline
        }
    }
}

/// The device's network path from `NWPathMonitor`: `isOffline` flips the moment iOS knows (Airplane Mode, no Wi-Fi or cellular),
/// before any request could time out. Test Round 1 (c2) read "matrix.autopute.ai took too long to answer" in Airplane Mode.
/// E6 stage fix: the monitor runs on the main queue and each update is applied synchronously there (`MainActor.assumeIsolated`), so
/// updates land in the order iOS sent them (a Task per update could reorder them). `shared` starts at app launch (`AppHooks.setUp`),
/// so `isOffline` is already right when the Dev log or a schedule first asks.
@MainActor
@Observable
final class ForkNetworkPath {
    static let shared = ForkNetworkPath(monitoring: true)

    private(set) var state: ForkNetworkReach.State = .online
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var continuations: [UUID: AsyncStream<ForkNetworkReach.State>.Continuation] = [:]

    var isOffline: Bool { state.isOffline }

    /// How many `changes()` streams are open (tests: a dropped Dev log model must close its own).
    var observerCount: Int { continuations.count }

    /// `monitoring: false` is the test seam: nothing watches the real path; `update(_:)` drives it.
    init(monitoring: Bool) {
        guard monitoring else { return }
        let monitor = NWPathMonitor()
        // Weak: a non-shared instance must not keep itself alive through its own monitor.
        monitor.pathUpdateHandler = Self.handler { [weak self] state in
            MainActor.assumeIsolated { self?.update(state) }
        }
        monitor.start(queue: .main)
        self.monitor = monitor
    }

    isolated deinit {
        monitor?.cancel()
        for continuation in continuations.values { continuation.finish() }
    }

    func update(_ newState: ForkNetworkReach.State) {
        guard newState != state else { return }
        state = newState
        MXLog.info("TJ network path: \(newState)")
        for continuation in continuations.values {
            continuation.yield(newState)
        }
    }

    /// Test convenience: plain offline / online.
    func update(offline: Bool) {
        update(offline ? .offline : .online)
    }

    /// Each change of `state` from now on.
    func changes() -> AsyncStream<ForkNetworkReach.State> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ForkNetworkReach.State>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.continuations[id] = nil }
        }
        return stream
    }

    /// Built outside the main actor so the closure isn't main-actor isolated by inference; the monitor calls it on `.main`.
    private nonisolated static func handler(_ sink: @escaping @Sendable (ForkNetworkReach.State) -> Void) -> @Sendable (NWPath) -> Void {
        { path in sink(ForkNetworkReach.state(status: path.status, reason: path.unsatisfiedReason)) }
    }
}
