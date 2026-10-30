//
// TJ fork: Schedules contract, pure layer (iOS Workshop, Element card).
// Based on Element X iOS. SPDX-License-Identifier: AGPL-3.0-only
//
// Spec: WatchLab/Element/04_VOICE_SCHEDULE_SPEC.md rev 2, §B2 (frozen v1 data model), §B2.4 (recurrence subset), §B2.5
// (trust), §B6 (app). The relay's evaluator (WatchLab/WatchLab/scripts/scheduler.py, T1/T2) is the reference: this is a
// line-for-line port of its S1 section, and both pass the same vectors (Tests/ForkScheduleVectors.json). Everything here
// is nonisolated and side-effect free.
//

import Foundation

// MARK: - Error codes (B2.2 `error`)

nonisolated enum ForkScheduleError: String, Error, Equatable, Sendable {
    case unknownV = "unknown_v"
    case unsupportedRRule = "unsupported_rrule"
    case unknownTZ = "unknown_tz"
    case badDtstart = "bad_dtstart"
    case badAction = "bad_action"
    case untrustedSender = "untrusted_sender"
    case roomNotSetup = "room_not_setup"
    case encryptedRoom = "encrypted_room"
}

// MARK: - Civil time (proleptic Gregorian, no Calendar: the relay's datetime/date arithmetic)

nonisolated struct ForkCivilDate: Equatable, Comparable, Sendable {
    let year: Int
    let month: Int
    let day: Int

    /// Days since 1970-01-01 (H. Hinnant's days_from_civil).
    var dayNumber: Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(dayNumber z0: Int) {
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        self.init(year: yoe + era * 400 + (month <= 2 ? 1 : 0), month: month, day: day)
    }

    /// Monday = 0 … Sunday = 6 (Python's `weekday()`); 1970-01-01 was a Thursday.
    var weekday: Int {
        ((dayNumber + 3) % 7 + 7) % 7
    }

    func adding(days: Int) -> ForkCivilDate {
        ForkCivilDate(dayNumber: dayNumber + days)
    }

    static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    /// Python's `date` range (years 1…9999) and a real day of the month.
    static func isValid(year: Int, month: Int, day: Int) -> Bool {
        (1...9999).contains(year) && (1...12).contains(month) && day >= 1 && day <= daysInMonth(year: year, month: month)
    }

    static func < (lhs: ForkCivilDate, rhs: ForkCivilDate) -> Bool {
        lhs.dayNumber < rhs.dayNumber
    }
}

nonisolated enum ForkScheduleTime {
    /// "YYYY-MM-DDTHH:MM:SSZ" (B2.2 `planned` / `next_fire`), nil for anything else.
    static func parseUTC(_ string: String) -> Date? {
        guard let match = string.wholeMatch(of: /(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z/),
              let y = Int(match.1), let mo = Int(match.2), let d = Int(match.3),
              let h = Int(match.4), let mi = Int(match.5), let s = Int(match.6),
              ForkCivilDate.isValid(year: y, month: mo, day: d), h < 24, mi < 60, s < 60 else {
            return nil
        }
        let seconds = ForkCivilDate(year: y, month: mo, day: d).dayNumber * 86400 + h * 3600 + mi * 60 + s
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    static func utcString(_ date: Date) -> String {
        let seconds = Int(date.timeIntervalSince1970.rounded(.down))
        let days = seconds >= 0 ? seconds / 86400 : (seconds - 86399) / 86400
        let rest = seconds - days * 86400
        let civil = ForkCivilDate(dayNumber: days)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ", civil.year, civil.month, civil.day, rest / 3600, rest % 3600 / 60, rest % 60)
    }

    /// The IANA zone, or `unknown_tz` (B2.1). The identifier must round-trip exactly, so a "GMT+5" form (Foundation turns it
    /// into "GMT+0500"; the relay's zoneinfo refuses it) fails. `knownTimeZoneIdentifiers` isn't used: it lacks real IANA
    /// names such as Asia/Kolkata (vector V41).
    static func zone(_ name: String?) throws(ForkScheduleError) -> TimeZone {
        guard let name, !name.isEmpty, !name.contains(".."), !name.hasPrefix("/"),
              let zone = TimeZone(identifier: name), zone.identifier == name || name == "UTC" else { // Foundation calls UTC "GMT"
            throw .unknownTZ
        }
        return zone
    }

    /// A local wall time (seconds since the epoch as if UTC) → the UTC instant, the relay's `fold=0` rule (RFC 5545):
    /// a time in a DST gap takes the pre-gap offset (`exists == false`), a repeated hour resolves to its first occurrence.
    static func utc(localSeconds: Int, in zone: TimeZone) -> (date: Date, exists: Bool) {
        let before = zone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(localSeconds - 86400)))
        let after = zone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(localSeconds + 86400)))
        let valid = Set([before, after]).compactMap { offset -> Int? in
            let instant = localSeconds - offset
            return zone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(instant))) == offset ? instant : nil
        }
        if let first = valid.min() {
            return (Date(timeIntervalSince1970: TimeInterval(first)), true)
        }
        return (Date(timeIntervalSince1970: TimeInterval(localSeconds - before)), false)
    }

    /// The local calendar date of an instant in a zone.
    static func localDate(of date: Date, in zone: TimeZone) -> ForkCivilDate {
        let local = Int(date.timeIntervalSince1970.rounded(.down)) + zone.secondsFromGMT(for: date)
        return ForkCivilDate(dayNumber: local >= 0 ? local / 86400 : (local - 86399) / 86400)
    }
}

// MARK: - Recurrence (B2.4 subset, fail closed; port of scheduler.py S1)

nonisolated struct ForkScheduleRule: Equatable, Sendable {
    enum Frequency: String, Sendable {
        case daily = "DAILY"
        case weekly = "WEEKLY"
        case monthly = "MONTHLY"
    }

    static let dayCodes = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]

    let frequency: Frequency
    let interval: Int
    /// Monday = 0 … Sunday = 6, sorted; nil = dtstart's weekday.
    let byDay: [Int]?
    /// 1…31 or -1 (last day); nil = dtstart's day.
    let byMonthDay: Int?
    let count: Int?
    let until: Date?

    private static func number(_ value: String, _ range: ClosedRange<Int>) throws(ForkScheduleError) -> Int {
        // Canonical digits only: no sign, no leading zero (vectors E11, E32).
        guard value.wholeMatch(of: /[1-9][0-9]{0,3}/) != nil, let number = Int(value), range.contains(number) else {
            throw .unsupportedRRule
        }
        return number
    }

    /// nil = one-shot. Parts in any order; WKST accepted and ignored (weeks start Monday); any other part, a duplicate,
    /// COUNT with UNTIL or a non-canonical number → `unsupported_rrule`.
    static func parse(_ rrule: String?) throws(ForkScheduleError) -> ForkScheduleRule? {
        guard let rrule else { return nil }
        var parts: [String: String] = [:]
        for part in rrule.split(separator: ";", omittingEmptySubsequences: false) {
            guard let equals = part.firstIndex(of: "=") else { throw .unsupportedRRule }
            let key = String(part[..<equals])
            let value = String(part[part.index(after: equals)...])
            guard !value.isEmpty, parts[key] == nil else { throw .unsupportedRRule }
            parts[key] = value
        }
        parts["WKST"] = nil
        guard let frequency = parts.removeValue(forKey: "FREQ").flatMap(Frequency.init(rawValue:)) else { throw .unsupportedRRule }
        let allowed: Set<String> = switch frequency {
        case .daily: ["INTERVAL", "COUNT", "UNTIL"]
        case .weekly: ["INTERVAL", "BYDAY", "COUNT", "UNTIL"]
        case .monthly: ["INTERVAL", "BYMONTHDAY", "COUNT", "UNTIL"]
        }
        guard Set(parts.keys).isSubset(of: allowed), !(parts["COUNT"] != nil && parts["UNTIL"] != nil) else { throw .unsupportedRRule }

        let interval = try number(parts["INTERVAL"] ?? "1", 1...52)
        var byDay: [Int]?
        if let value = parts["BYDAY"] {
            let days = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            let indices = days.compactMap { dayCodes.firstIndex(of: $0) }
            guard indices.count == days.count, Set(indices).count == indices.count else { throw .unsupportedRRule }
            byDay = indices.sorted()
        }
        var byMonthDay: Int?
        if let value = parts["BYMONTHDAY"] {
            guard value.wholeMatch(of: /-1|[1-9]|[12][0-9]|3[01]/) != nil else { throw .unsupportedRRule }
            byMonthDay = Int(value)
        }
        let count = try parts["COUNT"].map { value throws(ForkScheduleError) in try number(value, 1...1000) }
        var until: Date?
        if let value = parts["UNTIL"] {
            guard let match = value.wholeMatch(of: /(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z/),
                  let date = ForkScheduleTime.parseUTC("\(match.1)-\(match.2)-\(match.3)T\(match.4):\(match.5):\(match.6)Z") else {
                throw .unsupportedRRule
            }
            until = date
        }
        return ForkScheduleRule(frequency: frequency, interval: interval, byDay: byDay, byMonthDay: byMonthDay, count: count, until: until)
    }

    /// The dates period `k` holds (dtstart's period = 0), before the dtstart filter. A MONTHLY period whose month lacks the
    /// day holds none. nil = past year 9999 (nothing further exists).
    fileprivate func periodDays(from d0: ForkCivilDate, period k: Int) -> [ForkCivilDate]? {
        let days: [ForkCivilDate]
        switch frequency {
        case .daily:
            days = [d0.adding(days: k * interval)]
        case .weekly:
            let week = d0.adding(days: -d0.weekday + 7 * k * interval)
            days = (byDay ?? [d0.weekday]).map { week.adding(days: $0) }
        case .monthly:
            let m0 = d0.month - 1 + k * interval
            let year = d0.year + Int((Double(m0) / 12).rounded(.down))
            let month = ((m0 % 12) + 12) % 12 + 1
            guard year <= 9999 else { return nil }
            let last = ForkCivilDate.daysInMonth(year: year, month: month)
            let wanted = byMonthDay ?? d0.day
            let monthDay = wanted == -1 ? last : wanted
            days = monthDay <= last ? [ForkCivilDate(year: year, month: month, day: monthDay)] : []
        }
        return days.contains(where: { $0.year > 9999 }) ? nil : days
    }

    /// Whole periods between dtstart's date and `day` (used to jump ahead).
    fileprivate func periods(from d0: ForkCivilDate, to day: ForkCivilDate) -> Int {
        let span = switch frequency {
        case .daily: day.dayNumber - d0.dayNumber
        case .weekly: Int((Double(day.adding(days: -day.weekday).dayNumber - d0.adding(days: -d0.weekday).dayNumber) / 7).rounded(.down))
        case .monthly: (day.year - d0.year) * 12 + day.month - d0.month
        }
        return Int((Double(span) / Double(interval)).rounded(.down))
    }
}

nonisolated enum ForkScheduleRecurrence {
    /// Month lengths and leap days repeat every 400 years: a rule that produced nothing for that long never will (V51, V52).
    static let gregorianCycleMonths = 400 * 12
    /// A guard; no valid rule gets near it.
    static let maxCandidates = 200_000

    /// The local wall time "YYYY-MM-DDTHH:MM:00" (B2.1 `dtstart`) as (date, minute of day), or `bad_dtstart`.
    static func dtstart(_ value: String?) throws(ForkScheduleError) -> (date: ForkCivilDate, minute: Int) {
        guard let value, let match = value.wholeMatch(of: /(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):00/),
              let y = Int(match.1), let mo = Int(match.2), let d = Int(match.3), let h = Int(match.4), let mi = Int(match.5),
              ForkCivilDate.isValid(year: y, month: mo, day: d), h < 24, mi < 60 else {
            throw .badDtstart
        }
        return (ForkCivilDate(year: y, month: mo, day: d), h * 60 + mi)
    }

    /// The planned UTC instants >= `after`, in order, at most `count`; or the entry's error (checked tz, dtstart, rrule:
    /// the relay's order). RFC 5545 (B2.4): the dtstart instance always counts (a gap time takes the pre-gap offset); a
    /// later instance in a DST gap is omitted and not counted; a repeated hour resolves to its first occurrence; UNTIL is
    /// inclusive; COUNT counts only instances that exist; an unsynchronized dtstart is not an instance.
    static func nextInstants(tz: String?, dtstart value: String?, rrule: String?, after: Date, count: Int) throws(ForkScheduleError) -> [Date] {
        let zone = try ForkScheduleTime.zone(tz)
        let (d0, minute) = try dtstart(value)
        let rule = try ForkScheduleRule.parse(rrule)
        guard count > 0 else { return [] }
        let firstLocal = d0.dayNumber * 86400 + minute * 60
        guard let rule else {
            let (instant, _) = ForkScheduleTime.utc(localSeconds: firstLocal, in: zone)
            return instant >= after ? [instant] : []
        }

        var out: [Date] = []
        var produced = 0
        var candidates = 0
        var period = rule.count == nil ? max(0, rule.periods(from: d0, to: ForkScheduleTime.localDate(of: after, in: zone)) - 1) : 0
        var emptyPeriods = 0
        while true {
            guard let all = rule.periodDays(from: d0, period: period) else { return out }
            let days = all.filter { $0 >= d0 }
            if days.isEmpty {
                emptyPeriods += 1
                if emptyPeriods * rule.interval > gregorianCycleMonths { return out }
            } else {
                emptyPeriods = 0
            }
            for day in days {
                candidates += 1
                if candidates > maxCandidates { return out }
                let local = day.dayNumber * 86400 + minute * 60
                let (instant, exists) = ForkScheduleTime.utc(localSeconds: local, in: zone)
                if !exists, local != firstLocal { continue }
                if let until = rule.until, instant > until { return out }
                produced += 1
                if instant >= after {
                    out.append(instant)
                    if out.count >= count { return out }
                }
                if let limit = rule.count, produced >= limit { return out }
            }
            period += 1
        }
    }
}

// MARK: - Constants (B2.1–B2.3, B2.5)

nonisolated enum ForkScheduleConstants {
    static let scheduleType = "ai.autopute.schedule"
    static let statusType = "ai.autopute.schedule.status"
    static let killType = "ai.autopute.schedule.kill"
    static let operatorID = "@turner:autopute.ai"
    static let workshopBotID = "@tjtest:autopute.ai"
    static let defaultTZ = "America/Chicago"
    static let maxTitle = 48
    static let maxBrief = 2000
    static let maxNLSource = 280
    /// B2.1: serialized content ≤ 8 KiB (the relay measures it with spaced separators, so the editor keeps a margin).
    static let maxContentBytes = 8 * 1024
    static let editorByteMargin = 256
    /// B6: "Waiting for the workshop…" turns into "hasn't confirmed" after 3 minutes.
    static let confirmationWindow: TimeInterval = 180

    static func isValidSID(_ value: String) -> Bool {
        value.wholeMatch(of: /[a-z0-9][a-z0-9-]{0,62}/) != nil
    }

    static func isValidEventID(_ value: String) -> Bool {
        value.wholeMatch(of: /\$[A-Za-z0-9_\-+\/=.:]{1,255}/) != nil
    }

    /// Lengths as the relay counts them (Python `len`: Unicode code points, not grapheme clusters).
    static func length(_ value: String) -> Int {
        value.unicodeScalars.count
    }
}

// MARK: - Editor draft ↔ B2.1 content (TS5)

/// What the editor edits. It keeps the decoded content as `base`, so any key the editor doesn't model (a future field, a
/// call's settings, catch-up and grace) survives an edit unchanged, and a rule it can't show is kept as `.custom`.
nonisolated struct ForkScheduleDraft: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case message
        case call
        case agent
    }

    enum Repeat: Hashable, Sendable {
        case once
        case daily
        case weekdays
        /// Monday = 0 … Sunday = 6.
        case weekly([Int])
        /// A rule the v1 editor doesn't offer (MONTHLY, INTERVAL, COUNT/UNTIL, a non-canonical spelling): kept verbatim.
        case custom(String)

        static let weekdaysRRule = "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"

        init(rrule: String?) {
            guard let rrule else { self = .once; return }
            if rrule == "FREQ=DAILY" { self = .daily; return }
            if rrule == Self.weekdaysRRule { self = .weekdays; return }
            if rrule.hasPrefix("FREQ=WEEKLY;BYDAY=") {
                let codes = rrule.dropFirst("FREQ=WEEKLY;BYDAY=".count).split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                let days = codes.compactMap { ForkScheduleRule.dayCodes.firstIndex(of: $0) }
                if !days.isEmpty, days.count == codes.count, zip(days, days.dropFirst()).allSatisfy({ $0 < $1 }) {
                    self = .weekly(days)
                    return
                }
            }
            self = .custom(rrule)
        }

        var rrule: String? {
            switch self {
            case .once: nil
            case .daily: "FREQ=DAILY"
            case .weekdays: Self.weekdaysRRule
            case .weekly(let days): "FREQ=WEEKLY;BYDAY=" + Set(days).sorted().map { ForkScheduleRule.dayCodes[$0] }.joined(separator: ",")
            case .custom(let rule): rule
            }
        }
    }

    enum Problem: Hashable, Sendable {
        case noTitle
        case titleTooLong
        case noMessage
        case messageTooLong
        case noDays
        case tooBig
        /// E6 S1: a Once at or before the current time.
        case inPast
        /// E6 stage fix S1: a Once less than `ForkScheduleOnce.minimumLead` ahead (it hasn't passed, so it isn't `inPast`).
        case tooSoon
        case rule(ForkScheduleError)

        /// Depends on the clock (shown in red; re-checked at save).
        var isTiming: Bool {
            self == .inPast || self == .tooSoon
        }
    }

    /// A new schedule's sid is set at its first save, from the title (`makeSID`).
    var sid: String
    var title: String
    var enabled: Bool
    var tz: String
    var date: ForkCivilDate
    /// Minutes after local midnight (B2.1: seconds are always 0).
    var minute: Int
    var repeatRule: Repeat
    var kind: Kind
    var brief: String
    var threadRoot: String?
    var devlog: Bool
    private let base: [String: ForkJSON]

    /// A fresh Message schedule (B6 defaults: results in this thread when opened from one).
    static func new(sid: String, tz: String, today: ForkCivilDate, threadRoot: String?) -> ForkScheduleDraft {
        let base: [String: ForkJSON] = [
            "action": .object(["kind": .string(Kind.message.rawValue), "brief": .string(""), "thread_root": .null, "devlog": .bool(false)]),
            "catch_up": .string("skip"),
            "grace_min": .number(15),
        ]
        return ForkScheduleDraft(sid: sid, title: "", enabled: true, tz: tz, date: today, minute: 9 * 60, repeatRule: .once, kind: .message,
                                 brief: "", threadRoot: threadRoot, devlog: false, base: base)
    }

    private init(sid: String, title: String, enabled: Bool, tz: String, date: ForkCivilDate, minute: Int, repeatRule: Repeat, kind: Kind,
                 brief: String, threadRoot: String?, devlog: Bool, base: [String: ForkJSON]) {
        self.sid = sid
        self.title = title
        self.enabled = enabled
        self.tz = tz
        self.date = date
        self.minute = minute
        self.repeatRule = repeatRule
        self.kind = kind
        self.brief = brief
        self.threadRoot = threadRoot
        self.devlog = devlog
        self.base = base
    }

    /// nil when the content isn't an editable v1 schedule (the sheet then shows the entry read-only with its error).
    init?(sid: String = "", content: ForkJSON) {
        guard let object = content.object, object["v"]?.int == 1,
              let title = object["title"]?.string, let enabled = object["enabled"]?.bool, let tz = object["tz"]?.string,
              let start = try? ForkScheduleRecurrence.dtstart(object["dtstart"]?.string),
              let action = object["action"]?.object, let kind = action["kind"]?.string.flatMap(Kind.init(rawValue:)),
              let brief = action["brief"]?.string else {
            return nil
        }
        let rrule: String?
        switch object["rrule"] {
        case nil, .null?: rrule = nil
        case .string(let value)?: rrule = value
        default: return nil
        }
        let threadRoot: String?
        switch action["thread_root"] {
        case nil, .null?: threadRoot = nil
        case .string(let value)?: threadRoot = value
        default: return nil
        }
        let devlog: Bool
        switch action["devlog"] {
        case nil: devlog = false
        case .bool(let value)?: devlog = value
        default: return nil
        }
        self.init(sid: sid, title: title, enabled: enabled, tz: tz, date: start.date, minute: start.minute, repeatRule: Repeat(rrule: rrule),
                  kind: kind, brief: brief, threadRoot: threadRoot, devlog: devlog, base: object)
    }

    var dtstart: String {
        String(format: "%04d-%02d-%02dT%02d:%02d:00", date.year, date.month, date.day, minute / 60, minute % 60)
    }

    /// The B2.1 state content to PUT. An optional key the original lacked stays absent unless the editor set it.
    func content(updatedTS: Int) -> ForkJSON {
        var object = base
        object["v"] = .number(1)
        object["title"] = .string(title)
        object["enabled"] = .bool(enabled)
        object["tz"] = .string(tz)
        object["dtstart"] = .string(dtstart)
        Self.set(&object, "rrule", repeatRule.rrule.map(ForkJSON.string))
        object["updated_ts"] = .number(Double(updatedTS))
        var action = base["action"]?.object ?? [:]
        action["kind"] = .string(kind.rawValue)
        action["brief"] = .string(brief)
        Self.set(&action, "thread_root", threadRoot.map(ForkJSON.string))
        if devlog || action["devlog"] != nil { action["devlog"] = .bool(devlog) }
        object["action"] = .object(action)
        return .object(object)
    }

    /// Why Save is off (empty = the relay will accept it).
    func problems() -> [Problem] {
        var problems: [Problem] = []
        let titleLength = ForkScheduleConstants.length(title)
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { problems.append(.noTitle) }
        if titleLength > ForkScheduleConstants.maxTitle { problems.append(.titleTooLong) }
        if brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { problems.append(.noMessage) }
        if ForkScheduleConstants.length(brief) > ForkScheduleConstants.maxBrief { problems.append(.messageTooLong) }
        if case .weekly(let days) = repeatRule, days.isEmpty {
            problems.append(.noDays)
        } else {
            do {
                _ = try ForkScheduleRecurrence.nextInstants(tz: tz, dtstart: dtstart, rrule: repeatRule.rrule, after: .distantPast, count: 1)
            } catch {
                problems.append(.rule(error))
            }
        }
        let size = (try? content(updatedTS: Int(Date().timeIntervalSince1970 * 1000)).sortedData().count) ?? Int.max
        if size > ForkScheduleConstants.maxContentBytes - ForkScheduleConstants.editorByteMargin { problems.append(.tooBig) }
        return problems
    }

    /// B2.1 sid: a slug of the title plus 4 random base36 characters.
    static func makeSID(title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var slug = ""
        for scalar in folded.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                slug.unicodeScalars.append(scalar)
            } else if !slug.isEmpty, !slug.hasSuffix("-") {
                slug += "-"
            }
        }
        slug = String(slug.prefix(50))
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.isEmpty { slug = "schedule" }
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return slug + "-" + String((0..<4).map { _ in alphabet.randomElement()! })
    }

    private static func set(_ object: inout [String: ForkJSON], _ key: String, _ value: ForkJSON?) {
        if let value {
            object[key] = value
        } else if object[key] != nil {
            object[key] = .null
        }
    }
}

// MARK: - Once timing (E6 S1)

/// Test Round 1 (e2): a Once made at 11:16 for 11:17 was stored for tomorrow. The new-schedule default is 9:00 AM tomorrow once 9:00
/// has passed, and the time-only picker kept that date. Now a time picked without touching the date means its next occurrence.
nonisolated enum ForkScheduleOnce {
    /// A Once must be at least this far ahead at save, so the relay sees it before it's due (B3: an occurrence planned before the
    /// relay first sees the schedule never fires).
    static let minimumLead: TimeInterval = 30

    /// The instant a local date + minute names in the zone (the relay's fold=0 rule, `ForkScheduleTime.utc`).
    static func instant(date: ForkCivilDate, minute: Int, zone: TimeZone) -> Date {
        ForkScheduleTime.utc(localSeconds: date.dayNumber * 86400 + minute * 60, in: zone).date
    }

    /// The alarm-clock rule: today if that time is still ahead, else tomorrow.
    static func nextDate(minute: Int, now: Date, zone: TimeZone) -> ForkCivilDate {
        let today = ForkScheduleTime.localDate(of: now, in: zone)
        return instant(date: today, minute: minute, zone: zone) > now ? today : today.adding(days: 1)
    }
}

nonisolated extension ForkScheduleDraft {
    /// B6 defaults: Once at 9:00 AM, today or (once 9:00 has passed) tomorrow.
    static func new(tz: String, now: Date, threadRoot: String?) -> ForkScheduleDraft {
        let zone = (try? ForkScheduleTime.zone(tz)) ?? .gmt
        return new(sid: "", tz: tz, today: ForkScheduleOnce.nextDate(minute: 9 * 60, now: now, zone: zone), threadRoot: threadRoot)
    }

    /// The time picker: with the date untouched the date follows the time to its next occurrence, but only for a Once or a
    /// brand-new schedule. An existing repeating schedule keeps its start date (E6 stage fix P-B1): its dtstart anchors which
    /// days an INTERVAL/BYDAY rule fires on and where COUNT/UNTIL count from, so moving it would silently change the schedule.
    mutating func setTime(minute: Int, now: Date, dateTouched: Bool, isNew: Bool) {
        self.minute = minute
        guard !dateTouched, repeatRule == .once || isNew, let zone = try? ForkScheduleTime.zone(tz) else { return }
        date = ForkScheduleOnce.nextDate(minute: minute, now: now, zone: zone)
    }

    /// The instant the draft's date + time names (the Once fire time; a repeating rule's start).
    var startInstant: Date? {
        (try? ForkScheduleTime.zone(tz)).map { ForkScheduleOnce.instant(date: date, minute: minute, zone: $0) }
    }

    /// `.inPast` for a Once that has passed, `.tooSoon` for one seconds away. Separate from `problems()` because it depends on the
    /// clock and must not block Turn off / Delete on an old schedule.
    func timingProblem(now: Date) -> Problem? {
        guard repeatRule == .once, let start = startInstant else { return nil }
        let lead = start.timeIntervalSince(now)
        if lead <= 0 { return .inPast }
        return lead < ForkScheduleOnce.minimumLead ? .tooSoon : nil
    }
}

// MARK: - Rail item look (B6)

/// What the room's Schedule bar item shows. The iOS 26+ bar keeps only an item's icon image and label text (it drops
/// `.opacity` and `.accessibilityValue`), so the not-ready reason rides in the label and the dim is drawn into the icon.
nonisolated struct ForkScheduleRailLook: Equatable, Sendable {
    let isDimmed: Bool
    let accessibilityLabel: String
    let badge: String?

    /// `availability` is nil until the room's first `/state` read lands.
    init(availability: ForkScheduleRoom.Availability?, enabledCount: Int) {
        let reason = availability?.message
        isDimmed = reason != nil
        accessibilityLabel = reason.map { "Schedule. \($0)" } ?? "Schedule"
        badge = availability == .ready && enabledCount > 0 ? "\(enabledCount)" : nil
    }
}

// MARK: - Room snapshot (B2.5 trust as the app applies it, B6 availability)

/// One `/state` snapshot of a room, reduced to what the Schedule rail item and sheet show.
nonisolated struct ForkScheduleRoom: Equatable, Sendable {
    enum Availability: Equatable, Sendable {
        case ready
        case encrypted
        case noWorkshop
        case notSetUp

        /// B6: the explanation shown on tap when the rail item is disabled.
        var message: String? {
            switch self {
            case .ready: nil
            case .encrypted: "Schedules need an unencrypted room."
            case .noWorkshop: "The workshop isn't in this chat."
            case .notSetUp: "This chat isn't set up for schedules yet. Ask the workshop to set it up."
            }
        }
    }

    struct Run: Equatable, Sendable, Identifiable {
        let key: String
        let planned: Date?
        let outcome: String
        let lateBySeconds: Int?
        let detail: String?
        let resultEvent: String?

        var id: String { key + (planned.map(ForkScheduleTime.utcString) ?? "") }
    }

    /// B2.2, written by the workshop bot only.
    struct Status: Equatable, Sendable {
        let seenUpdatedTS: Int?
        let nextFire: Date?
        let error: String?
        let runs: [Run]

        init(content: ForkJSON) {
            seenUpdatedTS = content["seen_updated_ts"]?.int
            nextFire = content["next_fire"]?.string.flatMap(ForkScheduleTime.parseUTC)
            error = content["error"]?.string
            runs = (content["runs"]?.array ?? []).prefix(10).compactMap { run in
                guard let outcome = run["outcome"]?.string else { return nil }
                return Run(key: run["key"]?.string ?? "", planned: run["planned"]?.string.flatMap(ForkScheduleTime.parseUTC), outcome: outcome,
                           lateBySeconds: run["late_by_s"]?.int, detail: run["detail"]?.string,
                           resultEvent: run["result_event"]?.string.flatMap { ForkScheduleConstants.isValidEventID($0) ? $0 : nil })
            }
        }

        /// B6: a status `error` in plain words.
        static func message(for error: String) -> String {
            switch error {
            case "unsupported_rrule": "The relay doesn't understand this repeat rule."
            case "unknown_tz": "The relay doesn't know this time zone."
            case "bad_dtstart": "The start date or time isn't valid."
            case "bad_action": "The relay can't run this kind of schedule yet."
            case "unknown_v": "The relay can't read this schedule."
            case "untrusted_sender": "The relay won't run this: only schedules you write run."
            case "room_not_setup": "This chat isn't set up for schedules yet."
            case "encrypted_room": "Schedules don't run in encrypted rooms."
            default: "The relay refused this schedule (\(error))."
            }
        }
    }

    struct Entry: Equatable, Sendable, Identifiable {
        let sid: String
        let content: ForkJSON
        /// nil when the v1 editor can't open it (shown read-only).
        let draft: ForkScheduleDraft?
        let updatedTS: Int
        let status: Status?

        var id: String { sid }
        var title: String { content["title"]?.string ?? sid }
        var isEnabled: Bool { content["enabled"]?.bool == true }
    }

    let availability: Availability
    /// Trusted entries only (B2.5; A5-12: the app doesn't show anyone else's), by title.
    let entries: [Entry]
    /// Pause all (B2.3): only the operator's `.kill` counts.
    let isPaused: Bool

    /// B6 badge: enabled trusted schedules.
    var enabledCount: Int {
        entries.filter(\.isEnabled).count
    }

    /// The app can't read the relay config (B2.5 rule 4), so "set up" = the schedule event's power level is ≥ 100 (rule 2).
    /// Trusted = the operator (rule 1; the gate sender is a relay-side scratch-room exception the app never shows), at
    /// level ≥ 100 (rule 3, same level calculation as artifacts §3.2), v == 1 (rule 5).
    init(stateEvents: [ForkJSON], isEncrypted: Bool,
         operatorID: String = ForkScheduleConstants.operatorID, botID: String = ForkScheduleConstants.workshopBotID) {
        let levels = ForkPowerLevels(stateEvents: stateEvents)
        let isSetUp = (levels.content?["events"]?[ForkScheduleConstants.scheduleType]?.int ?? 0) >= 100
        let operatorTrusted = isSetUp && levels.senderLevel(operatorID) >= 100
        var encrypted = isEncrypted
        var botJoined = false
        var paused = false
        var schedules: [(sid: String, content: ForkJSON)] = []
        var statuses: [String: Status] = [:]

        for event in stateEvents {
            guard let type = event["type"]?.string, let key = event["state_key"]?.string, let sender = event["sender"]?.string else { continue }
            let content = event["content"] ?? .null
            switch type {
            case "m.room.encryption" where key.isEmpty:
                encrypted = true
            case "m.room.member" where key == botID:
                botJoined = content["membership"]?.string == "join"
            case ForkScheduleConstants.killType where key.isEmpty && sender == operatorID && operatorTrusted:
                paused = content["v"]?.int == 1 && content["paused"]?.bool == true
            case ForkScheduleConstants.statusType where sender == botID:
                statuses[key] = Status(content: content)
            case ForkScheduleConstants.scheduleType where sender == operatorID && operatorTrusted && ForkScheduleConstants.isValidSID(key):
                if content["v"]?.int == 1 { schedules.append((key, content)) }
            default:
                break
            }
        }

        availability = encrypted ? .encrypted : (!botJoined ? .noWorkshop : (!isSetUp ? .notSetUp : .ready))
        isPaused = paused
        entries = schedules.map { sid, content in
            Entry(sid: sid, content: content, draft: ForkScheduleDraft(sid: sid, content: content),
                  updatedTS: content["updated_ts"]?.int ?? 0, status: statuses[sid])
        }
        .sorted { ($0.title.localizedLowercase, $0.sid) < ($1.title.localizedLowercase, $1.sid) }
    }

    /// B2.3 content for Pause all (`paused: true`) / Resume (`false`).
    static func killContent(paused: Bool, ts: Int) -> ForkJSON {
        .object(["v": .number(1), "paused": .bool(paused), "ts": .number(Double(ts))])
    }
}

// MARK: - Relay confirmation (B6)

nonisolated enum ForkScheduleConfirmation: Equatable, Sendable {
    case confirmed
    case waiting
    case unconfirmed

    /// Confirmed once a trusted status reflects this version (`seen_updated_ts == updated_ts`); before that, "waiting" for 3
    /// minutes, then the Mac-may-be-asleep text (the operator's only signal that the relay isn't running).
    init(updatedTS: Int, status: ForkScheduleRoom.Status?, now: Date) {
        if status?.seenUpdatedTS == updatedTS {
            self = .confirmed
        } else if now.timeIntervalSince1970 - TimeInterval(updatedTS) / 1000 < ForkScheduleConstants.confirmationWindow {
            self = .waiting
        } else {
            self = .unconfirmed
        }
    }

    var message: String? {
        switch self {
        case .confirmed: nil
        case .waiting: "Waiting for the workshop…"
        case .unconfirmed: "The workshop hasn't confirmed. The Mac may be asleep; this won't fire until it does."
        }
    }
}

// MARK: - The one new state write (B6: extends artifacts §3.3 / §5.1)

nonisolated enum ForkScheduleWrite {
    enum Refusal: Error, Equatable {
        case typeNotAllowed
        case tooBig
    }

    /// `ForkMatrixREST.putState` writes nothing else: the schedule and Pause-all types, ≤ 8 KiB.
    static let allowedTypes: Set<String> = [ForkScheduleConstants.scheduleType, ForkScheduleConstants.killType]

    static func check(type: String, content: Data) throws(Refusal) {
        guard allowedTypes.contains(type) else { throw .typeNotAllowed }
        guard content.count <= ForkScheduleConstants.maxContentBytes else { throw .tooBig }
    }
}

// MARK: - Preview + words (B6)

nonisolated extension ForkScheduleDraft {
    /// B6 "Next 5 occurrences": from now, because an occurrence planned before the save never fires (B3 first-sight, A5-17).
    func preview(now: Date, count: Int = 5) -> [Date] {
        (try? ForkScheduleRecurrence.nextInstants(tz: tz, dtstart: dtstart, rrule: repeatRule.rrule, after: now, count: count)) ?? []
    }

    /// B2.4: the editor warns when the time is 02:00–02:59 in a zone that springs forward.
    var dstWarning: String? {
        guard (120..<180).contains(minute), let zone = try? ForkScheduleTime.zone(tz),
              zone.nextDaylightSavingTimeTransition(after: Date(timeIntervalSince1970: TimeInterval(date.dayNumber * 86400))) != nil else {
            return nil
        }
        return "2:00–2:59 doesn't exist on the spring-forward day, so that day is skipped."
    }
}

nonisolated enum ForkScheduleText {
    static let dayNames = ["Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays", "Sundays"]
    static let shortDayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    static let weekdayNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    static let shortMonthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    static func repeatWords(_ rule: ForkScheduleDraft.Repeat) -> String {
        switch rule {
        case .once: return "Once"
        case .daily: return "Every day"
        case .weekdays: return "Weekdays"
        case .weekly(let days):
            let sorted = Set(days).sorted()
            if sorted.count == 7 { return "Every day" }
            if sorted == [0, 1, 2, 3, 4] { return "Weekdays" }
            if sorted.count == 1 { return dayNames[sorted[0]] }
            return sorted.map { shortDayNames[$0] }.joined(separator: ", ")
        case .custom: return "Custom repeat"
        }
    }

    /// "in 3 d" / "in 5 h" / "in 12 min" / "now" / "1 h ago" (B6 row: the next fire).
    static func relative(_ date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        let magnitude = abs(seconds)
        if magnitude < 60 { return "now" }
        let words = magnitude < 3600 ? "\(Int(magnitude / 60)) min" : (magnitude < 86400 ? "\(Int(magnitude / 3600)) h" : "\(Int(magnitude / 86400)) d")
        return seconds > 0 ? "in \(words)" : "\(words) ago"
    }

    /// E6 S1: "Fires in 3 min" / "Fires today at 3:05 PM" / "Fires tomorrow at 11:17 AM" / "Fires Tuesday at 9:00 AM" /
    /// "Fires Fri, Nov 20 at 9:00 AM", in the schedule's zone. Fixed English, like the rest of the schedule words.
    static func countdown(to fire: Date, now: Date, zone: TimeZone) -> String {
        let seconds = fire.timeIntervalSince(now)
        guard seconds > 0 else { return "That time has passed" }
        if seconds < 60 { return "Fires in under a minute" }
        if seconds < 3600 { return "Fires in \(Int((seconds / 60).rounded(.up))) min" }
        let day = ForkScheduleTime.localDate(of: fire, in: zone)
        let today = ForkScheduleTime.localDate(of: now, in: zone)
        let local = Int(fire.timeIntervalSince1970.rounded(.down)) + zone.secondsFromGMT(for: fire)
        let clock = clock12(((local % 86400) + 86400) % 86400 / 60)
        switch day.dayNumber - today.dayNumber {
        case 0: return "Fires today at \(clock)"
        case 1: return "Fires tomorrow at \(clock)"
        case 2...6: return "Fires \(weekdayNames[day.weekday]) at \(clock)"
        default:
            let date = "\(shortDayNames[day.weekday]), \(shortMonthNames[day.month - 1]) \(day.day)"
            return "Fires \(day.year == today.year ? date : "\(date), \(day.year)") at \(clock)"
        }
    }

    static func clock12(_ minute: Int) -> String {
        let hour = minute / 60
        return "\(hour % 12 == 0 ? 12 : hour % 12):\(String(format: "%02d", minute % 60)) \(hour < 12 ? "AM" : "PM")"
    }

    /// B2.2 run outcomes in plain words.
    static func outcome(_ outcome: String) -> String {
        switch outcome {
        case "done": "Done"
        case "skipped_late": "Skipped · late"
        case "skipped_quiet": "Skipped · quiet hours"
        case "capped": "Skipped · daily cap"
        case "killed": "Skipped · paused"
        case "no_answer": "No answer"
        case "voicemail": "Voicemail"
        case "failed": "Failed"
        case "unknown_restart": "Unknown · relay restarted"
        default: outcome
        }
    }
}
