//
// TJ fork: Dev log list + receipts (iOS Workshop, Element card).
// Based on Element X iOS. SPDX-License-Identifier: AGPL-3.0-only
//
// Spec: WatchLab/Element/03_ARTIFACTS_SPEC.md rev 3, §3.4 (ticket schema + client rules), §5.7 (screens), D8.
// Native SwiftUI in PodLight DevKit's information architecture (title + 7-step stepper + progress). No DevKit networking:
// tickets are `ai.autopute.devlog.ticket` state events in #tj-devlog, read over REST with the operator's own session.
//

import SwiftUI

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
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var roomID: String?

    init(rest: ForkMatrixREST) {
        self.rest = rest
    }

    var pipeline: [ForkDevLogTicket] {
        tickets.filter(\.isInPipeline)
    }

    var history: [ForkDevLogTicket] {
        tickets.filter { !$0.isInPipeline }
    }

    func ticket(id: String) -> ForkDevLogTicket? {
        tickets.first { $0.id == id }
    }

    func appeared() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    func disappeared() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        do {
            let roomID = try await resolvedRoomID()
            let events = try await rest.state(roomID: roomID)
            tickets = ForkDevLogIndex.parse(stateEvents: events)
            phase = .loaded
        } catch ForkMatrixREST.RESTError.forbidden {
            phase = .notJoined
        } catch ForkMatrixREST.RESTError.notFound {
            phase = .error("The Dev Log room (\(ForkArtifactConstants.devlogAlias)) doesn't exist yet.")
        } catch ForkMatrixREST.RESTError.sessionExpired {
            phase = .error("Session expired: reopen TJ Element")
            disappeared()
        } catch ForkMatrixREST.RESTError.noSession {
            phase = .error("Can't reach the Dev log (signed-in session not found)")
        } catch {
            if !(error is CancellationError), tickets.isEmpty { phase = .error("Can't reach the Dev log right now") }
        }
    }

    func join() async {
        isJoining = true
        defer { isJoining = false }
        do {
            roomID = try await rest.join(ForkArtifactConstants.devlogAlias)
            await refresh()
        } catch {
            phase = .error("Couldn't join: \(ForkArtifactsModel.describe(error))")
        }
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
            case .error(let message):
                Text(message).foregroundStyle(.secondary)
            case .loaded:
                if model.tickets.isEmpty {
                    Text("No tickets yet.").foregroundStyle(.secondary)
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

struct ForkDevLogPipelineRow: View {
    let ticket: ForkDevLogTicket

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ticket.title).font(.headline)
            ForkStageStepper(ticket: ticket)
            HStack {
                if let label = ticket.progress?.label { Text(label) }
                Spacer()
                if let number = ticket.build?.number { Text("Build \(number)").monospacedDigit() }
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
                if let updated = ticket.updatedTS { Text(ForkDevLogFormat.relative(updated)) }
                Spacer()
                if let cost = ticket.cost?.totalUSD { Text(ForkDevLogFormat.usd(cost, estimate: ticket.cost?.totalIsEstimate == true)) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
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
        let layout = ForkStageStepperLayout.layout(stage: ticket.stage, stages: ticket.resolvedStages, progressDone: ticket.progress?.done)
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

enum ForkDevLogFormat {
    static func fraction(_ ticket: ForkDevLogTicket) -> Double {
        let total = max(ticket.progress?.total ?? ticket.resolvedStages.count, 1)
        return min(1, max(0, Double(ticket.progress?.done ?? 0) / Double(total)))
    }

    static func relative(_ ms: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(ms) / 1000).formatted(.relative(presentation: .named))
    }

    static func absolute(_ ms: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(ms) / 1000).formatted(date: .abbreviated, time: .shortened)
    }

    static func usd(_ value: Double, estimate: Bool) -> String {
        String(format: "$%.2f", value) + (estimate ? " est." : "")
    }

    static func tokens(_ value: Int?) -> String {
        guard let value else { return "–" }
        return value.formatted(.number.notation(.compactName))
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
                if let number = ticket.build?.number { Text("Build \(number)").monospacedDigit() }
                if let tf = ticket.build?.testflight { Text("· TestFlight \(tf)") }
                Spacer()
                if let updated = ticket.updatedTS { Text("Updated \(ForkDevLogFormat.relative(updated))") }
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
                                Text(item.costUSD.map { String(format: "$%.2f", $0) } ?? "").font(.caption.monospacedDigit())
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
                            Text([item.status, item.feature, item.costUSD.map { String(format: "$%.2f", $0) }].compactMap { $0 }.joined(separator: " · "))
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
                              run.costUSD.map { String(format: "$%.2f", $0) },
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
