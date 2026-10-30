//
// TJ fork: Dev log list + receipts (iOS Workshop, Element card).
// Based on Element X iOS. SPDX-License-Identifier: AGPL-3.0-only
//
// Spec: WatchLab/Element/03_ARTIFACTS_SPEC.md rev 3.4, §3.4 (ticket schema + client rules), §5.7 (screens), D8,
// §13.7 (build 4: every failure has its own message, the last tickets stay on screen while it retries with backoff, Retry).
// Native SwiftUI in PodLight DevKit's information architecture (title + 7-step stepper + progress). No DevKit networking:
// tickets are `ai.autopute.devlog.ticket` state events in #tj-devlog, read over REST with the operator's own session.
//

import SwiftUI

// MARK: - Failures (§13.7): one specific message per cause

nonisolated enum ForkDevLogProblem: Equatable, Sendable {
    case offline
    /// E6 stage fix D1: the path is down because TJ Element isn't allowed mobile data / Wi-Fi (Settings → TJ Element), not because
    /// the iPhone is offline.
    case cellularDenied
    case wifiDenied
    case connectionLost
    case timedOut
    case cannotFindHost
    case cannotConnect
    case secureConnection
    case network(code: Int)
    case rateLimited
    case server(status: Int)
    case http(status: Int)
    case badResponse
    case hostChanged
    case roomMissing
    case notJoined
    case sessionExpired
    case notSignedIn
    case unexpected(String)

    /// nil for a cancellation: a cancelled poll throws `CancellationError` or, from URLSession, `URLError(.cancelled)`.
    /// Neither is a failure (build 3 showed "Can't reach the Dev log right now" for the URLSession one).
    static func from(_ error: Error) -> ForkDevLogProblem? {
        if isCancellation(error) { return nil }
        if let rest = error as? ForkMatrixREST.RESTError {
            switch rest {
            case .noSession: return .notSignedIn
            case .hostMismatch: return .hostChanged
            case .sessionExpired: return .sessionExpired
            case .forbidden: return .notJoined
            case .notFound: return .roomMissing
            case .http(429): return .rateLimited
            case .http(let status) where status >= 500: return .server(status: status)
            case .http(let status): return .http(status: status)
            case .badResponse: return .badResponse
            }
        }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive: return .offline
            case .networkConnectionLost: return .connectionLost
            case .timedOut: return .timedOut
            case .cannotFindHost, .dnsLookupFailed: return .cannotFindHost
            case .cannotConnectToHost: return .cannotConnect
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
                 .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
                return .secureConnection
            case .badServerResponse, .cannotParseResponse, .cannotDecodeContentData, .cannotDecodeRawData, .zeroByteResource:
                return .badResponse
            default: return .network(code: url.errorCode)
            }
        }
        let ns = error as NSError
        return .unexpected("\(ns.domain) \(ns.code)")
    }

    /// E6 D1: while the network path is down, any transport error is "offline" (Airplane Mode used to read "took too long").
    static func from(_ error: Error, pathOffline: Bool) -> ForkDevLogProblem? {
        guard let problem = from(error) else { return nil }
        return pathOffline && error is URLError ? .offline : problem
    }

    /// The problem a down network path stands for (nil while online).
    static func from(path: ForkNetworkReach.State) -> ForkDevLogProblem? {
        switch path {
        case .online: nil
        case .offline: .offline
        case .cellularDenied: .cellularDenied
        case .wifiDenied: .wifiDenied
        }
    }

    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    func message(host: String) -> String {
        switch self {
        case .offline: ForkNetworkReach.State.offline.message
        case .cellularDenied: ForkNetworkReach.State.cellularDenied.message
        case .wifiDenied: ForkNetworkReach.State.wifiDenied.message
        case .connectionLost: "The connection to \(host) dropped."
        case .timedOut: "\(host) took too long to answer."
        case .cannotFindHost: "Can't find \(host) (DNS lookup failed)."
        case .cannotConnect: "Can't connect to \(host)."
        case .secureConnection: "The secure connection to \(host) failed."
        case .network(let code): "Network error \(code) talking to \(host)."
        case .rateLimited: "\(host) is rate limiting requests."
        case .server(let status): "\(host) had a server error (HTTP \(status))."
        case .http(let status): "\(host) refused the request (HTTP \(status))."
        case .badResponse: "\(host)'s answer couldn't be read as Matrix data."
        case .hostChanged: "Your homeserver address changed. Close the Dev log and open it again."
        case .roomMissing: "The Dev log room (\(ForkArtifactConstants.devlogAlias)) wasn't found on your server."
        case .notJoined: "You're not in the Dev log room."
        case .sessionExpired: "Your session expired. Reopen TJ Element."
        case .notSignedIn: "No signed-in session on this iPhone, so the Dev log can't be read."
        case .unexpected(let detail): "Unexpected error (\(detail))."
        }
    }

    /// Whether the poll keeps retrying (with backoff) after this failure.
    var retries: Bool {
        switch self {
        case .sessionExpired, .notSignedIn, .notJoined: false
        default: true
        }
    }
}

/// 2 → 4 → 8 → 16 → 32 → 60 s after consecutive failures; the 10 s poll after a success.
nonisolated enum ForkDevLogBackoff {
    static let pollInterval: TimeInterval = 10

    static func delay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return pollInterval }
        return min(60, 2 * pow(2, Double(min(failures, 6) - 1)))
    }
}

/// The last loaded tickets, per user and room (§13.7). Only ticket + power-level + create events are kept, so the §3.2 trust
/// rule re-runs on load. Lives under the artifacts cache's per-user folder, so §5.1's sign-out purge removes it too.
nonisolated struct ForkDevLogCache: Sendable {
    struct Snapshot: Codable, Equatable {
        let savedMS: Int
        let events: [ForkJSON]

        enum CodingKeys: String, CodingKey {
            case savedMS = "saved_ms"
            case events
        }
    }

    let url: URL

    init(userID: String, roomKey: String, base: URL = ForkArtifactCache.baseDirectory) {
        url = base.appending(path: ForkArtifactSHA.prefix16(userID), directoryHint: .isDirectory)
            .appending(path: "devlog-\(ForkArtifactSHA.prefix16(roomKey)).json")
    }

    static func relevant(_ events: [ForkJSON]) -> [ForkJSON] {
        events.filter { event in
            switch event["type"]?.string {
            case ForkArtifactConstants.ticketStateType, "m.room.power_levels", "m.room.create": true
            default: false
            }
        }
    }

    func save(_ events: [ForkJSON], now: Date = Date()) {
        let snapshot = Snapshot(savedMS: Int(now.timeIntervalSince1970 * 1000), events: Self.relevant(events))
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }
}

// MARK: - Model

@Observable
final class ForkDevLogModel {
    enum Phase: Equatable {
        case loading
        case notJoined
        case loaded
        case error(String)
    }

    @ObservationIgnored let rest: ForkMatrixREST
    private(set) var phase: Phase = .loading
    private(set) var tickets: [ForkDevLogTicket] = []
    private(set) var isJoining = false
    /// The current failure; shown above the last tickets (or alone when there are none). nil after a success.
    private(set) var problem: String?
    /// When the next automatic retry runs (nil while polling normally or stopped).
    private(set) var nextRetryAt: Date?
    /// When the tickets on screen were loaded (from the server, or the cache's save time).
    private(set) var loadedAt: Date?
    private(set) var isShowingSaved = false
    private(set) var isRetrying = false
    /// E6 D1: offline per the network path; polling stops and the next path change retries.
    private(set) var isWaitingForNetwork = false
    /// What the banner says while waiting for the path ("Retries when this iPhone is back online.").
    private(set) var waitingLine: String?
    @ObservationIgnored let network: ForkNetworkPath
    @ObservationIgnored private var pathTask: Task<Void, Never>?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var visibleViews = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var roomID: String?
    @ObservationIgnored private var cache: ForkDevLogCache?
    @ObservationIgnored private var host = "your homeserver"

    init(rest: ForkMatrixREST, cacheBase: URL = ForkArtifactCache.baseDirectory, network: ForkNetworkPath = .shared) {
        self.rest = rest
        self.network = network
        let cache = ForkDevLogCache(userID: rest.userID, roomKey: Self.roomKey, base: cacheBase)
        self.cache = cache
        if let snapshot = cache.load() {
            let saved = ForkDevLogIndex.parse(stateEvents: snapshot.events)
            if !saved.isEmpty {
                tickets = saved
                phase = .loaded
                isShowingSaved = true
                loadedAt = Date(timeIntervalSince1970: TimeInterval(snapshot.savedMS) / 1000)
            }
        }
    }

    var pipeline: [ForkDevLogTicket] {
        tickets.filter(\.isInPipeline)
    }

    var history: [ForkDevLogTicket] {
        tickets.filter { !$0.isInPipeline }
    }

    var totals: ForkDevLogTotals {
        ForkDevLogTotals(tickets: tickets)
    }

    /// E6 stage fix D1: a model dropped without `disappeared()` (e.g. its sheet torn down) stops polling and watching the path.
    isolated deinit {
        pollTask?.cancel()
        pathTask?.cancel()
    }

    func ticket(id: String) -> ForkDevLogTicket? {
        tickets.first { $0.id == id }
    }

    /// The list and an open receipt both count, so pushing a receipt keeps the poll running.
    func appeared() {
        visibleViews += 1
        startWatchingNetwork()
        startPolling()
    }

    func disappeared() {
        visibleViews = max(0, visibleViews - 1)
        guard visibleViews == 0 else { return }
        stopPolling()
        pathTask?.cancel()
        pathTask = nil
    }

    /// E6 D1: the path went down → say so now and drop the in-flight request; it came back → fetch at once.
    func networkChanged(offline: Bool) async {
        if offline {
            stopPolling()
            showOffline()
        } else if isWaitingForNetwork || problem != nil {
            isWaitingForNetwork = false
            if visibleViews > 0 { retryNow() } else { await refresh() }
        }
    }

    /// The Retry button: fetch now, then carry on polling.
    func retryNow() {
        stopPolling()
        startPolling()
    }

    /// One fetch. Returns the delay before the next one, or nil when retrying can't help (signed out, expired, not joined).
    @discardableResult
    func refresh() async -> TimeInterval? {
        guard !network.isOffline else {
            showOffline()
            return nil
        }
        isRetrying = problem != nil
        defer { isRetrying = false }
        do {
            #if DEBUG
            // Gate harness only (`-TJDevlogFault offline`): fail every fetch as if offline, to show the saved-tickets banner.
            if UserDefaults.standard.string(forKey: "TJDevlogFault") == "offline" { throw URLError(.notConnectedToInternet) }
            #endif
            let roomID = try await resolvedRoomID()
            let events = try await rest.state(roomID: roomID)
            tickets = ForkDevLogIndex.parse(stateEvents: events)
            cache?.save(events)
            phase = .loaded
            problem = nil
            failures = 0
            isWaitingForNetwork = false
            isShowingSaved = false
            loadedAt = Date()
            return ForkDevLogBackoff.pollInterval
        } catch {
            guard let failure = ForkDevLogProblem.from(error, pathOffline: network.isOffline) else { return ForkDevLogBackoff.pollInterval }
            if failure == .offline, network.isOffline {
                showOffline()
                return nil
            }
            if let pinned = await rest.currentHost() { host = pinned }
            failures += 1
            switch failure {
            case .notJoined where tickets.isEmpty:
                phase = .notJoined
                problem = nil
            default:
                let message = failure.message(host: host)
                problem = message
                if tickets.isEmpty { phase = .error(message) }
            }
            return failure.retries ? ForkDevLogBackoff.delay(afterFailures: failures) : nil
        }
    }

    func join() async {
        isJoining = true
        defer { isJoining = false }
        do {
            roomID = try await rest.join(ForkArtifactConstants.devlogAlias)
            await refresh()
        } catch {
            let failure = ForkDevLogProblem.from(error)
            phase = .error("Couldn't join: \(failure?.message(host: host) ?? "cancelled")")
        }
    }

    // MARK: - Private

    private func showOffline() {
        let state = network.state == .online ? ForkNetworkReach.State.offline : network.state
        let message = (ForkDevLogProblem.from(path: state) ?? .offline).message(host: host)
        problem = message
        waitingLine = state.waitLine
        isWaitingForNetwork = true
        nextRetryAt = nil
        if tickets.isEmpty, phase != .notJoined { phase = .error(message) }
    }

    private func startWatchingNetwork() {
        guard pathTask == nil else { return }
        let changes = network.changes()
        pathTask = Task { [weak self] in
            for await state in changes {
                guard let self else { return }
                await networkChanged(offline: state.isOffline)
            }
        }
    }

    /// The loop holds the model only while a fetch runs, never across the sleep, so a dropped model is freed (and its deinit
    /// cancels the loop).
    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = await self?.pollOnce() else { return }
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    /// One poll step: fetch, then note when the next retry runs. nil stops the loop.
    private func pollOnce() async -> TimeInterval? {
        guard let delay = await refresh() else {
            nextRetryAt = nil
            return nil
        }
        nextRetryAt = problem == nil ? nil : Date().addingTimeInterval(delay)
        return delay
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        nextRetryAt = nil
    }

    private static var roomKey: String {
        #if DEBUG
        if let override = UserDefaults.standard.string(forKey: "TJDevlogRoom"), override.hasPrefix("!") { return override }
        #endif
        return ForkArtifactConstants.devlogAlias
    }

    private func resolvedRoomID() async throws -> String {
        if let roomID { return roomID }
        #if DEBUG
        // Gate harness only (`-TJDevlogRoom <scratch room id>`): render fixture tickets from a scratch room, never #tj-devlog.
        if let override = UserDefaults.standard.string(forKey: "TJDevlogRoom"), override.hasPrefix("!") {
            roomID = override
            return override
        }
        #endif
        let id = try await rest.resolveAlias(ForkArtifactConstants.devlogAlias)
        roomID = id
        return id
    }
}

/// Content only: the sheet wraps it in a NavigationStack; Settings pushes it inside its own stack.
struct ForkDevLogScreen: View {
    let model: ForkDevLogModel
    /// nil in Settings (no room flow), so "Jump to message" is hidden there.
    let jumpToMessage: ((_ eventID: String, _ roomID: String) -> Void)?

    var body: some View {
        List {
            if model.problem != nil || model.isShowingSaved, model.phase == .loaded {
                Section { ForkDevLogStatusBanner(model: model) }
            }
            switch model.phase {
            case .loading:
                HStack { Spacer(); ProgressView(); Spacer() }
            case .notJoined:
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Join the Dev Log room").font(.headline)
                        Text("Tickets and receipts from the workshop live in TJ Dev Log. Join it once to see them here.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button {
                            Task { await model.join() }
                        } label: {
                            if model.isJoining { ProgressView() } else { Text("Join") }
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("tj_devlog-join")
                    }
                    .padding(.vertical, 6)
                }
            case .error:
                Section { ForkDevLogStatusBanner(model: model) }
            case .loaded:
                if model.tickets.isEmpty {
                    Text("No tickets yet.").foregroundStyle(.secondary)
                }
                if let headline = model.totals.headline {
                    Section {
                        Text(headline)
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .accessibilityIdentifier("tj_devlog-total")
                    }
                }
                if !model.pipeline.isEmpty {
                    Section("In the pipeline") {
                        ForEach(model.pipeline) { ticket in
                            NavigationLink {
                                ForkDevLogReceipt(model: model, ticketID: ticket.id, jumpToMessage: jumpToMessage)
                            } label: {
                                ForkDevLogPipelineRow(ticket: ticket)
                            }
                            .accessibilityIdentifier("tj_devlog-ticket_\(ticket.id)")
                        }
                    }
                }
                if !model.history.isEmpty {
                    Section("History") {
                        ForEach(model.history) { ticket in
                            NavigationLink {
                                ForkDevLogReceipt(model: model, ticketID: ticket.id, jumpToMessage: jumpToMessage)
                            } label: {
                                ForkDevLogHistoryRow(ticket: ticket)
                            }
                            .accessibilityIdentifier("tj_devlog-ticket_\(ticket.id)")
                        }
                    }
                }
            }
        }
        .navigationTitle("Dev log")
        .refreshable { await model.refresh() }
        .onAppear { model.appeared() }
        .onDisappear { model.disappeared() }
        .accessibilityIdentifier("tj_devlog-list")
    }
}

/// The reason, how old the tickets on screen are, the next automatic retry, and Retry.
struct ForkDevLogStatusBanner: View {
    let model: ForkDevLogModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let problem = model.problem {
                Label(problem, systemImage: "wifi.exclamationmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("tj_devlog-problem")
            }
            if !model.tickets.isEmpty, let loadedAt = model.loadedAt, model.problem != nil || model.isShowingSaved {
                Text("Showing tickets from \(loadedAt.formatted(date: .omitted, time: .shortened)) (\(loadedAt.formatted(.relative(presentation: .named)))).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("tj_devlog-saved")
            }
            if model.problem != nil {
                HStack {
                    SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                        if model.isRetrying {
                            Text("Retrying…")
                        } else if model.isWaitingForNetwork {
                            Text(model.waitingLine ?? ForkNetworkReach.State.offline.waitLine)
                        } else if let next = model.nextRetryAt {
                            Text("Retrying in \(max(0, Int(next.timeIntervalSince(context.date).rounded(.up)))) s")
                        } else {
                            Text("Not retrying automatically.")
                        }
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry") { model.retryNow() }
                        .buttonStyle(.bordered)
                        .font(.footnote.weight(.semibold))
                        .accessibilityIdentifier("tj_devlog-retry")
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tj_devlog-banner")
    }
}

struct ForkDevLogPipelineRow: View {
    let ticket: ForkDevLogTicket

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ticket.title).font(.headline)
            ForkStageStepper(ticket: ticket)
            HStack {
                if let label = ticket.progress?.label { Text(label) }
                Spacer()
                if let build = ForkDevLogFormat.buildLine(ticket.build) { Text(build).monospacedDigit() }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct ForkDevLogHistoryRow: View {
    let ticket: ForkDevLogTicket

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(ticket.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Spacer()
                ForkStageBadge(stage: ticket.stage)
            }
            ProgressView(value: ForkDevLogFormat.fraction(ticket))
                .tint(ticket.stage == "failed" ? .red : .accentColor)
            HStack {
                if let when = ForkDevLogFormat.historyWhen(ticket) { Text(when) }
                Spacer()
                if let build = ForkDevLogFormat.buildLine(ticket.build) { Text(build).monospacedDigit() }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let cost = ForkDevLogFormat.historyCost(ticket) {
                Text(cost)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("tj_devlog-row-cost")
            }
        }
        .padding(.vertical, 2)
    }
}

struct ForkStageBadge: View {
    let stage: String

    var body: some View {
        let color: Color = switch stage {
        case "delivered": .green
        case "failed": .red
        case "escalated": .orange
        default: .secondary
        }
        Text(stage)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }
}

/// 7 dots: done ✓ filled, current = accent with a pulse, future hollow; escalated amber pause, failed red ✗ (§3.4).
struct ForkStageStepper: View {
    let ticket: ForkDevLogTicket
    @State private var pulse = false

    var body: some View {
        let layout = ForkStageStepperLayout.layout(stage: ticket.stage, stages: ticket.resolvedStages, progressDone: ticket.progress?.done,
                                                   testflight: ticket.build?.testflight)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                ForEach(Array(layout.states.enumerated()), id: \.offset) { index, state in
                    dot(state)
                    if index < layout.states.count - 1 {
                        Rectangle()
                            .fill(state == .done ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(height: 2)
                    }
                }
            }
            HStack(spacing: 4) {
                Text(layout.label).font(.caption.weight(.semibold))
                if let caption = layout.unknownCaption {
                    Text("(\(caption))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Stage \(layout.index + 1) of \(layout.states.count): \(layout.label)")
        .onAppear { pulse = true }
    }

    @ViewBuilder
    private func dot(_ state: ForkStageStepperState) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor).font(.system(size: 14))
        case .current:
            Circle().fill(Color.accentColor).frame(width: 12, height: 12)
                .scaleEffect(pulse ? 1.2 : 0.9)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
        case .future:
            Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1.5).frame(width: 12, height: 12)
        case .escalated:
            Image(systemName: "pause.circle.fill").foregroundStyle(.orange).font(.system(size: 14))
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red).font(.system(size: 14))
        }
    }
}

nonisolated enum ForkDevLogFormat {
    /// E6 D2: "E5 · 202610300709"; "Build 202610300709" before codes; "E6" before a number.
    static func buildLine(_ build: ForkDevLogTicket.Build?) -> String? {
        switch (build?.code, build?.number) {
        case let (code?, number?): "\(code) · \(number)"
        case let (nil, number?): "Build \(number)"
        case let (code?, nil): code
        case (nil, nil): nil
        }
    }

    /// E6 stage fix D2: "Delivered Oct 29, 2026 at 5:52 PM" only from `delivered_ts`; a delivered ticket without it says "Finished"
    /// (no time: `updated_ts` is when it last changed, not when it was delivered); any other stage says "Updated 3 hours ago".
    static func historyWhen(_ ticket: ForkDevLogTicket, now: Date = Date()) -> String? {
        if let delivered = ticket.deliveredMS { return "Delivered \(absolute(delivered))" }
        if ticket.stage == "delivered" { return "Finished" }
        guard let updated = ticket.updatedTS else { return nil }
        return "Updated \(relative(updated, now: now))"
    }

    /// E6 D2 list row: "$0.32 plan · $29.96 API-rate" (nil without a cost block).
    static func historyCost(_ ticket: ForkDevLogTicket) -> String? {
        guard let plan = ticket.cost?.totalMicros else { return nil }
        let estimate = ticket.cost?.totalIsEstimate == true ? " est." : ""
        var line = money(micros: plan) + estimate + " plan"
        if let api = ticket.cost?.apiRateMicros { line += " · \(money(micros: api)) API-rate" }
        return line
    }

    /// Integer micro-USD → dollars, rounding half up to the cent; `$0.0008` style for a non-zero amount under a cent (§13.7), and
    /// "<$0.0001" below that, so a non-zero amount never reads "$0.0000". Total over every `Int` (Int.min included: no `abs` trap).
    static func money(micros: Int) -> String {
        let sign = micros < 0 ? "-" : ""
        let magnitude = micros.magnitude
        if magnitude > 0, magnitude < 10_000 {
            let tenThousandths = (magnitude + 50) / 100
            if tenThousandths == 0 { return micros < 0 ? ">-$0.0001" : "<$0.0001" }
            if tenThousandths < 100 { return "\(sign)$0.\(String(format: "%04d", Int(tenThousandths)))" }
        }
        let cents = (magnitude + 5000) / 10_000
        return "\(sign)$\(grouped(cents / 100)).\(String(format: "%02d", Int(cents % 100)))"
    }

    private static func grouped(_ value: UInt) -> String {
        var digits = String(value)
        var out = ""
        while digits.count > 3 {
            out = "," + digits.suffix(3) + out
            digits.removeLast(3)
        }
        return digits + out
    }

    static func fraction(_ ticket: ForkDevLogTicket) -> Double {
        let total = max(ticket.progress?.total ?? ticket.resolvedStages.count, 1)
        return min(1, max(0, Double(ticket.progress?.done ?? 0) / Double(total)))
    }

    /// "3 hours ago" / "yesterday", relative to `now` (mid-sentence: it follows "Updated").
    static func relative(_ ms: Int, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.formattingContext = .middleOfSentence
        return formatter.localizedString(for: Date(timeIntervalSince1970: TimeInterval(ms) / 1000), relativeTo: now)
    }

    static func absolute(_ ms: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(ms) / 1000).formatted(date: .abbreviated, time: .shortened)
    }

    static func usd(_ value: Double, estimate: Bool) -> String {
        money(value) + (estimate ? " est." : "")
    }

    /// `$%.2f`, but `$%.4f` for a non-zero amount under one cent, so a small run never reads "$0.00" (§13.7).
    static func money(_ value: Double) -> String {
        if value > 0, value < 0.01 { return String(format: "$%.4f", value) }
        return String(format: "$%.2f", value)
    }

    /// "Provisional until …" while `provisional_until` (ms) is still in the future; nil once it has passed.
    static func provisionalLine(_ ms: Int?, now: Date = Date()) -> String? {
        guard let ms else { return nil }
        let until = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        guard until > now else { return nil }
        return "Provisional until \(until.formatted(date: .abbreviated, time: .shortened))"
    }

    static func tokens(_ value: Int?) -> String {
        guard let value else { return "–" }
        return value.formatted(.number.notation(.compactName))
    }
}

/// E6 D2: the Dev log's running total — every ticket's cost block summed in integer micro-USD (no float drift).
nonisolated struct ForkDevLogTotals: Equatable, Sendable {
    let planMicros: Int?
    let apiRateMicros: Int?
    /// Some summed plan cost is an estimate (`total_is_estimate`), so the total is too.
    let includesEstimate: Bool

    /// Never traps: an amount that would overflow the sum is left out (and logged) instead (E6 stage fix S-B1).
    init(tickets: [ForkDevLogTicket]) {
        let priced = tickets.filter { $0.cost?.totalMicros != nil }
        planMicros = ForkMicros.sum(priced.compactMap { $0.cost?.totalMicros }, label: "plan")
        apiRateMicros = ForkMicros.sum(tickets.compactMap { $0.cost?.apiRateMicros }, label: "API-rate")
        includesEstimate = priced.contains { $0.cost?.totalIsEstimate == true }
    }

    /// "Total so far: $5.34 of your plan · $315.23 API-rate" ("$5.34 est." when any part is an estimate; nil until some ticket has a
    /// cost).
    var headline: String? {
        guard let planMicros else { return nil }
        var line = "Total so far: \(ForkDevLogFormat.money(micros: planMicros))\(includesEstimate ? " est." : "") of your plan"
        if let apiRateMicros { line += " · \(ForkDevLogFormat.money(micros: apiRateMicros)) API-rate" }
        return line
    }
}

/// The receipt (§5.7): header, your request (verbatim + Jump), plan (interpretations → open decisions → steps),
/// what shipped, gates, cost & tokens (every number labeled), links.
struct ForkDevLogReceipt: View {
    let model: ForkDevLogModel
    let ticketID: String
    let jumpToMessage: ((_ eventID: String, _ roomID: String) -> Void)?

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if let ticket = model.ticket(id: ticketID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header(ticket)
                    request(ticket)
                    plan(ticket)
                    shipped(ticket)
                    gates(ticket)
                    cost(ticket)
                    links(ticket)
                }
                .padding(16)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { model.appeared() }
            .onDisappear { model.disappeared() }
            .accessibilityIdentifier("tj_devlog-receipt")
        } else {
            ForkArtifactMessage(symbol: "doc.questionmark", title: "Ticket not found", detail: ticketID)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.title3.bold())
    }

    private func header(_ ticket: ForkDevLogTicket) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ticket.title).font(.title.bold())
            ForkStageStepper(ticket: ticket)
            ProgressView(value: ForkDevLogFormat.fraction(ticket)) {
                if let label = ticket.progress?.label { Text(label).font(.caption) }
            }
            HStack(spacing: 6) {
                if let build = ForkDevLogFormat.buildLine(ticket.build) { Text(build).monospacedDigit() }
                if let tf = ticket.build?.testflight { Text(ForkDevLogFormat.buildLine(ticket.build) == nil ? "TestFlight \(tf)" : "· TestFlight \(tf)") }
                Spacer()
                if let delivered = ticket.deliveredMS {
                    Text("Delivered \(ForkDevLogFormat.absolute(delivered))")
                } else if let updated = ticket.updatedTS {
                    Text("Updated \(ForkDevLogFormat.relative(updated))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let note = ticket.statusNote, !note.isEmpty {
                Text(note).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("tj_devlog-receipt-header")
    }

    @ViewBuilder
    private func request(_ ticket: ForkDevLogTicket) -> some View {
        if let request = ticket.request {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Your request")
                quote(request.body ?? "")
                HStack {
                    Text([request.sender, request.ts.map(ForkDevLogFormat.absolute)].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let jumpToMessage, let eventID = request.eventID, let roomID = request.roomID {
                        Button("Jump to message") { jumpToMessage(eventID, roomID) }
                            .font(.footnote.weight(.semibold))
                            .accessibilityIdentifier("tj_devlog-jump")
                    }
                }
                ForEach(Array((request.addenda ?? []).enumerated()), id: \.offset) { index, addendum in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Addendum \(index + 1) · \(addendum.via == "matrix" ? "from Matrix" : "from workshop chat")")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        quote(addendum.body ?? "")
                        if let jumpToMessage, let eventID = addendum.eventID, let roomID = request.roomID {
                            Button("Jump to message") { jumpToMessage(eventID, roomID) }.font(.footnote)
                        }
                    }
                }
            }
        }
    }

    private func quote(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .textSelection(.enabled)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .leading) { Rectangle().fill(Color.accentColor).frame(width: 3) }
    }

    @ViewBuilder
    private func plan(_ ticket: ForkDevLogTicket) -> some View {
        let interpretations = ticket.interpretations ?? []
        let decisions = ticket.decisionsOpen ?? []
        let steps = ticket.plan ?? []
        if !interpretations.isEmpty || !decisions.isEmpty || !steps.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Plan")
                if !interpretations.isEmpty {
                    Text("How we read your request").font(.headline)
                    ForEach(Array(interpretations.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 4) {
                            if let id = item.id { Text(id).font(.caption.weight(.bold)).foregroundStyle(.secondary) }
                            if let words = item.yourWords { Text("Your words: “\(words)”").font(.footnote).italic() }
                            if let reading = item.reading { Text("Our reading: \(reading)").font(.footnote) }
                            if let alternative = item.alternative { Text("Alternative: \(alternative)").font(.footnote).foregroundStyle(.secondary) }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .accessibilityIdentifier("tj_devlog-interpretations")
                }
                if !decisions.isEmpty {
                    Text("Decisions waiting on you").font(.headline).foregroundStyle(.orange)
                    ForEach(Array(decisions.enumerated()), id: \.offset) { _, decision in
                        VStack(alignment: .leading, spacing: 4) {
                            Text([decision.id, decision.question].compactMap { $0 }.joined(separator: ": ")).font(.footnote.weight(.semibold))
                            if let choice = decision.defaultChoice { Text("Default: \(choice)").font(.footnote) }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                if !steps.isEmpty {
                    Text("Steps").font(.headline)
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: Self.stepSymbol(step.status)).foregroundStyle(Self.stepColor(step.status))
                            Text(step.step ?? "").font(.footnote)
                            Spacer()
                            if let lane = step.lane { Text(lane).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule()) }
                        }
                    }
                }
            }
        }
    }

    static func stepSymbol(_ status: String?) -> String {
        switch status {
        case "done": "checkmark.circle.fill"
        case "doing": "circle.dotted.circle"
        case "skipped": "minus.circle"
        default: "circle"
        }
    }

    static func stepColor(_ status: String?) -> Color {
        switch status {
        case "done": .green
        case "doing": .accentColor
        default: .secondary
        }
    }

    @ViewBuilder
    private func shipped(_ ticket: ForkDevLogTicket) -> some View {
        if let items = ticket.items, !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("What shipped")
                if sizeClass == .regular {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Text("Name"); Text("Type"); Text("Status"); Text("F-code"); Text("Note / validation"); Text("$")
                        }
                        .font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            GridRow {
                                Text(item.name ?? "").font(.footnote.weight(.semibold))
                                Text(item.type ?? "").font(.caption)
                                Text(item.status ?? "").font(.caption)
                                Text(item.feature ?? "").font(.caption.monospaced())
                                Text([item.note, item.validation].compactMap { $0 }.joined(separator: " · ")).font(.caption)
                                Text(item.costUSD.map(ForkDevLogFormat.money) ?? "").font(.caption.monospacedDigit())
                            }
                        }
                    }
                } else {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(item.name ?? "").font(.footnote.weight(.semibold))
                                Spacer()
                                if let type = item.type { Text(type).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule()) }
                            }
                            Text([item.status, item.feature, item.costUSD.map(ForkDevLogFormat.money)].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                            if let note = item.note { Text(note).font(.caption) }
                            if let validation = item.validation { Text(validation).font(.caption).foregroundStyle(.secondary) }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func gates(_ ticket: ForkDevLogTicket) -> some View {
        if let gates = ticket.gates, !gates.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Gates")
                ForEach(Array(gates.enumerated()), id: \.offset) { _, gate in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: Self.gateSymbol(gate.result)).foregroundStyle(Self.gateColor(gate.result))
                        VStack(alignment: .leading, spacing: 2) {
                            Text([gate.id, gate.name].compactMap { $0 }.joined(separator: " · ")).font(.footnote.weight(.semibold))
                            if let evidence = gate.evidence { Text(evidence).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        }
                        Spacer()
                        Text(gate.result ?? "pending").font(.caption)
                    }
                }
            }
        }
    }

    static func gateSymbol(_ result: String?) -> String {
        switch result {
        case "pass": "checkmark.seal.fill"
        case "fail": "xmark.octagon.fill"
        case "n/a": "minus.circle"
        default: "clock"
        }
    }

    static func gateColor(_ result: String?) -> Color {
        switch result {
        case "pass": .green
        case "fail": .red
        default: .secondary
        }
    }

    @ViewBuilder
    private func cost(_ ticket: ForkDevLogTicket) -> some View {
        if let cost = ticket.cost {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Cost & tokens")
                if cost.isPartial {
                    Text("Coverage: partial: \(cost.coverageNote ?? "some usage could not be located")")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("tj_devlog-coverage-partial")
                }
                if let total = cost.totalUSD {
                    Text(ForkDevLogFormat.usd(total, estimate: cost.totalIsEstimate == true)).font(.title2.bold().monospacedDigit())
                }
                if let basis = cost.basis { Text(basis).font(.caption).foregroundStyle(.secondary) }
                if let apiRate = cost.apiRateUSD {
                    Text("API-rate equivalent \(ForkDevLogFormat.money(apiRate))")
                        .font(.footnote.monospacedDigit())
                        .accessibilityIdentifier("tj_devlog-cost-api-rate")
                }
                if let note = cost.note, !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("tj_devlog-cost-note")
                }
                if let provisional = ForkDevLogFormat.provisionalLine(cost.provisionalUntil) {
                    Label(provisional, systemImage: "hourglass")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("tj_devlog-cost-provisional")
                }
                if let tokens = cost.tokens {
                    Text("Tokens · input \(ForkDevLogFormat.tokens(tokens.input)) · output \(ForkDevLogFormat.tokens(tokens.output)) · cache read \(ForkDevLogFormat.tokens(tokens.cacheRead)) · cache write \(ForkDevLogFormat.tokens(tokens.cacheWrite))")
                        .font(.caption.monospacedDigit())
                }
                ForEach(Array((cost.runs ?? []).enumerated()), id: \.offset) { _, run in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text([run.kind, run.label].compactMap { $0 }.joined(separator: " · ")).font(.footnote.weight(.semibold))
                            Spacer()
                            Text(run.sourceChip)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(run.source == "result-event" ? Color.green.opacity(0.15) : Color.orange.opacity(0.15), in: Capsule())
                        }
                        Text([run.model,
                              "in \(ForkDevLogFormat.tokens(run.input))",
                              "out \(ForkDevLogFormat.tokens(run.output))",
                              "cache \(ForkDevLogFormat.tokens(run.cacheRead))/\(ForkDevLogFormat.tokens(run.cacheWrite))",
                              run.costUSD.map(ForkDevLogFormat.money),
                              run.apiRateUSD.map { "API \(ForkDevLogFormat.money($0))" },
                              run.durationMS.map { "\($0 / 1000) s" }].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .accessibilityIdentifier("tj_devlog-cost")
        }
    }

    @ViewBuilder
    private func links(_ ticket: ForkDevLogTicket) -> some View {
        if let links = ticket.links, links.spec != nil || links.report != nil {
            VStack(alignment: .leading, spacing: 4) {
                sectionTitle("Links")
                if let spec = links.spec { Text(spec).font(.caption.monospaced()).textSelection(.enabled) }
                if let report = links.report { Text(report).font(.caption.monospaced()).textSelection(.enabled) }
            }
        }
    }
}
