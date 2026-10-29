//
// TJ fork: coordinators for the Artifacts zone and TJ sheets (iOS Workshop, Element card).
// Based on Element X iOS. SPDX-License-Identifier: AGPL-3.0-only
//
// Spec: WatchLab/Element/03_ARTIFACTS_SPEC.md rev 3, §5.1 (compact: the zone is pushed onto the room's stack and
// becomes the main screen; sheets go through the split's sheet so they survive the stack <-> split swap).
//

import SwiftUI

/// The pushed zone (compact width). The system Back is "back to chat".
final class ForkArtifactsCoordinator: CoordinatorProtocol {
    let model: ForkArtifactsModel
    private let actions: ForkArtifactsActions

    init(model: ForkArtifactsModel, actions: ForkArtifactsActions) {
        self.model = model
        self.actions = actions
    }

    func toPresentable() -> AnyView {
        AnyView(ForkArtifactsScreen(model: model, actions: actions))
    }
}

/// Wraps a SwiftUI view as a coordinator, for TJ sheets presented through upstream's navigation coordinators.
final class ForkHostingCoordinator: CoordinatorProtocol {
    private let view: AnyView
    private let onStop: (() -> Void)?

    init(_ view: some View, onStop: (() -> Void)? = nil) {
        self.view = AnyView(view)
        self.onStop = onStop
    }

    func stop() {
        onStop?()
    }

    func toPresentable() -> AnyView {
        view
    }
}
