//
// TJ fork: Schedule sheet, list + editor (iOS Workshop, Element card).
// Based on Element X iOS. SPDX-License-Identifier: AGPL-3.0-only
//
// Spec: WatchLab/Element/04_VOICE_SCHEDULE_SPEC.md rev 2, §B6, ticket T3 (Message kind; editor v1 = Once / Every day /
// Weekdays / Weekly + time + message, §G-1). A sheet, like Dev log (OD-9).
//

import SwiftUI

struct ForkScheduleSheet: View {
    let model: ForkScheduleModel
    let roomName: String
    let onDone: () -> Void
    let onOpenEvent: (String) -> Void

    @State private var path: [Route] = []

    enum Route: Hashable {
        case edit(String)
        case new
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Schedules")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done", action: onDone)
                            .accessibilityIdentifier("tj_schedule-done")
                    }
                    if model.room?.availability == .ready {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                path.append(.new)
                            } label: {
                                Label("New schedule", systemImage: "plus")
                            }
                            .accessibilityIdentifier("tj_schedule-new")
                        }
                    }
                }
                .navigationDestination(for: Route.self) { route in
                    destination(route)
                }
        }
        .task { await model.poll() }
    }

    @ViewBuilder
    private var content: some View {
        if let room = model.room {
            if let reason = room.availability.message {
                ContentUnavailableView {
                    Label("Schedules", systemImage: "calendar.badge.clock")
                } description: {
                    Text(reason)
                }
                .accessibilityIdentifier("tj_schedule-unavailable")
            } else {
                list(room)
            }
        } else if case .failed(let reason) = model.loadState {
            ContentUnavailableView {
                Label("Couldn't load schedules", systemImage: "exclamationmark.triangle")
            } description: {
                Text(reason)
            } actions: {
                Button("Retry") { Task { await model.refresh() } }
            }
        } else {
            ProgressView("Loading schedules…")
        }
    }

    private func list(_ room: ForkScheduleRoom) -> some View {
        let now = Date()
        return List {
            Section {
                Toggle("Pause all", isOn: Binding(get: { room.isPaused }, set: { paused in Task { await model.setPaused(paused) } }))
                    .disabled(model.isWriting)
                    .accessibilityIdentifier("tj_schedule-pause")
            } header: {
                Text(roomName)
            } footer: {
                if room.isPaused { Text("Nothing in this chat fires until you resume.") }
            }

            if let error = model.writeError {
                Section { Text(error).foregroundStyle(.red) }
            }

            Section {
                if room.entries.isEmpty {
                    Text("No schedules yet. Tap + to add one.")
                        .foregroundStyle(.secondary)
                }
                ForEach(room.entries) { entry in
                    row(entry, paused: room.isPaused, now: now)
                }
            } header: {
                Text("This chat")
            } footer: {
                if !model.isOperator {
                    Text("Only schedules \(ForkScheduleConstants.operatorID) writes ever run. You're signed in as \(model.userID).")
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: ForkScheduleRoom.Entry, paused: Bool, now: Date) -> some View {
        let label = ForkScheduleRow(entry: entry, paused: paused, now: now)
        if entry.draft != nil {
            NavigationLink(value: Route.edit(entry.sid)) { label }
                .accessibilityIdentifier("tj_schedule-row-\(entry.sid)")
                .swipeActions(edge: .trailing) {
                    Button("Delete", role: .destructive) { Task { await model.delete(entry) } }
                    Button(entry.isEnabled ? "Turn off" : "Turn on") { Task { await model.setEnabled(entry, !entry.isEnabled) } }
                        .tint(entry.isEnabled ? .gray : .green)
                }
        } else {
            label
                .accessibilityIdentifier("tj_schedule-row-\(entry.sid)")
                .swipeActions(edge: .trailing) {
                    Button("Delete", role: .destructive) { Task { await model.delete(entry) } }
                }
        }
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .new:
            ForkScheduleEditor(model: model, entry: nil, draft: Self.newDraft(), onOpenEvent: onOpenEvent) { path.removeAll() }
        case .edit(let sid):
            if let entry = model.room?.entries.first(where: { $0.sid == sid }), let draft = entry.draft {
                ForkScheduleEditor(model: model, entry: entry, draft: draft, onOpenEvent: onOpenEvent) { path.removeAll() }
            } else {
                ContentUnavailableView("This schedule was deleted.", systemImage: "calendar.badge.exclamationmark")
            }
        }
    }

    /// B6 defaults: device time zone, Once, 9:00 AM today (tomorrow once 9:00 has passed). Changing only the time moves the date
    /// with it (E6 S1, `ForkScheduleDraft.setTime`).
    private static func newDraft() -> ForkScheduleDraft {
        let tz = (try? ForkScheduleTime.zone(TimeZone.current.identifier)) != nil ? TimeZone.current.identifier : ForkScheduleConstants.defaultTZ
        return ForkScheduleDraft.new(tz: tz, now: Date(), threadRoot: nil)
    }
}

// MARK: - Row

struct ForkScheduleRow: View {
    let entry: ForkScheduleRoom.Entry
    let paused: Bool
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ForkScheduleUI.kindSymbol(entry.draft?.kind))
                .foregroundStyle(entry.isEnabled ? Color.accentColor : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(entry.isEnabled ? .primary : .secondary)
                if let draft = entry.draft {
                    Text(ForkScheduleUI.summary(draft))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let fireLine {
                    ForkScheduleUI.line(fireLine, color: .secondary)
                        .accessibilityIdentifier("tj_schedule-fires")
                }
                stateLine
            }
            Spacer(minLength: 8)
            if let last = entry.status?.runs.first {
                Circle()
                    .fill(ForkScheduleUI.outcomeColor(last.outcome))
                    .frame(width: 9, height: 9)
                    .padding(.top, 6)
                    .accessibilityLabel("Last run: \(ForkScheduleText.outcome(last.outcome))")
            }
        }
        .padding(.vertical, 2)
    }

    /// E6 S1: "Fires in 3 min" / "Fires tomorrow at 11:17 AM", from the relay's next fire, else from the schedule itself (so a
    /// wrong date shows even while the workshop hasn't confirmed yet).
    private var fireLine: String? {
        guard let draft = entry.draft, entry.isEnabled, !paused, entry.status?.error == nil,
              let zone = try? ForkScheduleTime.zone(draft.tz) else {
            return nil
        }
        guard let next = entry.status?.nextFire ?? draft.preview(now: now, count: 1).first else { return nil }
        return ForkScheduleText.countdown(to: next, now: now, zone: zone)
    }

    @ViewBuilder
    private var stateLine: some View {
        let confirmation = ForkScheduleConfirmation(updatedTS: entry.updatedTS, status: entry.status, now: now)
        if entry.draft == nil {
            ForkScheduleUI.line("This version of TJ Element can't edit this schedule.", color: .orange)
        } else if let message = confirmation.message {
            ForkScheduleUI.line(message, color: .orange)
                .accessibilityIdentifier("tj_schedule-waiting")
        } else if let error = entry.status?.error {
            ForkScheduleUI.line(ForkScheduleRoom.Status.message(for: error), color: .red)
        } else if !entry.isEnabled {
            ForkScheduleUI.line("Off", color: .secondary)
        } else if paused {
            ForkScheduleUI.line("Paused", color: .secondary)
        } else if fireLine == nil {
            ForkScheduleUI.line("Nothing left to fire", color: .secondary)
        }
    }
}

// MARK: - Editor

struct ForkScheduleEditor: View {
    let model: ForkScheduleModel
    let entry: ForkScheduleRoom.Entry?
    let onOpenEvent: (String) -> Void
    let onClose: () -> Void

    @State private var draft: ForkScheduleDraft
    /// E6 S1: false until the user picks a date, so a time picked alone lands on its next occurrence. An existing schedule whose
    /// start is still ahead keeps its date; one that has passed rolls like a new one.
    @State private var dateTouched: Bool
    @State private var saveRefusal: String?
    @State private var confirmDelete = false
    /// Made once, so a retried save can't create a second schedule.
    @State private var newSID: String?

    init(model: ForkScheduleModel, entry: ForkScheduleRoom.Entry?, draft: ForkScheduleDraft, onOpenEvent: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        self.model = model
        self.entry = entry
        self.onOpenEvent = onOpenEvent
        self.onClose = onClose
        _draft = State(initialValue: draft)
        _dateTouched = State(initialValue: entry != nil && (draft.startInstant ?? .distantPast) > Date())
    }

    private var zone: TimeZone {
        (try? ForkScheduleTime.zone(draft.tz)) ?? .gmt
    }

    private var problems: [ForkScheduleDraft.Problem] {
        draft.problems() + [draft.timingProblem(now: Date())].compactMap { $0 }
    }

    var body: some View {
        Form {
            Section("Title") {
                TextField("Monday workout", text: $draft.title)
                    .accessibilityIdentifier("tj_schedule-title")
            }
            Section {
                TextField("What should the message say?", text: $draft.brief, axis: .vertical)
                    .lineLimit(3...8)
                    .accessibilityIdentifier("tj_schedule-message")
            } header: {
                Text(draft.kind == .message ? "Message" : ForkScheduleUI.kindName(draft.kind))
            } footer: {
                Text(draft.kind == .message
                    ? "Sent by the workshop as an @mention, so your phone buzzes. \(ForkScheduleConstants.length(draft.brief))/\(ForkScheduleConstants.maxBrief)"
                    : "Call and Agent task schedules can be edited here, but the workshop doesn't run them yet.")
            }
            whenSection
            previewSection
            if let entry { statusSections(entry) }
            if !problems.isEmpty || saveRefusal != nil {
                Section {
                    ForEach(problems, id: \.self) { problem in
                        Text(ForkScheduleUI.words(problem)).foregroundStyle(problem == .inPast ? Color.red : .secondary)
                    }
                    if let saveRefusal, !problems.contains(.inPast) {
                        Text(saveRefusal).foregroundStyle(.red)
                    }
                }
                .accessibilityIdentifier("tj_schedule-problems")
            }
            // Also at the end: on the closed Duo, scrolling hides the navigation bar and its Save (T3 G-S-A2 run).
            Section {
                Button(entry == nil ? "Save schedule" : "Save changes", action: save)
                    .frame(maxWidth: .infinity)
                    .disabled(!problems.isEmpty || model.isWriting)
                    .accessibilityIdentifier("tj_schedule-save-bottom")
            }
            if entry != nil {
                Section {
                    Button("Delete schedule", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .navigationTitle(entry == nil ? "New schedule" : "Edit schedule")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                .disabled(!problems.isEmpty || model.isWriting)
                .accessibilityIdentifier("tj_schedule-save")
            }
        }
        .confirmationDialog("Delete \(draft.title)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let entry else { return }
                Task {
                    await model.delete(entry)
                    onClose()
                }
            }
        }
    }

    private func save() {
        // The clock moved since the last render: check the Once time again right now.
        if let late = draft.timingProblem(now: Date()) {
            saveRefusal = ForkScheduleUI.words(late)
            return
        }
        saveRefusal = nil
        if entry == nil {
            let sid = newSID ?? ForkScheduleDraft.makeSID(title: draft.title)
            newSID = sid
            draft.sid = sid
        }
        Task { if await model.save(draft) { onClose() } }
    }

    // MARK: When

    private var whenSection: some View {
        Section {
            Picker("Repeat", selection: repeatChoice) {
                ForEach(ForkScheduleUI.RepeatChoice.allCases.filter { $0 != .custom || isCustom }, id: \.self) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .accessibilityIdentifier("tj_schedule-repeat")
            if case .weekly(let days) = draft.repeatRule {
                ForkScheduleDayPicker(days: days) { draft.repeatRule = .weekly($0) }
            }
            if case .custom(let rule) = draft.repeatRule {
                LabeledContent("Rule", value: rule)
                    .font(.footnote.monospaced())
            }
            DatePicker(draft.repeatRule == .once ? "Date" : "Starts", selection: datePart, displayedComponents: .date)
                .accessibilityIdentifier("tj_schedule-date")
            DatePicker("Time", selection: timePart, displayedComponents: .hourAndMinute)
                .accessibilityIdentifier("tj_schedule-time")
            if draft.tz != ForkScheduleConstants.defaultTZ {
                LabeledContent("Time zone", value: draft.tz)
            }
            fireSummary
        } header: {
            Text("When")
        } footer: {
            if let warning = draft.dstWarning { Text(warning) }
        }
        .environment(\.timeZone, zone)
    }

    private var isCustom: Bool {
        if case .custom = draft.repeatRule { return true }
        return false
    }

    private var repeatChoice: Binding<ForkScheduleUI.RepeatChoice> {
        Binding {
            ForkScheduleUI.RepeatChoice(draft.repeatRule)
        } set: { choice in
            switch choice {
            case .once:
                draft.repeatRule = .once
                draft.setTime(minute: draft.minute, now: Date(), dateTouched: dateTouched)
            case .daily: draft.repeatRule = .daily
            case .weekdays: draft.repeatRule = .weekdays
            case .weekly: draft.repeatRule = .weekly([draft.date.weekday])
            case .custom: break
            }
        }
    }

    /// The full date the schedule fires (or starts) and how far away that is, so a wrong day can't hide (E6 S1).
    private var fireSummary: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 15)) { context in
            let next = draft.repeatRule == .once ? draft.startInstant : draft.preview(now: context.date, count: 1).first
            VStack(alignment: .leading, spacing: 3) {
                if let next {
                    Text(next.formatted(Date.FormatStyle(date: .complete, time: .shortened, timeZone: zone)))
                        .font(.callout.weight(.semibold))
                    let countdown = ForkScheduleText.countdown(to: next, now: context.date, zone: zone)
                    Text(countdown)
                        .font(.footnote)
                        .foregroundStyle(next.timeIntervalSince(context.date) < ForkScheduleOnce.minimumLead ? Color.red : .secondary)
                } else {
                    Text("Nothing will fire").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("tj_schedule-fire-summary")
        }
    }

    /// The draft's local date + time as a Date in the schedule's zone (the pickers run in that zone).
    private var wallClockDate: Date {
        ForkScheduleOnce.instant(date: draft.date, minute: draft.minute, zone: zone)
    }

    /// The date picker: the user chose a day, so it sticks.
    private var datePart: Binding<Date> {
        Binding {
            wallClockDate
        } set: { date in
            draft.date = ForkScheduleTime.localDate(of: date, in: zone)
            dateTouched = true
        }
    }

    /// The time picker: only the minute comes from it; the date follows unless the user picked one (E6 S1 root cause: this
    /// picker used to keep the default's rolled-over date).
    private var timePart: Binding<Date> {
        Binding {
            wallClockDate
        } set: { date in
            let local = Int(date.timeIntervalSince1970) + zone.secondsFromGMT(for: date)
            draft.setTime(minute: ((local % 86400) + 86400) % 86400 / 60, now: Date(), dateTouched: dateTouched)
        }
    }

    // MARK: Preview + status

    private var previewSection: some View {
        let next = draft.preview(now: Date())
        return Section("Next 5") {
            if next.isEmpty {
                Text(problems.isEmpty ? "Nothing will fire: that time has passed." : "Fix the schedule to see when it fires.")
                    .foregroundStyle(.secondary)
            }
            ForEach(next, id: \.self) { date in
                Text(date.formatted(Date.FormatStyle(date: .complete, time: .shortened, timeZone: zone)))
                    .font(.callout.monospacedDigit())
            }
        }
        .accessibilityIdentifier("tj_schedule-preview")
    }

    @ViewBuilder
    private func statusSections(_ entry: ForkScheduleRoom.Entry) -> some View {
        let confirmation = ForkScheduleConfirmation(updatedTS: entry.updatedTS, status: entry.status, now: Date())
        if confirmation.message != nil || entry.status?.error != nil {
            Section("Workshop") {
                if let message = confirmation.message { Text(message).foregroundStyle(.orange) }
                if let error = entry.status?.error { Text(ForkScheduleRoom.Status.message(for: error)).foregroundStyle(.red) }
            }
        }
        Section("History") {
            let runs = entry.status?.runs ?? []
            if runs.isEmpty {
                Text("No runs yet.").foregroundStyle(.secondary)
            }
            ForEach(runs) { run in
                ForkScheduleRunRow(run: run, zone: zone, onOpenEvent: onOpenEvent)
            }
        }
    }
}

struct ForkScheduleRunRow: View {
    let run: ForkScheduleRoom.Run
    let zone: TimeZone
    let onOpenEvent: (String) -> Void

    var body: some View {
        if let event = run.resultEvent {
            Button { onOpenEvent(event) } label: { label }
        } else {
            label
        }
    }

    private var label: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(ForkScheduleUI.outcomeColor(run.outcome)).frame(width: 9, height: 9).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(ForkScheduleText.outcome(run.outcome)).foregroundStyle(.primary)
                if let planned = run.planned {
                    Text(planned.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: zone)))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let detail = run.detail {
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if run.resultEvent != nil {
                Image(systemName: "arrow.up.forward.square").foregroundStyle(.tint)
            }
        }
    }
}

struct ForkScheduleDayPicker: View {
    let days: [Int]
    let onChange: ([Int]) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<7, id: \.self) { day in
                let on = days.contains(day)
                Button {
                    onChange(on ? days.filter { $0 != day } : (days + [day]).sorted())
                } label: {
                    Text(String(ForkScheduleText.shortDayNames[day].prefix(2)))
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background(on ? Color.accentColor : Color.secondary.opacity(0.15), in: Capsule())
                        .foregroundStyle(on ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(ForkScheduleText.dayNames[day])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

// MARK: - Shared bits

enum ForkScheduleUI {
    enum RepeatChoice: CaseIterable {
        case once
        case daily
        case weekdays
        case weekly
        case custom

        init(_ rule: ForkScheduleDraft.Repeat) {
            switch rule {
            case .once: self = .once
            case .daily: self = .daily
            case .weekdays: self = .weekdays
            case .weekly: self = .weekly
            case .custom: self = .custom
            }
        }

        var title: String {
            switch self {
            case .once: "Once"
            case .daily: "Every day"
            case .weekdays: "Weekdays"
            case .weekly: "Weekly"
            case .custom: "Custom (kept as is)"
            }
        }
    }

    static func kindSymbol(_ kind: ForkScheduleDraft.Kind?) -> String {
        switch kind {
        case .call: "phone"
        case .agent: "sparkles"
        case .message, nil: "text.bubble"
        }
    }

    static func kindName(_ kind: ForkScheduleDraft.Kind) -> String {
        switch kind {
        case .message: "Message"
        case .call: "Call"
        case .agent: "Agent task"
        }
    }

    /// The row's second line: "Once · Sat, Oct 31, 11:17 AM" (the date matters for a Once) or "Every day · 9:00 AM".
    static func summary(_ draft: ForkScheduleDraft) -> String {
        let words = ForkScheduleText.repeatWords(draft.repeatRule)
        guard draft.repeatRule == .once, let start = draft.startInstant, let zone = try? ForkScheduleTime.zone(draft.tz) else {
            return "\(words) · \(clock(draft.minute))"
        }
        return "\(words) · \(start.formatted(Date.FormatStyle(timeZone: zone).weekday(.abbreviated).month(.abbreviated).day())), \(clock(draft.minute))"
    }

    static func clock(_ minute: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(minute * 60)).formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: .gmt))
    }

    static func outcomeColor(_ outcome: String) -> Color {
        switch outcome {
        case "done": .green
        case "failed", "unknown_restart": .red
        default: .orange
        }
    }

    static func line(_ text: String, color: Color) -> some View {
        Text(text).font(.footnote).foregroundStyle(color)
    }

    static func words(_ problem: ForkScheduleDraft.Problem) -> String {
        switch problem {
        case .noTitle: "Add a title."
        case .titleTooLong: "Keep the title to \(ForkScheduleConstants.maxTitle) characters."
        case .noMessage: "Write the message."
        case .messageTooLong: "Keep the message to \(ForkScheduleConstants.maxBrief) characters."
        case .noDays: "Pick at least one day."
        case .tooBig: "This schedule is too long to save."
        case .inPast: "That time has passed. Pick a later time or date."
        case .rule(let error): ForkScheduleRoom.Status.message(for: error.rawValue)
        }
    }
}
