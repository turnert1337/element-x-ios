//
// TJ fork: Duo decision rules, pure and SDK-independent (iOS Workshop, Element card).
// Based on Element X iOS. SPDX-License-Identifier: AGPL-3.0-only
//
// Steward decisions for Duo build 2 (WatchLab/Element/01_DUO_SPEC.md rev 3, 2026-10-29):
// - D3: the fold assist re-focuses the composer ONLY on a hinge-confirmed fold transition (a `UIHinge` exists before
//   and after, and it crossed closed <-> open). A size-class change alone (iPad resizing, Pro Max rotation, the sim
//   driver's trait override) never re-focuses. The sheet guard runs only while `partiallyOpen` with an upright fold.
// - D4: the back-screen card window is only ever created for TJ's own accessory (`sceneAccessoryUserInfo ==
//   "tj.duo.card"`), never while the mode is Off, and on path B only while TJ holds a live registration.
//
// No iOS 27 types here, so Components/Variants/TJ/Tests can exercise every branch on any SDK.
// ForkDuoFold27.swift and ForkDuoBackScreen27.swift map their UIKit values onto these inputs.
//

#if IS_MAIN_APP

import CoreGraphics
import Foundation

// MARK: - D3 fold assist

nonisolated enum ForkDuoFoldRules {
    /// `UIHinge.Status` without the SDK dependency. `UIHinge.Status.unknown` maps to nil (no confirmation).
    enum Posture: Equatable, Sendable {
        case closed
        case partiallyOpen
        case fullyOpen

        var isClosed: Bool {
            self == .closed
        }
    }

    /// How long a hinge-confirmed fold stays "current" for the layout swap that follows it. The keyboard is dropped by
    /// the stack <-> split swap, which lands within this window of the hinge crossing closed <-> open.
    static let hingeFoldWindow: TimeInterval = 2.0

    /// A fold transition the hinge itself confirms: a hinge was present before and after, and it crossed closed <-> open.
    /// nil on either side (no `UIHinge` in the hierarchy, or `.unknown`) is never a confirmation.
    static func isHingeConfirmedFold(from old: Posture?, to new: Posture?) -> Bool {
        guard let old, let new else { return false }
        return old.isClosed != new.isClosed
    }

    /// Re-focus the composer only when the assist is on, a composer had (or just lost) focus, and a hinge-confirmed
    /// fold happened within `hingeFoldWindow`. `secondsSinceHingeFold == nil` means no hinge-confirmed fold is pending,
    /// which is every size-class-only change.
    static func shouldRefocus(assistEnabled: Bool, composerWasFocused: Bool, secondsSinceHingeFold: TimeInterval?) -> Bool {
        guard assistEnabled, composerWasFocused, let age = secondsSinceHingeFold else { return false }
        return age >= 0 && age <= hingeFoldWindow
    }

    /// An upright fold: a tall, thin `.division` region (book posture). Only this can be avoided by leading placement.
    static func uprightDivisions(_ divisions: [CGRect]) -> [CGRect] {
        divisions.filter { $0.height > $0.width }
    }

    /// The sheet guard runs only while partially open AND an active division stands upright.
    static func shouldGuardSheets(assistEnabled: Bool, posture: Posture?, activeDivisions: [CGRect]) -> Bool {
        assistEnabled && posture == .partiallyOpen && !uprightDivisions(activeDivisions).isEmpty
    }
}

// MARK: - D4 back-screen attach guard

nonisolated enum ForkDuoAccessoryAttachGuard {
    /// Passed as `UISceneAccessory.cameraCapture(sceneConfiguration:userInfo:)` and read back as
    /// `UIScene.ConnectionOptions.sceneAccessoryUserInfo` (UISceneOptions.h:49-52).
    static let userInfo = "tj.duo.card"

    enum Path: String, Sendable {
        /// `ForkDuoBackScreenSceneDelegate`, the TJ configuration's own delegate.
        case a = "A"
        /// Upstream `SceneDelegate` kept the session (AppDelegate.swift:21-26); TJ sees the connection beside it.
        case b = "B"
    }

    /// - Path A: the userInfo must be TJ's and the mode must not be Off.
    /// - Path B: the same, AND this presenter must hold a live registration right now.
    /// With mode Off no TJ window is created on any accessory scene, whatever the userInfo says.
    static func shouldAttach(path: Path, userInfo: Any?, mode: ForkDuoSettings.BackScreenMode, hasLiveRegistration: Bool) -> Bool {
        guard mode != .off, userInfo as? String == Self.userInfo else { return false }
        switch path {
        case .a:
            return true
        case .b:
            return hasLiveRegistration
        }
    }
}

#endif
