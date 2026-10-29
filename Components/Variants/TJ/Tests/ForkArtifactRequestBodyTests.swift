//
// TJ fork: New artifact request event tests (iOS Workshop, Element card).
// Based on Element X iOS. SPDX-License-Identifier: AGPL-3.0-only
//
// Spec: WatchLab/Element/03_ARTIFACTS_SPEC.md rev 3, §3.3 + Appendix A.3, G-A8 (retry idempotence: same txn id → one event).
//

@testable import ElementX
import Foundation
import Synchronization
import Testing

struct ForkArtifactRequestBodyTests {
    // MARK: - A.3 vectors

    @Test
    func a3Vector1NASNoTitle() throws {
        let message = try ForkArtifactRequest.build(pipe: .nas, title: nil, text: "a tiny color picker", clientTS: 1_793_280_000_000, targetAID: nil)
        #expect(message.body == "🧩 Artifact request · NAS\na tiny color picker")
        try expectKey(message, equals: #"{"v":1,"pipe":"nas","text":"a tiny color picker","client_ts":1793280000000}"#)
        #expect(ForkArtifactRequest.parseFirstLine(message.body)?.pipe == .nas)
    }

    @Test
    func a3Vector2XcodeWithTitle() throws {
        let message = try ForkArtifactRequest.build(pipe: .xcode, title: "Timer v2", text: "laps please", clientTS: 1_793_280_000_001, targetAID: nil)
        #expect(message.body == "🧩 Artifact request · Xcode · Timer v2\nlaps please")
        try expectKey(message, equals: #"{"v":1,"pipe":"xcode","title":"Timer v2","text":"laps please","client_ts":1793280000001}"#)
        let parsed = try #require(ForkArtifactRequest.parseFirstLine(message.body))
        #expect(!parsed.isChange && parsed.pipe == .xcode && parsed.title == "Timer v2")
    }

    @Test
    func a3Vector3Change() throws {
        let message = try ForkArtifactRequest.build(pipe: .nas, title: "Lumen Drift", text: "make the motes bigger", clientTS: 1_793_280_100_000, targetAID: "lumen-drift")
        #expect(message.body == "🧩 Artifact change · NAS · Lumen Drift\nmake the motes bigger")
        try expectKey(message, equals: #"{"v":1,"pipe":"nas","title":"Lumen Drift","text":"make the motes bigger","client_ts":1793280100000,"target_aid":"lumen-drift"}"#)
        #expect(ForkArtifactRequest.parseFirstLine(message.body)?.isChange == true)
    }

    @Test
    func a3Vector4EncryptedIsBodyOnly() throws {
        let message = try ForkArtifactRequest.build(pipe: .xcode, title: nil, text: "Timer v2", clientTS: 1, targetAID: nil, encrypted: true)
        #expect(message.body == "🧩 Artifact request · Xcode\nTimer v2")
        #expect(message.key == nil)
        let content = try ForkJSON.decode(message.contentData())
        #expect(content[ForkArtifactConstants.requestContentKey] == nil)
        #expect(ForkArtifactRequest.parseFirstLine(message.body)?.pipe == .xcode)
    }

    @Test
    func a3Vector5TextBoundsAreRefused() {
        #expect(throws: ForkArtifactRequest.BuildError.emptyText) { try ForkArtifactRequest.build(pipe: .nas, title: nil, text: "", clientTS: 1, targetAID: nil) }
        #expect(throws: ForkArtifactRequest.BuildError.emptyText) { try ForkArtifactRequest.build(pipe: .nas, title: nil, text: "  \n", clientTS: 1, targetAID: nil) }
        #expect(throws: ForkArtifactRequest.BuildError.textTooLong) { try ForkArtifactRequest.build(pipe: .nas, title: nil, text: String(repeating: "a", count: 4001), clientTS: 1, targetAID: nil) }
        #expect(throws: Never.self) { try ForkArtifactRequest.build(pipe: .nas, title: nil, text: String(repeating: "a", count: 4000), clientTS: 1, targetAID: nil) }
    }

    @Test
    func a3Vector6InvalidKeyIsIgnored() {
        #expect(ForkArtifactRequest.validate(key: .object(["v": .number(2), "pipe": .string("nas"), "text": .string("x"), "client_ts": .number(1)])) == nil)
    }

    @Test
    func a3Vector7ValidKeyWinsOverBody() throws {
        let key = try #require(ForkArtifactRequest.validate(key: .object(["v": .number(1), "pipe": .string("nas"), "text": .string("not the grammar"), "client_ts": .number(1)])))
        #expect(key.pipe == .nas)
        #expect(ForkArtifactRequest.parseFirstLine("not the grammar") == nil)
    }

    @Test
    func fullContentIsTheFrozenShape() throws {
        let message = try ForkArtifactRequest.build(pipe: .nas, title: "Color picker", text: "a tiny color picker", clientTS: 1_793_280_000_000, targetAID: nil)
        let content = try ForkJSON.decode(message.contentData())
        #expect(content["msgtype"] == .string("m.text"))
        #expect(content["m.mentions"] == .object([:]))
        #expect(content["body"] == .string("🧩 Artifact request · NAS · Color picker\na tiny color picker"))
        #expect(ForkArtifactRequest.validate(key: content[ForkArtifactConstants.requestContentKey]) == message.key)
        // Key-sorted bytes are stable.
        #expect(try message.contentData() == message.contentData())
    }

    @Test
    func keyValidationRules() {
        let base: [String: ForkJSON] = ["v": .number(1), "pipe": .string("xcode"), "text": .string("x"), "client_ts": .number(5)]
        #expect(ForkArtifactRequest.validate(key: .object(base)) != nil)
        var badPipe = base; badPipe["pipe"] = .string("cdn")
        var badTitle = base; badTitle["title"] = .string(String(repeating: "t", count: 61))
        var nullTitle = base; nullTitle["title"] = .null
        var badTarget = base; badTarget["target_aid"] = .string("Bad_Aid")
        var floatTS = base; floatTS["client_ts"] = .number(1.5)
        #expect(ForkArtifactRequest.validate(key: .object(badPipe)) == nil)
        #expect(ForkArtifactRequest.validate(key: .object(badTitle)) == nil)
        #expect(ForkArtifactRequest.validate(key: .object(nullTitle))?.title == nil)
        #expect(ForkArtifactRequest.validate(key: .object(badTarget)) == nil)
        #expect(ForkArtifactRequest.validate(key: .object(floatTS)) == nil)
    }

    @Test
    func relayRegexIsCaseInsensitiveOnThePipeOnly() {
        #expect(ForkArtifactRequest.parseFirstLine("🧩 Artifact request · nas\nx")?.pipe == .nas)
        #expect(ForkArtifactRequest.parseFirstLine("🧩 artifact request · NAS\nx") == nil)
    }

    // MARK: - G-A8 retry idempotence

    @Test
    func retryReusesTheTxnIDSoTheServerKeepsOneEvent() async throws {
        ForkStubMatrixServer.reset(failFirstSend: true)
        let rest = ForkMatrixREST(userID: "@tjtest:autopute.ai",
                                  credentialsProvider: { _ in ForkSessionCredentials(accessToken: "stub-token", homeserverURL: URL(string: "https://matrix.example.org")!) },
                                  protocolClasses: [ForkStubMatrixServer.self])
        let model = ForkArtifactsModel(userID: "@tjtest:autopute.ai", roomID: "!scratch:example.org", rest: rest,
                                       cacheBase: FileManager.default.temporaryDirectory.appending(path: "TJArtifactsReqTests"))
        model.draft.pipe = .nas
        model.draft.title = "Gate color picker"
        model.draft.text = "a tiny color picker"

        let first = await model.sendDraft(isEncrypted: false) { _ in false }
        #expect(!first)
        #expect(model.draft.error != nil)
        let txn = try #require(model.draft.txnID)
        #expect(txn.hasPrefix("tjart-"))

        let second = await model.sendDraft(isEncrypted: false) { _ in false }
        #expect(second)
        #expect(model.draft.txnID == txn)
        let snapshot = ForkStubMatrixServer.snapshot()
        #expect(snapshot.sendPaths.count == 2)
        #expect(Set(snapshot.sendPaths).count == 1)
        #expect(snapshot.events.count == 1)
        #expect(snapshot.sendPaths.first?.hasSuffix("/send/m.room.message/\(txn)") == true)
        let content = try #require(snapshot.events.values.first)
        #expect(content[ForkArtifactConstants.requestContentKey]?["pipe"] == .string("nas"))
        #expect(content[ForkArtifactConstants.requestContentKey]?["title"] == .string("Gate color picker"))

        // A replay of the same txn id is still one event (Matrix txn semantics, mirrored by the stub).
        _ = try await rest.sendMessage(roomID: "!scratch:example.org", content: model.draft.isEmpty ? Data("{}".utf8) : Data("{}".utf8), txnID: txn)
        #expect(ForkStubMatrixServer.snapshot().events.count == 1)
    }

    @Test
    func requestsToAnotherHostAreRefused() async {
        let counter = ForkHostFlip()
        let rest = ForkMatrixREST(userID: "@a:b",
                                  credentialsProvider: { _ in counter.next() },
                                  protocolClasses: [ForkStubMatrixServer.self])
        ForkStubMatrixServer.reset(failFirstSend: false)
        _ = try? await rest.state(roomID: "!r:b")
        await #expect(throws: ForkMatrixREST.RESTError.hostMismatch) { _ = try await rest.state(roomID: "!r:b") }
    }

    /// L6 (c): the Bearer header must never follow a redirect to another host, or from https down to http.
    @Test
    func redirectGuardRules() {
        let home = URL(string: "https://matrix.example.org/_matrix/client/v3/rooms/x/state")
        #expect(ForkRedirectGuard.allows(from: home, to: URL(string: "https://matrix.example.org/_matrix/other")))
        #expect(ForkRedirectGuard.allows(from: home, to: URL(string: "https://MATRIX.example.org/x")))
        #expect(!ForkRedirectGuard.allows(from: home, to: URL(string: "https://evil.example.org/x")))
        #expect(!ForkRedirectGuard.allows(from: home, to: URL(string: "http://matrix.example.org/x")))
        #expect(!ForkRedirectGuard.allows(from: home, to: nil))
        #expect(!ForkRedirectGuard.allows(from: nil, to: home))
    }

    @Test
    func crossHostRedirectIsNotFollowed() async {
        let rest = ForkMatrixREST(userID: "@a:b",
                                  credentialsProvider: { _ in ForkSessionCredentials(accessToken: "t", homeserverURL: URL(string: "https://matrix.example.org")!) },
                                  protocolClasses: [ForkRedirectingServer.self])
        ForkRedirectingServer.reset(target: "https://evil.example.org/steal")
        await #expect(throws: (any Error).self) { _ = try await rest.state(roomID: "!r:b") }
        #expect(!ForkRedirectingServer.hosts().contains("evil.example.org"))

        ForkRedirectingServer.reset(target: "https://matrix.example.org/_matrix/client/v3/rooms/moved/state")
        _ = try? await rest.state(roomID: "!r:b")
        #expect(ForkRedirectingServer.hosts() == ["matrix.example.org", "matrix.example.org"])
    }

    // MARK: - Helpers

    private func expectKey(_ message: ForkArtifactRequestMessage, equals expected: String) throws {
        let key = try #require(message.key)
        let built = try ForkJSON.decode(JSONEncoder().encode(key)).sortedData()
        let frozen = try ForkJSON.decode(Data(expected.utf8)).sortedData()
        #expect(String(decoding: built, as: UTF8.self) == String(decoding: frozen, as: UTF8.self))
    }
}

/// Returns a different homeserver host on the second read.
nonisolated final class ForkHostFlip: Sendable {
    private let calls = Mutex(0)

    func next() -> ForkSessionCredentials {
        let call = calls.withLock { value -> Int in
            value += 1
            return value
        }
        let host = call == 1 ? "https://matrix.example.org" : "https://evil.example.org"
        return ForkSessionCredentials(accessToken: "t", homeserverURL: URL(string: host)!)
    }
}

/// A stub homeserver: `/state` returns [], `PUT …/send/…/{txn}` dedupes by txn id; optionally fails the first send.
nonisolated final class ForkStubMatrixServer: URLProtocol {
    struct State {
        var failNextSend = false
        var sendPaths: [String] = []
        var events: [String: ForkJSON] = [:]
    }

    private static let state = Mutex(State())

    static func reset(failFirstSend: Bool) {
        state.withLock { $0 = State(failNextSend: failFirstSend) }
    }

    static func snapshot() -> State {
        state.withLock { $0 }
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let path = url.path(percentEncoded: true)
        var status = 200
        var body = Data("{}".utf8)
        if request.httpMethod == "PUT", path.contains("/send/m.room.message/") {
            let txn = String(path.split(separator: "/").last ?? "")
            let content = (request.httpBody ?? Self.readStream(request.httpBodyStream)).flatMap { try? ForkJSON.decode($0) }
            let fail = Self.state.withLock { state -> Bool in
                state.sendPaths.append(path)
                if state.failNextSend { state.failNextSend = false; return true }
                if state.events[txn] == nil { state.events[txn] = content ?? .null }
                return false
            }
            status = fail ? 500 : 200
            body = Data(#"{"event_id":"$stub-\#(txn)"}"#.utf8)
        } else if path.hasSuffix("/state") {
            body = Data("[]".utf8)
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }

    private static func readStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// Answers the first request with a 302 to `target`; any request it is asked for afterwards returns `[]`.
nonisolated final class ForkRedirectingServer: URLProtocol {
    private static let state = Mutex((target: "", hosts: [String]()))

    static func reset(target: String) {
        state.withLock { $0 = (target: target, hosts: []) }
    }

    static func hosts() -> [String] {
        state.withLock { $0.hosts }
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let (isFirst, target) = Self.state.withLock { state -> (Bool, String) in
            state.hosts.append(url.host() ?? "")
            return (state.hosts.count == 1, state.target)
        }
        if isFirst, let targetURL = URL(string: target) {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: targetURL), redirectResponse: response)
            client?.urlProtocol(self, didFailWithError: CocoaError(.userCancelled))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("[]".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}
