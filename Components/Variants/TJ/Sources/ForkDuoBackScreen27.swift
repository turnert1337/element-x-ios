//
// TJ fork: Duo back-screen card, the iOS 27.1 half (iOS Workshop, Element card).
// Based on Element X iOS. SPDX-License-Identifier: AGPL-3.0-only
//
// NOT COMPILED ON XCODE 26.6. `TJ_SDK27` is only set when building against an iOS 27.x SDK (fork.yml).
// Written from Apple's documentation (WatchLab/Element/research/duo/01_apple_web.md rows 74-78) before the SDK
// was available: every symbol below is UNVERIFIED until gate G1 greps the 27.1 SDK and G2 compiles it.
// Spec: WatchLab/Element/01_DUO_SPEC.md §5.3 (register / attach paths A and B), §7 (APIs).
//

#if IS_MAIN_APP && TJ_DUO_BACKSCREEN && TJ_SDK27

import SwiftUI

extension ForkDuoRuntime {
    static func makeAccessoryPresenter() -> ForkDuoAccessoryPresenter {
        if #available(iOS 27.1, *) {
            return ForkDuoCameraCaptureAccessoryPresenter()
        }
        return ForkDuoLoggingAccessoryPresenter()
    }
}

/// Registers the camera-capture scene accessory on the main window's root view controller (Duo outer display).
@available(iOS 27.1, *)
final class ForkDuoCameraCaptureAccessoryPresenter: ForkDuoAccessoryPresenter {
    static let configurationName = "TJDuoBackScreen"

    private var registration: UISceneAccessoryRegistration?
    private var connectObserver: NSObjectProtocol?
    private var lastPolicy: ForkDuoBackScreenPolicy?

    var stateSummary: String {
        guard let registration else { return "cam:reg=0" }
        return "cam:reg=1:avail=\(registration.isAvailable ? 1 : 0):en=\(registration.isEnabled ? 1 : 0)"
    }

    init() {
        // Attach path B (zero upstream edits): AppDelegate forces SceneDelegate on every role
        // (AppDelegate.swift:21-26), so observe the connection instead of relying on our delegate class.
        connectObserver = NotificationCenter.default.addObserver(forName: UIScene.willConnectNotification, object: nil, queue: .main) { note in
            let sceneID = (note.object as AnyObject?).map(ObjectIdentifier.init) // Notification isn't Sendable
            MainActor.assumeIsolated {
                guard let scene = UIApplication.shared.connectedScenes.first(where: { ObjectIdentifier($0) == sceneID }) as? UIWindowScene,
                      scene.session.role == .windowCameraCaptureAccessory else { return }
                ForkDuoBackScreenAccessoryAttach.attach(to: scene)
            }
        }
    }

    func apply(_ policy: ForkDuoBackScreenPolicy) {
        lastPolicy = policy
        if policy.shouldRegister, registration == nil {
            register()
        } else if !policy.shouldRegister, let registration {
            unregister(registration)
        }
        registration?.isEnabled = policy.isEnabled
        ForkDuoBackScreenAccessoryAttach.status = policy.callActive ? .call(since: policy.captureStart ?? .now) : .camera
    }

    private func register() {
        let mainWindow: UIWindow? = SceneDelegate.windowManager?.mainWindow
        guard let root = mainWindow?.rootViewController else {
            ForkDuoBackScreen.logger.error("DUO v=1 ev=backscreen register-failed reason=no-root")
            return
        }
        let configuration = UISceneConfiguration(name: Self.configurationName, sessionRole: .windowCameraCaptureAccessory)
        registration = root.registerSceneAccessory(.cameraCapture(sceneConfiguration: configuration))
        ForkDuoBackScreen.logger.notice("DUO v=1 ev=backscreen registered \(self.stateSummary, privacy: .public)")
    }

    private func unregister(_ registration: UISceneAccessoryRegistration) {
        let mainWindow: UIWindow? = SceneDelegate.windowManager?.mainWindow
        mainWindow?.rootViewController?.unregisterSceneAccessory(registration)
        self.registration = nil
        ForkDuoBackScreen.logger.notice("DUO v=1 ev=backscreen unregistered")
    }
}

/// Hosts the stateless card in a TJ-owned window on the accessory scene. Idempotent per scene.
@available(iOS 27.1, *)
enum ForkDuoBackScreenAccessoryAttach {
    static var status: ForkDuoBackScreenCard.Status = .camera {
        didSet { refresh() }
    }

    private static var windows: [ObjectIdentifier: UIWindow] = [:]

    static func attach(to scene: UIWindowScene) {
        let key = ObjectIdentifier(scene)
        guard windows[key] == nil else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: card())
        window.overrideUserInterfaceStyle = .dark
        window.isHidden = false
        windows[key] = window
        ForkDuoBackScreen.logger.notice("DUO v=1 ev=backscreen attached")
    }

    private static func refresh() {
        for window in windows.values {
            (window.rootViewController as? UIHostingController<ForkDuoBackScreenCard>)?.rootView = card()
        }
    }

    private static func card() -> ForkDuoBackScreenCard {
        ForkDuoBackScreenCard(status: status)
    }
}

#endif
