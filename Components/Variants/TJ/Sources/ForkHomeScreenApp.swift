//
// TJ fork: Home Screen app launch — deep link router + app-mode overlay content (iOS Workshop, Element card).
// Based on Element X iOS. SPDX-License-Identifier: AGPL-3.0-only
//
// Spec: WatchLab/Element/03_ARTIFACTS_SPEC.md rev 3.4, §13.2. The ONE upstream line (Application.swift `openURL`) hands
// every opened URL to `ForkDeepLinkRouter.handle` first; anything that isn't `<scheme>://artifact?room=…&a=…` returns false
// and upstream routing carries on unchanged. The artifact goes through the existing per-room model, so §3.2 trust, mxc-only,
// sha256 and the sandboxed renderer all apply exactly as in the zone.
//

import OSLog
import SwiftUI

/// What an app-mode overlay shows: one artifact of one room, or a problem message.
struct ForkArtifactAppTarget: Equatable {
    let link: ForkArtifactDeepLink
    var problem: String?
}

@MainActor
final class ForkDeepLinkRouter {
    static let shared = ForkDeepLinkRouter()

    private let overlay = ForkArtifactOverlayController()
    private let logger = Logger(subsystem: "tj.artifacts", category: "homescreen")
    private var openRoute: ((AppRoute) -> Void)?
    private var current: (link: ForkArtifactDeepLink, model: ForkArtifactsModel?)?
    private var presentTask: Task<Void, Never>?

    var scheme: String {
        InfoPlistReader.app.appScheme
    }

    /// Called by upstream's `Application.openURL` before its own routing. Returns true when the URL was ours.
    func handle(_ url: URL, openRoute: @escaping (AppRoute) -> Void) -> Bool {
        guard let link = ForkArtifactDeepLink.parse(url, scheme: scheme) else { return false }
        self.openRoute = openRoute
        logger.notice("TJHOME open artifact \(link.aid, privacy: .public) in \(link.roomID, privacy: .public)")
        presentTask?.cancel()
        presentTask = Task { await present(link) }
        return true
    }

    // MARK: - Private

    private func present(_ link: ForkArtifactDeepLink) async {
        guard let scene = await waitForScene() else {
            logger.error("TJHOME no window scene to present on")
            return
        }
        guard let userID = Self.signedInUser() else {
            show(ForkArtifactAppTarget(link: link, problem: "Sign in to TJ Element first, then tap the icon again."), model: nil, on: scene)
            return
        }
        let model = ForkArtifactsStore.shared.model(roomID: link.roomID, userID: userID)
        if model.isFullScreen, current?.model !== model {
            // The room's own full screen is already up for this chat: just switch it to this artifact.
            model.selectedAID = link.aid
            return
        }
        model.selectedAID = link.aid
        model.setFullScreen(true)
        show(ForkArtifactAppTarget(link: link), model: model, on: scene)
        await model.refresh()
    }

    private func show(_ target: ForkArtifactAppTarget, model: ForkArtifactsModel?, on scene: UIWindowScene) {
        let model = model ?? ForkArtifactsModel(userID: "", roomID: target.link.roomID, rest: ForkMatrixREST(userID: "") { _ in nil },
                                                cacheBase: FileManager.default.temporaryDirectory.appending(path: "TJHomeAppEmpty"))
        if let previous = current?.model, previous !== model {
            previous.setFullScreen(false)
        }
        current = (target.link, model)
        let exit: () -> Void = { [weak self] in self?.backToThread() }
        if overlay.isPresented {
            overlay.update(model: model, app: target, exit: exit)
        } else {
            overlay.present(model: model, on: scene, app: target, exit: exit)
        }
    }

    /// "← Thread": close the app overlay and open the room (the agent thread) as the root of the stack.
    private func backToThread() {
        guard let current else { overlay.dismiss(); return }
        overlay.dismiss()
        current.model?.setFullScreen(false)
        self.current = nil
        let isSignedIn = Self.signedInUser() != nil
        if isSignedIn {
            openRoute?(.room(roomID: current.link.roomID, via: []))
        }
    }

    /// Up to ~5 s for a cold start to connect a scene with a window.
    private func waitForScene() async -> UIWindowScene? {
        for _ in 0..<50 {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let ranked = scenes.sorted { Self.rank($0.activationState) < Self.rank($1.activationState) }
            if let scene = ranked.first(where: { !$0.windows.isEmpty }) { return scene }
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return nil }
        }
        return nil
    }

    private static func rank(_ state: UIScene.ActivationState) -> Int {
        switch state {
        case .foregroundActive: 0
        case .foregroundInactive: 1
        case .background: 2
        default: 3
        }
    }

    /// The signed-in user from upstream's session keychain (read only). Element X keeps one session; prefer the active one.
    private static func signedInUser() -> String? {
        let users = ForkMatrixREST.signedInUserIDs()
        if let active = ForkArtifactsStore.shared.activeUserID, users.contains(active) { return active }
        return users.sorted().first
    }
}

/// The app-mode canvas: exactly the linked artifact, or why it can't be shown.
struct ForkArtifactAppContent: View {
    let model: ForkArtifactsModel
    let target: ForkArtifactAppTarget

    var body: some View {
        Group {
            if let problem = target.problem {
                message(problem)
            } else if model.entries.contains(where: { $0.aid == target.link.aid }) {
                if model.selectedEntry?.aid == target.link.aid {
                    ForkArtifactCanvas(model: model, isFullScreenHost: true)
                } else {
                    // A refresh that briefly lacked this aid moved the selection; put it back (never show another artifact).
                    ProgressView().task { model.selectedAID = target.link.aid }
                }
            } else if !model.hasFetchedOnce {
                ProgressView("Opening…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                message(ForkHomeAppProblem.message(fetchFailure: model.fetchFailure, hasEntries: !model.entries.isEmpty))
            }
        }
        .background(Color(uiColor: .systemBackground))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tj_homeapp")
    }

    private func message(_ text: String) -> some View {
        ForkArtifactMessage(symbol: "square.stack.3d.up.slash", title: "Can't open this app", detail: text)
            .accessibilityIdentifier("tj_homeapp-problem")
    }
}

nonisolated enum ForkHomeAppProblem {
    static func message(fetchFailure: ForkMatrixREST.RESTError?, hasEntries: Bool) -> String {
        switch fetchFailure {
        case .forbidden?: "You're not in the chat this app comes from any more. Tap Thread to see your chats."
        case .notFound?: "The chat this app comes from doesn't exist on your server."
        case .noSession?: "Sign in to TJ Element first, then tap the icon again."
        case .sessionExpired?: "Your session expired. Open TJ Element and sign in again."
        case .some: "TJ Element can't reach your server right now. It keeps trying; tap Thread to go to the chat."
        case nil: hasEntries ? "This artifact isn't in that chat any more. It may have been removed."
            : "That chat has no artifacts any more."
        }
    }
}
