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

final class ForkArtifactFullScreenHost: UIHostingController<ForkArtifactFullScreenView> {
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityViewIsModal = true
    }
}

struct ForkArtifactFullScreenView: View {
    let model: ForkArtifactsModel
    let exit: () -> Void

    @State private var dimmed = false
    @State private var fadeTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForkArtifactCanvas(model: model, isFullScreenHost: true)
                .ignoresSafeArea()
                .simultaneousGesture(TapGesture().onEnded { wake() })
            Button(action: exit) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .modifier(ForkRailCircleBackground(selected: false))
            }
            .buttonStyle(.plain)
            .opacity(dimmed ? 0.3 : 1)
            .animation(.easeInOut(duration: 0.6), value: dimmed)
            .padding(.leading, 10)
            .padding(.top, 6)
            .accessibilityLabel("Exit full screen")
            .accessibilityIdentifier("tj_artifacts-exit-fullscreen")
            .accessibilitySortPriority(1000)
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            model.zoneAppeared()
            wake()
        }
        .onDisappear {
            fadeTask?.cancel()
            model.zoneDisappeared()
        }
    }

    private func wake() {
        dimmed = false
        fadeTask?.cancel()
        fadeTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            dimmed = true
        }
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
        overlay.rootViewController = ForkArtifactFullScreenHost(rootView: ForkArtifactFullScreenView(model: model, exit: exit))
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
