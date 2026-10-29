//
// TJ fork: Duo probe, geometry half (iOS Workshop, Element card).
// Based on Element X iOS. SPDX-License-Identifier: AGPL-3.0-only
//
// Spec: WatchLab/Element/01_DUO_SPEC.md §5.5; prep notes: research/duo/06_prep_on_26.md A3.
// Logs one machine-parsable line per change (subsystem com.turnertomlinson.element, category DuoProbe)
// and shows the same fields in a pill for 4 s. Never logs or shows content, names, room IDs or text.
// The 27.1 fields (hinge, vertical-bar edge, reserved regions) come from ForkDuoFold27.swift; `n/a` on older SDKs/OSes.
//
// Query: log show --last 5m --predicate 'subsystem == "com.turnertomlinson.element" AND category == "DuoProbe"'
//

#if IS_MAIN_APP && TJ_DUO_PROBE

import os
import SwiftUI

final class ForkDuoProbe {
    static let shared = ForkDuoProbe()

    nonisolated static let logger = Logger(subsystem: "com.turnertomlinson.element", category: "DuoProbe")

    private var isStarted = false
    private weak var mainScene: UIWindowScene?
    private weak var mainWindow: UIWindow?
    private var probeWindow: UIWindow?
    private let pill = ForkDuoPillModel()
    private var windowTraitRegistration: (any UITraitChangeRegistration)?
    private var rootTraitRegistration: (any UITraitChangeRegistration)?
    private weak var observedRoot: UIViewController?
    private var geometryObservation: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []
    private var isKeyboardVisible = false
    private var isLockScreenVisible = false
    private var pendingEmit: Task<Void, Never>?
    private var pillHideTask: Task<Void, Never>?

    /// Extra fields appended by other TJ components (e.g. the back-screen controller's `acc=` state).
    var accessoryState = "n/a"
    /// Artifacts zone posture (`-` | push | split | full), set by ForkRoomChrome (03_ARTIFACTS_SPEC.md §5.1).
    var artifactsState = "-"

    func start() {
        guard !isStarted else { return }
        isStarted = true

        let center = NotificationCenter.default
        observe(center, UIScene.didActivateNotification) { probe, _ in
            probe.attachIfNeeded()
            probe.scheduleEmit("scene-activate")
        }
        observe(center, UIScene.willConnectNotification) { probe, _ in probe.scheduleEmit("scene-connect") }
        observe(center, UIScene.didDisconnectNotification) { probe, _ in probe.scheduleEmit("scene-disconnect") }
        observe(center, UIResponder.keyboardDidShowNotification) { probe, _ in
            probe.isKeyboardVisible = true
            probe.scheduleEmit("kb")
        }
        observe(center, UIResponder.keyboardDidHideNotification) { probe, _ in
            probe.isKeyboardVisible = false
            probe.scheduleEmit("kb")
        }
        observe(center, UIWindow.didBecomeVisibleNotification) { probe, objectID in probe.windowVisibilityChanged(objectID, visible: true) }
        observe(center, UIWindow.didBecomeHiddenNotification) { probe, objectID in probe.windowVisibilityChanged(objectID, visible: false) }
        observe(center, UserDefaults.didChangeNotification) { probe, _ in probe.updateProbeWindowVisibility() }

        attachIfNeeded()
    }

    /// Emits one `ev=<event>` line right away (used by the sim driver's `dump`).
    func emitNow(_ event: String) {
        attachIfNeeded()
        let line = makeLine(event: event)
        Self.logger.notice("\(line, privacy: .public)")
        showPill(line)
    }

    // MARK: - Attachment

    private func attachIfNeeded() {
        guard let scene = Self.findMainScene() else { return }
        guard let window = Self.findMainWindow(in: scene, excluding: probeWindow) else { return }

        if scene !== mainScene || probeWindow == nil {
            mainScene = scene
            makeProbeWindow(on: scene)
            geometryObservation = scene.observe(\.effectiveGeometry, options: [.new]) { _, _ in
                Task { @MainActor in ForkDuoProbe.shared.scheduleEmit("geometry") }
            }
        }

        // Observe the MAIN window and its root view controller, not the probe window, so trait
        // overrides from the sim driver are seen exactly where SwiftUI sees them.
        let traits: [UITrait] = [UITraitHorizontalSizeClass.self, UITraitVerticalSizeClass.self, UITraitDisplayScale.self]
        if window !== mainWindow {
            if let old = mainWindow, let registration = windowTraitRegistration {
                old.unregisterForTraitChanges(registration)
            }
            mainWindow = window
            windowTraitRegistration = window.registerForTraitChanges(traits) { (_: UIWindow, _: UITraitCollection) in
                ForkDuoProbe.shared.scheduleEmit("trait")
            }
            scheduleEmit("attach")
        }
        if let root = window.rootViewController, root !== observedRoot {
            if let old = observedRoot, let registration = rootTraitRegistration {
                old.unregisterForTraitChanges(registration)
            }
            observedRoot = root
            rootTraitRegistration = root.registerForTraitChanges(traits) { (_: UIViewController, _: UITraitCollection) in
                ForkDuoProbe.shared.scheduleEmit("trait")
            }
        }
    }

    private func makeProbeWindow(on scene: UIWindowScene) {
        let window = UIWindow(windowScene: scene)
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 10)
        window.isUserInteractionEnabled = false
        window.backgroundColor = .clear
        let host = UIHostingController(rootView: ForkDuoPillView(model: pill))
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        window.rootViewController = host
        probeWindow = window
        updateProbeWindowVisibility()
    }

    private func windowVisibilityChanged(_ objectID: ObjectIdentifier?, visible: Bool) {
        let alternateWindow: UIWindow? = SceneDelegate.windowManager?.alternateWindow
        guard let objectID, let alternateWindow, objectID == ObjectIdentifier(alternateWindow) else { return }
        isLockScreenVisible = visible
        updateProbeWindowVisibility()
        scheduleEmit(visible ? "lock" : "unlock")
    }

    private func updateProbeWindowVisibility() {
        // Never key: `isHidden = false` alone shows the window without taking key status.
        probeWindow?.isHidden = isLockScreenVisible || !ForkDuoSettings.probeEnabled
    }

    // MARK: - Emission

    /// Coalesces bursts (a fold fires trait + geometry + layout) and lets the split view settle first.
    func scheduleEmit(_ event: String) {
        pendingEmit?.cancel()
        pendingEmit = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            self.attachIfNeeded()
            guard ForkDuoSettings.probeEnabled else { return }
            let line = self.makeLine(event: event)
            Self.logger.notice("\(line, privacy: .public)")
            self.showPill(line)
        }
    }

    private func showPill(_ line: String) {
        guard !isLockScreenVisible else { return }
        pill.text = line.replacingOccurrences(of: "DUO v=1 ", with: "")
        pillHideTask?.cancel()
        pillHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.pill.text = nil
        }
    }

    private func makeLine(event: String) -> String {
        guard let window = mainWindow, let scene = mainScene else {
            return "DUO v=1 ev=\(event) attached=0 mainScenes=\(Self.mainSceneCount())"
        }
        let root = window.rootViewController
        let traits = root?.traitCollection ?? window.traitCollection
        let layout = Self.inferLayout(root)
        let orientation = Self.orientationName(scene.effectiveGeometry.interfaceOrientation)
        let full = window.frame.size == scene.screen.bounds.size // upstream's isFullScreen rule (NavigationTabCoordinator.swift:499-502)
        let fields = [
            "DUO v=1",
            "ev=\(event)",
            "w=\(Int(window.bounds.width))",
            "h=\(Int(window.bounds.height))",
            "H=\(Self.sizeClassName(traits.horizontalSizeClass))",
            "Hw=\(Self.sizeClassName(window.traitCollection.horizontalSizeClass))",
            "V=\(Self.sizeClassName(traits.verticalSizeClass))",
            "scale=\(Self.format(traits.displayScale))",
            "screen=\(Int(scene.screen.bounds.width))x\(Int(scene.screen.bounds.height))",
            "full=\(full ? 1 : 0)",
            "orient=\(orientation)",
            "layout=\(layout.layout)",
            "collapsed=\(layout.collapsed)",
            "tabs=\(layout.tabs)",
            "mainScenes=\(Self.mainSceneCount())",
            "scenes=[\(Self.sceneSummary())]",
            "kb=\(isKeyboardVisible ? 1 : 0)",
            "lock=\(isLockScreenVisible ? 1 : 0)",
            Self.foldFields(),
            "acc=\(accessoryState)",
            "artifacts=\(artifactsState)"
        ]
        return fields.joined(separator: " ")
    }

    /// Handlers get only the identity of `note.object` (Sendable), never the Notification itself.
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor (ForkDuoProbe, ObjectIdentifier?) -> Void) {
        observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
            let objectID = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                handler(ForkDuoProbe.shared, objectID)
            }
        })
    }

    // MARK: - Helpers

    static func findMainScene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.session.userInfo?[SceneDelegate.sceneIDKey] as? String == SceneDelegate.mainSceneID }
    }

    static func findMainWindow(in scene: UIWindowScene, excluding probeWindow: UIWindow?) -> UIWindow? {
        let managed: UIWindow? = SceneDelegate.windowManager?.mainWindow
        if let managed, managed.windowScene === scene {
            return managed
        }
        return scene.windows.first { $0 !== probeWindow && $0.rootViewController != nil }
    }

    static func mainSceneCount() -> Int {
        UIApplication.shared.connectedScenes.count(where: { $0.session.userInfo?[SceneDelegate.sceneIDKey] as? String == SceneDelegate.mainSceneID })
    }

    /// Scene IDs are only ever "Main" or "other" (a secondary window's SwiftUI value could carry a room ID).
    static func sceneSummary() -> String {
        UIApplication.shared.connectedScenes.map { scene in
            let id = scene.session.userInfo?[SceneDelegate.sceneIDKey] as? String == SceneDelegate.mainSceneID ? "Main" : "other"
            let role = Self.roleName(scene.session.role)
            let state = switch scene.activationState {
            case .foregroundActive: "fa"
            case .foregroundInactive: "fi"
            case .background: "bg"
            default: "u"
            }
            return "\(id):\(role):\(state)"
        }
        .sorted()
        .joined(separator: ",")
    }

    /// Hinge, vertical-bar edge and reserved regions from the fold monitor (iOS 27.1 SDK and OS only).
    static func foldFields() -> String {
        #if TJ_SDK27
        if #available(iOS 27.1, *) {
            return ForkDuoFoldMonitor.shared.snapshot.probeFields
        }
        #endif
        return "hinge=n/a bar=n/a div=n/a"
    }

    static func roleName(_ role: UISceneSession.Role) -> String {
        if role == .windowApplication { return "app" }
        #if TJ_SDK27
        if #available(iOS 27.1, *), role == .windowCameraCaptureAccessory { return "camacc" }
        #endif
        return "other"
    }

    /// SwiftUI's NavigationSplitView / NavigationStack / TabView sit on UIKit containers. Element shows a
    /// NavigationStack in compact and a split in regular (NavigationCoordinators.swift:344), so a visible
    /// UISplitViewController means "split". Heuristic: `?` when nothing recognisable is found.
    static func inferLayout(_ root: UIViewController?) -> (layout: String, collapsed: String, tabs: String) {
        var split: UISplitViewController?
        var hasNavigation = false
        var tabBar: UITabBarController?
        var stack: [UIViewController] = root.map { [$0] } ?? []
        var visited = 0
        while let controller = stack.popLast(), visited < 400 {
            visited += 1
            if controller.isViewLoaded, controller.view.window != nil {
                if split == nil, let svc = controller as? UISplitViewController { split = svc }
                if controller is UINavigationController { hasNavigation = true }
                if tabBar == nil, let tbc = controller as? UITabBarController { tabBar = tbc }
            }
            stack.append(contentsOf: controller.children)
            if let presented = controller.presentedViewController, presented.presentingViewController === controller {
                stack.append(presented)
            }
        }
        let layout: String
        let collapsed: String
        if let split {
            layout = split.isCollapsed ? "stack" : "split"
            collapsed = split.isCollapsed ? "1" : "0"
        } else {
            layout = hasNavigation ? "stack" : "?"
            collapsed = "-"
        }
        let tabs: String
        if let tabBar {
            tabs = tabBar.tabBar.isHidden || tabBar.tabBar.alpha == 0 ? "bar-hidden" : "bar"
        } else {
            tabs = "none"
        }
        return (layout, collapsed, tabs)
    }

    static func sizeClassName(_ sizeClass: UIUserInterfaceSizeClass) -> String {
        switch sizeClass {
        case .compact: "C"
        case .regular: "R"
        default: "U"
        }
    }

    static func orientationName(_ orientation: UIInterfaceOrientation) -> String {
        switch orientation {
        case .portrait: "portrait"
        case .portraitUpsideDown: "portraitUpsideDown"
        case .landscapeLeft: "landscapeLeft"
        case .landscapeRight: "landscapeRight"
        default: "unknown"
        }
    }

    static func format(_ value: CGFloat) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }
}

@Observable
final class ForkDuoPillModel {
    var text: String?
}

private struct ForkDuoPillView: View {
    let model: ForkDuoPillModel

    var body: some View {
        VStack {
            if let text = model.text {
                Text(text)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.72), in: .rect(cornerRadius: 10))
                    .padding(.horizontal, 12)
                    .accessibilityHidden(true)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 4)
        .allowsHitTesting(false)
    }
}

#endif
