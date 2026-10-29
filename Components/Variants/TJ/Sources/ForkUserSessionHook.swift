//
// TJ fork: signed-in user hooks (iOS Workshop, Element card).
// Based on Element X iOS. SPDX-License-Identifier: AGPL-3.0-only
//
// Mirrors `DefaultUserSessionHook` (ElementX/Sources/AppHooks/Hooks/UserSessionHook.swift) except that the
// signed-in Developer options screen gets the Duo rows. Spec: WatchLab/Element/01_DUO_SPEC.md §5.4.
//

import MatrixRustSDK

nonisolated struct ForkUserSessionHook: UserSessionHookProtocol {
    #if IS_MAIN_APP
    func makeUserHooks(for clientProxy: ClientProxyProtocol) -> UserHooks {
        UserHooks(developerOptionsScreenHook: ForkDuoDeveloperRows(userID: clientProxy.userID))
    }
    #endif

    func configure(_ userSettings: UserSettings, forHomeserver homeserver: String) -> UserSettings {
        userSettings
    }
}
