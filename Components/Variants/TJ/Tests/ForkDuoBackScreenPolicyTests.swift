//
// TJ fork: Duo back-screen policy tests (iOS Workshop, Element card).
// Based on Element X iOS. SPDX-License-Identifier: AGPL-3.0-only
//
// Spec: WatchLab/Element/01_DUO_SPEC.md §5.3. Added to UnitTests via Components/Variants/TJ/fork.yml.
//

@testable import ElementX
import Foundation
import Testing

struct ForkDuoBackScreenPolicyTests {
    @Test(arguments: ForkDuoSettings.BackScreenMode.allCases, [false, true])
    func truthTable(mode: ForkDuoSettings.BackScreenMode, foreground: Bool) {
        for captureRunning in [false, true] {
            for forceSim in [false, true] {
                let policy = makePolicy(mode: mode, captureRunning: captureRunning, forceSim: forceSim, foreground: foreground)
                let expected = mode != .off && (captureRunning || forceSim) && foreground
                #expect(policy.shouldRegister == expected,
                        "mode=\(mode) capture=\(captureRunning) force=\(forceSim) foreground=\(foreground)")
            }
        }
    }

    @Test
    func lockDisablesWithoutUnregistering() {
        let locked = makePolicy(captureRunning: true, locked: true)
        #expect(locked.shouldRegister)
        #expect(!locked.isEnabled)
        #expect(makePolicy(captureRunning: true, locked: false).isEnabled)
    }

    @Test
    func cardTextForCameraAndCall() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        #expect(makePolicy(captureRunning: true).cardText(now: start) == "Camera on")
        let call = makePolicy(captureRunning: true, callActive: true, captureStart: start)
        #expect(call.cardText(now: start.addingTimeInterval(65)) == "On a call · 1:05")
        #expect(makePolicy(callActive: true).cardText(now: start) == "On a call · 0:00")
    }

    @Test
    func elapsedFormatting() {
        #expect(ForkDuoBackScreenPolicy.formatElapsed(5) == "0:05")
        #expect(ForkDuoBackScreenPolicy.formatElapsed(12 * 60 + 34) == "12:34")
        #expect(ForkDuoBackScreenPolicy.formatElapsed(3600 + 2 * 60 + 3) == "1:02:03")
        #expect(ForkDuoBackScreenPolicy.formatElapsed(-3) == "0:00")
    }

    /// v2 ships the card dark (01_DUO_SPEC.md §4.1 item 3, §6.1): an unset `tj.duo.backScreen` means Off,
    /// and Off never registers, whatever else is true.
    @Test
    func backScreenDefaultsToOff() {
        #expect(ForkDuoSettings.defaultBackScreenMode == .off)
        #expect(!makePolicy(mode: ForkDuoSettings.defaultBackScreenMode, captureRunning: true, forceSim: true).shouldRegister)
    }

    // MARK: - Helpers

    private func makePolicy(mode: ForkDuoSettings.BackScreenMode = .statusOnly,
                            captureRunning: Bool = false,
                            forceSim: Bool = false,
                            foreground: Bool = true,
                            locked: Bool = false,
                            callActive: Bool = false,
                            captureStart: Date? = nil) -> ForkDuoBackScreenPolicy {
        ForkDuoBackScreenPolicy(mode: mode,
                                captureRunning: captureRunning,
                                forceSim: forceSim,
                                foreground: foreground,
                                locked: locked,
                                callActive: callActive,
                                captureStart: captureStart)
    }
}
