//
// TJ fork runtime overrides (iOS Workshop, Element card).
// Based on Element X iOS. SPDX-License-Identifier: AGPL-3.0-only
//
// Added to the ElementX target only, via Components/Variants/TJ/fork.yml.
// No upstream Swift file is edited: AppCoordinator calls `appHooks.setUp()` before
// `appHooks.appSettingsHook.configure(...)`, and this extension supplies that `setUp()`.
//

#if IS_MAIN_APP

import Foundation

nonisolated extension AppHooks {
    func setUp() {
        registerAppSettingsHook(ForkAppSettingsHook())
    }
}

/// Modeled on `DefaultAppSettingsHook`. Passes every current value through unchanged except:
/// - `oAuthRedirectURL`: a custom scheme (no associated domain / AASA needed).
/// - `accountProviders`: the operator's own homeserver first (the login default), matrix.org second.
///   `allowOtherAccountProviders` stays `true`, so "Change server" still accepts any server (e.g. matrix.org).
nonisolated struct ForkAppSettingsHook: AppSettingsHookProtocol {
    /// Custom-scheme OAuth redirect. Must be the reversed host of the OAuth `client_uri`
    /// (`https://element.io/apps/ios`) for MAS to accept it.
    static let oAuthRedirectURL: URL = "io.element.tjfork:/callback"

    /// The operator's private homeserver: server name `autopute.ai` (.well-known delegated to matrix.autopute.ai).
    static let accountProviders: [AccountProvider] = [.managed(serverName: "autopute.ai", baseURL: "https://matrix.autopute.ai"),
                                                      .managed(serverName: "matrix.org", baseURL: "https://matrix-client.matrix.org")]

    @MainActor func configure(_ appSettings: AppSettings) -> AppSettings {
        appSettings.override(accountProviders: Self.accountProviders,
                             allowOtherAccountProviders: true,
                             hideBrandChrome: appSettings.hideBrandChrome,
                             pushGatewayBaseURL: appSettings.pushGatewayBaseURL,
                             oAuthRedirectURL: Self.oAuthRedirectURL,
                             oAuthClientURIPath: appSettings.oAuthClientURIPath,
                             websiteURL: appSettings.websiteURL,
                             logoURL: appSettings.logoURL,
                             copyrightURL: appSettings.copyrightURL,
                             acceptableUseURL: appSettings.acceptableUseURL,
                             privacyURL: appSettings.privacyURL,
                             encryptionURL: appSettings.encryptionURL,
                             deviceVerificationURL: appSettings.deviceVerificationURL,
                             chatBackupDetailsURL: appSettings.chatBackupDetailsURL,
                             identityPinningViolationDetailsURL: appSettings.identityPinningViolationDetailsURL,
                             historySharingDetailsURL: appSettings.historySharingDetailsURL,
                             elementWebHosts: appSettings.elementWebHosts,
                             accountProvisioningHost: appSettings.accountProvisioningHost,
                             bugReportApplicationID: appSettings.bugReportApplicationID,
                             analyticsTermsURL: appSettings.analyticsTermsURL,
                             bundledMapTilerConfiguration: appSettings.bundledMapTilerConfiguration)
        return appSettings
    }
}

#endif
