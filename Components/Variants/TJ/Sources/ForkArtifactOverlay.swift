//
// TJ fork: full-screen artifact overlay window (iOS Workshop, Element card).
// Based on Element X iOS. SPDX-License-Identifier: AGPL-3.0-only
//
// Spec: WatchLab/Element/03_ARTIFACTS_SPEC.md rev 3, §5.4a. A TJ-owned UIWindow on the room's scene, above the whole tab
// hierarchy, so a fold (which rebuilds the split at another structural identity) never touches it. One per scene.
// Graceful exit: > 30 s in the background, scene disconnect, or the window losing its scene → back to push/split with the
// web view re-adopted (no reload; the page has paused itself on visibilitychange/resize).
//

import SwiftUI
import UIKit

final class ForkArtifactOverlayWindow: UIWindow {
    override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        windowLevel = .normal + 1
        backgroundColor = .clear
        accessibilityIdentifier = "tj_artifacts-overlay"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// The exit button is a UIKit view on top of the hosting view: a SwiftUI button drawn over the WKWebView
/// (a UIViewRepresentable) never received the touch on iOS 27.1 (G-A2 run 1), because UIKit routes it to the web view.
final class ForkArtifactFullScreenHost: UIHostingController<ForkArtifactFullScreenView>, UIGestureRecognizerDelegate {
    var onExit: (() -> Void)?
    private let exitButton = UIButton(type: .system)
    private var fadeTask: Task<Void, Never>?

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityViewIsModal = true

        // White on a dark disc: readable over any artifact (games are often dark, diagrams light).
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "arrow.down.right.and.arrow.up.left",
                                      withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
        configuration.baseForegroundColor = .white
        configuration.background.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        configuration.background.strokeColor = UIColor.white.withAlphaComponent(0.35)
        configuration.background.strokeWidth = 1
        configuration.background.cornerRadius = 22
        exitButton.configuration = configuration
        exitButton.accessibilityLabel = "Exit full screen"
        exitButton.accessibilityIdentifier = "tj_artifacts-exit-fullscreen"
        exitButton.addAction(UIAction { [weak self] _ in self?.onExit?() }, for: .primaryActionTriggered)
        exitButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(exitButton)
        NSLayoutConstraint.activate([exitButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 10),
                                     exitButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
                                     exitButton.widthAnchor.constraint(equalToConstant: 44),
                                     exitButton.heightAnchor.constraint(equalToConstant: 44)])
        view.accessibilityElements = nil

        // Any touch wakes the button (fades to 30% after 3 s; never hidden).
        let wake = UITapGestureRecognizer(target: self, action: #selector(wakeButton))
        wake.cancelsTouchesInView = false
        wake.delegate = self
        view.addGestureRecognizer(wake)
        wakeButton()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        view.bringSubviewToFront(exitButton)
    }

    @objc private func wakeButton() {
        exitButton.alpha = 1
        fadeTask?.cancel()
        fadeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            UIView.animate(withDuration: 0.6) { self?.exitButton.alpha = 0.3 }
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}

struct ForkArtifactFullScreenView: View {
    let model: ForkArtifactsModel

    var body: some View {
        ForkArtifactCanvas(model: model, isFullScreenHost: true)
            .ignoresSafeArea()
            .statusBarHidden(true)
            .persistentSystemOverlays(.hidden)
            .onAppear { model.zoneAppeared() }
            .onDisappear { model.zoneDisappeared() }
    }
}

/// Owns at most one overlay window per scene.
final class ForkArtifactOverlayController {
    private var window: ForkArtifactOverlayWindow?
    private weak var previousKeyWindow: UIWindow?
    private var observers: [NSObjectProtocol] = []
    private var backgroundTask: Task<Void, Never>?
    private var backgroundedAt: Date?
    private var sceneCheck: Task<Void, Never>?
    private var onGracefulExit: (() -> Void)?

    var isPresented: Bool {
        window != nil
    }

    func present(model: ForkArtifactsModel, on scene: UIWindowScene, exit: @escaping () -> Void) {
        guard window == nil else { return }
        previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let overlay = ForkArtifactOverlayWindow(windowScene: scene)
        let host = ForkArtifactFullScreenHost(rootView: ForkArtifactFullScreenView(model: model))
        host.onExit = exit
        overlay.rootViewController = host
        overlay.makeKeyAndVisible()
        window = overlay
        onGracefulExit = exit
        observe(scene: scene)
    }

    func dismiss() {
        backgroundTask?.cancel()
        sceneCheck?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        onGracefulExit = nil
        guard let window else { return }
        window.rootViewController = nil
        window.isHidden = true
        self.window = nil
        previousKeyWindow?.makeKey()
    }

    private func observe(scene: UIWindowScene) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIScene.didEnterBackgroundNotification, object: scene, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didEnterBackground() }
        })
        observers.append(center.addObserver(forName: UIScene.willEnterForegroundNotification, object: scene, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willEnterForeground() }
        })
        observers.append(center.addObserver(forName: UIScene.didDisconnectNotification, object: scene, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.gracefulExit() }
        })
        sceneCheck = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let window else { return }
                if window.windowScene == nil { gracefulExit(); return }
            }
        }
    }

    private func didEnterBackground() {
        backgroundedAt = Date()
        backgroundTask?.cancel()
        backgroundTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.gracefulExit()
        }
    }

    private func willEnterForeground() {
        backgroundTask?.cancel()
        if let backgroundedAt, Date().timeIntervalSince(backgroundedAt) > 30 {
            gracefulExit()
        }
        backgroundedAt = nil
    }

    private func gracefulExit() {
        let exit = onGracefulExit
        exit?()
    }
}

/// Reports the hosting window's size and scene (no `UIScreen.main`), from `didMoveToWindow` and `layoutSubviews`.
struct ForkWindowMetricsReader: UIViewRepresentable {
    let onChange: (CGSize, UIWindowScene?) -> Void

    func makeUIView(context: Context) -> ForkWindowMetricsView {
        let view = ForkWindowMetricsView()
        view.isUserInteractionEnabled = false
        view.onChange = onChange
        return view
    }

    func updateUIView(_ uiView: ForkWindowMetricsView, context: Context) {
        uiView.onChange = onChange
    }
}

final class ForkWindowMetricsView: UIView {
    var onChange: ((CGSize, UIWindowScene?) -> Void)?
    private var lastSize: CGSize = .zero
    private weak var lastScene: UIWindowScene?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        report()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        report()
    }

    private func report() {
        guard let window else { return }
        let size = window.bounds.size
        guard size != lastSize || window.windowScene !== lastScene else { return }
        lastSize = size
        lastScene = window.windowScene
        let scene = window.windowScene
        let callback = onChange
        // Never mutate SwiftUI state during layout.
        Task { @MainActor in callback?(size, scene) }
    }
}
