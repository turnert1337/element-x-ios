//
// TJ fork: Dev log reach (R3) + cost display (R2) tests (iOS Workshop, Element card).
// Based on Element X iOS. SPDX-License-Identifier: AGPL-3.0-only
//
// Spec: WatchLab/Element/03_ARTIFACTS_SPEC.md rev 3.4, §13.7; §3.4 rev 3.3 cost fields.
//

@testable import ElementX
import Foundation
import Synchronization
import Testing

struct ForkDevLogReachTests {
    static let oldGeneric = "Can't reach the Dev log right now"

    // MARK: - Error mapping: every cause has its own message

    @Test
    func cancellationIsNotAFailure() {
        #expect(ForkDevLogProblem.from(CancellationError()) == nil)
        #expect(ForkDevLogProblem.from(URLError(.cancelled)) == nil)
        #expect(ForkDevLogProblem.isCancellation(URLError(.cancelled)))
    }

    @Test
    func everyErrorMapsToItsOwnProblem() {
        let table: [(any Error, ForkDevLogProblem)] = [
            (ForkMatrixREST.RESTError.noSession, .notSignedIn),
            (ForkMatrixREST.RESTError.hostMismatch, .hostChanged),
            (ForkMatrixREST.RESTError.sessionExpired, .sessionExpired),
            (ForkMatrixREST.RESTError.forbidden, .notJoined),
            (ForkMatrixREST.RESTError.notFound, .roomMissing),
            (ForkMatrixREST.RESTError.http(429), .rateLimited),
            (ForkMatrixREST.RESTError.http(502), .server(status: 502)),
            (ForkMatrixREST.RESTError.http(418), .http(status: 418)),
            (ForkMatrixREST.RESTError.badResponse, .badResponse),
            (URLError(.notConnectedToInternet), .offline),
            (URLError(.dataNotAllowed), .offline),
            (URLError(.networkConnectionLost), .connectionLost),
            (URLError(.timedOut), .timedOut),
            (URLError(.cannotFindHost), .cannotFindHost),
            (URLError(.dnsLookupFailed), .cannotFindHost),
            (URLError(.cannotConnectToHost), .cannotConnect),
            (URLError(.secureConnectionFailed), .secureConnection),
            (URLError(.serverCertificateUntrusted), .secureConnection),
            (URLError(.badServerResponse), .badResponse),
            (URLError(.resourceUnavailable), .network(code: URLError.Code.resourceUnavailable.rawValue)),
            (CocoaError(.fileReadCorruptFile), .unexpected("NSCocoaErrorDomain \(CocoaError.Code.fileReadCorruptFile.rawValue)"))
        ]
        for (error, expected) in table {
            #expect(ForkDevLogProblem.from(error) == expected, "\(error)")
        }
    }

    @Test
    func messagesAreDistinctNamedAndNeverTheOldGenericOne() {
        let problems: [ForkDevLogProblem] = [.offline, .connectionLost, .timedOut, .cannotFindHost, .cannotConnect, .secureConnection,
                                             .network(code: -1008), .rateLimited, .server(status: 502), .http(status: 418), .badResponse,
                                             .hostChanged, .roomMissing, .notJoined, .sessionExpired, .notSignedIn, .unexpected("X 1")]
        let messages = problems.map { $0.message(host: "matrix.autopute.ai") }
        #expect(Set(messages).count == messages.count)
        #expect(!messages.contains { $0.localizedCaseInsensitiveContains(Self.oldGeneric) })
        for problem in [ForkDevLogProblem.connectionLost, .timedOut, .cannotFindHost, .cannotConnect, .server(status: 503)] {
            #expect(problem.message(host: "matrix.autopute.ai").contains("matrix.autopute.ai"))
        }
        #expect(ForkDevLogProblem.server(status: 502).message(host: "h").contains("502"))
    }

    @Test
    func onlyHopelessFailuresStopRetrying() {
        #expect(!ForkDevLogProblem.sessionExpired.retries)
        #expect(!ForkDevLogProblem.notSignedIn.retries)
        #expect(!ForkDevLogProblem.notJoined.retries)
        #expect(ForkDevLogProblem.connectionLost.retries)
        #expect(ForkDevLogProblem.badResponse.retries)
        #expect(ForkDevLogProblem.server(status: 500).retries)
    }

    @Test
    func backoffDoublesFromTwoToSixtySeconds() {
        #expect((1...8).map { ForkDevLogBackoff.delay(afterFailures: $0) } == [2, 4, 8, 16, 32, 60, 60, 60])
        #expect(ForkDevLogBackoff.delay(afterFailures: 0) == 10)
    }

    // MARK: - Transport, through the real REST client and a scripted server

    @Test
    func htmlInsteadOfJSONIsABadResponseNotAGenericError() async {
        ForkScriptedServer.reset([.respond(200, "<html>autopute</html>")])
        let rest = Self.rest()
        await #expect(throws: ForkMatrixREST.RESTError.badResponse) { _ = try await rest.state(roomID: "!r") }
    }

    @Test
    func aDroppedConnectionIsRetriedOnceForAGet() async throws {
        ForkScriptedServer.reset([.fail(.networkConnectionLost), .respond(200, "[]")])
        let events = try await Self.rest().state(roomID: "!r")
        #expect(events.isEmpty)
        #expect(ForkScriptedServer.requestCount() == 2)
    }

    @Test
    func twoDroppedConnectionsSurfaceAsConnectionLost() async {
        ForkScriptedServer.reset([.fail(.networkConnectionLost), .fail(.networkConnectionLost)])
        do {
            _ = try await Self.rest().state(roomID: "!r")
            Issue.record("expected a failure")
        } catch {
            #expect(ForkDevLogProblem.from(error) == .connectionLost)
        }
    }

    // MARK: - Model: cached tickets stay on screen while it retries

    @Test
    func failureWithoutCacheShowsTheSpecificReason() async throws {
        let base = Self.tempBase()
        ForkScriptedServer.reset([.respond(502, "{}"), .respond(502, "{}")])
        let model = ForkDevLogModel(rest: Self.rest(), cacheBase: base)
        let delay = await model.refresh()
        #expect(delay == 2)
        #expect(model.phase == .error("matrix.example.org had a server error (HTTP 502)."))
        #expect(model.problem == "matrix.example.org had a server error (HTTP 502).")
        #expect(await model.refresh() == 4)
    }

    @Test
    func cachedTicketsStayWhileTheServerIsDown() async throws {
        let base = Self.tempBase()
        // 1. A good fetch fills the cache.
        ForkScriptedServer.reset([.respond(200, "{\"room_id\":\"!dev\"}"), .respond(200, Self.stateJSON)])
        let first = ForkDevLogModel(rest: Self.rest(), cacheBase: base)
        #expect(await first.refresh() == 10)
        #expect(first.tickets.map(\.id) == ["T-1"])

        // 2. A new screen (fresh model) while the server is down: the saved tickets show with the reason and a retry time.
        ForkScriptedServer.reset([.respond(200, "{\"room_id\":\"!dev\"}"), .fail(.notConnectedToInternet)])
        let second = ForkDevLogModel(rest: Self.rest(), cacheBase: base)
        #expect(second.isShowingSaved)
        #expect(second.tickets.map(\.id) == ["T-1"])
        #expect(second.phase == .loaded)
        #expect(await second.refresh() == 2)
        #expect(second.phase == .loaded)
        #expect(second.tickets.map(\.id) == ["T-1"])
        #expect(second.problem == "This iPhone is offline.")
    }

    @Test
    func signedOutStopsRetryingWithItsOwnMessage() async {
        let rest = ForkMatrixREST(userID: "@nobody:example.org") { _ in nil }
        let model = ForkDevLogModel(rest: rest, cacheBase: Self.tempBase())
        #expect(await model.refresh() == nil)
        #expect(model.problem == ForkDevLogProblem.notSignedIn.message(host: "your homeserver"))
    }

    @Test
    func cacheKeepsOnlyTrustRelevantEventsAndReRunsTheTrustRule() throws {
        let cache = ForkDevLogCache(userID: "@u:x", roomKey: "#tj-devlog:x", base: Self.tempBase())
        let untrusted = ForkJSON.object(["type": .string(ForkArtifactConstants.ticketStateType), "state_key": .string("T-2"),
                                         "sender": .string("@stranger:x"), "content": Self.ticketContent(id: "T-2")])
        let member = ForkJSON.object(["type": .string("m.room.member"), "state_key": .string("@u:x"), "sender": .string("@u:x"),
                                      "content": .object(["membership": .string("join")])])
        let events = try #require(try ForkJSON.decode(Data(Self.stateJSON.utf8)).array) + [untrusted, member]
        cache.save(events, now: Date(timeIntervalSince1970: 1_793_300_000))
        let snapshot = try #require(cache.load())
        #expect(snapshot.savedMS == 1_793_300_000_000)
        #expect(!snapshot.events.contains { $0["type"]?.string == "m.room.member" })
        #expect(ForkDevLogIndex.parse(stateEvents: snapshot.events).map(\.id) == ["T-1"])
    }

    // MARK: - R2: rev 3.3 cost fields, from the real build-3 ticket

    nonisolated static let realTicketPath = "/Users/turnertomlinson/CommandCenter/WatchLab/WatchLab/Element/artifacts/tickets/T-20261029-0623-artifacts.json"

    /// Read from the workshop checkout (not copied into the public fork: it holds the operator's verbatim request).
    @Test(.enabled(if: FileManager.default.fileExists(atPath: realTicketPath), "needs the workshop checkout"))
    func realTicketDecodesTheProratedAndAPIRateCosts() throws {
        let content = try ForkJSON.decode(Data(contentsOf: URL(fileURLWithPath: Self.realTicketPath)))
        let ticket = try #require(ForkDevLogTicket.parse(content: content))
        let cost = try #require(ticket.cost)
        #expect(cost.totalUSD == 1.94785)
        #expect(cost.apiRateUSD == 156.725005)
        #expect(cost.note?.hasPrefix("Only Claude Code usage on the dev Mac is visible") == true)
        #expect(cost.provisionalUntil == 1_793_336_400_000)
        let runs = try #require(cost.runs)
        #expect(runs.count == 10)
        #expect(runs.compactMap(\.apiRateUSD).count == runs.count)
        let microsTotal = runs.compactMap(\.costUSD).reduce(0, +)
        #expect(abs(microsTotal - 1.94785) < 0.000_001)
        let smallest = try #require(runs.compactMap(\.costUSD).min())
        #expect(smallest < 0.01)
        #expect(ForkDevLogFormat.money(smallest) != "$0.00")
        #expect(ForkDevLogFormat.money(smallest).hasPrefix("$0.00"))
    }

    @Test
    func moneyNeverRoundsASmallRunToZero() {
        #expect(ForkDevLogFormat.money(0.000836) == "$0.0008")
        #expect(ForkDevLogFormat.money(0.00179) == "$0.0018")
        #expect(ForkDevLogFormat.money(0.0099) == "$0.0099")
        #expect(ForkDevLogFormat.money(0.01) == "$0.01")
        #expect(ForkDevLogFormat.money(1.94785) == "$1.95")
        #expect(ForkDevLogFormat.money(0) == "$0.00")
        #expect(ForkDevLogFormat.usd(1.94785, estimate: true) == "$1.95 est.")
    }

    @Test
    func provisionalLineShowsOnlyWhileInTheFuture() {
        let now = Date(timeIntervalSince1970: 1_793_300_000)
        #expect(ForkDevLogFormat.provisionalLine(1_793_336_400_000, now: now)?.hasPrefix("Provisional until ") == true)
        #expect(ForkDevLogFormat.provisionalLine(1_793_200_000_000, now: now) == nil)
        #expect(ForkDevLogFormat.provisionalLine(nil, now: now) == nil)
    }

    @Test
    func olderTicketsWithoutTheNewFieldsStillDecode() throws {
        let ticket = try #require(ForkDevLogTicket.parse(content: Self.ticketContent(id: "T-9")))
        #expect(ticket.cost?.apiRateUSD == nil)
        #expect(ticket.cost?.note == nil)
        #expect(ticket.cost?.provisionalUntil == nil)
        #expect(ticket.cost?.runs?.first?.apiRateUSD == nil)
    }

    // MARK: - Helpers

    static func rest() -> ForkMatrixREST {
        ForkMatrixREST(userID: "@tjtest:example.org",
                       credentialsProvider: { _ in ForkSessionCredentials(accessToken: "stub-token", homeserverURL: URL(string: "https://matrix.example.org")!) },
                       protocolClasses: [ForkScriptedServer.self])
    }

    static func tempBase() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "TJDevLogTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    static func ticketContent(id: String) -> ForkJSON {
        .object(["v": .number(1), "id": .string(id), "title": .string("Ticket \(id)"), "stage": .string("building"), "updated_ts": .number(1),
                 "cost": .object(["total_usd_micros": .number(4_210_000),
                                  "runs": .array([.object(["kind": .string("steward"), "cost_usd_micros": .number(4_210_000)])])])])
    }

    static var stateJSON: String {
        let create = #"{"type":"m.room.create","state_key":"","sender":"@tjtest:example.org","content":{"room_version":"12"}}"#
        let levels = #"{"type":"m.room.power_levels","state_key":"","sender":"@tjtest:example.org","content":{"events":{"ai.autopute.devlog.ticket":50},"users":{"@turner:example.org":100}}}"#
        let ticket = #"{"type":"ai.autopute.devlog.ticket","state_key":"T-1","sender":"@tjtest:example.org","content":{"v":1,"id":"T-1","title":"One","stage":"building"}}"#
        return "[\(create),\(levels),\(ticket)]"
    }
}

/// E6 D1 (Test Round 1, step c2): in Airplane Mode the Dev log said "matrix.autopute.ai took too long to answer". The network path
/// (NWPathMonitor) decides "offline" now, before and regardless of what a request error says.
struct ForkDevLogOfflineTests {
    @Test
    func pathStatusMapsToOffline() {
        #expect(ForkNetworkReach.isOffline(.unsatisfied))
        #expect(!ForkNetworkReach.isOffline(.satisfied))
        #expect(!ForkNetworkReach.isOffline(.requiresConnection)) // e.g. VPN on demand: let the request try
    }

    @Test
    func anyTransportErrorWhileThePathIsDownIsOffline() {
        #expect(ForkDevLogProblem.from(URLError(.timedOut), pathOffline: true) == .offline)
        #expect(ForkDevLogProblem.from(URLError(.cannotFindHost), pathOffline: true) == .offline)
        #expect(ForkDevLogProblem.from(URLError(.timedOut), pathOffline: false) == .timedOut)
        #expect(ForkDevLogProblem.from(ForkMatrixREST.RESTError.noSession, pathOffline: true) == .notSignedIn)
        #expect(ForkDevLogProblem.from(URLError(.cancelled), pathOffline: true) == nil)
    }

    @Test
    func offlinePathFailsAtOnceWithoutARequest() async {
        ForkScriptedServer.reset([.respond(200, "{\"room_id\":\"!dev\"}"), .respond(200, ForkDevLogReachTests.stateJSON)])
        let network = ForkNetworkPath(monitoring: false)
        network.update(offline: true)
        let model = ForkDevLogModel(rest: ForkDevLogReachTests.rest(), cacheBase: ForkDevLogReachTests.tempBase(), network: network)
        let started = Date()
        let delay = await model.refresh()
        #expect(Date().timeIntervalSince(started) < 1)
        #expect(ForkScriptedServer.requestCount() == 0)
        #expect(delay == nil) // no backoff polling: the path change brings it back
        #expect(model.problem == "This iPhone is offline.")
        #expect(model.isWaitingForNetwork)
    }

    @Test
    func comingBackOnlineRecoversByItself() async {
        ForkScriptedServer.reset([.respond(200, "{\"room_id\":\"!dev\"}"), .respond(200, ForkDevLogReachTests.stateJSON)])
        let network = ForkNetworkPath(monitoring: false)
        network.update(offline: true)
        let model = ForkDevLogModel(rest: ForkDevLogReachTests.rest(), cacheBase: ForkDevLogReachTests.tempBase(), network: network)
        await model.refresh()
        #expect(model.problem == "This iPhone is offline.")
        network.update(offline: false)
        await model.networkChanged(offline: false)
        #expect(model.problem == nil)
        #expect(!model.isWaitingForNetwork)
        #expect(model.tickets.map(\.id) == ["T-1"])
    }

    @Test
    func goingOfflineShowsTheBannerImmediately() async {
        ForkScriptedServer.reset([.respond(200, "{\"room_id\":\"!dev\"}"), .respond(200, ForkDevLogReachTests.stateJSON)])
        let network = ForkNetworkPath(monitoring: false)
        let model = ForkDevLogModel(rest: ForkDevLogReachTests.rest(), cacheBase: ForkDevLogReachTests.tempBase(), network: network)
        #expect(await model.refresh() == 10)
        network.update(offline: true)
        await model.networkChanged(offline: true)
        #expect(model.problem == "This iPhone is offline.")
        #expect(model.phase == .loaded)                 // the tickets stay on screen
        #expect(model.tickets.map(\.id) == ["T-1"])
        #expect(model.nextRetryAt == nil)
    }

    @Test
    func requestsFailFastInsteadOfWaitingForConnectivity() async {
        // The session the client really uses (not a constant beside it): no waiting for a network, 20 s per request.
        let policy = await ForkDevLogReachTests.rest().connectivityPolicy()
        #expect(policy.waitsForConnectivity == false)
        #expect(policy.requestTimeout == 20)
    }

    // MARK: - E6 stage fix (D1 review): denied ≠ offline, path order, no leaked watchers

    @Test
    func deniedPathsNameThePermissionNotOffline() {
        #expect(ForkNetworkReach.state(status: .unsatisfied, reason: .cellularDenied) == .cellularDenied)
        #expect(ForkNetworkReach.state(status: .unsatisfied, reason: .wifiDenied) == .wifiDenied)
        #expect(ForkNetworkReach.state(status: .unsatisfied, reason: .notAvailable) == .offline)
        #expect(ForkNetworkReach.state(status: .satisfied, reason: .notAvailable) == .online)
        #expect(ForkNetworkReach.state(status: .requiresConnection, reason: .notAvailable) == .online)
        #expect(ForkNetworkReach.State.cellularDenied.message == "TJ Element isn't allowed to use mobile data. Check Settings → TJ Element.")
        #expect(ForkNetworkReach.State.wifiDenied.message == "TJ Element isn't allowed to use Wi-Fi. Check Settings → TJ Element.")
        #expect(ForkNetworkReach.State.offline.message == "This iPhone is offline.")
    }

    @Test
    func mobileDataDeniedSaysSoInsteadOfOffline() async {
        ForkScriptedServer.reset([.respond(200, "{\"room_id\":\"!dev\"}"), .respond(200, ForkDevLogReachTests.stateJSON)])
        let network = ForkNetworkPath(monitoring: false)
        network.update(.cellularDenied)
        let model = ForkDevLogModel(rest: ForkDevLogReachTests.rest(), cacheBase: ForkDevLogReachTests.tempBase(), network: network)
        #expect(await model.refresh() == nil)
        #expect(model.problem == "TJ Element isn't allowed to use mobile data. Check Settings → TJ Element.")
        #expect(model.waitingLine == "Retries when TJ Element is allowed to use the network.")
        network.update(.offline)
        await model.networkChanged(offline: true)
        #expect(model.problem == "This iPhone is offline.")
        #expect(model.waitingLine == "Retries when this iPhone is back online.")
    }

    @Test
    func scheduleWordsNameADeniedPermission() {
        #expect(ForkScheduleModel.words(for: URLError(.timedOut), network: .wifiDenied) == "TJ Element isn't allowed to use Wi-Fi. Check Settings → TJ Element.")
        #expect(ForkScheduleModel.words(for: URLError(.timedOut), network: .offline) == "This iPhone is offline.")
        #expect(ForkScheduleModel.words(for: URLError(.notConnectedToInternet), network: .online) == "This iPhone is offline.")
    }

    @Test
    func pathChangesArriveInTheOrderTheyHappened() async {
        let network = ForkNetworkPath(monitoring: false)
        let changes = network.changes()
        var iterator = changes.makeAsyncIterator()
        network.update(.offline)
        #expect(await iterator.next() == .offline)
        network.update(.cellularDenied)
        #expect(await iterator.next() == .cellularDenied)
        network.update(.online)
        #expect(await iterator.next() == .online)
        #expect(network.state == .online)
    }

    @Test
    func aDroppedModelStopsWatchingThePath() async throws {
        let network = ForkNetworkPath(monitoring: false)
        network.update(.offline) // the poll ends at once: no request, nothing scripted needed
        var model: ForkDevLogModel? = ForkDevLogModel(rest: ForkDevLogReachTests.rest(), cacheBase: ForkDevLogReachTests.tempBase(), network: network)
        weak let dropped = model
        model?.appeared()
        #expect(network.observerCount == 1)
        try await Task.sleep(for: .milliseconds(300))
        model = nil
        for _ in 0..<60 where dropped != nil || network.observerCount > 0 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(dropped == nil)
        #expect(network.observerCount == 0) // the model's path task was cancelled with it
    }
}

/// E6 D2 (Test Round 1, steps c1 + r2): build codes, delivery time, plan + API-rate cost per finished ticket, the running total,
/// and an honest label when a build is already on TestFlight waiting for the operator's check.
struct ForkDevLogMoneyTests {
    static func ticket(_ id: String, stage: String = "delivered", micros: Int? = nil, apiMicros: Int? = nil, build: [String: ForkJSON]? = nil,
                       updated: Int = 1_793_327_379_262, delivered: Int? = nil) -> ForkDevLogTicket {
        var object: [String: ForkJSON] = ["v": .number(1), "id": .string(id), "title": .string(id), "stage": .string(stage), "updated_ts": .number(Double(updated))]
        var cost: [String: ForkJSON] = [:]
        if let micros { cost["total_usd_micros"] = .number(Double(micros)) }
        if let apiMicros { cost["api_rate_usd_micros"] = .number(Double(apiMicros)) }
        if !cost.isEmpty { object["cost"] = .object(cost) }
        if let build { object["build"] = .object(build) }
        if let delivered { object["delivered_ts"] = .number(Double(delivered)) }
        return ForkDevLogTicket.parse(content: .object(object))!
    }

    @Test
    func buildLineUsesTheCodeWhenPresent() {
        let coded = Self.ticket("T-5", build: ["number": .string("202610300709"), "code": .string("E5"), "testflight": .string("VALID")])
        #expect(coded.build?.code == "E5")
        #expect(ForkDevLogFormat.buildLine(coded.build) == "E5 · 202610300709")
        #expect(ForkDevLogFormat.buildLine(Self.ticket("T-4", build: ["number": .string("202610300213")]).build) == "Build 202610300213")
        #expect(ForkDevLogFormat.buildLine(Self.ticket("T-6", build: ["code": .string("E6")]).build) == "E6")
        #expect(ForkDevLogFormat.buildLine(Self.ticket("T-7", build: ["code": .number(6)]).build) == nil) // wrong type: hidden, still decodes
        #expect(ForkDevLogFormat.buildLine(nil) == nil)
    }

    @Test
    func deliveredTimeComesOnlyFromDeliveredTS() {
        #expect(Self.ticket("T-1", delivered: 1_793_314_371_739).deliveredMS == 1_793_314_371_739)
        // updated_ts is when the ticket last changed, not when it was delivered: no delivery time without delivered_ts.
        #expect(Self.ticket("T-2", updated: 1_793_330_438_837).deliveredMS == nil)
        #expect(Self.ticket("T-3", stage: "processing").deliveredMS == nil)
        #expect(Self.ticket("T-4", stage: "failed", delivered: 1_793_314_371_739).deliveredMS == nil)
        let now = Date(timeIntervalSince1970: 1_793_340_000)
        #expect(ForkDevLogFormat.historyWhen(Self.ticket("T-1", delivered: 1_793_314_371_739), now: now)?.hasPrefix("Delivered ") == true)
        #expect(ForkDevLogFormat.historyWhen(Self.ticket("T-2", updated: 1_793_330_438_837), now: now) == "Finished")
        let failed = ForkDevLogFormat.historyWhen(Self.ticket("T-4", stage: "failed", updated: 1_793_330_438_837), now: now)
        #expect(failed?.hasPrefix("Updated ") == true)
        #expect(failed?.contains("Delivered") == false)
    }

    @Test
    func headerSaysEstimateWhenAnySummedCostIsOne() throws {
        let content = ForkJSON.object(["v": .number(1), "id": .string("T-E"), "title": .string("E"), "stage": .string("delivered"),
                                       "cost": .object(["total_usd_micros": .number(1_041_830), "api_rate_usd_micros": .number(82_377_554),
                                                        "total_is_estimate": .bool(true)])])
        let estimated = try #require(ForkDevLogTicket.parse(content: content))
        let measured = Self.ticket("M", micros: 318_984, apiMicros: 29_962_136)
        #expect(ForkDevLogTotals(tickets: [estimated, measured]).headline == "Total so far: $1.36 est. of your plan · $112.34 API-rate")
        #expect(ForkDevLogTotals(tickets: [measured]).headline == "Total so far: $0.32 of your plan · $29.96 API-rate")
    }

    // MARK: - E6 stage fix (S-B1): hostile numbers never crash the Dev log

    static func rawTicket(_ id: String, cost: String) throws -> ForkDevLogTicket {
        let json = #"{"v":1,"id":"\#(id)","title":"\#(id)","stage":"delivered","cost":\#(cost)}"#
        return try JSONDecoder().decode(ForkDevLogTicket.self, from: Data(json.utf8))
    }

    @Test(arguments: ["nan", "NaN", "inf", "-inf", "infinity", "1e20", "-1e20"])
    func hostileLegacyDollarsAreDroppedNotTrapped(_ text: String) throws {
        let issues = ForkDecodeIssues()
        let content = ForkJSON.object(["v": .number(1), "id": .string("T-H"), "title": .string("H"), "stage": .string("delivered"),
                                       "cost": .object(["total_usd": .string(text)])])
        let ticket = try #require(ForkDevLogTicket.parse(content: content, issues: issues))
        #expect(ticket.cost?.totalMicros == nil)
        #expect(ticket.cost?.totalUSD == nil) // the receipt never shows "$nan" or a number the list can't sum
        #expect(ForkDevLogTotals(tickets: [ticket]).headline == nil)
        #expect(ForkDevLogFormat.historyCost(ticket) == nil)
        #expect(issues.paths == ["cost.total_usd"])
    }

    @Test
    func aSumThatWouldOverflowDropsTheValueInsteadOfTrapping() throws {
        let big = try Self.rawTicket("A", cost: #"{"total_usd_micros":9223372036854775797,"api_rate_usd_micros":9223372036854775000}"#)
        let bigger = try Self.rawTicket("B", cost: #"{"total_usd_micros":9223372036854775787,"api_rate_usd_micros":9223372036854775000}"#)
        #expect(big.cost?.totalMicros == 9_223_372_036_854_775_797)
        let totals = ForkDevLogTotals(tickets: [big, bigger, Self.ticket("C", micros: 1_000_000)])
        #expect(totals.planMicros == 9_223_372_036_854_775_797) // B and C would overflow: dropped
        #expect(totals.apiRateMicros == 9_223_372_036_854_775_000)
        #expect(totals.headline == "Total so far: $9,223,372,036,854.78 of your plan · $9,223,372,036,854.78 API-rate")
        let negative = try Self.rawTicket("N", cost: #"{"total_usd_micros":-9223372036854775808}"#)
        #expect(ForkDevLogFormat.money(micros: negative.cost?.totalMicros ?? 0) == "-$9,223,372,036,854.78")
        #expect(ForkDevLogTotals(tickets: [negative, Self.ticket("D", micros: -1)]).planMicros == Int.min)
    }

    @Test
    func wrongTypesAreReportedNotSilentlyDropped() throws {
        let issues = ForkDecodeIssues()
        let content = ForkJSON.object(["v": .number(1), "id": .string("T-W"), "title": .string("W"), "stage": .string("delivered"),
                                       "delivered_ts": .string("yesterday"),
                                       "build": .object(["number": .number(202_610_300_709), "code": .string("E6")]),
                                       "cost": .object(["total_usd_micros": .string("1000"), "api_rate_usd_micros": .bool(true),
                                                        "total_usd": .object([:])])])
        let ticket = try #require(ForkDevLogTicket.parse(content: content, issues: issues))
        #expect(ticket.build?.code == "E6")      // the good fields still show
        #expect(ticket.build?.number == nil)
        #expect(ticket.cost?.totalMicros == nil)
        #expect(Set(issues.paths) == ["delivered_ts", "build.number", "cost.total_usd_micros", "cost.api_rate_usd_micros", "cost.total_usd"])

        let blockIssues = ForkDecodeIssues()
        let badBlock = ForkJSON.object(["v": .number(1), "id": .string("T-B"), "title": .string("B"), "stage": .string("building"),
                                        "build": .string("E6")])
        #expect(try #require(ForkDevLogTicket.parse(content: badBlock, issues: blockIssues)).build?.code == nil)
        #expect(blockIssues.paths == ["build"])

        // A block that can't decode at all still drops the ticket (as before), but says so.
        let costIssues = ForkDecodeIssues()
        let badCost = ForkJSON.object(["v": .number(1), "id": .string("T-C"), "title": .string("C"), "stage": .string("building"),
                                       "cost": .string("$4.21")])
        #expect(ForkDevLogTicket.parse(content: badCost, issues: costIssues) == nil)
        #expect(costIssues.paths == ["cost"])

        // Absent or null fields are not problems.
        let quiet = ForkDecodeIssues()
        let plain = ForkJSON.object(["v": .number(1), "id": .string("T-Q"), "title": .string("Q"), "stage": .string("building"),
                                     "delivered_ts": .null, "build": .null, "cost": .object(["total_usd_micros": .null])])
        #expect(ForkDevLogTicket.parse(content: plain, issues: quiet) != nil)
        #expect(quiet.paths.isEmpty)
    }

    @Test
    func totalsAreIntegerMicroDollars() {
        // The five priced tickets on #tj-devlog at E5 (one, devlog-reach, has no cost block).
        let tickets = [Self.ticket("A", micros: 1_041_830, apiMicros: 82_377_554), Self.ticket("B", micros: 1_947_850, apiMicros: 156_725_005),
                       Self.ticket("C", micros: 318_984, apiMicros: 29_962_136), Self.ticket("D", micros: 31_855, apiMicros: 2_992_122),
                       Self.ticket("E"), Self.ticket("F", stage: "processing", micros: 1_995_059, apiMicros: 43_176_296)]
        let total = ForkDevLogTotals(tickets: tickets)
        #expect(total.planMicros == 5_335_578)
        #expect(total.apiRateMicros == 315_233_113)
        #expect(total.headline == "Total so far: $5.34 of your plan · $315.23 API-rate")
        // No float drift: three thirds of a dollar are a dollar, not $0.99 or $1.0000001.
        let thirds = ForkDevLogTotals(tickets: (0..<3).map { Self.ticket("T\($0)", micros: 333_334) })
        #expect(thirds.planMicros == 1_000_002)
        #expect(thirds.headline == "Total so far: $1.00 of your plan")
        #expect(ForkDevLogTotals(tickets: [Self.ticket("E")]).headline == nil)
    }

    @Test
    func legacyDollarTotalsJoinTheSumAsMicros() {
        let content = ForkJSON.object(["v": .number(1), "id": .string("T-L"), "title": .string("L"), "stage": .string("delivered"),
                                       "cost": .object(["total_usd": .string("$4.21")])])
        let ticket = ForkDevLogTicket.parse(content: content)!
        #expect(ticket.cost?.totalMicros == 4_210_000)
        #expect(ForkDevLogTotals(tickets: [ticket]).planMicros == 4_210_000)
    }

    @Test
    func microMoneyFormatting() {
        #expect(ForkDevLogFormat.money(micros: 0) == "$0.00")
        #expect(ForkDevLogFormat.money(micros: 836) == "$0.0008")
        #expect(ForkDevLogFormat.money(micros: 10_000) == "$0.01")
        #expect(ForkDevLogFormat.money(micros: 1_005_000) == "$1.01")     // half a cent rounds up
        #expect(ForkDevLogFormat.money(micros: 1_004_999) == "$1.00")
        #expect(ForkDevLogFormat.money(micros: 12_345_678_900) == "$12,345.68")
        // Non-zero but under a ten-thousandth of a dollar: never "$0.0000".
        #expect(ForkDevLogFormat.money(micros: 1) == "<$0.0001")
        #expect(ForkDevLogFormat.money(micros: 49) == "<$0.0001")
        #expect(ForkDevLogFormat.money(micros: 50) == "$0.0001")
        #expect(ForkDevLogFormat.money(micros: -1) == ">-$0.0001")
    }

    @Test
    func finishedRowShowsDeliveryPlanAndAPIRate() {
        let row = ForkDevLogFormat.historyCost(Self.ticket("T", micros: 318_984, apiMicros: 29_962_136))
        #expect(row == "$0.32 plan · $29.96 API-rate")
        #expect(ForkDevLogFormat.historyCost(Self.ticket("T", micros: 31_855)) == "$0.03 plan")
        #expect(ForkDevLogFormat.historyCost(Self.ticket("T")) == nil)
    }

    @Test
    func processingWithAValidTestFlightBuildWaitsOnTheOperator() {
        let valid = ForkStageStepperLayout.layout(stage: "processing", stages: [], progressDone: 6, testflight: "VALID")
        #expect(valid.label == "On TestFlight · your check")
        #expect(ForkStageStepperLayout.layout(stage: "processing", stages: [], progressDone: 6, testflight: nil).label == "Processing")
        #expect(ForkStageStepperLayout.layout(stage: "processing", stages: [], progressDone: 6, testflight: "PROCESSING").label == "Processing")
        #expect(ForkStageStepperLayout.layout(stage: "delivered", stages: [], progressDone: 7, testflight: "VALID").label == "Delivered")
    }
}

/// A scripted homeserver: each request takes the next step (a status + body, or a transport error); the last step repeats.
nonisolated final class ForkScriptedServer: URLProtocol {
    enum Step: Sendable {
        case respond(Int, String)
        case fail(URLError.Code)
    }

    private static let state = Mutex((steps: [Step](), count: 0))

    static func reset(_ steps: [Step]) {
        state.withLock { $0 = (steps: steps, count: 0) }
    }

    static func requestCount() -> Int {
        state.withLock { $0.count }
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let step = Self.state.withLock { state -> Step in
            let index = min(state.count, max(state.steps.count - 1, 0))
            state.count += 1
            return state.steps.isEmpty ? .respond(200, "[]") : state.steps[index]
        }
        switch step {
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .respond(let status, let body):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() { }
}
