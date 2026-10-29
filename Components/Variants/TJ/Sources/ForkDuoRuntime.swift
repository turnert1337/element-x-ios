//
// TJ fork: Duo runtime entry point (iOS Workshop, Element card).
// Based on Element X iOS. SPDX-License-Identifier: AGPL-3.0-only
//
// Started from `AppHooks.setUp()` (ForkHooks.swift). In the Debug simulator build it is also started for
// upstream's UI-test mock session (`UI_TESTS_SCREEN=userSessionScreen`, which never calls `setUp()`) by
// ForkDuoBootstrap.m, so the fold proxy can be exercised on a real navigation stack without signing in.
//

#if IS_MAIN_APP

import os
import SwiftUI

enum ForkDuoRuntime {
    private static var isStarted = false
    private nonisolated static let logger = Logger(subsystem: "com.turnertomlinson.element", category: "DuoProbe")
    
    static func start(reason: String) {
        guard !isStarted else { return }
        isStarted = true
        #if TJ_DUO_PROBE
        ForkDuoProbe.shared.start()
        #endif
        #if TJ_DUO_BACKSCREEN
        // 26.6: the logging presenter only. The 27.1 presenter is chosen in ForkDuoBackScreen27.swift (TJ_SDK27).
        ForkDuoBackScreen.shared.start(presenter: ForkDuoRuntime.makeAccessoryPresenter())
        #endif
        #if DEBUG && targetEnvironment(simulator)
        ForkDuoSimDriver.shared.start()
        #endif
        logger.notice("DUO v=1 ev=runtime-start reason=\(reason, privacy: .public)")
    }
}

#if TJ_DUO_BACKSCREEN && !TJ_SDK27
extension ForkDuoRuntime {
    static func makeAccessoryPresenter() -> ForkDuoAccessoryPresenter {
        ForkDuoLoggingAccessoryPresenter()
    }
}
#endif

#if DEBUG && targetEnvironment(simulator)
/// Called by ForkDuoBootstrap.m after launch, only when `UI_TESTS_SCREEN` is set (upstream's mock fixtures).
@objc(TJDuoBootstrap)
final class ForkDuoBootstrap: NSObject {
    @objc static func tjStartForMockSession() {
        ForkDuoRuntime.start(reason: "mock-session")
    }
}
#endif

#endif
