//
// TJ fork: per-room Artifacts model + per-user store (iOS Workshop, Element card).
// Based on Element X iOS. SPDX-License-Identifier: AGPL-3.0-only
//
// Spec: WatchLab/Element/03_ARTIFACTS_SPEC.md rev 3, §5.1 ("Per-user state"), §5.3, §5.4 (fetch, cache, polling,
// D16 reload), §5.5 (Timer finish driven by the model), §5.6 (draft survives a fold).
// The model outlives every view: selection, web views (via the pool), the Timer and the New-artifact draft live here,
// so push <-> split <-> full screen and a fold never reset anything.
//

import AudioToolbox
import Foundation
import SwiftUI
import UIKit

// MARK: - On-disk cache (per user + room)

nonisolated struct ForkArtifactCache: Sendable {
    let root: URL

    static var baseDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return caches.appending(path: "TJArtifacts", directoryHint: .isDirectory)
    }

    init(userID: String, roomID: String, base: URL = ForkArtifactCache.baseDirectory) {
        root = base.appending(path: ForkArtifactSHA.prefix16(userID), directoryHint: .isDirectory)
            .appending(path: ForkArtifactSHA.prefix16(roomID), directoryHint: .isDirectory)
    }

    func htmlURL(aid: String, version: Int, sha256: String) -> URL {
        root.appending(path: aid, directoryHint: .isDirectory).appending(path: "\(version)-\(sha256).html")
    }

    /// Both parts land in a file path, so a value that could leave the cache folder is never used (parse already refuses it).
    static func isSafeKey(aid: String, sha256: String) -> Bool {
        ForkArtifactConstants.isValidAID(aid) && ForkArtifactSHA.isValidHex(sha256)
    }

    /// Verified read: a sha mismatch deletes the file and returns nil.
    func read(aid: String, version: Int, sha256: String) -> Data? {
        guard Self.isSafeKey(aid: aid, sha256: sha256) else { return nil }
        let url = htmlURL(aid: aid, version: version, sha256: sha256)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard ForkArtifactSHA.matches(data, expected: sha256) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return data
    }

    /// Writes verified bytes and keeps the 2 newest versions of the aid.
    func write(_ data: Data, aid: String, version: Int, sha256: String) throws {
        guard Self.isSafeKey(aid: aid, sha256: sha256) else { throw CocoaError(.fileWriteInvalidFileName) }
        let url = htmlURL(aid: aid, version: version, sha256: sha256)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        let folder = url.deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let versioned = files.compactMap { file -> (Int, URL)? in
            guard let number = Int(file.lastPathComponent.split(separator: "-").first ?? "") else { return nil }
            return (number, file)
        }.sorted { $0.0 > $1.0 }
        for (_, stale) in versioned.dropFirst(2) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    var indexURL: URL {
        root.appending(path: "index.json")
    }

    func saveIndex(_ events: [ForkJSON]) {
        guard let data = try? JSONEncoder().encode(events) else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: indexURL, options: .atomic)
    }

    func loadIndex() -> [ForkJSON]? {
        guard let data = try? Data(contentsOf: indexURL) else { return nil }
        return try? JSONDecoder().decode([ForkJSON].self, from: data)
    }

    /// Deletes cache folders and Timer keys of users that are no longer signed in (§5.1).
    static func purge(keepingUserIDs userIDs: Set<String>, base: URL = ForkArtifactCache.baseDirectory, defaults: UserDefaults = .standard) {
        let keep = Set(userIDs.map(ForkArtifactSHA.prefix16))
        let folders = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where !keep.contains(folder.lastPathComponent) {
            try? FileManager.default.removeItem(at: folder)
        }
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(ForkTimerStorage.prefix) {
            let userHash = key.dropFirst(ForkTimerStorage.prefix.count).split(separator: ".").first.map(String.init) ?? ""
            if !keep.contains(userHash) { defaults.removeObject(forKey: key) }
        }
    }
}

nonisolated enum ForkTimerStorage {
    static let prefix = "tj.artifact.timer."

    static func key(userID: String, roomID: String) -> String {
        prefix + ForkArtifactSHA.prefix16(userID) + "." + ForkArtifactSHA.prefix16(roomID)
    }
}

// MARK: - New-artifact draft (§5.6: lives in the model, never in sheet @State)

struct ForkArtifactDraft: Equatable {
    var pipe: ForkArtifactPipe?
    var title = ""
    var text = ""
    /// Set for "Request a change" (§5.6b): the pipe is fixed to NAS.
    var targetAID: String?
    var targetTitle: String?
    var txnID: String?
    var txnFingerprint: String?
    var isSending = false
    var error: String?

    var isChange: Bool { targetAID != nil }

    var isEmpty: Bool {
        pipe == nil && title.isEmpty && text.isEmpty && targetAID == nil
    }

    var canSend: Bool {
        pipe != nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && ForkArtifactRequest.length(text) <= ForkArtifactRequest.maxText && !isSending
    }

    var fingerprint: String {
        ForkArtifactSHA.hex("\(pipe?.rawValue ?? "")|\(title)|\(text)|\(targetAID ?? "")")
    }
}

// MARK: - Model

@Observable
final class ForkArtifactsModel {
    struct HTMLState: Equatable {
        /// Newest version whose verified bytes are in the cache.
        var readyVersion: Int?
        var isDownloading = false
        var error: String?
        /// D16 chip: a newer version is ready while the artifact is on screen and was touched recently.
        var chipVersion: Int?
    }

    let userID: String
    let roomID: String
    @ObservationIgnored let rest: ForkMatrixREST
    @ObservationIgnored let cache: ForkArtifactCache
    @ObservationIgnored private let keyPrefix: String

    // Index
    private(set) var entries: [ForkArtifactEntry] = []
    private(set) var hasFetchedOnce = false
    private(set) var isFetching = false
    private(set) var fetchError: String?
    private(set) var sessionExpired = false

    // Zone
    var selectedAID: String? {
        didSet { if selectedAID != oldValue { selectionChanged() } }
    }

    var isOpen = false
    var isFullScreen = false
    /// The underlying push / split / chatOnly mode (`.full` is an overlay on top of it).
    var layoutMode: ForkArtifactLayout.Mode = .chatOnly
    @ObservationIgnored var savedColumnVisibility: NavigationSplitViewVisibility?

    // HTML
    private(set) var htmlStates: [String: HTMLState] = [:]
    /// aid → version currently loaded in a live pooled web view.
    private(set) var liveHosts: [String: Int] = [:]
    private(set) var headerNote: (aid: String, text: String)?

    // Draft
    var draft = ForkArtifactDraft()
    var draftKept = false

    // Timer
    private(set) var timer: ForkTimerClock
    private(set) var timerDoneBadge = false
    private(set) var timerPulse = false

    @ObservationIgnored private var visibleZoneViews = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var reloadTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var downloadTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastTouch: [String: Date] = [:]
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var noteTask: Task<Void, Never>?
    @ObservationIgnored private var foregroundObserver: NSObjectProtocol?
    @ObservationIgnored private(set) var isTornDown = false
    /// Probe hook (ForkDuoProbe `artifacts=`).
    @ObservationIgnored var onModeChange: ((String) -> Void)?

    init(userID: String, roomID: String, rest: ForkMatrixREST, cacheBase: URL = ForkArtifactCache.baseDirectory) {
        self.userID = userID
        self.roomID = roomID
        self.rest = rest
        cache = ForkArtifactCache(userID: userID, roomID: roomID, base: cacheBase)
        keyPrefix = ForkArtifactSHA.prefix16(userID) + "/" + ForkArtifactSHA.prefix16(roomID) + "/"
        timer = Self.loadTimer(userID: userID, roomID: roomID)
        if let cached = cache.loadIndex() {
            entries = ForkArtifactIndex.parse(stateEvents: cached)
        }
        reconcileTimer(playSound: false)
        foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reconcileTimer(playSound: false)
                if self.visibleZoneViews > 0 { Task { await self.refresh() } }
            }
        }
    }

    var probeValue: String {
        isFullScreen ? ForkArtifactLayout.Mode.full.probeValue : layoutMode.probeValue
    }

    var selectedEntry: ForkArtifactEntry? {
        entries.first { $0.aid == selectedAID } ?? entries.first
    }

    func hostKey(_ aid: String) -> String {
        keyPrefix + aid
    }

    var hostKeyPrefix: String {
        keyPrefix
    }

    // MARK: Lifecycle

    func tearDown() {
        isTornDown = true
        pollTask?.cancel()
        timerTask?.cancel()
        noteTask?.cancel()
        reloadTasks.values.forEach { $0.cancel() }
        downloadTasks.values.forEach { $0.cancel() }
        reloadTasks = [:]
        downloadTasks = [:]
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
        foregroundObserver = nil
        ForkArtifactWebPool.shared.remove(prefix: keyPrefix)
        liveHosts = [:]
    }

    func roomOpened() {
        Task { await refresh() }
    }

    func zoneAppeared() {
        visibleZoneViews += 1
        if selectedAID == nil { selectedAID = entries.first?.aid }
        updatePins()
        clearTimerBadgeIfViewing()
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    func zoneDisappeared() {
        visibleZoneViews = max(0, visibleZoneViews - 1)
        if visibleZoneViews == 0 {
            pollTask?.cancel()
            pollTask = nil
        }
        updatePins()
    }

    var isZoneVisible: Bool {
        visibleZoneViews > 0
    }

    func setLayoutMode(_ mode: ForkArtifactLayout.Mode) {
        layoutMode = mode
        onModeChange?(probeValue)
    }

    func setFullScreen(_ value: Bool) {
        isFullScreen = value
        onModeChange?(probeValue)
    }

    // MARK: Index

    func refresh() async {
        guard !isTornDown, !sessionExpired, !isFetching else { return }
        isFetching = true
        defer { isFetching = false }
        do {
            let events = try await rest.state(roomID: roomID)
            let relevant = ForkArtifactIndex.relevantEvents(events)
            cache.saveIndex(relevant)
            apply(entries: ForkArtifactIndex.parse(stateEvents: relevant))
            fetchError = nil
            hasFetchedOnce = true
        } catch ForkMatrixREST.RESTError.sessionExpired {
            sessionExpired = true
            fetchError = "Session expired: reopen TJ Element"
            pollTask?.cancel()
            pollTask = nil
        } catch ForkMatrixREST.RESTError.noSession {
            fetchError = "Can't reach artifacts (signed-in session not found)"
            hasFetchedOnce = true
        } catch {
            if !(error is CancellationError) {
                fetchError = "Can't reach artifacts right now"
                hasFetchedOnce = true
            }
        }
    }

    /// Test seam + internal: applies a new index and starts background downloads for newer html versions.
    func apply(entries newEntries: [ForkArtifactEntry]) {
        let old = Dictionary(uniqueKeysWithValues: entries.map { ($0.aid, $0) })
        entries = newEntries
        if let selectedAID, !newEntries.contains(where: { $0.aid == selectedAID }) {
            self.selectedAID = newEntries.first?.aid
        } else if selectedAID == nil, isZoneVisible {
            selectedAID = newEntries.first?.aid
        }
        for entry in newEntries {
            guard case .html = entry.source else { continue }
            let ready = htmlStates[entry.aid]?.readyVersion ?? 0
            if entry.version > ready {
                prepareHTML(entry)
            } else if let previous = old[entry.aid], previous.version != entry.version {
                prepareHTML(entry)
            }
        }
        let liveAIDs = Set(newEntries.map(\.aid))
        let gone = liveHosts.keys.filter { !liveAIDs.contains($0) }
        if !gone.isEmpty {
            ForkArtifactWebPool.shared.remove(keys: gone.map(hostKey))
            gone.forEach { liveHosts.removeValue(forKey: $0) }
        }
    }

    // MARK: HTML download + display (§5.4, D16)

    /// Downloads, verifies and caches `entry`'s current version in the background. Nothing on screen changes yet.
    func prepareHTML(_ entry: ForkArtifactEntry) {
        guard case .html(let mxc) = entry.source, let sha = entry.sha256 else {
            htmlStates[entry.aid, default: HTMLState()].error = entry.sha256 == nil ? "Missing checksum" : nil
            return
        }
        if cache.read(aid: entry.aid, version: entry.version, sha256: sha) != nil {
            versionReady(aid: entry.aid, version: entry.version)
            return
        }
        guard downloadTasks[entry.aid] == nil else { return }
        htmlStates[entry.aid, default: HTMLState()].isDownloading = true
        let rest = rest
        let cache = cache
        downloadTasks[entry.aid] = Task { [weak self] in
            var result: String?
            for attempt in 0..<2 {
                do {
                    let data = try await rest.downloadMedia(mxc: mxc)
                    if ForkArtifactSHA.matches(data, expected: sha) {
                        try cache.write(data, aid: entry.aid, version: entry.version, sha256: sha)
                        result = nil
                        break
                    }
                    result = "Checksum mismatch: not shown"
                    MXLog.warning("TJ artifacts: sha256 mismatch for \(entry.aid) v\(entry.version) (attempt \(attempt + 1))")
                } catch {
                    result = "Download failed"
                }
            }
            guard let self, !Task.isCancelled else { return }
            downloadTasks[entry.aid] = nil
            htmlStates[entry.aid, default: HTMLState()].isDownloading = false
            if let result {
                htmlStates[entry.aid, default: HTMLState()].error = result
            } else {
                htmlStates[entry.aid, default: HTMLState()].error = nil
                versionReady(aid: entry.aid, version: entry.version)
            }
        }
    }

    private func versionReady(aid: String, version: Int) {
        let previous = htmlStates[aid]?.readyVersion ?? 0
        guard version > previous || htmlStates[aid]?.readyVersion == nil else { return }
        htmlStates[aid, default: HTMLState()].readyVersion = version
        guard let loaded = liveHosts[aid], loaded < version else { return }
        // A live view shows an older version: D16.
        let action = ForkReloadPolicy.decide(isOnScreen: isOnScreen(aid), lastTouch: lastTouch[aid], now: Date())
        switch action {
        case .swapSilently:
            break // the next display loads the new version (`display(aid:)`)
        case .reloadNow:
            reload(aid: aid)
        case .showChip(let at):
            htmlStates[aid, default: HTMLState()].chipVersion = version
            scheduleAutoReload(aid: aid, at: at)
        }
    }

    func isOnScreen(_ aid: String) -> Bool {
        isOpen && selectedAID == aid && (isZoneVisible || isFullScreen) && liveHosts[aid] != nil
    }

    /// Called whenever the canvas shows `aid`: creates or re-adopts the pooled view and loads the newest ready version
    /// if the view is new or holds a stale one (the off-screen swap of D16 step 2).
    func display(aid: String) async {
        guard let entry = entries.first(where: { $0.aid == aid }), case .html = entry.source, let sha = entry.sha256 else { return }
        if htmlStates[aid]?.readyVersion == nil { prepareHTML(entry) }
        guard let ready = htmlStates[aid]?.readyVersion,
              let host = await ForkArtifactWebPool.shared.makeHost(key: hostKey(aid), aid: aid) else { return }
        guard !isTornDown else { return }
        ForkArtifactWebPool.shared.onEvict = { keys in ForkArtifactsStore.shared.hostsEvicted(keys) }
        updatePins()
        if let loaded = host.loadedVersion, loaded >= ready, liveHosts[aid] != nil { return }
        if host.loadedVersion != nil, liveHosts[aid] != nil, htmlStates[aid]?.chipVersion != nil { return } // waiting on the chip
        let shaForReady = ready == entry.version ? sha : nil
        guard let data = loadCached(aid: aid, version: ready, preferredSHA: shaForReady) else {
            htmlStates[aid, default: HTMLState()].readyVersion = nil
            prepareHTML(entry)
            return
        }
        host.load(version: ready, data: data)
        liveHosts[aid] = ready
    }

    private func loadCached(aid: String, version: Int, preferredSHA: String?) -> Data? {
        if let preferredSHA { return cache.read(aid: aid, version: version, sha256: preferredSHA) }
        let folder = cache.root.appending(path: aid, directoryHint: .isDirectory)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        guard let file = files.first(where: { $0.lastPathComponent.hasPrefix("\(version)-") }) else { return nil }
        let sha = String(file.deletingPathExtension().lastPathComponent.dropFirst("\(version)-".count))
        return cache.read(aid: aid, version: version, sha256: sha)
    }

    /// Reload now to the newest ready version (chip tap, quiet timeout, or untouched on screen).
    func reload(aid: String) {
        reloadTasks[aid]?.cancel()
        reloadTasks[aid] = nil
        htmlStates[aid, default: HTMLState()].chipVersion = nil
        guard let ready = htmlStates[aid]?.readyVersion, let host = ForkArtifactWebPool.shared.host(forKey: hostKey(aid)) else { return }
        let entry = entries.first { $0.aid == aid }
        guard let data = loadCached(aid: aid, version: ready, preferredSHA: entry?.version == ready ? entry?.sha256 : nil) else { return }
        host.load(version: ready, data: data)
        liveHosts[aid] = ready
        if let note = entry?.changeNote, entry?.version == ready, !note.isEmpty {
            showHeaderNote(aid: aid, text: note)
        }
    }

    private func scheduleAutoReload(aid: String, at date: Date) {
        reloadTasks[aid]?.cancel()
        reloadTasks[aid] = Task { [weak self] in
            let delay = max(0, date.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            let action = ForkReloadPolicy.decide(isOnScreen: isOnScreen(aid), lastTouch: lastTouch[aid], now: Date())
            switch action {
            case .reloadNow, .swapSilently:
                reload(aid: aid)
            case .showChip(let next):
                scheduleAutoReload(aid: aid, at: next)
            }
        }
    }

    func noteTouch(aid: String) {
        lastTouch[aid] = Date()
        if htmlStates[aid]?.chipVersion != nil {
            scheduleAutoReload(aid: aid, at: Date().addingTimeInterval(ForkReloadPolicy.quietInterval))
        }
    }

    private func showHeaderNote(aid: String, text: String) {
        headerNote = (aid, text)
        noteTask?.cancel()
        noteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.headerNote = nil
        }
    }

    func hostsEvicted(_ keys: [String]) {
        for key in keys where key.hasPrefix(keyPrefix) {
            liveHosts.removeValue(forKey: String(key.dropFirst(keyPrefix.count)))
        }
    }

    private func selectionChanged() {
        updatePins()
        clearTimerBadgeIfViewing()
    }

    /// The visible room's selected artifact is never evicted.
    func updatePins() {
        guard let selectedAID, isOpen, isZoneVisible || isFullScreen else {
            ForkArtifactWebPool.shared.setPinned([])
            return
        }
        ForkArtifactWebPool.shared.setPinned([hostKey(selectedAID)])
    }

    // MARK: Timer (§5.5)

    static func loadTimer(userID: String, roomID: String) -> ForkTimerClock {
        guard let data = UserDefaults.standard.data(forKey: ForkTimerStorage.key(userID: userID, roomID: roomID)),
              let clock = try? JSONDecoder().decode(ForkTimerClock.self, from: data) else {
            return ForkTimerClock()
        }
        return clock
    }

    func updateTimer(_ change: (inout ForkTimerClock) -> Void) {
        var clock = timer
        change(&clock)
        timer = clock
        if let data = try? JSONEncoder().encode(clock) {
            UserDefaults.standard.set(data, forKey: ForkTimerStorage.key(userID: userID, roomID: roomID))
        }
        scheduleTimerFinish()
    }

    /// A fire time that passed while the app was away marks the countdown finished with no sound (§5.5).
    func reconcileTimer(playSound: Bool) {
        let now = Date()
        if let fireDate = timer.fireDate, fireDate <= now {
            updateTimer { $0.markFinished(at: fireDate) }
            if playSound { celebrateTimer() } else { timerDoneBadge = true }
        } else {
            scheduleTimerFinish()
        }
    }

    private func scheduleTimerFinish() {
        timerTask?.cancel()
        guard let fireDate = timer.fireDate, !isTornDown else { timerTask = nil; return }
        timerTask = Task { [weak self] in
            let delay = max(0, fireDate.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            let foreground = UIApplication.shared.applicationState == .active
            updateTimer { $0.markFinished(at: fireDate) }
            if foreground { celebrateTimer() } else { timerDoneBadge = true }
        }
    }

    private func celebrateTimer() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        AudioServicesPlaySystemSound(1005)
        timerDoneBadge = true
        timerPulse = true
        clearTimerBadgeIfViewing()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.timerPulse = false
        }
    }

    private func clearTimerBadgeIfViewing() {
        guard timerDoneBadge, isOpen, isZoneVisible || isFullScreen,
              let entry = selectedEntry, entry.nativeID == ForkNativeArtifacts.timerID else { return }
        timerDoneBadge = false
    }

    // MARK: Draft (§5.6)

    func beginNewArtifact() {
        if draft.isChange { draft = ForkArtifactDraft() }
        draftKept = false
    }

    func beginChange(for entry: ForkArtifactEntry) {
        if draft.targetAID != entry.aid { draft = ForkArtifactDraft() }
        draft.targetAID = entry.aid
        draft.targetTitle = entry.title
        draft.pipe = .nas
        draftKept = false
    }

    func clearDraft() {
        draft = ForkArtifactDraft()
        draftKept = false
    }

    /// Notify chat. Unencrypted rooms: REST with the structured key; encrypted: upstream's timeline, body only.
    func sendDraft(isEncrypted: Bool, sendBodyOnly: (String) async -> Bool) async -> Bool {
        guard draft.canSend, let pipe = draft.pipe else { return false }
        let message: ForkArtifactRequestMessage
        do {
            message = try ForkArtifactRequest.build(pipe: pipe,
                                                    title: draft.isChange ? draft.targetTitle : draft.title,
                                                    text: draft.text,
                                                    clientTS: Int(Date().timeIntervalSince1970 * 1000),
                                                    targetAID: draft.targetAID,
                                                    encrypted: isEncrypted)
        } catch {
            draft.error = "Check the title (≤ 60) and text (1–4000)."
            return false
        }
        draft.isSending = true
        draft.error = nil
        defer { draft.isSending = false }

        if isEncrypted {
            guard await sendBodyOnly(message.body) else {
                draft.error = "Couldn't send. Your draft is kept; try again."
                return false
            }
            return true
        }

        if draft.txnID == nil || draft.txnFingerprint != draft.fingerprint {
            draft.txnID = "tjart-" + UUID().uuidString.lowercased()
            draft.txnFingerprint = draft.fingerprint
        }
        guard let txnID = draft.txnID, let content = try? message.contentData() else { return false }
        do {
            _ = try await rest.sendMessage(roomID: roomID, content: content, txnID: txnID)
            return true
        } catch {
            draft.error = "Couldn't send (\(Self.describe(error))). Your draft is kept; try again."
            return false
        }
    }

    static func describe(_ error: Error) -> String {
        switch error as? ForkMatrixREST.RESTError {
        case .sessionExpired?: "session expired"
        case .forbidden?: "not allowed in this room"
        case .noSession?: "no signed-in session"
        case .http(let code)?: "HTTP \(code)"
        default: "network"
        }
    }
}

// MARK: - Per-user store

final class ForkArtifactsStore {
    static let shared = ForkArtifactsStore()

    private(set) var activeUserID: String?
    private var models: [String: ForkArtifactsModel] = [:]
    private var rests: [String: ForkMatrixREST] = [:]
    private var didPurge = false

    var modelCount: Int {
        models.count
    }

    /// Activating a different user tears down every model, timer task and web view of the previous one (§5.1).
    func activate(userID: String, purge: Bool = true) {
        if purge, !didPurge {
            didPurge = true
            let signedIn = ForkMatrixREST.signedInUserIDs().union([userID])
            Task.detached(priority: .utility) {
                ForkArtifactCache.purge(keepingUserIDs: signedIn)
            }
        }
        guard activeUserID != userID else { return }
        models.values.forEach { $0.tearDown() }
        models = [:]
        rests = [:]
        ForkArtifactWebPool.shared.removeAll()
        activeUserID = userID
    }

    func rest(forUser userID: String) -> ForkMatrixREST {
        if let rest = rests[userID] { return rest }
        let rest = ForkMatrixREST(userID: userID)
        rests[userID] = rest
        return rest
    }

    func model(roomID: String, userID: String) -> ForkArtifactsModel {
        activate(userID: userID)
        if let model = models[roomID] { return model }
        let model = ForkArtifactsModel(userID: userID, roomID: roomID, rest: rest(forUser: userID))
        models[roomID] = model
        return model
    }

    /// Test seam: installs a model built with a stub REST client.
    func install(_ model: ForkArtifactsModel) {
        activate(userID: model.userID, purge: false)
        models[model.roomID] = model
    }

    func existingModel(roomID: String) -> ForkArtifactsModel? {
        models[roomID]
    }

    func hostsEvicted(_ keys: [String]) {
        models.values.forEach { $0.hostsEvicted(keys) }
    }
}
