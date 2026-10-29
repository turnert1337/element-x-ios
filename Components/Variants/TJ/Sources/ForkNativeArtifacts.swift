//
// TJ fork: native (Xcode-pipe) artifact registry + the Timer (iOS Workshop, Element card).
// Based on Element X iOS. SPDX-License-Identifier: AGPL-3.0-only
//
// Spec: WatchLab/Element/03_ARTIFACTS_SPEC.md rev 3, §3.7 (registry), §3.2 rule 4 / D15 (min_build card), §5.5 (Timer).
// Adding a native_id is always an Xcode-pipe change: steward session → gates → TestFlight.
//

import SwiftUI

enum ForkNativeArtifacts {
    static let timerID = "timer"

    /// The compiled registry (§3.7).
    static let registry: [String: (ForkArtifactsModel) -> AnyView] = [
        timerID: { AnyView(ForkTimerArtifactView(model: $0)) }
    ]

    static var registeredIDs: Set<String> {
        Set(registry.keys)
    }

    static func decision(for entry: ForkArtifactEntry) -> ForkNativeGate.Decision {
        ForkNativeGate.decide(nativeID: entry.nativeID ?? "", minBuild: entry.minBuild, bundleVersion: ForkBuildInfo.bundleVersion, registry: registeredIDs)
    }
}

// MARK: - Clock (pure, unit-tested)

nonisolated struct ForkTimerClock: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable {
        case countdown
        case stopwatch
    }

    var mode: Mode = .countdown
    /// Non-nil while running.
    var startedAt: Date?
    var accumulated: TimeInterval = 0
    /// Countdown length.
    var target: TimeInterval? = 300
    var laps: [TimeInterval] = []
    /// Set when a countdown reaches zero ("Finished at h:mm").
    var finishedAt: Date?

    var isRunning: Bool {
        startedAt != nil
    }

    func elapsed(now: Date) -> TimeInterval {
        accumulated + (startedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    func remaining(now: Date) -> TimeInterval {
        max(0, (target ?? 0) - elapsed(now: now))
    }

    /// When a running countdown hits zero (the model's finish task sleeps until this).
    var fireDate: Date? {
        guard mode == .countdown, let startedAt, let target else { return nil }
        return startedAt.addingTimeInterval(max(0, target - accumulated))
    }

    var hasStarted: Bool {
        isRunning || accumulated > 0 || finishedAt != nil
    }

    mutating func start(now: Date) {
        guard startedAt == nil else { return }
        if mode == .countdown, finishedAt != nil || remaining(now: now) <= 0 {
            accumulated = 0
            finishedAt = nil
        }
        startedAt = now
    }

    mutating func pause(now: Date) {
        guard let startedAt else { return }
        accumulated += max(0, now.timeIntervalSince(startedAt))
        if mode == .countdown, let target { accumulated = min(accumulated, target) }
        self.startedAt = nil
    }

    mutating func reset() {
        startedAt = nil
        accumulated = 0
        laps = []
        finishedAt = nil
    }

    mutating func lap(now: Date) {
        guard mode == .stopwatch, isRunning else { return }
        laps.append(elapsed(now: now))
    }

    mutating func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        reset()
        mode = newMode
    }

    mutating func setTarget(_ seconds: TimeInterval) {
        reset()
        target = max(1, seconds)
    }

    mutating func markFinished(at date: Date) {
        startedAt = nil
        accumulated = target ?? accumulated
        finishedAt = date
    }

    static func format(_ interval: TimeInterval, tenths: Bool = false) -> String {
        let clamped = max(0, interval)
        let total = Int(clamped)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        var text = hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%02d:%02d", minutes, seconds)
        if tenths {
            text += String(format: ".%d", Int((clamped - Double(total)) * 10) % 10)
        }
        return text
    }

    static func spoken(_ interval: TimeInterval, suffix: String) -> String {
        let total = Int(max(0, interval.rounded()))
        let components = DateComponents(hour: total / 3600, minute: (total % 3600) / 60, second: total % 60)
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = total >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        return "\(formatter.string(from: components) ?? "\(total) seconds") \(suffix)"
    }
}

// MARK: - Timer view

struct ForkTimerArtifactView: View {
    let model: ForkArtifactsModel

    @State private var showingCustom = false
    @State private var customHours = 0
    @State private var customMinutes = 5
    @State private var customSeconds = 0

    private static let presets: [Int] = [1, 3, 5, 10, 25]

    var body: some View {
        GeometryReader { proxy in
            let landscapeShaped = proxy.size.width > proxy.size.height * 1.15
            ScrollView {
                Group {
                    if landscapeShaped {
                        HStack(alignment: .center, spacing: 24) {
                            digits.frame(maxWidth: .infinity)
                            controls.frame(maxWidth: 360)
                        }
                    } else {
                        VStack(spacing: 20) {
                            digits
                            controls
                        }
                    }
                }
                .padding(20)
                .frame(minHeight: proxy.size.height)
            }
        }
        .accessibilityIdentifier("tj_timer")
        .sheet(isPresented: $showingCustom) {
            customSheet
        }
    }

    private var clock: ForkTimerClock {
        model.timer
    }

    private var digits: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let now = context.date
            let value = clock.mode == .countdown ? clock.remaining(now: now) : clock.elapsed(now: now)
            VStack(spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    digitText(value, size: 88)
                    digitText(value, size: 64)
                    digitText(value, size: 44)
                    digitText(value, size: 30)
                }
                .scaleEffect(model.timerPulse ? 1.08 : 1)
                .animation(model.timerPulse ? .easeInOut(duration: 0.4).repeatCount(5, autoreverses: true) : .default, value: model.timerPulse)
                if let finishedAt = clock.finishedAt, clock.mode == .countdown {
                    Text("Finished at \(finishedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(clock.mode == .countdown ? ForkTimerClock.spoken(value, suffix: "remaining") : ForkTimerClock.spoken(value, suffix: "elapsed"))
            .accessibilityIdentifier("tj_timer-digits")
        }
    }

    private func digitText(_ value: TimeInterval, size: CGFloat) -> some View {
        Text(ForkTimerClock.format(value, tenths: clock.mode == .stopwatch))
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
    }

    private var controls: some View {
        VStack(spacing: 16) {
            Picker("Mode", selection: Binding(get: { clock.mode }, set: { mode in model.updateTimer { $0.setMode(mode) } })) {
                Text("Countdown").tag(ForkTimerClock.Mode.countdown)
                Text("Stopwatch").tag(ForkTimerClock.Mode.stopwatch)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("tj_timer-mode")

            if clock.mode == .countdown {
                countdownPresets
            }

            HStack(spacing: 12) {
                primaryButton
                if clock.mode == .stopwatch {
                    Button("Lap") { model.updateTimer { $0.lap(now: Date()) } }
                        .buttonStyle(.bordered)
                        .disabled(!clock.isRunning)
                        .accessibilityIdentifier("tj_timer-lap")
                }
                Button("Reset") { model.updateTimer { $0.reset() } }
                    .buttonStyle(.bordered)
                    .disabled(!clock.hasStarted)
                    .accessibilityIdentifier("tj_timer-reset")
            }
            .controlSize(.large)

            if clock.mode == .stopwatch, !clock.laps.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(clock.laps.enumerated().reversed()), id: \.offset) { index, lap in
                        HStack {
                            Text("Lap \(index + 1)")
                            Spacer()
                            Text(ForkTimerClock.format(lap, tenths: true)).monospacedDigit()
                        }
                        .font(.callout)
                    }
                }
                .padding(12)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var countdownPresets: some View {
        let target = Int(clock.target ?? 300)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.presets, id: \.self) { minutes in
                    Button("\(minutes) min") { model.updateTimer { $0.setTarget(TimeInterval(minutes * 60)) } }
                        .buttonStyle(.bordered)
                        .tint(target == minutes * 60 ? .accentColor : .secondary)
                        .accessibilityIdentifier("tj_timer-preset-\(minutes)")
                }
                Button("Custom…") {
                    customHours = target / 3600
                    customMinutes = (target % 3600) / 60
                    customSeconds = target % 60
                    showingCustom = true
                }
                .buttonStyle(.bordered)
            }
        }
        .disabled(clock.isRunning)
    }

    @ViewBuilder
    private var primaryButton: some View {
        if clock.isRunning {
            Button("Pause") { model.updateTimer { $0.pause(now: Date()) } }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("tj_timer-pause")
        } else {
            Button(clock.hasStarted && clock.finishedAt == nil ? "Resume" : "Start") { model.updateTimer { $0.start(now: Date()) } }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("tj_timer-start")
        }
    }

    private var customSheet: some View {
        NavigationStack {
            HStack(spacing: 0) {
                wheel("h", range: 0..<24, selection: $customHours)
                wheel("m", range: 0..<60, selection: $customMinutes)
                wheel("s", range: 0..<60, selection: $customSeconds)
            }
            .padding()
            .navigationTitle("Custom countdown")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingCustom = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set") {
                        let total = customHours * 3600 + customMinutes * 60 + customSeconds
                        model.updateTimer { $0.setTarget(TimeInterval(max(1, total))) }
                        showingCustom = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func wheel(_ unit: String, range: Range<Int>, selection: Binding<Int>) -> some View {
        Picker(unit, selection: selection) {
            ForEach(range, id: \.self) { Text("\($0) \(unit)").tag($0) }
        }
        .pickerStyle(.wheel)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - "Arrives in a TestFlight update" card (§3.2 rule 4)

struct ForkArrivesInUpdateCard: View {
    let entry: ForkArtifactEntry
    let needsBuild: Int?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: entry.symbolName)
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text(entry.title)
                    .font(.title2.bold())
                if let summary = entry.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.body)
                        .multilineTextAlignment(.center)
                }
                Label("Arrives in a TestFlight update", systemImage: "shippingbox")
                    .font(.headline)
                    .padding(.top, 6)
                Text("Built through Xcode. It appears once a TestFlight build with it is installed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let needsBuild {
                    Text("needs build ≥ \(String(needsBuild))")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("tj_native-card-needs-build")
                }
            }
            .padding(24)
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("tj_native-card")
    }
}
