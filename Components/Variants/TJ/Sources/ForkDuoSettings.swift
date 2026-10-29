//
// TJ fork: iPhone Duo settings (iOS Workshop, Element card).
// Based on Element X iOS. SPDX-License-Identifier: AGPL-3.0-only
//
// The `tj.duo.*` keys live in `UserDefaults.standard` (the app's own domain), so
// `xcrun simctl spawn <udid> defaults read com.turnertomlinson.element tj.duo.backScreen`
// reads them back. Spec: WatchLab/Element/01_DUO_SPEC.md §5.4, §6.1.
//

#if IS_MAIN_APP

import SwiftUI

nonisolated enum ForkDuoSettings {
    enum Key {
        static let probe = "tj.duo.probe"
        static let backScreen = "tj.duo.backScreen"
        static let backScreenForceSim = "tj.duo.backScreen.forceSim"
    }

    enum BackScreenMode: String, CaseIterable, Sendable {
        case off
        case statusOnly

        var title: String {
            switch self {
            case .off: "Off"
            case .statusOnly: "Status only"
            }
        }
    }

    static var probeEnabled: Bool {
        UserDefaults.standard.object(forKey: Key.probe) as? Bool ?? true
    }

    static var backScreenMode: BackScreenMode {
        UserDefaults.standard.string(forKey: Key.backScreen).flatMap(BackScreenMode.init) ?? .statusOnly
    }

    /// Simulator only: the sim has no camera, so this stands in for a running capture session (G4).
    static var backScreenForceSim: Bool {
        #if targetEnvironment(simulator)
        UserDefaults.standard.bool(forKey: Key.backScreenForceSim)
        #else
        false
        #endif
    }
}

/// Adds the Duo rows to the "General" section of Developer options.
/// Registered twice: as the pre-login `AppHooks.developerOptionsScreenHook` and, via `ForkUserSessionHook`,
/// as the signed-in `UserHooks.developerOptionsScreenHook` (`SettingsFlowCoordinator.swift:318`).
nonisolated struct ForkDuoDeveloperRows: DeveloperOptionsScreenHookProtocol {
    func generalSectionRows() -> AnyView? {
        // The protocol is nonisolated; AnyView.init is too, so wrap a stateless nonisolated host whose
        // (main-actor) body builds the real rows. No MainActor.assumeIsolated needed (AnyView isn't Sendable).
        AnyView(ForkDuoRowsHost())
    }
}

private nonisolated struct ForkDuoRowsHost: View {
    var body: some View {
        ForkDuoRowsView()
    }
}

private struct ForkDuoRowsView: View {
    @AppStorage(ForkDuoSettings.Key.probe) private var probeEnabled = true
    @AppStorage(ForkDuoSettings.Key.backScreen) private var backScreenMode = ForkDuoSettings.BackScreenMode.statusOnly.rawValue
    @AppStorage(ForkDuoSettings.Key.backScreenForceSim) private var forceSim = false

    #if DEBUG && targetEnvironment(simulator)
    @State private var isPreviewingCard = false
    #endif

    var body: some View {
        Toggle(isOn: $probeEnabled) {
            Text("Duo probe")
            Text("Logs size class, layout and scenes (DuoProbe) and shows a 4 s pill after each change. Never content.")
        }

        Picker(selection: $backScreenMode) {
            ForEach(ForkDuoSettings.BackScreenMode.allCases, id: \.rawValue) { mode in
                Text(mode.title).tag(mode.rawValue)
            }
        } label: {
            Text("Back-screen card")
            Text("iPhone Duo outer display while the camera is in use (iOS 27.1).")
        }

        #if targetEnvironment(simulator)
        Toggle(isOn: $forceSim) {
            Text("Force back-screen card")
            Text("Simulator only: pretend a capture session is running.")
        }
        #endif

        #if DEBUG && targetEnvironment(simulator)
        Button("Preview back-screen card") {
            isPreviewingCard = true
        }
        .sheet(isPresented: $isPreviewingCard) {
            ForkDuoBackScreenCardPreviewSheet()
        }
        #endif
    }
}

#endif
