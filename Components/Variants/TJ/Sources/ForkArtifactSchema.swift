//
// TJ fork: Artifacts + Dev log contract, pure layer (iOS Workshop, Element card).
// Based on Element X iOS. SPDX-License-Identifier: AGPL-3.0-only
//
// Spec: WatchLab/Element/03_ARTIFACTS_SPEC.md rev 3, §3.2 (artifact state), §3.3 (request event), §3.4 (tickets),
// §5.3 (layout mode), D15 (native gate), D16 (reload policy). Everything here is nonisolated and side-effect free (apart from an
// MXLog warning when a lenient field drops a value), so the Appendix A vectors run against it directly (Components/Variants/TJ/Tests).
//

import CryptoKit
import Foundation
import SwiftUI
import Synchronization

// MARK: - A tiny JSON value (Sendable, decodes any Matrix event content)

nonisolated enum ForkJSON: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ForkJSON])
    case object([String: ForkJSON])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ForkJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: ForkJSON].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            if let int = Self.exactInt(value) {
                try container.encode(int)
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    subscript(key: String) -> ForkJSON? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// Only an exact integer (a JSON number with no fractional part) counts; `"20"` or `20.5` do not.
    var int: Int? {
        if case .number(let value) = self { return Self.exactInt(value) }
        return nil
    }

    var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var array: [ForkJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var object: [String: ForkJSON]? {
        if case .object(let value) = self { return value }
        return nil
    }

    static func exactInt(_ value: Double) -> Int? {
        guard value.isFinite, value.rounded() == value, abs(value) < 9.0e15 else { return nil }
        return Int(value)
    }

    static func decode(_ data: Data) throws -> ForkJSON {
        try JSONDecoder().decode(ForkJSON.self, from: data)
    }

    /// Key-sorted, slash-unescaped serialization (what A.3 compares byte for byte).
    func sortedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

// MARK: - Constants (§3.1)

nonisolated enum ForkArtifactConstants {
    static let artifactStateType = "ai.autopute.artifact"
    static let ticketStateType = "ai.autopute.devlog.ticket"
    static let requestContentKey = "ai.autopute.artifact_request"
    static let devlogAlias = "#tj-devlog:autopute.ai"
    static let scheme = "tjartifact"

    static func isValidAID(_ value: String) -> Bool {
        value.wholeMatch(of: /[a-z0-9][a-z0-9-]{0,62}/) != nil
    }

    static func isValidTicketID(_ value: String) -> Bool {
        value.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_.\-]{0,79}/) != nil
    }
}

// MARK: - Trust (§3.2 rule 2)

nonisolated struct ForkPowerLevels: Equatable, Sendable {
    /// The `m.room.power_levels` content, or nil when the room has none.
    let content: ForkJSON?
    /// `m.room.create` sender + `content.additional_creators`, only for room versions where creators are infinite (v12+).
    let creators: Set<String>

    init(content: ForkJSON?, creators: Set<String>) {
        self.content = content
        self.creators = creators
    }

    /// Reads both events out of a `/state` response.
    init(stateEvents: [ForkJSON]) {
        var powerLevels: ForkJSON?
        var creators = Set<String>()
        for event in stateEvents {
            guard event["state_key"]?.string == "" else { continue }
            switch event["type"]?.string {
            case "m.room.power_levels":
                powerLevels = event["content"]
            case "m.room.create":
                let content = event["content"]
                let version = content?["room_version"]?.string ?? "1"
                if let number = Int(version), number >= 12 {
                    if let sender = event["sender"]?.string { creators.insert(sender) }
                    for extra in content?["additional_creators"]?.array ?? [] {
                        if let id = extra.string { creators.insert(id) }
                    }
                }
            default:
                break
            }
        }
        self.init(content: powerLevels, creators: creators)
    }

    func requiredLevel(forStateType type: String) -> Int {
        guard let content else { return 50 }
        return content["events"]?[type]?.int ?? content["state_default"]?.int ?? 50
    }

    func senderLevel(_ sender: String) -> Int {
        if creators.contains(sender) { return Int.max }
        guard let content else { return 0 }
        return content["users"]?[sender]?.int ?? content["users_default"]?.int ?? 0
    }

    func isTrusted(sender: String, stateType: String) -> Bool {
        senderLevel(sender) >= requiredLevel(forStateType: stateType)
    }
}

// MARK: - Artifact entries (§3.2)

nonisolated enum ForkArtifactPipe: String, Codable, CaseIterable, Sendable {
    case nas
    case xcode

    var badge: String {
        switch self {
        case .nas: "NAS"
        case .xcode: "Xcode"
        }
    }
}

nonisolated enum ForkArtifactKind: String, Sendable {
    case html
    case native
}

nonisolated struct ForkArtifactEntry: Equatable, Sendable, Identifiable {
    enum Source: Equatable, Sendable {
        case html(mxc: String)
        case native(id: String)
        case unsupported
    }

    var id: String { aid }

    let aid: String
    let sender: String
    let title: String
    let icon: String
    let pipe: ForkArtifactPipe
    let kind: String
    let url: String?
    let size: Int?
    let sha256: String?
    let version: Int
    let order: Int
    let updatedTS: Int
    let summary: String?
    let requestEventID: String?
    let changeNote: String?
    let nativeID: String?
    /// nil when absent, null, or not an integer (§3.2 rule 4: treated as null).
    let minBuild: Int?

    var source: Source {
        switch kind {
        case ForkArtifactKind.html.rawValue:
            if let url, url.hasPrefix("mxc://") { return .html(mxc: url) }
            return .unsupported
        case ForkArtifactKind.native.rawValue:
            if let nativeID, !nativeID.isEmpty { return .native(id: nativeID) }
            return .unsupported
        default:
            return .unsupported
        }
    }

    var isHTML: Bool {
        if case .html = source { return true }
        return false
    }

    /// The SF Symbol to draw; unknown names fall back to `square.dashed` (§3.2).
    var symbolName: String {
        UIImage(systemName: icon) == nil ? "square.dashed" : icon
    }

    /// Parses one state event's content. Returns nil when the entry is not live (§3.2 rule 1).
    static func parse(aid: String, sender: String, content: ForkJSON) -> ForkArtifactEntry? {
        guard ForkArtifactConstants.isValidAID(aid),
              content["v"]?.int == 1,
              let title = content["title"]?.string,
              let kind = content["kind"]?.string,
              let version = content["version"]?.int,
              let order = content["order"]?.int else {
            return nil
        }
        let sha256 = content["sha256"]?.string?.lowercased()
        // A malformed hash is refused outright: it becomes part of a cache path (`../` would escape the cache folder).
        if let sha256, !ForkArtifactSHA.isValidHex(sha256) { return nil }
        let derivedPipe: ForkArtifactPipe = kind == ForkArtifactKind.native.rawValue ? .xcode : .nas
        return ForkArtifactEntry(aid: aid,
                                 sender: sender,
                                 title: String(title.prefix(32)),
                                 icon: content["icon"]?.string ?? "square.dashed",
                                 pipe: content["pipe"]?.string.flatMap(ForkArtifactPipe.init(rawValue:)) ?? derivedPipe,
                                 kind: kind,
                                 url: content["url"]?.string,
                                 size: content["size"]?.int,
                                 sha256: sha256,
                                 version: version,
                                 order: order,
                                 updatedTS: content["updated_ts"]?.int ?? 0,
                                 summary: content["summary"]?.string,
                                 requestEventID: content["request_event_id"]?.string,
                                 changeNote: content["change_note"]?.string.map { String($0.prefix(140)) },
                                 nativeID: content["native_id"]?.string,
                                 minBuild: content["min_build"]?.int)
    }
}

nonisolated enum ForkArtifactIndex {
    /// Filters a `/state` response down to the live, trusted artifacts, sorted for the rail (§3.2).
    static func parse(stateEvents: [ForkJSON]) -> [ForkArtifactEntry] {
        let powerLevels = ForkPowerLevels(stateEvents: stateEvents)
        let entries = stateEvents.compactMap { event -> ForkArtifactEntry? in
            guard event["type"]?.string == ForkArtifactConstants.artifactStateType,
                  let aid = event["state_key"]?.string,
                  let sender = event["sender"]?.string,
                  let content = event["content"],
                  powerLevels.isTrusted(sender: sender, stateType: ForkArtifactConstants.artifactStateType) else {
                return nil
            }
            return ForkArtifactEntry.parse(aid: aid, sender: sender, content: content)
        }
        return sorted(entries)
    }

    /// `order` ascending, ties `updated_ts` descending, then aid (deterministic).
    static func sorted(_ entries: [ForkArtifactEntry]) -> [ForkArtifactEntry] {
        entries.sorted { lhs, rhs in
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            if lhs.updatedTS != rhs.updatedTS { return lhs.updatedTS > rhs.updatedTS }
            return lhs.aid < rhs.aid
        }
    }

    /// Keeps only the artifact (and trust) events of a `/state` response, for the on-disk index cache.
    static func relevantEvents(_ stateEvents: [ForkJSON]) -> [ForkJSON] {
        stateEvents.filter { event in
            switch event["type"]?.string {
            case ForkArtifactConstants.artifactStateType, "m.room.power_levels", "m.room.create": true
            default: false
            }
        }
    }
}

// MARK: - Native gate (§3.2 rule 4, D15)

nonisolated enum ForkNativeGate {
    enum Decision: Equatable, Sendable {
        case render
        /// The "Arrives in a TestFlight update" card; `needsBuild` adds the "needs build ≥ N" caption.
        case arrivesInUpdate(needsBuild: Int?)
    }

    /// Shipped builds use `date -u +%Y%m%d%H%M`; anything that doesn't parse or is below this is a developer build.
    static let shippedBuildFloor = 1_000_000_000

    static func isDeveloperBuild(_ bundleVersion: String) -> Bool {
        guard let number = Int(bundleVersion) else { return true }
        return number < shippedBuildFloor
    }

    static func decide(nativeID: String, minBuild: Int?, bundleVersion: String, registry: Set<String>) -> Decision {
        guard registry.contains(nativeID) else { return .arrivesInUpdate(needsBuild: minBuild) }
        guard let minBuild else { return .render }
        if isDeveloperBuild(bundleVersion) { return .render }
        guard let build = Int(bundleVersion) else { return .render }
        return build >= minBuild ? .render : .arrivesInUpdate(needsBuild: minBuild)
    }
}

// MARK: - Layout mode (§5.3)

nonisolated enum ForkArtifactLayout {
    enum Mode: String, Sendable {
        case chatOnly
        case push
        case split
        case full

        /// The Duo probe's `artifacts=` value.
        var probeValue: String {
            switch self {
            case .chatOnly: "-"
            case .push: "push"
            case .split: "split"
            case .full: "full"
            }
        }
    }

    static let splitMinimumWindowWidth: CGFloat = 600
    static let minimumSideWidth: CGFloat = 280
    static let chatFloor: CGFloat = 260

    static func mode(sizeClass: UserInterfaceSizeClass?, windowWidth: CGFloat, hasSplit: Bool, isOpen: Bool, isFullScreen: Bool) -> Mode {
        guard isOpen else { return .chatOnly }
        if isFullScreen { return .full }
        if hasSplit, sizeClass == .regular, windowWidth >= splitMinimumWindowWidth { return .split }
        return .push
    }

    /// 50/50 of the detail width, each side ≥ 280 pt; under 560 pt the pane gets 280 and the chat the rest,
    /// but the chat keeps a 260 pt floor and the pane shrinks first (§5.3 "Entering split" step 3).
    static func splitWidths(detailWidth: CGFloat, dividerWidth: CGFloat = 1) -> (chat: CGFloat, pane: CGFloat) {
        let available = max(0, detailWidth - dividerWidth)
        if available >= minimumSideWidth * 2 {
            let half = (available / 2).rounded(.down)
            return (available - half, half)
        }
        var pane = minimumSideWidth
        var chat = available - pane
        if chat < chatFloor {
            chat = min(chatFloor, available)
            pane = max(0, available - chat)
        }
        return (chat, pane)
    }
}

// MARK: - Request event (§3.3, D14)

nonisolated struct ForkArtifactRequestKey: Codable, Equatable, Sendable {
    let v: Int
    let pipe: ForkArtifactPipe
    let title: String?
    let text: String
    let clientTS: Int
    let targetAID: String?

    enum CodingKeys: String, CodingKey {
        case v, pipe, title, text
        case clientTS = "client_ts"
        case targetAID = "target_aid"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(v, forKey: .v)
        try container.encode(pipe, forKey: .pipe)
        try container.encodeIfPresent(title, forKey: .title) // absent optional fields are omitted, never null (A.3)
        try container.encode(text, forKey: .text)
        try container.encode(clientTS, forKey: .clientTS)
        try container.encodeIfPresent(targetAID, forKey: .targetAID)
    }
}

nonisolated struct ForkArtifactRequestMessage: Equatable, Sendable {
    let body: String
    /// nil in an encrypted room (body-only fallback, §3.3).
    let key: ForkArtifactRequestKey?

    /// The full `m.room.message` content, key-sorted.
    func contentData() throws -> Data {
        var object: [String: ForkJSON] = ["msgtype": .string("m.text"),
                                          "body": .string(body),
                                          "m.mentions": .object([:])]
        if let key {
            object[ForkArtifactConstants.requestContentKey] = try ForkJSON.decode(JSONEncoder().encode(key))
        }
        return try ForkJSON.object(object).sortedData()
    }
}

nonisolated enum ForkArtifactRequest {
    enum BuildError: Error, Equatable {
        case emptyText
        case textTooLong
        case titleTooLong
        case badTargetAID
    }

    static let maxText = 4000
    static let maxTitle = 60

    /// Code points, like the relay's Python `len()`.
    static func length(_ string: String) -> Int {
        string.unicodeScalars.count
    }

    static func normalizedTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let single = title.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        return single.trimmingCharacters(in: .whitespaces).isEmpty ? nil : single
    }

    /// Notify chat's payload. `encrypted` drops the structured key (the relay can't read the room anyway).
    static func build(pipe: ForkArtifactPipe, title: String?, text: String, clientTS: Int, targetAID: String?, encrypted: Bool = false) throws -> ForkArtifactRequestMessage {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BuildError.emptyText }
        guard length(text) <= maxText else { throw BuildError.textTooLong }
        let title = normalizedTitle(title)
        if let title, length(title) > maxTitle { throw BuildError.titleTooLong }
        if let targetAID, !ForkArtifactConstants.isValidAID(targetAID) { throw BuildError.badTargetAID }

        let verb = targetAID == nil ? "request" : "change"
        var firstLine = "🧩 Artifact \(verb) · \(pipe.badge)"
        if let title { firstLine += " · \(title)" }
        let body = firstLine + "\n" + text
        let key = encrypted ? nil : ForkArtifactRequestKey(v: 1, pipe: pipe, title: title, text: text, clientTS: clientTS, targetAID: targetAID)
        return ForkArtifactRequestMessage(body: body, key: key)
    }

    /// §3.3 key validation (shared with the relay): nil when invalid.
    static func validate(key json: ForkJSON?) -> ForkArtifactRequestKey? {
        guard let json, json["v"]?.int == 1,
              let pipe = json["pipe"]?.string.flatMap(ForkArtifactPipe.init(rawValue:)),
              let text = json["text"]?.string, (1...maxText).contains(length(text)),
              let clientTS = json["client_ts"]?.int else {
            return nil
        }
        var title: String?
        switch json["title"] {
        case nil, .null?: title = nil
        case .string(let value)? where (1...maxTitle).contains(length(value)): title = value
        default: return nil
        }
        var target: String?
        switch json["target_aid"] {
        case nil, .null?: target = nil
        case .string(let value)? where ForkArtifactConstants.isValidAID(value): target = value
        default: return nil
        }
        return ForkArtifactRequestKey(v: 1, pipe: pipe, title: title, text: text, clientTS: clientTS, targetAID: target)
    }

    /// The relay's first-line regex (§3.3): `^🧩 Artifact (request|change) · (NAS|Xcode)(?: · (.{1,60}))?\s*$`.
    static func parseFirstLine(_ body: String) -> (isChange: Bool, pipe: ForkArtifactPipe, title: String?)? {
        let firstLine = body.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let regex = /^🧩 Artifact (request|change) · (?i:(NAS|Xcode))(?: · (.{1,60}))?\s*$/
        guard let match = firstLine.wholeMatch(of: regex) else { return nil }
        let pipe: ForkArtifactPipe = match.2.lowercased() == "nas" ? .nas : .xcode
        return (match.1 == "change", pipe, match.3.map(String.init))
    }
}

// MARK: - Reload policy (D16)

nonisolated enum ForkReloadPolicy {
    enum Action: Equatable, Sendable {
        /// Not on screen: the next display loads the new version.
        case swapSilently
        case reloadNow
        /// On screen and touched recently: show the chip, auto-reload at this time unless touched again.
        case showChip(autoReloadAt: Date)
    }

    static let quietInterval: TimeInterval = 10

    static func decide(isOnScreen: Bool, lastTouch: Date?, now: Date) -> Action {
        guard isOnScreen else { return .swapSilently }
        guard let lastTouch else { return .reloadNow }
        let quietAt = lastTouch.addingTimeInterval(quietInterval)
        return now >= quietAt ? .reloadNow : .showChip(autoReloadAt: quietAt)
    }
}

// MARK: - Hashing (§5.4 sha256 check, per-user paths)

nonisolated enum ForkArtifactSHA {
    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func hex(_ string: String) -> String {
        hex(Data(string.utf8))
    }

    private static let lowercaseHexDigits = Set("0123456789abcdef".utf8)

    /// §3.2: exactly 64 lowercase hex digits.
    static func isValidHex(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy(lowercaseHexDigits.contains)
    }

    static func matches(_ data: Data, expected: String?) -> Bool {
        guard let expected, !expected.isEmpty else { return false }
        return hex(data) == expected.lowercased()
    }

    /// `sha256(value)[:16]`, used for cache folders and the Timer key (§5.1 "Per-user state").
    static func prefix16(_ value: String) -> String {
        String(hex(value).prefix(16))
    }
}

// MARK: - Dev log tickets (§3.4)

/// Matrix forbids floats in event JSON (canonical JSON: Synapse answers M_BAD_JSON "float"). rev 3.1 writers send integer
/// micro-USD; the retired dollar fields may still arrive as integers, numeric strings or numbers, so decode all three, and
/// never fail the whole ticket over one.
/// A string that doesn't parse, or isn't finite ("nan", "inf"), reads as nil and is reported (E6 stage fix S-B1).
nonisolated struct ForkLenientDouble: Decodable, Equatable, Sendable {
    let value: Double?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        var parsed: Double?
        if let number = try? container.decode(Double.self) {
            parsed = number
        } else if let text = try? container.decode(String.self) {
            parsed = Double(text.trimmingCharacters(in: CharacterSet(charactersIn: "$ ")))
        }
        if let parsed, parsed.isFinite {
            value = parsed
        } else {
            value = nil
            decoder.reportDropped(nil, reason: parsed == nil ? "wrong type" : "not finite")
        }
    }
}

/// An integer that never fails its parent's decode: a wrong type reads as nil, and is reported (E6 D2 `delivered_ts`).
nonisolated struct ForkLenientInt: Decodable, Equatable, Sendable {
    let value: Int?

    init(from decoder: Decoder) throws {
        value = try? decoder.singleValueContainer().decode(Int.self)
        if value == nil { decoder.reportDropped(nil) }
    }
}

/// E6 stage fix: a lenient field drops a value of the wrong type so the ticket still shows, but never silently. Every drop is
/// an `MXLog` warning; a decoder can also carry one of these (`userInfo[ForkDecodeIssues.key]`) to collect the paths (tests).
nonisolated final class ForkDecodeIssues: Sendable {
    static let key = CodingUserInfoKey(rawValue: "tj.decodeIssues")!

    private let storage = Mutex<[String]>([])

    init() { }

    /// Dotted coding paths, e.g. "cost.total_usd_micros", in the order they were dropped.
    var paths: [String] {
        storage.withLock { $0 }
    }

    func add(_ path: String) {
        storage.withLock { $0.append(path) }
    }

    static func path(_ codingPath: [CodingKey]) -> String {
        codingPath.map(\.stringValue).joined(separator: ".")
    }

    static func report(path: String, reason: String, issues: ForkDecodeIssues?) {
        issues?.add(path)
        MXLog.warning("TJ decode: dropped \(path.isEmpty ? "(root)" : path) (\(reason))")
    }
}

extension Decoder {
    /// Logs (and collects, when the decoder carries `ForkDecodeIssues`) a present value that was dropped.
    nonisolated func reportDropped(_ key: CodingKey?, reason: String = "wrong type") {
        ForkDecodeIssues.report(path: ForkDecodeIssues.path(codingPath + (key.map { [$0] } ?? [])), reason: reason,
                                issues: userInfo[ForkDecodeIssues.key] as? ForkDecodeIssues)
    }
}

/// Integer micro-USD from legacy dollars without trapping: nil for NaN, ±inf or anything outside `Int` (e.g. "1e20").
nonisolated enum ForkMicros {
    static func fromDollars(_ dollars: Double) -> Int? {
        guard dollars.isFinite else { return nil }
        return Int(exactly: (dollars * 1_000_000).rounded())
    }

    /// Adds without trapping: a value that would overflow the running sum is left out (and logged).
    static func sum(_ values: [Int], label: String) -> Int? {
        guard var total = values.first else { return nil }
        for value in values.dropFirst() {
            let (next, overflow) = total.addingReportingOverflow(value)
            if overflow {
                MXLog.warning("TJ devlog: left \(value) µ$ out of the \(label) total (it would overflow)")
            } else {
                total = next
            }
        }
        return total
    }
}

extension KeyedDecodingContainer {
    /// nil when absent or null; a present value of the wrong type is nil too, and reported (never silently dropped).
    nonisolated func decodeReported<T: Decodable>(_ type: T.Type, forKey key: Key, in decoder: Decoder) -> T? {
        guard contains(key), (try? decodeNil(forKey: key)) != true else { return nil }
        if let value = try? decode(T.self, forKey: key) { return value }
        decoder.reportDropped(key)
        return nil
    }

    nonisolated func decodeLenientDouble(forKey key: Key) -> Double? {
        (try? decodeIfPresent(ForkLenientDouble.self, forKey: key))?.value
    }

    /// Dollars from §3.4 rev 3.1 integer micro-USD when present, else from the retired dollar field.
    nonisolated func decodeUSD(micros: Key, legacy: Key) -> Double? {
        if let value = try? decodeIfPresent(Int.self, forKey: micros) { return Double(value) / 1_000_000 }
        return decodeLenientDouble(forKey: legacy)
    }

    /// Dollars from an integer micro-USD field (nil when absent, null or not an integer).
    nonisolated func decodeMicros(_ key: Key) -> Double? {
        (try? decodeIfPresent(Int.self, forKey: key)).flatMap { $0 }.map { Double($0) / 1_000_000 }
    }
}

nonisolated struct ForkDevLogTicket: Decodable, Equatable, Sendable, Identifiable {
    struct Progress: Decodable, Equatable, Sendable {
        let done: Int?
        let total: Int?
        let label: String?
    }

    struct Addendum: Decodable, Equatable, Sendable {
        let eventID: String?
        let via: String?
        let ts: Int?
        let body: String?

        enum CodingKeys: String, CodingKey {
            case eventID = "event_id"
            case via, ts, body
        }
    }

    struct Request: Decodable, Equatable, Sendable {
        let roomID: String?
        let eventID: String?
        let sender: String?
        let ts: Int?
        let body: String?
        let addenda: [Addendum]?

        enum CodingKeys: String, CodingKey {
            case roomID = "room_id"
            case eventID = "event_id"
            case sender, ts, body, addenda
        }
    }

    struct PlanStep: Decodable, Equatable, Sendable {
        let step: String?
        let lane: String?
        let status: String?
    }

    struct Interpretation: Decodable, Equatable, Sendable {
        let id: String?
        let yourWords: String?
        let reading: String?
        let alternative: String?

        enum CodingKeys: String, CodingKey {
            case id
            case yourWords = "your_words"
            case reading, alternative
        }
    }

    struct OpenDecision: Decodable, Equatable, Sendable {
        let id: String?
        let question: String?
        let defaultChoice: String?
        let owner: String?

        enum CodingKeys: String, CodingKey {
            case id, question, owner
            case defaultChoice = "default"
        }
    }

    struct Item: Decodable, Equatable, Sendable {
        let name: String?
        let type: String?
        let feature: String?
        let status: String?
        let note: String?
        let validation: String?
        let costUSD: Double?

        enum CodingKeys: String, CodingKey {
            case name, type, feature, status, note, validation
            case costUSD = "cost_usd"
            case costUSDMicros = "cost_usd_micros"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try? c.decodeIfPresent(String.self, forKey: .name)
            type = try? c.decodeIfPresent(String.self, forKey: .type)
            feature = try? c.decodeIfPresent(String.self, forKey: .feature)
            status = try? c.decodeIfPresent(String.self, forKey: .status)
            note = try? c.decodeIfPresent(String.self, forKey: .note)
            validation = try? c.decodeIfPresent(String.self, forKey: .validation)
            costUSD = c.decodeUSD(micros: .costUSDMicros, legacy: .costUSD)
        }
    }

    struct Gate: Decodable, Equatable, Sendable {
        let id: String?
        let name: String?
        let result: String?
        let evidence: String?
    }

    struct Build: Decodable, Equatable, Sendable {
        let number: String?
        let forkSHA: String?
        let xcode: String?
        let testflight: String?
        /// E6 D2: the universal build code ("E5"), shown before the TestFlight number.
        let code: String?

        enum CodingKeys: String, CodingKey {
            case number, xcode, testflight, code
            case forkSHA = "fork_sha"
        }

        init(from decoder: Decoder) throws {
            guard let c = try? decoder.container(keyedBy: CodingKeys.self) else {
                decoder.reportDropped(nil) // e.g. "build": "E6": the block is ignored, the ticket still shows
                number = nil
                forkSHA = nil
                xcode = nil
                testflight = nil
                code = nil
                return
            }
            number = c.decodeReported(String.self, forKey: .number, in: decoder)
            forkSHA = c.decodeReported(String.self, forKey: .forkSHA, in: decoder)
            xcode = c.decodeReported(String.self, forKey: .xcode, in: decoder)
            testflight = c.decodeReported(String.self, forKey: .testflight, in: decoder)
            code = c.decodeReported(String.self, forKey: .code, in: decoder)
        }
    }

    struct Tokens: Decodable, Equatable, Sendable {
        let input: Int?
        let output: Int?
        let cacheRead: Int?
        let cacheWrite: Int?

        enum CodingKeys: String, CodingKey {
            case input, output
            case cacheRead = "cache_read"
            case cacheWrite = "cache_write"
        }
    }

    struct Run: Decodable, Equatable, Sendable {
        let kind: String?
        let label: String?
        let model: String?
        let input: Int?
        let output: Int?
        let cacheRead: Int?
        let cacheWrite: Int?
        let costUSD: Double?
        /// rev 3.3: the same tokens at API list price (secondary; `costUSD` is the prorated plan share).
        let apiRateUSD: Double?
        let durationMS: Int?
        let source: String?

        enum CodingKeys: String, CodingKey {
            case kind, label, model, input, output, source
            case cacheRead = "cache_read"
            case cacheWrite = "cache_write"
            case costUSD = "cost_usd"
            case costUSDMicros = "cost_usd_micros"
            case apiRateUSDMicros = "api_rate_usd_micros"
            case durationMS = "duration_ms"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try? c.decodeIfPresent(String.self, forKey: .kind)
            label = try? c.decodeIfPresent(String.self, forKey: .label)
            model = try? c.decodeIfPresent(String.self, forKey: .model)
            input = try? c.decodeIfPresent(Int.self, forKey: .input)
            output = try? c.decodeIfPresent(Int.self, forKey: .output)
            cacheRead = try? c.decodeIfPresent(Int.self, forKey: .cacheRead)
            cacheWrite = try? c.decodeIfPresent(Int.self, forKey: .cacheWrite)
            costUSD = c.decodeUSD(micros: .costUSDMicros, legacy: .costUSD)
            apiRateUSD = c.decodeMicros(.apiRateUSDMicros)
            durationMS = try? c.decodeIfPresent(Int.self, forKey: .durationMS)
            source = try? c.decodeIfPresent(String.self, forKey: .source)
        }

        /// The receipt's source chip (§5.7 item 6).
        var sourceChip: String {
            switch source {
            case "result-event": "measured"
            case "transcript-usage": "transcript sum"
            default: "estimate"
            }
        }
    }

    struct Cost: Decodable, Equatable, Sendable {
        let basis: String?
        let totalUSD: Double?
        /// E6 D2: exact integer micro-USD for sums (the legacy dollar field converted once, rounded to the micro).
        let totalMicros: Int?
        let apiRateMicros: Int?
        /// rev 3.3: the API-rate equivalent of the same usage (shown under the basis line).
        let apiRateUSD: Double?
        /// rev 3.3: e.g. "only dev-Mac usage is visible, so this is an upper bound" (caption).
        let note: String?
        /// rev 3.3: ms; while in the future the prorated share can still fall ("Provisional until …").
        let provisionalUntil: Int?
        let totalIsEstimate: Bool?
        let coverage: String?
        let coverageNote: String?
        let tokens: Tokens?
        let runs: [Run]?

        enum CodingKeys: String, CodingKey {
            case basis, coverage, tokens, runs, note
            case totalUSD = "total_usd"
            case totalUSDMicros = "total_usd_micros"
            case apiRateUSDMicros = "api_rate_usd_micros"
            case provisionalUntil = "provisional_until"
            case totalIsEstimate = "total_is_estimate"
            case coverageNote = "coverage_note"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            basis = try? c.decodeIfPresent(String.self, forKey: .basis)
            // E6 stage fix S-B1: hostile or odd numbers ("nan", "inf", "1e20", a string where an integer belongs) are dropped and
            // logged; nothing here can trap. The receipt's dollars and the list's micros always agree (both nil, or the same value).
            if let micros = c.decodeReported(Int.self, forKey: .totalUSDMicros, in: decoder) {
                totalMicros = micros
            } else if let dollars = c.decodeLenientDouble(forKey: .totalUSD) {
                totalMicros = ForkMicros.fromDollars(dollars)
                if totalMicros == nil { decoder.reportDropped(CodingKeys.totalUSD, reason: "out of range") }
            } else {
                totalMicros = nil
            }
            totalUSD = totalMicros.map { Double($0) / 1_000_000 }
            apiRateMicros = c.decodeReported(Int.self, forKey: .apiRateUSDMicros, in: decoder)
            apiRateUSD = apiRateMicros.map { Double($0) / 1_000_000 }
            note = try? c.decodeIfPresent(String.self, forKey: .note)
            provisionalUntil = try? c.decodeIfPresent(Int.self, forKey: .provisionalUntil)
            totalIsEstimate = try? c.decodeIfPresent(Bool.self, forKey: .totalIsEstimate)
            coverage = try? c.decodeIfPresent(String.self, forKey: .coverage)
            coverageNote = try? c.decodeIfPresent(String.self, forKey: .coverageNote)
            tokens = try? c.decodeIfPresent(Tokens.self, forKey: .tokens)
            runs = try? c.decodeIfPresent([Run].self, forKey: .runs)
        }

        var isPartial: Bool { coverage == "partial" }
    }

    struct Links: Decodable, Equatable, Sendable {
        let spec: String?
        let report: String?
    }

    let v: Int?
    let id: String
    let project: String?
    let title: String
    let stage: String
    let stages: [String]?
    let progress: Progress?
    let statusNote: String?
    let createdTS: Int?
    let updatedTS: Int?
    let request: Request?
    let plan: [PlanStep]?
    let interpretations: [Interpretation]?
    let decisionsOpen: [OpenDecision]?
    let items: [Item]?
    let gates: [Gate]?
    let build: Build?
    let cost: Cost?
    let links: Links?
    /// E6 D2: optional ms when the ticket reached `delivered`. Without it there is no delivery time (`updated_ts` is only when the
    /// ticket last changed).
    let deliveredTS: ForkLenientInt?

    enum CodingKeys: String, CodingKey {
        case v, id, project, title, stage, stages, progress, request, plan, interpretations, items, gates, build, cost, links
        case statusNote = "status_note"
        case createdTS = "created_ts"
        case updatedTS = "updated_ts"
        case decisionsOpen = "decisions_open"
        case deliveredTS = "delivered_ts"
    }

    /// When a delivered ticket was delivered (ms), from `delivered_ts` only; nil for any other stage or without it.
    var deliveredMS: Int? {
        guard stage == "delivered" else { return nil }
        return deliveredTS?.value
    }

    static let defaultStages = ["queued", "planning", "building", "validating", "shipping", "processing", "delivered"]

    var resolvedStages: [String] {
        let list = stages ?? []
        return list.isEmpty ? Self.defaultStages : list
    }

    var isInPipeline: Bool {
        stage != "delivered" && stage != "failed"
    }

    /// Lenient decode of one state event's content: nil when not live (`v == 1`, `id`, `title`, `stage`). A field that can't decode
    /// at all still drops the ticket, but that is logged too (with `issues`, its path is collected).
    static func parse(content: ForkJSON, issues: ForkDecodeIssues? = nil) -> ForkDevLogTicket? {
        guard content["v"]?.int == 1,
              let id = content["id"]?.string, content["title"]?.string != nil, content["stage"]?.string != nil,
              let data = try? JSONEncoder().encode(content) else {
            return nil
        }
        let decoder = JSONDecoder()
        if let issues { decoder.userInfo[ForkDecodeIssues.key] = issues }
        do {
            return try decoder.decode(ForkDevLogTicket.self, from: data)
        } catch {
            let path: String = switch error as? DecodingError {
            case .typeMismatch(_, let context)?, .valueNotFound(_, let context)?, .keyNotFound(_, let context)?, .dataCorrupted(let context)?:
                ForkDecodeIssues.path(context.codingPath)
            default: ""
            }
            ForkDecodeIssues.report(path: path, reason: "ticket \(id) not shown", issues: issues)
            return nil
        }
    }
}

nonisolated enum ForkDevLogIndex {
    static func parse(stateEvents: [ForkJSON]) -> [ForkDevLogTicket] {
        let powerLevels = ForkPowerLevels(stateEvents: stateEvents)
        let tickets = stateEvents.compactMap { event -> ForkDevLogTicket? in
            guard event["type"]?.string == ForkArtifactConstants.ticketStateType,
                  let key = event["state_key"]?.string, ForkArtifactConstants.isValidTicketID(key),
                  let sender = event["sender"]?.string,
                  let content = event["content"],
                  powerLevels.isTrusted(sender: sender, stateType: ForkArtifactConstants.ticketStateType) else {
                return nil
            }
            return ForkDevLogTicket.parse(content: content)
        }
        return tickets.sorted { ($0.updatedTS ?? 0) > ($1.updatedTS ?? 0) }
    }
}

/// The 7-dot stepper's states (§3.4 client rules, A.2).
nonisolated enum ForkStageStepperState: Equatable, Sendable {
    case done
    case current
    case future
    case escalated
    case failed
}

nonisolated enum ForkStageStepperLayout {
    struct Result: Equatable, Sendable {
        let states: [ForkStageStepperState]
        /// The index the stepper highlights.
        let index: Int
        /// The raw stage when it isn't one of `stages` (rendered as queued with this caption).
        let unknownCaption: String?
        let label: String
    }

    /// E6 D2: Apple's processing is over once the build is VALID; the ticket then waits on the operator's check.
    static let onTestFlightLabel = "On TestFlight · your check"

    static func layout(stage: String, stages: [String], progressDone: Int?, testflight: String? = nil) -> Result {
        let stages = stages.isEmpty ? ForkDevLogTicket.defaultStages : stages
        let count = stages.count
        switch stage {
        case "escalated", "failed":
            let index = min(max(progressDone ?? 0, 0), count - 1)
            let mark: ForkStageStepperState = stage == "escalated" ? .escalated : .failed
            let states = (0..<count).map { $0 < index ? ForkStageStepperState.done : ($0 == index ? mark : .future) }
            return Result(states: states, index: index, unknownCaption: nil,
                          label: stage == "escalated" ? "Waiting on the steward" : "Failed")
        default:
            if let index = stages.firstIndex(of: stage) {
                let delivered = index == count - 1 && stage == "delivered"
                let states = (0..<count).map { position -> ForkStageStepperState in
                    if position < index || (delivered && position == index) { return .done }
                    return position == index ? .current : .future
                }
                let label = stage == "processing" && testflight == "VALID" ? onTestFlightLabel : stage.capitalized
                return Result(states: states, index: index, unknownCaption: nil, label: label)
            }
            let states = (0..<count).map { $0 == 0 ? ForkStageStepperState.current : .future }
            return Result(states: states, index: 0, unknownCaption: stage, label: "Queued")
        }
    }
}

// MARK: - Build number (D15; DEBUG override for G-A10)

nonisolated enum ForkBuildInfo {
    /// `CFBundleVersion`, or in DEBUG the `-TJForceBundleVersion <n>` launch argument (G-A10).
    static var bundleVersion: String {
        #if DEBUG
        if let forced = UserDefaults.standard.string(forKey: "TJForceBundleVersion"), !forced.isEmpty {
            return forced
        }
        #endif
        return Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}
