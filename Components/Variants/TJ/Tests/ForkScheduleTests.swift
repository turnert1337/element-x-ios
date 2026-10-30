//
// TJ fork: Schedules, pure layer tests (iOS Workshop, Element card).
// Based on Element X iOS. SPDX-License-Identifier: AGPL-3.0-only
//
// Spec: WatchLab/Element/04_VOICE_SCHEDULE_SPEC.md rev 2, §A4 TS1 + TS5, §B2, §B6, ticket T3.
// The recurrence vectors are the relay's own file (WatchLab/WatchLab/scripts/tests/scheduler/vectors.json), copied byte for
// byte into ForkScheduleVectors.json; `vectorsMatchTheRelayCopy` fails if the two drift. Expected values are literals there.
//

@testable import ElementX
import Foundation
import Synchronization
import Testing

private final class ForkScheduleBundleToken { }

nonisolated enum ForkScheduleFixtures {
    static let relayVectorsPath = "/Users/turnertomlinson/CommandCenter/WatchLab/WatchLab/scripts/tests/scheduler/vectors.json"

    static func vectorsData() throws -> Data {
        #if SWIFT_PACKAGE
        let url = try #require(Bundle.module.url(forResource: "ForkScheduleVectors", withExtension: "json"))
        #else
        let url = try #require(Bundle(for: ForkScheduleBundleToken.self).url(forResource: "ForkScheduleVectors", withExtension: "json"))
        #endif
        return try Data(contentsOf: url)
    }

    static func vectors() throws -> [ForkJSON] {
        try #require(ForkJSON.decode(vectorsData())["vectors"]?.array)
    }

    static func date(_ iso: String) -> Date {
        ForkScheduleTime.parseUTC(iso)!
    }
}

struct ForkScheduleRecurrenceTests {
    @Test
    func vectorsMatchTheRelayCopy() throws {
        let ours = try ForkScheduleFixtures.vectorsData()
        guard let relay = FileManager.default.contents(atPath: ForkScheduleFixtures.relayVectorsPath) else {
            return // not reachable from this test host (a device); the sim and the package loop both check it
        }
        #expect(ours == relay, "ForkScheduleVectors.json drifted from the relay's vectors.json: copy it again")
    }

    @Test
    func everyVectorPasses() throws {
        let vectors = try ForkScheduleFixtures.vectors()
        #expect(vectors.count >= 85)
        for vector in vectors {
            let id = vector["id"]?.string ?? "?"
            let tz = vector["tz"]?.string ?? "America/Chicago"
            let dtstart = try #require(vector["dtstart"]?.string)
            let rrule = vector["rrule"]?.string
            if let code = vector["error"]?.string {
                let error = try #require(ForkScheduleError(rawValue: code), "\(id): unknown code \(code)")
                #expect(throws: error, "\(id)") {
                    try ForkScheduleRecurrence.nextInstants(tz: tz, dtstart: dtstart, rrule: rrule,
                                                           after: ForkScheduleFixtures.date("2026-01-01T00:00:00Z"), count: 3)
                }
                continue
            }
            let after = ForkScheduleFixtures.date(try #require(vector["after"]?.string))
            let count = try #require(vector["n"]?.int)
            let expected = try #require(vector["expect"]?.array).compactMap(\.string)
            do {
                let got = try ForkScheduleRecurrence.nextInstants(tz: tz, dtstart: dtstart, rrule: rrule, after: after, count: count)
                #expect(got.map(ForkScheduleTime.utcString) == expected, "\(id)")
            } catch {
                Issue.record("\(id): threw \(error)")
            }
        }
    }

    @Test
    func utcStringsRoundTrip() {
        #expect(ForkScheduleTime.utcString(ForkScheduleFixtures.date("2026-11-02T13:00:00Z")) == "2026-11-02T13:00:00Z")
        #expect(ForkScheduleTime.parseUTC("2026-11-02T13:00:00") == nil)
        #expect(ForkScheduleTime.parseUTC("2026-02-30T13:00:00Z") == nil)
    }
}

// MARK: - S2 · editor ↔ B2.1 JSON (TS5)

struct ForkScheduleDraftTests {
    @Test
    func everyVectorRoundTripsThroughTheEditorUnchanged() throws {
        var checked = 0
        for vector in try ForkScheduleFixtures.vectors() where vector["error"] == nil {
            var object: [String: ForkJSON] = [
                "v": .number(1), "title": .string(try #require(vector["id"]?.string)), "enabled": .bool(true),
                "tz": .string(vector["tz"]?.string ?? "America/Chicago"), "dtstart": try #require(vector["dtstart"]),
                "rrule": vector["rrule"] ?? .null,
                "action": .object(["kind": .string("message"), "brief": .string("Workout today."), "thread_root": .null, "devlog": .bool(false)]),
                "catch_up": .string("skip"), "grace_min": .number(15), "nl_source": .null, "updated_ts": .number(1_793_331_600_000),
            ]
            if checked % 2 == 1 { object["catch_up"] = nil; object["grace_min"] = nil; object["nl_source"] = nil } // optional keys may be absent
            let content = ForkJSON.object(object)
            let draft = try #require(ForkScheduleDraft(content: content), "\(vector["id"]?.string ?? "?")")
            #expect(draft.content(updatedTS: 1_793_331_600_000) == content, "\(vector["id"]?.string ?? "?")")
            checked += 1
        }
        #expect(checked == 50) // V1–V53 minus the error vectors V8–V10
    }

    @Test
    func specExamplesRoundTrip() throws {
        let weekInReview = try ForkJSON.decode(Data(#"""
        {"v":1,"title":"Week in review call","enabled":true,"tz":"America/Chicago","dtstart":"2026-11-06T17:00:00",
         "rrule":"FREQ=WEEKLY;BYDAY=FR","action":{"kind":"call","brief":"Pull a summary of my week out of me: wins, misses, what's next. Then write it up.",
         "thread_root":"$abc","devlog":false},"catch_up":"skip","grace_min":15,"nl_source":null,"updated_ts":1793331600000}
        """#.utf8))
        let workout = try ForkJSON.decode(Data(#"""
        {"v":1,"title":"Monday workout","enabled":true,"tz":"America/Chicago","dtstart":"2026-11-02T07:00:00","rrule":"FREQ=WEEKLY;BYDAY=MO",
         "action":{"kind":"message","brief":"Workout today. 30 min, no excuses."},"updated_ts":1793331600000,"x_future":{"keep":true}}
        """#.utf8))
        for content in [weekInReview, workout] {
            let draft = try #require(ForkScheduleDraft(content: content))
            #expect(draft.content(updatedTS: 1_793_331_600_000) == content)
        }
        let call = try #require(ForkScheduleDraft(content: weekInReview))
        #expect(call.kind == .call && call.repeatRule == .weekly([4]) && call.threadRoot == "$abc" && call.minute == 17 * 60)
        let monday = try #require(ForkScheduleDraft(content: workout))
        #expect(monday.kind == .message && monday.repeatRule == .weekly([0]))
    }

    @Test
    func editorRulesMapToCanonicalRRules() throws {
        let cases: [(String?, ForkScheduleDraft.Repeat)] = [
            (nil, .once), ("FREQ=DAILY", .daily), ("FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR", .weekdays), ("FREQ=WEEKLY;BYDAY=MO,WE,FR", .weekly([0, 2, 4])),
            ("FREQ=WEEKLY;BYDAY=SU", .weekly([6])), ("BYDAY=MO;FREQ=WEEKLY", .custom("BYDAY=MO;FREQ=WEEKLY")), ("FREQ=WEEKLY", .custom("FREQ=WEEKLY")),
            ("FREQ=MONTHLY;BYMONTHDAY=-1", .custom("FREQ=MONTHLY;BYMONTHDAY=-1")), ("FREQ=WEEKLY;BYDAY=FR,MO", .custom("FREQ=WEEKLY;BYDAY=FR,MO")),
        ]
        for (rrule, expected) in cases {
            #expect(ForkScheduleDraft.Repeat(rrule: rrule) == expected, "\(rrule ?? "null")")
            #expect(expected.rrule == rrule, "\(rrule ?? "null")")
        }
        #expect(ForkScheduleDraft.Repeat.weekly([4, 0, 2]).rrule == "FREQ=WEEKLY;BYDAY=MO,WE,FR")
    }

    @Test
    func aNewWeekdaysMessageEncodesExactly() throws {
        var draft = ForkScheduleDraft.new(sid: "workout-ab12", tz: "America/Chicago", today: ForkCivilDate(year: 2026, month: 11, day: 2), threadRoot: "$root1")
        draft.title = "Workout"
        draft.brief = "Workout today. 30 min, no excuses."
        draft.minute = 7 * 60
        draft.repeatRule = .weekdays
        let data = try draft.content(updatedTS: 1_793_331_600_000).sortedData()
        #expect(String(decoding: data, as: UTF8.self) ==
            #"{"action":{"brief":"Workout today. 30 min, no excuses.","devlog":false,"kind":"message","thread_root":"$root1"},"catch_up":"skip","dtstart":"2026-11-02T07:00:00","enabled":true,"grace_min":15,"rrule":"FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR","title":"Workout","tz":"America/Chicago","updated_ts":1793331600000,"v":1}"#)
        #expect(draft.problems().isEmpty)
    }

    @Test
    func editorProblemsBlockSaving() {
        var draft = ForkScheduleDraft.new(sid: "x-0000", tz: "America/Chicago", today: ForkCivilDate(year: 2026, month: 11, day: 2), threadRoot: nil)
        #expect(Set(draft.problems()) == [.noTitle, .noMessage])
        draft.title = String(repeating: "t", count: 49)
        draft.brief = String(repeating: "b", count: 2001)
        #expect(Set(draft.problems()) == [.titleTooLong, .messageTooLong])
        draft.title = "ok"
        draft.brief = "  \n "
        draft.repeatRule = .weekly([])
        #expect(Set(draft.problems()) == [.noMessage, .noDays])
        draft.brief = "ok"
        draft.repeatRule = .custom("FREQ=HOURLY")
        #expect(draft.problems() == [.rule(.unsupportedRRule)])
        draft.repeatRule = .daily
        draft.title = String(repeating: "é", count: 48) // 48 code points, as the relay counts them
        #expect(draft.problems().isEmpty)
    }

    @Test
    func newSIDsMatchTheContract() {
        for title in ["Monday workout", "Week in review call!!", "  ", "Ünïcode 🚀 title", String(repeating: "long ", count: 30)] {
            let sid = ForkScheduleDraft.makeSID(title: title)
            #expect(sid.wholeMatch(of: /[a-z0-9][a-z0-9-]{0,62}/) != nil, "\(sid)")
        }
        #expect(ForkScheduleDraft.makeSID(title: "Monday workout").hasPrefix("monday-workout-"))
        #expect(ForkScheduleDraft.makeSID(title: "!!").hasPrefix("schedule-"))
    }
}

// MARK: - S3 · room snapshot: trust (B2.5), availability (B6), status + kill (B2.2, B2.3)

/// Build 5 E2E F2: the iOS 26+ toolbar drops `.opacity` and `.accessibilityValue` on a bar item, so the not-ready look lives
/// in what the bar does keep: the icon image's own colour and the item's label.
struct ForkScheduleRailLookTests {
    @Test
    func notReadyRoomsAreDimmedAndSayWhyInTheLabel() {
        let cases: [(ForkScheduleRoom.Availability, String)] = [
            (.encrypted, "Schedule. Schedules need an unencrypted room."),
            (.noWorkshop, "Schedule. The workshop isn't in this chat."),
            (.notSetUp, "Schedule. This chat isn't set up for schedules yet. Ask the workshop to set it up.")
        ]
        for (availability, label) in cases {
            let look = ForkScheduleRailLook(availability: availability, enabledCount: 0)
            #expect(look.isDimmed)
            #expect(look.accessibilityLabel == label)
            #expect(look.badge == nil)
        }
    }

    @Test
    func readyRoomIsPlainWithTheCountBadge() {
        let look = ForkScheduleRailLook(availability: .ready, enabledCount: 2)
        #expect(!look.isDimmed)
        #expect(look.accessibilityLabel == "Schedule")
        #expect(look.badge == "2")
        #expect(ForkScheduleRailLook(availability: .ready, enabledCount: 0).badge == nil)
    }

    @Test
    func beforeTheFirstStateReadTheItemIsNotDimmed() {
        let look = ForkScheduleRailLook(availability: nil, enabledCount: 0)
        #expect(!look.isDimmed)
        #expect(look.accessibilityLabel == "Schedule")
        #expect(look.badge == nil)
    }
}

struct ForkScheduleRoomTests {
    static let op = ForkScheduleConstants.operatorID
    static let bot = ForkScheduleConstants.workshopBotID

    static func event(_ type: String, _ key: String, _ sender: String, _ content: ForkJSON) -> ForkJSON {
        .object(["type": .string(type), "state_key": .string(key), "sender": .string(sender), "content": content])
    }

    static func schedule(_ title: String, enabled: Bool = true, updatedTS: Int = 1_793_331_600_000) -> ForkJSON {
        .object(["v": .number(1), "title": .string(title), "enabled": .bool(enabled), "tz": .string("America/Chicago"),
                 "dtstart": .string("2026-11-02T07:00:00"), "rrule": .string("FREQ=WEEKLY;BYDAY=MO"),
                 "action": .object(["kind": .string("message"), "brief": .string("Workout today.")]), "updated_ts": .number(Double(updatedTS))])
    }

    /// A v12 room created by the bot, the operator at 100, schedules set up (T1 room setup), the bot joined.
    static func baseState(scheduleLevel: Int? = 100, operatorLevel: Int = 100, botJoined: Bool = true, encrypted: Bool = false) -> [ForkJSON] {
        var events: [String: ForkJSON] = ["ai.autopute.schedule.kill": .number(100), "ai.autopute.schedule.status": .number(50)]
        if let scheduleLevel { events["ai.autopute.schedule"] = .number(Double(scheduleLevel)) }
        var state = [
            event("m.room.create", "", bot, .object(["room_version": .string("12")])),
            event("m.room.power_levels", "", bot, .object(["users": .object([op: .number(Double(operatorLevel)), "@guest:autopute.ai": .number(100)]),
                                                          "events": .object(events)])),
            event("m.room.member", bot, bot, .object(["membership": .string(botJoined ? "join" : "leave")])),
        ]
        if encrypted { state.append(event("m.room.encryption", "", op, .object(["algorithm": .string("m.megolm.v1.aes-sha2")]))) }
        return state
    }

    static func parse(_ state: [ForkJSON], encrypted: Bool = false) -> ForkScheduleRoom {
        ForkScheduleRoom(stateEvents: state, isEncrypted: encrypted)
    }

    @Test
    func availabilityStates() {
        #expect(Self.parse(Self.baseState()).availability == .ready)
        #expect(Self.parse(Self.baseState(encrypted: true)).availability == .encrypted)
        #expect(Self.parse(Self.baseState(), encrypted: true).availability == .encrypted)
        #expect(Self.parse(Self.baseState(botJoined: false)).availability == .noWorkshop)
        #expect(Self.parse(Self.baseState(scheduleLevel: nil)).availability == .notSetUp)
        #expect(Self.parse(Self.baseState(scheduleLevel: 99)).availability == .notSetUp)
        #expect(Self.parse([]).availability == .noWorkshop)
        #expect(ForkScheduleRoom.Availability.notSetUp.message == "This chat isn't set up for schedules yet. Ask the workshop to set it up.")
        #expect(ForkScheduleRoom.Availability.encrypted.message == "Schedules need an unencrypted room.")
        #expect(ForkScheduleRoom.Availability.noWorkshop.message == "The workshop isn't in this chat.")
    }

    @Test
    func onlyTheOperatorsSchedulesShow() {
        var state = Self.baseState()
        state.append(Self.event(ForkScheduleConstants.scheduleType, "mine-0001", Self.op, Self.schedule("Mine")))
        state.append(Self.event(ForkScheduleConstants.scheduleType, "bot-0001", Self.bot, Self.schedule("Bot (infinite power)")))
        state.append(Self.event(ForkScheduleConstants.scheduleType, "guest-0001", "@guest:autopute.ai", Self.schedule("Guest at 100")))
        state.append(Self.event(ForkScheduleConstants.scheduleType, "gone-0001", Self.op, .object([:])))
        state.append(Self.event(ForkScheduleConstants.scheduleType, "Bad_SID", Self.op, Self.schedule("Bad sid")))
        state.append(Self.event(ForkScheduleConstants.scheduleType, "v2-0001", Self.op, .object(["v": .number(2), "title": .string("Future")])))
        let room = Self.parse(state)
        #expect(room.entries.map(\.sid) == ["mine-0001"])
        #expect(room.enabledCount == 1)
    }

    @Test
    func theOperatorBelow100OrAnUnsetRoomShowsNothing() {
        for state in [Self.baseState(operatorLevel: 50), Self.baseState(scheduleLevel: 50)] {
            var events = state
            events.append(Self.event(ForkScheduleConstants.scheduleType, "mine-0001", Self.op, Self.schedule("Mine")))
            #expect(Self.parse(events).entries.isEmpty)
        }
    }

    @Test
    func statusOnlyFromTheWorkshopBot() throws {
        var state = Self.baseState()
        state.append(Self.event(ForkScheduleConstants.scheduleType, "mine-0001", Self.op, Self.schedule("Mine")))
        let status = try ForkJSON.decode(Data(#"""
        {"v":1,"seen_updated_ts":1793331600000,"next_fire":"2026-11-02T13:00:00Z","error":null,
         "runs":[{"key":"3f9c0a1b2d4e5f60","planned":"2026-10-26T12:00:00Z","started_ts":1793311201000,"outcome":"done","late_by_s":1,
                  "detail":"sent","result_event":"$def"},
                 {"key":"00","planned":"2026-10-19T12:00:00Z","outcome":"skipped_late","late_by_s":4000,"detail":"missed 2 while the relay was down"}]}
        """#.utf8))
        state.append(Self.event(ForkScheduleConstants.statusType, "mine-0001", "@guest:autopute.ai", .object(["v": .number(1), "seen_updated_ts": .number(1)])))
        #expect(Self.parse(state).entries.first?.status == nil)
        state.append(Self.event(ForkScheduleConstants.statusType, "mine-0001", Self.bot, status))
        let entry = try #require(Self.parse(state).entries.first)
        let parsed = try #require(entry.status)
        #expect(parsed.seenUpdatedTS == 1_793_331_600_000)
        #expect(parsed.nextFire.map(ForkScheduleTime.utcString) == "2026-11-02T13:00:00Z")
        #expect(parsed.error == nil)
        #expect(parsed.runs.map(\.outcome) == ["done", "skipped_late"])
        #expect(parsed.runs.first?.resultEvent == "$def" && parsed.runs.first?.lateBySeconds == 1)
        #expect(parsed.runs.last?.resultEvent == nil)
    }

    @Test
    func statusErrorsShowInPlainWords() {
        #expect(ForkScheduleRoom.Status.message(for: "unsupported_rrule") == "The relay doesn't understand this repeat rule.")
        #expect(ForkScheduleRoom.Status.message(for: "untrusted_sender") == "The relay won't run this: only schedules you write run.")
        #expect(ForkScheduleRoom.Status.message(for: "something_new") == "The relay refused this schedule (something_new).")
    }

    @Test
    func pauseAllCountsOnlyFromTheOperator() {
        let paused = ForkJSON.object(["v": .number(1), "paused": .bool(true), "ts": .number(1)])
        var state = Self.baseState()
        state.append(Self.event(ForkScheduleConstants.killType, "", Self.bot, paused))
        #expect(!Self.parse(state).isPaused)
        state[state.count - 1] = Self.event(ForkScheduleConstants.killType, "", Self.op, paused)
        #expect(Self.parse(state).isPaused)
        state[state.count - 1] = Self.event(ForkScheduleConstants.killType, "", Self.op, .object([:]))
        #expect(!Self.parse(state).isPaused)
        state[state.count - 1] = Self.event(ForkScheduleConstants.killType, "", Self.op, .object(["v": .number(1), "paused": .bool(false), "ts": .number(2)]))
        #expect(!Self.parse(state).isPaused)
    }

    @Test
    func killContentEncodesExactly() throws {
        let data = try ForkScheduleRoom.killContent(paused: true, ts: 1_793_331_600_000).sortedData()
        #expect(String(decoding: data, as: UTF8.self) == #"{"paused":true,"ts":1793331600000,"v":1}"#)
    }

    @Test
    func disabledSchedulesDontCountOnTheBadge() {
        var state = Self.baseState()
        state.append(Self.event(ForkScheduleConstants.scheduleType, "a-0001", Self.op, Self.schedule("A")))
        state.append(Self.event(ForkScheduleConstants.scheduleType, "b-0001", Self.op, Self.schedule("B", enabled: false)))
        let room = Self.parse(state)
        #expect(room.entries.map(\.sid) == ["a-0001", "b-0001"])
        #expect(room.enabledCount == 1)
    }
}

// MARK: - S4 · relay confirmation (B6 "Waiting for the workshop…") and the write allowlist (B6 putState)

struct ForkScheduleConfirmationTests {
    static let saved = 1_793_331_600_000
    static var savedDate: Date { Date(timeIntervalSince1970: TimeInterval(saved) / 1000) }

    static func status(seen: Int?) -> ForkScheduleRoom.Status {
        ForkScheduleRoom.Status(content: .object(seen.map { ["v": .number(1), "seen_updated_ts": .number(Double($0))] } ?? ["v": .number(1)]))
    }

    @Test
    func confirmationStates() {
        let now = Self.savedDate.addingTimeInterval(30)
        #expect(ForkScheduleConfirmation(updatedTS: Self.saved, status: nil, now: now) == .waiting)
        #expect(ForkScheduleConfirmation(updatedTS: Self.saved, status: Self.status(seen: Self.saved - 1), now: now) == .waiting)
        #expect(ForkScheduleConfirmation(updatedTS: Self.saved, status: Self.status(seen: Self.saved), now: now) == .confirmed)
        #expect(ForkScheduleConfirmation(updatedTS: Self.saved, status: Self.status(seen: nil), now: Self.savedDate.addingTimeInterval(179)) == .waiting)
        #expect(ForkScheduleConfirmation(updatedTS: Self.saved, status: nil, now: Self.savedDate.addingTimeInterval(180)) == .unconfirmed)
        #expect(ForkScheduleConfirmation.waiting.message == "Waiting for the workshop…")
        #expect(ForkScheduleConfirmation.unconfirmed.message == "The workshop hasn't confirmed. The Mac may be asleep; this won't fire until it does.")
        #expect(ForkScheduleConfirmation.confirmed.message == nil)
    }

    @Test
    func onlyScheduleTypesMayBeWritten() throws {
        let small = Data(#"{"v":1}"#.utf8)
        #expect(throws: Never.self) { try ForkScheduleWrite.check(type: "ai.autopute.schedule", content: small) }
        #expect(throws: Never.self) { try ForkScheduleWrite.check(type: "ai.autopute.schedule.kill", content: small) }
        for type in ["ai.autopute.schedule.status", "m.room.power_levels", "ai.autopute.artifact", "ai.autopute.schedule ", "m.room.name"] {
            #expect(throws: ForkScheduleWrite.Refusal.typeNotAllowed, "\(type)") { try ForkScheduleWrite.check(type: type, content: small) }
        }
        let big = Data(repeating: 0x61, count: 8 * 1024 + 1)
        #expect(throws: ForkScheduleWrite.Refusal.tooBig) { try ForkScheduleWrite.check(type: "ai.autopute.schedule", content: big) }
        #expect(throws: Never.self) { try ForkScheduleWrite.check(type: "ai.autopute.schedule", content: Data(repeating: 0x61, count: 8 * 1024)) }
    }
}

// MARK: - S5 · preview + words (B6)

struct ForkScheduleTextTests {
    static func draft(_ rule: ForkScheduleDraft.Repeat, minute: Int = 7 * 60, date: ForkCivilDate = ForkCivilDate(year: 2026, month: 10, day: 26)) -> ForkScheduleDraft {
        var draft = ForkScheduleDraft.new(sid: "t-0000", tz: "America/Chicago", today: date, threadRoot: nil)
        draft.repeatRule = rule
        draft.minute = minute
        return draft
    }

    @Test
    func previewIsTheNextFiveFromNow() {
        // V2's rule seen from 2026-10-29: the Monday 07:00 keeps its wall time across the 11-01 fall-back (A5-16).
        let preview = Self.draft(.weekly([0])).preview(now: ForkScheduleFixtures.date("2026-10-29T00:00:00Z"))
        #expect(preview.map(ForkScheduleTime.utcString) == ["2026-11-02T13:00:00Z", "2026-11-09T13:00:00Z", "2026-11-16T13:00:00Z",
                                                            "2026-11-23T13:00:00Z", "2026-11-30T13:00:00Z"])
        #expect(Self.draft(.once).preview(now: ForkScheduleFixtures.date("2026-10-29T00:00:00Z")).isEmpty) // 10-26 07:00 has passed
        #expect(Self.draft(.custom("FREQ=HOURLY")).preview(now: .now).isEmpty)
    }

    @Test
    func repeatWords() {
        #expect(ForkScheduleText.repeatWords(.once) == "Once")
        #expect(ForkScheduleText.repeatWords(.daily) == "Every day")
        #expect(ForkScheduleText.repeatWords(.weekdays) == "Weekdays")
        #expect(ForkScheduleText.repeatWords(.weekly([0])) == "Mondays")
        #expect(ForkScheduleText.repeatWords(.weekly([0, 2, 4])) == "Mon, Wed, Fri")
        #expect(ForkScheduleText.repeatWords(.weekly([0, 1, 2, 3, 4, 5, 6])) == "Every day")
        #expect(ForkScheduleText.repeatWords(.custom("FREQ=MONTHLY")) == "Custom repeat")
    }

    @Test
    func relativeWords() {
        let now = ForkScheduleFixtures.date("2026-11-02T12:00:00Z")
        #expect(ForkScheduleText.relative(ForkScheduleFixtures.date("2026-11-02T12:00:20Z"), now: now) == "now")
        #expect(ForkScheduleText.relative(ForkScheduleFixtures.date("2026-11-02T12:12:00Z"), now: now) == "in 12 min")
        #expect(ForkScheduleText.relative(ForkScheduleFixtures.date("2026-11-02T17:00:00Z"), now: now) == "in 5 h")
        #expect(ForkScheduleText.relative(ForkScheduleFixtures.date("2026-11-05T12:00:00Z"), now: now) == "in 3 d")
        #expect(ForkScheduleText.relative(ForkScheduleFixtures.date("2026-11-02T11:00:00Z"), now: now) == "1 h ago")
    }

    @Test
    func springForwardWarningOnlyFor2AM() {
        #expect(Self.draft(.daily, minute: 2 * 60 + 30).dstWarning == "2:00–2:59 doesn't exist on the spring-forward day, so that day is skipped.")
        #expect(Self.draft(.daily, minute: 3 * 60).dstWarning == nil)
        #expect(Self.draft(.daily, minute: 1 * 60 + 59).dstWarning == nil)
        var tokyo = Self.draft(.daily, minute: 2 * 60 + 30)
        tokyo.tz = "Asia/Tokyo"
        #expect(tokyo.dstWarning == nil)
    }

    @Test
    func outcomeWords() {
        #expect(ForkScheduleText.outcome("done") == "Done")
        #expect(ForkScheduleText.outcome("skipped_late") == "Skipped · late")
        #expect(ForkScheduleText.outcome("skipped_quiet") == "Skipped · quiet hours")
        #expect(ForkScheduleText.outcome("unknown_restart") == "Unknown · relay restarted")
        #expect(ForkScheduleText.outcome("brand_new") == "brand_new")
    }
}

// MARK: - putState over the wire (app target only: needs ForkMatrixREST)

#if !SWIFT_PACKAGE
struct ForkSchedulePutStateTests {
    static func client() -> ForkMatrixREST {
        ForkMatrixREST(userID: "@turner:example.org",
                       credentialsProvider: { _ in ForkSessionCredentials(accessToken: "t", homeserverURL: URL(string: "https://matrix.example.org")!) },
                       protocolClasses: [ForkScheduleStateServer.self])
    }

    @Test
    func scheduleStateIsPutAtItsPath() async throws {
        ForkScheduleStateServer.reset()
        let body = try ForkScheduleRoom.killContent(paused: true, ts: 5).sortedData()
        let eventID = try await Self.client().putState(roomID: "!room:example.org", type: "ai.autopute.schedule.kill", stateKey: "", content: body)
        #expect(eventID == "$state-1")
        let draftBody = try #require(ForkScheduleDraft(content: ForkScheduleRoomTests.schedule("Mine"))).content(updatedTS: 7).sortedData()
        _ = try await Self.client().putState(roomID: "!room:example.org", type: "ai.autopute.schedule", stateKey: "mine-0001", content: draftBody)
        let requests = ForkScheduleStateServer.requests()
        #expect(requests.map(\.method) == ["PUT", "PUT"])
        #expect(requests.map(\.path) == ["/_matrix/client/v3/rooms/%21room%3Aexample.org/state/ai.autopute.schedule.kill/",
                                          "/_matrix/client/v3/rooms/%21room%3Aexample.org/state/ai.autopute.schedule/mine-0001"])
        #expect(requests.first?.body == body)
    }

    @Test
    func otherTypesAndBigContentNeverLeaveThePhone() async {
        ForkScheduleStateServer.reset()
        for type in ["ai.autopute.schedule.status", "m.room.power_levels", "ai.autopute.artifact"] {
            await #expect(throws: ForkScheduleWrite.Refusal.typeNotAllowed) {
                try await Self.client().putState(roomID: "!room:example.org", type: type, stateKey: "", content: Data("{}".utf8))
            }
        }
        await #expect(throws: ForkScheduleWrite.Refusal.tooBig) {
            try await Self.client().putState(roomID: "!room:example.org", type: "ai.autopute.schedule", stateKey: "x",
                                             content: Data(repeating: 0x61, count: 8193))
        }
        #expect(ForkScheduleStateServer.requests().isEmpty)
    }

    @Test
    func forbiddenMeansNotSetUp() {
        #expect(ForkScheduleModel.words(for: ForkMatrixREST.RESTError.forbidden) == "This chat isn't set up for schedules yet. Ask the workshop to set it up.")
    }
}

/// A stub homeserver that records every request and answers a state PUT with a numbered event id.
nonisolated final class ForkScheduleStateServer: URLProtocol {
    struct Request: Sendable {
        let method: String
        let path: String
        let body: Data?
    }

    private static let log = Mutex([Request]())

    static func reset() { log.withLock { $0 = [] } }
    static func requests() -> [Request] { log.withLock { $0 } }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            stream.close()
            body = data
        }
        let entry = Request(method: request.httpMethod ?? "", path: url.path(percentEncoded: true), body: body)
        let number = Self.log.withLock { log -> Int in
            log.append(entry)
            return log.count
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"event_id":"$state-\#(number)"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}
#endif
