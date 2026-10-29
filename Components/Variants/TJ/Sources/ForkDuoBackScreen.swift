//
// TJ fork: Duo back-screen card state machine (iOS Workshop, Element card).
// Based on Element X iOS. SPDX-License-Identifier: AGPL-3.0-only
//
// Spec: WatchLab/Element/01_DUO_SPEC.md §5.3; prep notes: research/duo/06_prep_on_26.md §2 and A8.
// The controller computes the desired accessory state from old APIs (AVCaptureSession notifications,
// CXCallObserver, lock window, foreground, defaults) and hands it to a `ForkDuoAccessoryPresenter`.
// On the iOS 26 SDK the only presenter is `ForkDuoLoggingAccessoryPresenter`; the real 27.1 presenter
// (`registerSceneAccessory(.cameraCapture…)`) lives in ForkDuoBackScreen27.swift behind `#if TJ_SDK27`.
// The policy has no input that could carry identity, so the card can never show a name by construction.
//

#if IS_MAIN_APP

import AVFoundation
import CallKit
import os
import SwiftUI

// MARK: - Policy (pure, unit-tested in Components/Variants/TJ/Tests)

nonisolated struct ForkDuoBackScreenPolicy: Equatable, Sendable {
    var mode: ForkDuoSettings.BackScreenMode
    var captureRunning: Bool
    var forceSim: Bool
    var foreground: Bool
    var locked: Bool
    var callActive: Bool
    var captureStart: Date?

    var shouldRegister: Bool {
        mode != .off && (captureRunning || forceSim) && foreground
    }

    var isEnabled: Bool {
        !locked
    }

    func cardText(now: Date) -> String {
        guard callActive else { return "Camera on" }
        let elapsed = captureStart.map { now.timeIntervalSince($0) } ?? 0
        return "On a call · \(Self.formatElapsed(elapsed))"
    }

    /// m:ss under an hour, h:mm:ss past it (0:05, 12:34, 1:02:03).
    static func formatElapsed(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

#if TJ_DUO_BACKSCREEN

// MARK: - Presenter seam

protocol ForkDuoAccessoryPresenter: AnyObject {
    var stateSummary: String { get }
    func apply(_ policy: ForkDuoBackScreenPolicy)
}

/// iOS 26 SDK stand-in: logs what the 27.1 presenter would do (`wouldRegister` / `wouldUnregister` / `enabled=`).
final class ForkDuoLoggingAccessoryPresenter: ForkDuoAccessoryPresenter {
    private(set) var isRegistered = false
    private(set) var isEnabled = true

    var stateSummary: String {
        "log:reg=\(isRegistered ? 1 : 0):en=\(isEnabled ? 1 : 0)"
    }

    func apply(_ policy: ForkDuoBackScreenPolicy) {
        if policy.shouldRegister != isRegistered {
            isRegistered = policy.shouldRegister
            ForkDuoBackScreen.logger.notice("DUO v=1 ev=backscreen \(self.isRegistered ? "wouldRegister" : "wouldUnregister", privacy: .public) \(ForkDuoBackScreen.describe(policy), privacy: .public)")
        }
        if isRegistered, policy.isEnabled != isEnabled {
            isEnabled = policy.isEnabled
            ForkDuoBackScreen.logger.notice("DUO v=1 ev=backscreen enabled=\(self.isEnabled ? 1 : 0, privacy: .public) \(ForkDuoBackScreen.describe(policy), privacy: .public)")
        } else if !isRegistered {
            isEnabled = policy.isEnabled
        }
    }
}

// MARK: - Controller

final class ForkDuoBackScreen {
    static let shared = ForkDuoBackScreen()

    nonisolated static let logger = Logger(subsystem: "com.turnertomlinson.element", category: "DuoProbe")

    private var isStarted = false
    private var presenter: ForkDuoAccessoryPresenter = ForkDuoLoggingAccessoryPresenter()
    private var observers: [NSObjectProtocol] = []
    private let callObserver = CXCallObserver()
    private let callObserverDelegate = ForkDuoCallObserverDelegate()
    private var runningSessions: Set<ObjectIdentifier> = []
    private var captureStart: Date?
    private var foreground = true
    private var locked = false
    private var lastPolicy: ForkDuoBackScreenPolicy?

    var stateSummary: String {
        presenter.stateSummary
    }

    func start(presenter: ForkDuoAccessoryPresenter? = nil) {
        guard !isStarted else { return }
        isStarted = true
        if let presenter {
            self.presenter = presenter
        }
        foreground = UIApplication.shared.applicationState != .background
        callObserver.setDelegate(callObserverDelegate, queue: .main)

        let center = NotificationCenter.default
        observe(center, AVCaptureSession.didStartRunningNotification) { controller, session in
            guard let session else { return }
            if controller.runningSessions.isEmpty { controller.captureStart = .now }
            controller.runningSessions.insert(session)
            controller.recompute(reason: "capture-start")
        }
        observe(center, AVCaptureSession.didStopRunningNotification) { controller, session in
            guard let session else { return }
            controller.runningSessions.remove(session)
            if controller.runningSessions.isEmpty { controller.captureStart = nil }
            controller.recompute(reason: "capture-stop")
        }
        observe(center, UIApplication.didBecomeActiveNotification) { controller, _ in
            controller.foreground = true
            controller.recompute(reason: "active")
        }
        observe(center, UIApplication.didEnterBackgroundNotification) { controller, _ in
            controller.foreground = false
            controller.recompute(reason: "background")
        }
        observe(center, UIWindow.didBecomeVisibleNotification) { controller, objectID in controller.lockWindowChanged(objectID, visible: true) }
        observe(center, UIWindow.didBecomeHiddenNotification) { controller, objectID in controller.lockWindowChanged(objectID, visible: false) }
        observe(center, UserDefaults.didChangeNotification) { controller, _ in controller.recompute(reason: "defaults") }

        recompute(reason: "start")
    }

    func callsChanged() {
        recompute(reason: "call")
    }

    /// The current inputs, also used by the sim-only card preview.
    func currentPolicy() -> ForkDuoBackScreenPolicy {
        ForkDuoBackScreenPolicy(mode: ForkDuoSettings.backScreenMode,
                                captureRunning: !runningSessions.isEmpty,
                                forceSim: ForkDuoSettings.backScreenForceSim,
                                foreground: foreground,
                                locked: locked,
                                callActive: callObserver.calls.contains { !$0.hasEnded },
                                captureStart: captureStart)
    }

    private func recompute(reason: String) {
        let policy = currentPolicy()
        guard policy != lastPolicy else { return }
        lastPolicy = policy
        Self.logger.notice("DUO v=1 ev=backscreen-inputs reason=\(reason, privacy: .public) \(Self.describe(policy), privacy: .public)")
        presenter.apply(policy)
        #if TJ_DUO_PROBE
        ForkDuoProbe.shared.accessoryState = presenter.stateSummary
        #endif
    }

    private func lockWindowChanged(_ objectID: ObjectIdentifier?, visible: Bool) {
        let alternateWindow: UIWindow? = SceneDelegate.windowManager?.alternateWindow
        guard let objectID, let alternateWindow, objectID == ObjectIdentifier(alternateWindow) else { return }
        locked = visible
        recompute(reason: visible ? "lock" : "unlock")
    }

    /// Handlers get only the identity of `note.object` (Sendable), never the Notification itself.
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor (ForkDuoBackScreen, ObjectIdentifier?) -> Void) {
        observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
            let objectID = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                handler(ForkDuoBackScreen.shared, objectID)
            }
        })
    }

    nonisolated static func describe(_ policy: ForkDuoBackScreenPolicy) -> String {
        "mode=\(policy.mode.rawValue) capture=\(policy.captureRunning ? 1 : 0) force=\(policy.forceSim ? 1 : 0) fg=\(policy.foreground ? 1 : 0) locked=\(policy.locked ? 1 : 0) call=\(policy.callActive ? 1 : 0) register=\(policy.shouldRegister ? 1 : 0) enabled=\(policy.isEnabled ? 1 : 0)"
    }
}

nonisolated final class ForkDuoCallObserverDelegate: NSObject, CXCallObserverDelegate {
    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        Task { @MainActor in
            ForkDuoBackScreen.shared.callsChanged()
        }
    }
}

#endif // TJ_DUO_BACKSCREEN

#endif
