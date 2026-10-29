//
// TJ fork: Duo back-screen card, the iOS 27.1 half (iOS Workshop, Element card).
// Based on Element X iOS. SPDX-License-Identifier: AGPL-3.0-only
//
// NOT COMPILED ON XCODE 26.6. `TJ_SDK27` is only set when building against an iOS 27.x SDK (fork.yml), and every
// type here is `@available(iOS 27.1, *)`, so the app still runs on older iOS (deployment target 18.5).
// Spec: WatchLab/Element/01_DUO_SPEC.md rev 2 §5.3 (register, attach paths A and B, availability), §7 (APIs),
// rev 3 D4 (attach guard: TJ userInfo only, never while Off, path B only with a live registration; ForkDuoRules.swift).
// Symbols verified in iPhoneOS27.1.sdk (research/duo/07_g1_sdk_audit.md).
//
// Privacy: the card takes no identity input (ForkDuoBackScreenCard), the accessory is only registered while
// Element itself owns a running AVCaptureSession (native call / QR scanner) AND the operator has turned the
// mode on (default Off), and this file never creates, starts or fakes a capture session.
//

#if IS_MAIN_APP && TJ_DUO_BACKSCREEN && TJ_SDK27

import ObjectiveC
import SwiftUI

extension ForkDuoRuntime {
    static func makeAccessoryPresenter() -> ForkDuoAccessoryPresenter {
        if #available(iOS 27.1, *) {
            return ForkDuoCameraCaptureAccessoryPresenter()
        }
        return ForkDuoLoggingAccessoryPresenter()
    }
}

/// Registers the camera-capture scene accessory on the main window's root view controller.
/// "The system determines whether and where to present it" (UISceneAccessory.h:55); on the Duo that is expected to be
/// the outer display while the phone is open (tech talk 111464, unproven until G4-device).
@available(iOS 27.1, *)
final class ForkDuoCameraCaptureAccessoryPresenter: ForkDuoAccessoryPresenter {
    /// Not an Info.plist name: `UISceneConfiguration(name:)` (iOS 27.0) lets the system assign the accessory role.
    static let configurationName = "TJDuoBackScreen"
    /// Comes back as `UIScene.ConnectionOptions.sceneAccessoryUserInfo` (UISceneOptions.h:49-52).
    static let userInfo = ForkDuoAccessoryAttachGuard.userInfo

    private var registration: UISceneAccessoryRegistration?
    private weak var registeringRoot: UIViewController?
    private var availabilityView: ForkDuoAccessoryAvailabilityView?
    private var observers: [NSObjectProtocol] = []

    var stateSummary: String {
        guard let registration else { return "cam:reg=0" }
        return "cam:reg=1:avail=\(registration.isAvailable ? 1 : 0):en=\(registration.isEnabled ? 1 : 0):path=\(ForkDuoBackScreenAccessoryAttach.lastPath)"
    }

    init() {
        // Detach on disconnect, whichever path attached. Attaching never happens from a notification: path B needs the
        // connection options (sceneAccessoryUserInfo), which `UIScene.willConnectNotification` does not carry, so it
        // runs from `ForkDuoSceneConnectTap` (installed at the first registration, never while the mode is Off).
        observers.append(NotificationCenter.default.addObserver(forName: UIScene.didDisconnectNotification, object: nil, queue: .main) { note in
            let scene = note.object as? UIWindowScene // MainActor class, so Sendable
            MainActor.assumeIsolated {
                guard let scene else { return }
                ForkDuoBackScreenAccessoryAttach.detach(from: scene)
            }
        })
    }

    func apply(_ policy: ForkDuoBackScreenPolicy) {
        if policy.shouldRegister, registration == nil {
            register()
        } else if !policy.shouldRegister, let registration {
            unregister(registration)
        }
        // Spec §5.3: `isEnabled = !locked` (UISceneAccessoryRegistration.h:30, read-write).
        if let registration, registration.isEnabled != policy.isEnabled {
            registration.isEnabled = policy.isEnabled
            ForkDuoBackScreen.logger.notice("DUO v=1 ev=backscreen enabled=\(policy.isEnabled ? 1 : 0, privacy: .public)")
        }
        ForkDuoBackScreenAccessoryAttach.status = policy.callActive ? .call(since: policy.captureStart ?? .now) : .camera
    }

    private func register() {
        let mainWindow: UIWindow? = SceneDelegate.windowManager?.mainWindow
        guard let root = mainWindow?.rootViewController else {
            ForkDuoBackScreen.logger.error("DUO v=1 ev=backscreen register-failed reason=no-root")
            return
        }
        // CORRECTED at G1 (spec §5.3): init(name:) + delegateClass, never init(name:sessionRole:) (an Info.plist lookup;
        // the role "is assigned automatically… Clients do not set it directly", UIWindowScene.h:133-137).
        let configuration = UISceneConfiguration(name: Self.configurationName)
        configuration.delegateClass = ForkDuoBackScreenSceneDelegate.self
        // Path B's tap goes in before the first registration can make the system connect an accessory scene.
        ForkDuoSceneConnectTap.install()
        let registration = root.registerSceneAccessory(.cameraCapture(sceneConfiguration: configuration, userInfo: Self.userInfo))
        self.registration = registration
        registeringRoot = root
        ForkDuoBackScreenAccessoryAttach.hasLiveRegistration = true

        // `isAvailable` has no notification; it is observable in layoutSubviews/updateProperties
        // (UISceneAccessoryRegistration.h:24), so sample it from a zero-size TJ view. It goes on the main window,
        // not inside SwiftUI's hosting view.
        let availabilityView = ForkDuoAccessoryAvailabilityView(registration: registration)
        mainWindow?.addSubview(availabilityView)
        self.availabilityView = availabilityView

        ForkDuoBackScreen.logger.notice("DUO v=1 ev=backscreen registered \(self.stateSummary, privacy: .public)")
    }

    private func unregister(_ registration: UISceneAccessoryRegistration) {
        // Dismisses the accessory if it is presented (UIViewController.h:368-370).
        ForkDuoBackScreenAccessoryAttach.hasLiveRegistration = false
        (registeringRoot ?? SceneDelegate.windowManager?.mainWindow?.rootViewController)?.unregisterSceneAccessory(registration)
        // Belt and braces: no TJ window outlives the registration, even if the system is slow to disconnect the scene.
        ForkDuoBackScreenAccessoryAttach.detachAll(reason: "unregistered")
        availabilityView?.removeFromSuperview()
        availabilityView = nil
        self.registration = nil
        registeringRoot = nil
        ForkDuoBackScreen.logger.notice("DUO v=1 ev=backscreen unregistered")
        publishState()
    }

    fileprivate func publishState() {
        #if TJ_DUO_PROBE
        ForkDuoProbe.shared.accessoryState = stateSummary
        #endif
    }
}

/// Zero-size, non-interactive, accessibility-hidden view whose `updateProperties` / `layoutSubviews` read
/// `registration.isAvailable`. UIKit's automatic observation tracking re-runs them when the value changes.
@available(iOS 27.1, *)
final class ForkDuoAccessoryAvailabilityView: UIView {
    private let registration: UISceneAccessoryRegistration
    private var lastAvailable: Bool?

    init(registration: UISceneAccessoryRegistration) {
        self.registration = registration
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateProperties() {
        super.updateProperties()
        sample()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        sample()
    }

    private func sample() {
        let available = registration.isAvailable
        guard available != lastAvailable else { return }
        lastAvailable = available
        ForkDuoBackScreen.logger.notice("DUO v=1 ev=backscreen available=\(available ? 1 : 0, privacy: .public) enabled=\(self.registration.isEnabled ? 1 : 0, privacy: .public)")
        #if TJ_DUO_PROBE
        ForkDuoProbe.shared.accessoryState = "cam:reg=1:avail=\(available ? 1 : 0):en=\(registration.isEnabled ? 1 : 0):path=\(ForkDuoBackScreenAccessoryAttach.lastPath)"
        ForkDuoProbe.shared.scheduleEmit("accessory")
        #endif
    }
}

/// Attach path A: the configuration's delegate, "called for all lifecycle events associated with the scene accessory"
/// (UIViewController.h:~360-365). Never implements `windowScene(_:didUpdateEffectiveGeometry:)`: on 27.1 its
/// `previousEffectiveGeometry` is nil during scene init and crashes when read (research/duo/08_g1_probe.md:118).
@available(iOS 27.1, *)
final class ForkDuoBackScreenSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        // D4: path A attaches only for TJ's own accessory (userInfo "tj.duo.card") and never while the mode is Off.
        window = ForkDuoBackScreenAccessoryAttach.attachIfAllowed(to: windowScene, path: .a, userInfo: connectionOptions.sceneAccessoryUserInfo)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        guard let windowScene = scene as? UIWindowScene else { return }
        ForkDuoBackScreenAccessoryAttach.detach(from: windowScene)
        window = nil
    }
}

/// Hosts the stateless card in a TJ-owned window on the accessory scene. Idempotent per scene (A and B may both fire).
@available(iOS 27.1, *)
enum ForkDuoBackScreenAccessoryAttach {
    static var status: ForkDuoBackScreenCard.Status = .camera {
        didSet {
            guard status != oldValue else { return }
            refresh()
        }
    }

    /// Which attach path ran last ("-" = none yet). Logged for G4-GUI / G4-device.
    private(set) static var lastPath = "-"

    /// Set by `ForkDuoCameraCaptureAccessoryPresenter` while it holds a `UISceneAccessoryRegistration` (path B's guard).
    static var hasLiveRegistration = false

    private static var windows: [ObjectIdentifier: UIWindow] = [:]

    /// Every attach goes through the D4 guard (`ForkDuoAccessoryAttachGuard`). Returns nil, and creates nothing, when the
    /// guard refuses: not TJ's userInfo, mode Off, or (path B) no live registration.
    @discardableResult
    static func attachIfAllowed(to scene: UIWindowScene, path: ForkDuoAccessoryAttachGuard.Path, userInfo: Any?) -> UIWindow? {
        let mode = ForkDuoSettings.backScreenMode
        let isTJ = userInfo as? String == ForkDuoAccessoryAttachGuard.userInfo
        guard ForkDuoAccessoryAttachGuard.shouldAttach(path: path, userInfo: userInfo, mode: mode, hasLiveRegistration: hasLiveRegistration) else {
            ForkDuoBackScreen.logger.notice("DUO v=1 ev=backscreen attach-refused path=\(path.rawValue, privacy: .public) tj=\(isTJ ? 1 : 0, privacy: .public) mode=\(mode.rawValue, privacy: .public) reg=\(hasLiveRegistration ? 1 : 0, privacy: .public)")
            return nil
        }
        return attach(to: scene, path: path.rawValue)
    }

    private static func attach(to scene: UIWindowScene, path: String) -> UIWindow {
        let key = ObjectIdentifier(scene)
        if let existing = windows[key] {
            ForkDuoBackScreen.logger.notice("DUO v=1 ev=backscreen attach-skip path=\(path, privacy: .public)")
            return existing
        }
        let window = UIWindow(windowScene: scene)
        // Above anything SwiftUI's WindowGroup may have put on the forced SceneDelegate path.
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
        window.rootViewController = UIHostingController(rootView: card())
        window.overrideUserInterfaceStyle = .dark
        window.isHidden = false
        windows[key] = window
        lastPath = path
        ForkDuoBackScreen.logger.notice("DUO v=1 ev=backscreen attached path=\(path, privacy: .public)")
        return window
    }

    static func detach(from scene: UIWindowScene) {
        guard let window = windows.removeValue(forKey: ObjectIdentifier(scene)) else { return }
        window.isHidden = true
        ForkDuoBackScreen.logger.notice("DUO v=1 ev=backscreen detached")
    }

    static func detachAll(reason: String) {
        guard !windows.isEmpty else { return }
        for window in windows.values {
            window.isHidden = true
        }
        windows.removeAll()
        ForkDuoBackScreen.logger.notice("DUO v=1 ev=backscreen detached-all reason=\(reason, privacy: .public)")
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

/// Attach path B (zero upstream file edits). AppDelegate returns upstream's `SceneDelegate` for every role
/// (AppDelegate.swift:21-26), which may replace the TJ configuration's delegate, and `UIScene.willConnectNotification`
/// carries no connection options. So this wraps `SceneDelegate.scene(_:willConnectTo:options:)` at runtime: upstream's
/// implementation always runs first and unchanged, then, for camera-capture-accessory sessions only, TJ reads
/// `sceneAccessoryUserInfo` and asks the D4 guard. Main scenes return straight after upstream's code.
/// Installed once, at the first registration, so with the mode Off (the v2 default) upstream's method is never wrapped.
@available(iOS 27.1, *)
enum ForkDuoSceneConnectTap {
    private static var isInstalled = false

    private typealias WillConnect = @convention(c) (AnyObject, Selector, UIScene, UISceneSession, UIScene.ConnectionOptions) -> Void

    static func install() {
        guard !isInstalled else { return }
        isInstalled = true
        let selector = #selector(UISceneDelegate.scene(_:willConnectTo:options:))
        guard let method = class_getInstanceMethod(SceneDelegate.self, selector) else {
            ForkDuoBackScreen.logger.error("DUO v=1 ev=backscreen tap-failed reason=no-method")
            return
        }
        let original = unsafeBitCast(method_getImplementation(method), to: WillConnect.self)
        let wrapper: @convention(block) (AnyObject, UIScene, UISceneSession, UIScene.ConnectionOptions) -> Void = { delegate, scene, session, options in
            original(delegate, selector, scene, session, options)
            guard session.role == .windowCameraCaptureAccessory, let windowScene = scene as? UIWindowScene else { return }
            let userInfo = options.sceneAccessoryUserInfo
            MainActor.assumeIsolated {
                _ = ForkDuoBackScreenAccessoryAttach.attachIfAllowed(to: windowScene, path: .b, userInfo: userInfo)
            }
        }
        method_setImplementation(method, imp_implementationWithBlock(wrapper))
        ForkDuoBackScreen.logger.notice("DUO v=1 ev=backscreen tap-installed")
    }
}

#endif
