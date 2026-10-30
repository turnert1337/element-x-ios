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
        static let foldAssist = "tj.duo.foldAssist"
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
        UserDefaults.standard.object(forKey: Key.probe) as? Bool ?? defaultProbeEnabled
    }

    /// Steward decision D1 (01_DUO_SPEC.md rev 3): the probe is compiled into every config (TestFlight included) but its
    /// pill and log lines are OFF by default in Release and on by default in Debug. In Release it is switched on from
    /// Settings > tap the version footer 7 times > Developer options > "Duo probe" (signed in; SettingsScreen.swift).
    static let defaultProbeEnabled: Bool = {
        #if DEBUG
        true
        #else
        false
        #endif
    }()

    /// iOS 27.1 fold assist (ForkDuoFold27.swift): keyboard continuity across a fold, sheets kept off an upright fold.
    /// Off = observe and log only.
    static var foldAssistEnabled: Bool {
        UserDefaults.standard.object(forKey: Key.foldAssist) as? Bool ?? true
    }

    static var backScreenMode: BackScreenMode {
        UserDefaults.standard.string(forKey: Key.backScreen).flatMap(BackScreenMode.init) ?? defaultBackScreenMode
    }

    /// v2 ships the card dark: Off, so nothing registers until the operator opts in for G4-device
    /// (01_DUO_SPEC.md §0.2 item 1, §4.1 item 3, §6.1). Status only becomes the default in v2.1, only if G4-device passes.
    static let defaultBackScreenMode: BackScreenMode = .off

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
    /// The signed-in user (from `ForkUserSessionHook.makeUserHooks(for:)`); nil pre-login, which hides the Dev log row
    /// (03_ARTIFACTS_SPEC.md §5.7).
    let userID: String?

    func generalSectionRows() -> AnyView? {
        // The protocol is nonisolated; AnyView.init is too, so wrap a stateless nonisolated host whose
        // (main-actor) body builds the real rows. No MainActor.assumeIsolated needed (AnyView isn't Sendable).
        AnyView(ForkDuoRowsHost(userID: userID))
    }
}

private nonisolated struct ForkDuoRowsHost: View {
    let userID: String?

    var body: some View {
        ForkDuoRowsView(userID: userID)
    }
}

private struct ForkDuoRowsView: View {
    let userID: String?

    #if TJ_DUO_PROBE
    @AppStorage(ForkDuoSettings.Key.probe) private var probeEnabled = ForkDuoSettings.defaultProbeEnabled
    #endif
    @AppStorage(ForkDuoSettings.Key.foldAssist) private var foldAssistEnabled = true
    @AppStorage(ForkDuoSettings.Key.backScreen) private var backScreenMode = ForkDuoSettings.defaultBackScreenMode.rawValue
    @AppStorage(ForkDuoSettings.Key.backScreenForceSim) private var forceSim = false

    #if DEBUG && targetEnvironment(simulator)
    @State private var isPreviewingCard = false
    #endif

    var body: some View {
        if let userID {
            // Pushed inside Settings' own stack; no "Jump to message" here (no room flow).
            NavigationLink {
                ForkDevLogSettingsDestination(userID: userID)
            } label: {
                Text("Dev log")
                Text("Workshop tickets and receipts (TJ Dev Log room).")
            }
            .accessibilityIdentifier("tj_settings-devlog")
        }

        #if TJ_DUO_PROBE
        // Compiled into every config (fork.yml); off by default in Release, on in Debug (D1).
        Toggle(isOn: $probeEnabled) {
            Text("Duo probe")
            Text("Logs size class, hinge, bars, fold regions and scenes (DuoProbe) and shows a 4 s pill after each change. Never content.")
        }
        .accessibilityIdentifier("tj_duo-probe_toggle")
        #endif

        Toggle(isOn: $foldAssistEnabled) {
            Text("Fold assist")
            Text("iPhone Duo (iOS 27.1): keeps the composer keyboard across a fold and sheets off the fold. Off = log only.")
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

/// Keeps ONE Dev log model for the pushed screen (build 3 built a new model, and a new REST client, on every re-render of the
/// Settings list, so the screen could show a model that never started polling). Shares the user's REST client.
private struct ForkDevLogSettingsDestination: View {
    let userID: String
    @State private var model: ForkDevLogModel?

    var body: some View {
        Group {
            if let model {
                ForkDevLogScreen(model: model, jumpToMessage: nil)
            } else {
                ProgressView()
            }
        }
        .onAppear {
            if model == nil { model = ForkDevLogModel(rest: ForkArtifactsStore.shared.rest(forUser: userID)) }
        }
    }
}

#endif
