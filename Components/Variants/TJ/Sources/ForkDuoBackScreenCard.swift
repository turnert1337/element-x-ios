//
// TJ fork: Duo back-screen card view (iOS Workshop, Element card).
// Based on Element X iOS. SPDX-License-Identifier: AGPL-3.0-only
//
// Spec: WatchLab/Element/01_DUO_SPEC.md §5.3, §6.1. Stateless: the TJ mark, one status line and a clock.
// It takes no identity input (no room, no person, no avatar, no message), so it can never show one.
// On 27.1 it is hosted by the camera-capture accessory scene; on 26.6 it is only previewed in-app (sim).
//

#if IS_MAIN_APP

import SwiftUI

struct ForkDuoBackScreenCard: View {
    enum Status: Equatable {
        case call(since: Date)
        case camera
    }

    let status: Status

    var body: some View {
        // Qualified: ElementX has its own `TimelineView` (the room timeline).
        SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 10) {
                Text("TJ")
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundStyle(.secondary)
                Text(statusText(now: context.date))
                    .font(.system(size: 20, weight: .semibold))
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
                Text(context.date, format: .dateTime.hour().minute())
                    .font(.system(size: 34, weight: .light))
                    .monospacedDigit()
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        switch status {
        case .call: "TJ Element, on a call"
        case .camera: "TJ Element, camera on"
        }
    }

    private func statusText(now: Date) -> String {
        switch status {
        case .call(let since):
            ForkDuoBackScreenPolicy(mode: .statusOnly, captureRunning: true, forceSim: false, foreground: true,
                                    locked: false, callActive: true, captureStart: since).cardText(now: now)
        case .camera:
            ForkDuoBackScreenPolicy(mode: .statusOnly, captureRunning: true, forceSim: false, foreground: true,
                                    locked: false, callActive: false, captureStart: nil).cardText(now: now)
        }
    }
}

#if DEBUG && targetEnvironment(simulator)

/// Sim-only "Preview back-screen card" (Developer options). Dark by default, like the outer display.
struct ForkDuoBackScreenCardPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isCall = true
    @State private var isDark = true
    @State private var callStart = Date.now.addingTimeInterval(-65)

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                ForkDuoBackScreenCard(status: isCall ? .call(since: callStart) : .camera)
                    .frame(width: 300, height: 300)
                    .background(isDark ? Color.black : Color.white, in: .rect(cornerRadius: 40))
                    .environment(\.colorScheme, isDark ? .dark : .light)
                    .accessibilityIdentifier("tj-duo-card")
                Picker("Status", selection: $isCall) {
                    Text("Call").tag(true)
                    Text("Camera").tag(false)
                }
                .pickerStyle(.segmented)
                Toggle("Dark", isOn: $isDark)
            }
            .padding(24)
            .navigationTitle("Back-screen card")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#endif

#endif
