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
/// - The OAuth/OIDC client metadata (`AppSettings.oAuthConfiguration`), so the fork identifies to
///   authorization servers as the operator's own client, never as Element:
///   - client_name  = CFBundleDisplayName = "TJ Element" (APP_DISPLAY_NAME in fork.yml)
///   - client_uri   = `websiteURL` with `oAuthClientURIPath` = nil → https://autopute.ai/
///   - logo_uri     = `logoURL` (autopute.ai serves no image, so the site root)
///   - tos_uri      = `acceptableUseURL`, policy_uri = `privacyURL` → https://autopute.ai/privacy
///   - redirect_uri = `oAuthRedirectURL`, a custom scheme (no associated domain / AASA needed)
/// - `accountProviders`: the operator's own homeserver first (the login default), matrix.org second.
///   `allowOtherAccountProviders` stays `true`, so "Change server" still accepts any server (e.g. matrix.org).
/// - `pushGatewayBaseURL`: the operator's own Sygnal (push v1), not matrix.org's gateway, which cannot
///   deliver to this bundle id. The pusher app id is NOT overridden (and is not hookable): it derives as
///   BASE_BUNDLE_IDENTIFIER + ".ios.prod" (Release) = `com.turnertomlinson.element.ios.prod`, the Sygnal app key.
nonisolated struct ForkAppSettingsHook: AppSettingsHookProtocol {
    /// OAuth client_uri. The redirect scheme below must be this host reversed (MAS rule for native clients).
    static let websiteURL: URL = "https://autopute.ai/"
    /// nil, so client_uri is exactly `websiteURL` (no path appended).
    static let oAuthClientURIPath: String? = nil
    /// autopute.ai serves no image (every icon path falls back to the HTML index), so the site root.
    static let logoURL: URL = "https://autopute.ai/"
    /// GET https://autopute.ai/privacy → 200 "Privacy Policy — Autopute". Used for policy_uri and tos_uri.
    static let privacyURL: URL = "https://autopute.ai/privacy"
    static let acceptableUseURL: URL = "https://autopute.ai/privacy"

    /// Custom-scheme OAuth redirect: reversed client_uri host (autopute.ai → ai.autopute).
    static let oAuthRedirectURL: URL = "ai.autopute:/callback"

    /// The operator's private homeserver: server name `autopute.ai` (.well-known delegated to matrix.autopute.ai).
    /// Push gateway: Sygnal on the always-on Mac (127.0.0.1:5005) behind tunnel path ^/_matrix/push/v1/notify$.
    /// Origin only: AppSettings appends `_matrix/push/v1/notify` (AppSettings.swift:226-228) and Synapse
    /// requires exactly that path (synapse/push/httppusher.py:154-160). Public URL, so pushers registered
    /// on other homeservers (matrix.org, the second account provider) reach it too.
    static let pushGatewayBaseURL: URL = "https://matrix.autopute.ai"

    static let accountProviders: [AccountProvider] = [.managed(serverName: "autopute.ai", baseURL: "https://matrix.autopute.ai"),
                                                      .managed(serverName: "matrix.org", baseURL: "https://matrix-client.matrix.org")]

    @MainActor func configure(_ appSettings: AppSettings) -> AppSettings {
        appSettings.override(accountProviders: Self.accountProviders,
                             allowOtherAccountProviders: true,
                             hideBrandChrome: appSettings.hideBrandChrome,
                             pushGatewayBaseURL: Self.pushGatewayBaseURL,
                             oAuthRedirectURL: Self.oAuthRedirectURL,
                             oAuthClientURIPath: Self.oAuthClientURIPath,
                             websiteURL: Self.websiteURL,
                             logoURL: Self.logoURL,
                             copyrightURL: appSettings.copyrightURL,
                             acceptableUseURL: Self.acceptableUseURL,
                             privacyURL: Self.privacyURL,
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
