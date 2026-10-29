//
// TJ fork: Duo build 2 steward-decision tests (iOS Workshop, Element card).
// Based on Element X iOS. SPDX-License-Identifier: AGPL-3.0-only
//
// Spec: WatchLab/Element/01_DUO_SPEC.md rev 3 (D1 probe default, D3 fold assist scope, D4 attach guard).
// Added to UnitTests via Components/Variants/TJ/fork.yml.
//

import CoreGraphics
@testable import ElementX
import Foundation
import Testing

struct ForkDuoRulesTests {
    typealias Posture = ForkDuoFoldRules.Posture

    // MARK: - D3: re-focus only on a hinge-confirmed fold

    @Test
    func hingeConfirmedFoldNeedsAHingeOnBothSides() {
        #expect(ForkDuoFoldRules.isHingeConfirmedFold(from: .closed, to: .fullyOpen))
        #expect(ForkDuoFoldRules.isHingeConfirmedFold(from: .closed, to: .partiallyOpen))
        #expect(ForkDuoFoldRules.isHingeConfirmedFold(from: .fullyOpen, to: .closed))
        #expect(ForkDuoFoldRules.isHingeConfirmedFold(from: .partiallyOpen, to: .closed))
        // Open <-> open is not a fold (no stack <-> split swap).
        #expect(!ForkDuoFoldRules.isHingeConfirmedFold(from: .partiallyOpen, to: .fullyOpen))
        #expect(!ForkDuoFoldRules.isHingeConfirmedFold(from: .fullyOpen, to: .partiallyOpen))
        #expect(!ForkDuoFoldRules.isHingeConfirmedFold(from: .closed, to: .closed))
        // No hinge (iPad, Pro Max) or an unknown status never confirms.
        #expect(!ForkDuoFoldRules.isHingeConfirmedFold(from: nil, to: .closed))
        #expect(!ForkDuoFoldRules.isHingeConfirmedFold(from: .closed, to: nil))
        #expect(!ForkDuoFoldRules.isHingeConfirmedFold(from: nil, to: nil))
    }

    /// iPad Split View resizing, Pro Max rotation and the sim driver's trait override are size-class changes with no
    /// hinge-confirmed fold pending (`secondsSinceHingeFold == nil`): never a re-focus, whatever else is true.
    @Test(arguments: [false, true], [false, true])
    func sizeClassChangeAloneNeverRefocuses(assistEnabled: Bool, composerWasFocused: Bool) {
        #expect(!ForkDuoFoldRules.shouldRefocus(assistEnabled: assistEnabled, composerWasFocused: composerWasFocused, secondsSinceHingeFold: nil))
    }

    @Test
    func refocusTruthTable() {
        let window = ForkDuoFoldRules.hingeFoldWindow
        #expect(ForkDuoFoldRules.shouldRefocus(assistEnabled: true, composerWasFocused: true, secondsSinceHingeFold: 0))
        #expect(ForkDuoFoldRules.shouldRefocus(assistEnabled: true, composerWasFocused: true, secondsSinceHingeFold: window))
        #expect(!ForkDuoFoldRules.shouldRefocus(assistEnabled: true, composerWasFocused: true, secondsSinceHingeFold: window + 0.01))
        #expect(!ForkDuoFoldRules.shouldRefocus(assistEnabled: true, composerWasFocused: true, secondsSinceHingeFold: -1))
        #expect(!ForkDuoFoldRules.shouldRefocus(assistEnabled: false, composerWasFocused: true, secondsSinceHingeFold: 0))
        #expect(!ForkDuoFoldRules.shouldRefocus(assistEnabled: true, composerWasFocused: false, secondsSinceHingeFold: 0))
    }

    // MARK: - D3: sheet guard only while partially open with an upright fold

    @Test
    func sheetGuardNeedsPartiallyOpenAndAnUprightDivision() {
        let upright = CGRect(x: 400, y: 0, width: 20, height: 800)
        let flat = CGRect(x: 0, y: 400, width: 800, height: 20)
        #expect(ForkDuoFoldRules.shouldGuardSheets(assistEnabled: true, posture: .partiallyOpen, activeDivisions: [upright]))
        #expect(ForkDuoFoldRules.shouldGuardSheets(assistEnabled: true, posture: .partiallyOpen, activeDivisions: [flat, upright]))
        #expect(!ForkDuoFoldRules.shouldGuardSheets(assistEnabled: true, posture: .partiallyOpen, activeDivisions: [flat]))
        #expect(!ForkDuoFoldRules.shouldGuardSheets(assistEnabled: true, posture: .partiallyOpen, activeDivisions: []))
        #expect(!ForkDuoFoldRules.shouldGuardSheets(assistEnabled: false, posture: .partiallyOpen, activeDivisions: [upright]))
        for posture: Posture? in [.closed, .fullyOpen, nil] {
            #expect(!ForkDuoFoldRules.shouldGuardSheets(assistEnabled: true, posture: posture, activeDivisions: [upright]),
                    "posture=\(String(describing: posture))")
        }
        #expect(ForkDuoFoldRules.uprightDivisions([flat, upright]) == [upright])
    }

    // MARK: - D4: attach guard

    @Test(arguments: [ForkDuoAccessoryAttachGuard.Path.a, .b], [false, true])
    func modeOffNeverAttaches(path: ForkDuoAccessoryAttachGuard.Path, hasLiveRegistration: Bool) {
        for userInfo: Any? in [ForkDuoAccessoryAttachGuard.userInfo, "other", nil, 42] {
            #expect(!ForkDuoAccessoryAttachGuard.shouldAttach(path: path, userInfo: userInfo, mode: .off, hasLiveRegistration: hasLiveRegistration))
        }
    }

    @Test(arguments: [ForkDuoAccessoryAttachGuard.Path.a, .b], [false, true])
    func foreignUserInfoNeverAttaches(path: ForkDuoAccessoryAttachGuard.Path, hasLiveRegistration: Bool) {
        for userInfo: Any? in ["other", "tj.duo.card ", nil, 42, ["tj.duo.card"]] {
            #expect(!ForkDuoAccessoryAttachGuard.shouldAttach(path: path, userInfo: userInfo, mode: .statusOnly, hasLiveRegistration: hasLiveRegistration))
        }
    }

    @Test
    func pathANeedsOnlyTheTJUserInfo() {
        #expect(ForkDuoAccessoryAttachGuard.shouldAttach(path: .a, userInfo: "tj.duo.card", mode: .statusOnly, hasLiveRegistration: false))
        #expect(ForkDuoAccessoryAttachGuard.shouldAttach(path: .a, userInfo: "tj.duo.card", mode: .statusOnly, hasLiveRegistration: true))
    }

    @Test
    func pathBAlsoNeedsALiveRegistration() {
        #expect(ForkDuoAccessoryAttachGuard.shouldAttach(path: .b, userInfo: "tj.duo.card", mode: .statusOnly, hasLiveRegistration: true))
        #expect(!ForkDuoAccessoryAttachGuard.shouldAttach(path: .b, userInfo: "tj.duo.card", mode: .statusOnly, hasLiveRegistration: false))
    }

    @Test
    func attachUserInfoMatchesTheRegisteredOne() {
        #expect(ForkDuoAccessoryAttachGuard.userInfo == "tj.duo.card")
    }

    // MARK: - D1: probe default follows the build config

    /// Unit tests run the Debug config, where the probe defaults on; Release builds compile the same constant to false.
    @Test
    func probeDefaultFollowsBuildConfig() {
        #if DEBUG
        #expect(ForkDuoSettings.defaultProbeEnabled)
        #else
        #expect(!ForkDuoSettings.defaultProbeEnabled)
        #endif
    }
}
