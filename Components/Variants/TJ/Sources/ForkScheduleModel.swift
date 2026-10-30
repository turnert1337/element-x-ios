//
// TJ fork: per-room Schedules model (iOS Workshop, Element card).
// Based on Element X iOS. SPDX-License-Identifier: AGPL-3.0-only
//
// Spec: WatchLab/Element/04_VOICE_SCHEDULE_SPEC.md rev 2, §B6, ticket T3. Reads the room's `/state` (schedule, status, kill,
// power levels, membership, encryption) and writes only through `ForkMatrixREST.putState` (schedule + kill types). The
// relay (WatchLab/WatchLab/scripts/mxrelay.py) does all the firing; this model never sends a message.
//

import Foundation
import SwiftUI

@Observable
final class ForkScheduleModel {
    enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    let roomID: String
    let userID: String
    let rest: ForkMatrixREST
    private(set) var room: ForkScheduleRoom?
    private(set) var loadState: LoadState = .loading
    private(set) var isWriting = false
    /// The last write's failure, in plain words (cleared on the next write).
    var writeError: String?
    @ObservationIgnored private let isEncrypted: () -> Bool
    @ObservationIgnored private var fixture: ForkScheduleFixture?

    /// Writes from a non-operator account are refused by the relay (B2.5 rule 1): the sheet says so.
    var isOperator: Bool {
        userID == ForkScheduleConstants.operatorID
    }

    var railLook: ForkScheduleRailLook {
        ForkScheduleRailLook(availability: room?.availability, enabledCount: room?.enabledCount ?? 0)
    }

    /// Fast while a save waits for the relay's confirmation, slow otherwise.
    var pollInterval: Duration {
        let now = Date()
        let waiting = room?.entries.contains { ForkScheduleConfirmation(updatedTS: $0.updatedTS, status: $0.status, now: now) == .waiting } ?? false
        return waiting ? .seconds(4) : .seconds(20)
    }

    init(roomID: String, userID: String, rest: ForkMatrixREST, isEncrypted: @escaping () -> Bool) {
        self.roomID = roomID
        self.userID = userID
        self.rest = rest
        self.isEncrypted = isEncrypted
        #if DEBUG
        fixture = ForkScheduleFixture.fromLaunchArguments()
        #endif
    }

    // MARK: Read

    func refresh() async {
        do {
            let events = if let fixture { try await fixture.events() } else { try await rest.state(roomID: roomID) }
            room = ForkScheduleRoom(stateEvents: events, isEncrypted: isEncrypted())
            loadState = .loaded
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            if room == nil { loadState = .failed(Self.words(for: error)) }
        }
    }

    /// Runs while the sheet is on screen (SwiftUI cancels it on disappear).
    func poll() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: pollInterval)
        }
    }

    // MARK: Write (the one new state write, B6)

    func save(_ draft: ForkScheduleDraft) async -> Bool {
        await write(type: ForkScheduleConstants.scheduleType, key: draft.sid, content: draft.content(updatedTS: Self.nowMS()))
    }

    func setEnabled(_ entry: ForkScheduleRoom.Entry, _ enabled: Bool) async {
        guard var draft = entry.draft else { return }
        draft.enabled = enabled
        _ = await save(draft)
    }

    /// B2.1 "Deleted: {}".
    func delete(_ entry: ForkScheduleRoom.Entry) async {
        _ = await write(type: ForkScheduleConstants.scheduleType, key: entry.sid, content: .object([:]))
    }

    /// B2.3 Pause all / Resume.
    func setPaused(_ paused: Bool) async {
        _ = await write(type: ForkScheduleConstants.killType, key: "", content: ForkScheduleRoom.killContent(paused: paused, ts: Self.nowMS()))
    }

    private func write(type: String, key: String, content: ForkJSON) async -> Bool {
        guard !isWriting else { return false }
        isWriting = true
        writeError = nil
        defer { isWriting = false }
        do {
            let data = try content.sortedData()
            if let fixture {
                try await fixture.put(type: type, key: key, content: content, sender: ForkScheduleConstants.operatorID)
            } else {
                _ = try await rest.putState(roomID: roomID, type: type, stateKey: key, content: data)
            }
            await refresh()
            return true
        } catch {
            writeError = Self.words(for: error)
            return false
        }
    }

    // MARK: Helpers

    static func nowMS() -> Int {
        Int((Date().timeIntervalSince1970 * 1000).rounded())
    }

    static func words(for error: Error) -> String {
        switch error {
        case ForkMatrixREST.RESTError.forbidden:
            "This chat isn't set up for schedules yet. Ask the workshop to set it up."
        case ForkMatrixREST.RESTError.sessionExpired, ForkMatrixREST.RESTError.noSession:
            "Session expired: reopen TJ Element."
        case ForkScheduleWrite.Refusal.tooBig:
            "This schedule is too long to save. Shorten the message."
        case ForkScheduleWrite.Refusal.typeNotAllowed:
            "TJ Element refused that write."
        case let error as URLError where error.code == .notConnectedToInternet:
            "This iPhone is offline."
        case ForkMatrixREST.RESTError.http(let code):
            "The server said \(code). Try again."
        default:
            "Couldn't reach the server. Try again."
        }
    }
}

// MARK: - DEBUG fixture (gate harness only: `-TJScheduleFixture ready|notset|encrypted|nobot`)

/// Lets the simulator gates screenshot every state without writing to a live room: reads and writes stay in memory.
final class ForkScheduleFixture {
    private var state: [String: ForkJSON] = [:]

    #if DEBUG
    static func fromLaunchArguments() -> ForkScheduleFixture? {
        guard let mode = UserDefaults.standard.string(forKey: "TJScheduleFixture"), !mode.isEmpty else { return nil }
        return ForkScheduleFixture(mode: mode, now: Date())
    }
    #endif

    init(mode: String, now: Date) {
        let op = ForkScheduleConstants.operatorID
        let bot = ForkScheduleConstants.workshopBotID
        let nowMS = Int(now.timeIntervalSince1970 * 1000)
        var levels: [String: ForkJSON] = ["ai.autopute.schedule.kill": .number(100), "ai.autopute.schedule.status": .number(50)]
        if mode != "notset" { levels[ForkScheduleConstants.scheduleType] = .number(100) }
        put("m.room.create", "", bot, ["room_version": .string("12")])
        put("m.room.power_levels", "", bot, ["users": .object([op: .number(100)]), "events": .object(levels)])
        put("m.room.member", bot, bot, ["membership": .string(mode == "nobot" ? "leave" : "join")])
        if mode == "encrypted" { put("m.room.encryption", "", op, ["algorithm": .string("m.megolm.v1.aes-sha2")]) }
        guard mode == "ready" else { return }

        func schedule(_ title: String, _ dtstart: String, _ rrule: String?, _ brief: String, enabled: Bool = true, updated: Int) -> [String: ForkJSON] {
            ["v": .number(1), "title": .string(title), "enabled": .bool(enabled), "tz": .string(ForkScheduleConstants.defaultTZ),
             "dtstart": .string(dtstart), "rrule": rrule.map(ForkJSON.string) ?? .null, "updated_ts": .number(Double(updated)),
             "action": .object(["kind": .string("message"), "brief": .string(brief), "thread_root": .null, "devlog": .bool(false)]),
             "catch_up": .string("skip"), "grace_min": .number(15)]
        }
        let old = nowMS - 3 * 86_400_000
        put(ForkScheduleConstants.scheduleType, "monday-workout-k3f9", op,
            schedule("Monday workout", "2026-10-26T07:00:00", "FREQ=WEEKLY;BYDAY=MO", "Workout today. 30 min, no excuses.", updated: old))
        put(ForkScheduleConstants.statusType, "monday-workout-k3f9", bot, [
            "v": .number(1), "seen_updated_ts": .number(Double(old)), "error": .null,
            "next_fire": .string(ForkScheduleTime.utcString(ForkScheduleFixture.next("2026-10-26T07:00:00", "FREQ=WEEKLY;BYDAY=MO", now))),
            "runs": .array([
                .object(["key": .string("3f9c0a1b2d4e5f60"), "planned": .string("2026-10-26T12:00:00Z"), "outcome": .string("done"),
                         "late_by_s": .number(1), "detail": .string("sent"), "result_event": .string("$fixture-done")]),
                .object(["key": .string("8a1c0a1b2d4e5f61"), "planned": .string("2026-10-19T12:00:00Z"), "outcome": .string("skipped_late"),
                         "late_by_s": .number(4000), "detail": .string("missed 1 while the relay was down")]),
            ]),
        ])
        put(ForkScheduleConstants.scheduleType, "friday-wrap-up-p2x8", op,
            schedule("Friday wrap-up", "2026-10-30T16:30:00", "FREQ=WEEKLY;BYDAY=FR", "Write down the week's three wins before you log off.", updated: nowMS - 20000))
        put(ForkScheduleConstants.scheduleType, "rent-reminder-m7q1", op,
            schedule("Rent reminder", "2026-11-01T09:00:00", "FREQ=MONTHLY;BYMONTHDAY=1", "Rent is due today.", updated: old))
        put(ForkScheduleConstants.statusType, "rent-reminder-m7q1", bot, ["v": .number(1), "seen_updated_ts": .number(Double(old)), "error": .null, "runs": .array([]),
                                                                       "next_fire": .string(ForkScheduleTime.utcString(ForkScheduleFixture.next("2026-11-01T09:00:00", "FREQ=MONTHLY;BYMONTHDAY=1", now)))])
        put(ForkScheduleConstants.scheduleType, "dentist-a1b2", op,
            schedule("Dentist", "2026-11-04T08:15:00", nil, "Dentist at 9. Leave by 8:30.", enabled: false, updated: nowMS - 600_000))
        put(ForkScheduleConstants.statusType, "dentist-a1b2", bot, ["v": .number(1), "seen_updated_ts": .number(Double(nowMS - 600_000)), "error": .null, "runs": .array([])])
    }

    func events() async throws -> [ForkJSON] {
        try await Task.sleep(for: .milliseconds(150))
        return Array(state.values)
    }

    func put(type: String, key: String, content: ForkJSON, sender: String) async throws {
        try await Task.sleep(for: .milliseconds(250))
        put(type, key, sender, content.object ?? [:])
    }

    private func put(_ type: String, _ key: String, _ sender: String, _ content: [String: ForkJSON]) {
        state[type + "|" + key] = .object(["type": .string(type), "state_key": .string(key), "sender": .string(sender), "content": .object(content)])
    }

    private static func next(_ dtstart: String, _ rrule: String, _ now: Date) -> Date {
        (try? ForkScheduleRecurrence.nextInstants(tz: ForkScheduleConstants.defaultTZ, dtstart: dtstart, rrule: rrule, after: now, count: 1).first) ?? now
    }
}
