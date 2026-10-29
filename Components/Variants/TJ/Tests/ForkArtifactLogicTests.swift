//
// TJ fork: Artifacts pure-logic tests (iOS Workshop, Element card).
// Based on Element X iOS. SPDX-License-Identifier: AGPL-3.0-only
//
// Spec: WatchLab/Element/03_ARTIFACTS_SPEC.md rev 3, §5.9: ForkArtifactLayoutTests, ForkNativeGateTests,
// ForkReloadPolicyTests, ForkTimerClockTests, ForkDevLogSchemaTests (A.2), ForkArtifactSHATests.
//

@testable import ElementX
import Foundation
import SwiftUI
import Testing

struct ForkArtifactLayoutTests {
    typealias Mode = ForkArtifactLayout.Mode

    @Test
    func closedIsChatOnly() {
        #expect(ForkArtifactLayout.mode(sizeClass: .regular, windowWidth: 1000, hasSplit: true, isOpen: false, isFullScreen: true) == .chatOnly)
    }

    @Test
    func fullScreenWinsWhenOpen() {
        #expect(ForkArtifactLayout.mode(sizeClass: .compact, windowWidth: 400, hasSplit: false, isOpen: true, isFullScreen: true) == .full)
    }

    @Test
    func regularAt600SplitsAndAt599Pushes() {
        #expect(ForkArtifactLayout.mode(sizeClass: .regular, windowWidth: 600, hasSplit: true, isOpen: true, isFullScreen: false) == .split)
        #expect(ForkArtifactLayout.mode(sizeClass: .regular, windowWidth: 599, hasSplit: true, isOpen: true, isFullScreen: false) == .push)
    }

    @Test
    func noSplitCoordinatorNeverSplits() {
        #expect(ForkArtifactLayout.mode(sizeClass: .regular, windowWidth: 1366, hasSplit: false, isOpen: true, isFullScreen: false) == .push)
    }

    @Test
    func compactAt951Pushes() {
        #expect(ForkArtifactLayout.mode(sizeClass: .compact, windowWidth: 951, hasSplit: true, isOpen: true, isFullScreen: false) == .push)
        #expect(ForkArtifactLayout.mode(sizeClass: nil, windowWidth: 951, hasSplit: true, isOpen: true, isFullScreen: false) == .push)
    }

    @Test
    func splitWidths() {
        let wide = ForkArtifactLayout.splitWidths(detailWidth: 1001)
        #expect(wide.chat == 500 && wide.pane == 500)
        let narrow = ForkArtifactLayout.splitWidths(detailWidth: 551)
        #expect(narrow.pane == 280 && narrow.chat == 270)
        let tight = ForkArtifactLayout.splitWidths(detailWidth: 501)
        #expect(tight.chat == 260 && tight.pane == 240) // the chat keeps its floor; the pane shrinks first
    }

    @Test
    func probeValues() {
        #expect(Mode.chatOnly.probeValue == "-")
        #expect(Mode.push.probeValue == "push")
        #expect(Mode.split.probeValue == "split")
        #expect(Mode.full.probeValue == "full")
    }
}

struct ForkNativeGateTests {
    let registry: Set<String> = ["timer"]

    @Test
    func vector12ShippedBuildAtOrAboveMinBuildRenders() {
        #expect(ForkNativeGate.decide(nativeID: "timer", minBuild: 202_610_290_827, bundleVersion: "202610301200", registry: registry) == .render)
        #expect(ForkNativeGate.decide(nativeID: "timer", minBuild: 202_610_290_827, bundleVersion: "202610290827", registry: registry) == .render)
    }

    @Test
    func vector13DeveloperBuildRenders() {
        #expect(ForkNativeGate.decide(nativeID: "timer", minBuild: 202_610_290_827, bundleVersion: "1", registry: registry) == .render)
        #expect(ForkNativeGate.decide(nativeID: "timer", minBuild: 999_999_999_999, bundleVersion: "not-a-number", registry: registry) == .render)
    }

    @Test
    func vector14OlderShippedBuildGetsTheCardWithCaption() {
        #expect(ForkNativeGate.decide(nativeID: "timer", minBuild: 999_999_999_999, bundleVersion: "202610301200", registry: registry) == .arrivesInUpdate(needsBuild: 999_999_999_999))
    }

    @Test
    func vector15NonIntegerMinBuildIsNull() throws {
        var content = ForkArtifactFixtures.native
        content["min_build"] = .string("soon")
        let entry = try #require(ForkArtifactEntry.parse(aid: "timer", sender: ForkArtifactFixtures.bot, content: .object(content)))
        #expect(ForkNativeGate.decide(nativeID: "timer", minBuild: entry.minBuild, bundleVersion: "202610301200", registry: registry) == .render)
    }

    @Test
    func unknownIDGetsTheCard() {
        #expect(ForkNativeGate.decide(nativeID: "chess", minBuild: nil, bundleVersion: "1", registry: registry) == .arrivesInUpdate(needsBuild: nil))
    }

    @Test
    func timerIsRegistered() {
        #expect(ForkNativeArtifacts.registeredIDs == ["timer"])
    }
}

struct ForkReloadPolicyTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test
    func offScreenSwapsSilently() {
        #expect(ForkReloadPolicy.decide(isOnScreen: false, lastTouch: now, now: now) == .swapSilently)
    }

    @Test
    func onScreenNeverTouchedReloadsNow() {
        #expect(ForkReloadPolicy.decide(isOnScreen: true, lastTouch: nil, now: now) == .reloadNow)
    }

    @Test
    func onScreenQuietForTenSecondsReloadsNow() {
        #expect(ForkReloadPolicy.decide(isOnScreen: true, lastTouch: now.addingTimeInterval(-10), now: now) == .reloadNow)
    }

    @Test
    func touchAt9point9ShowsChipThenAutoReloadsTenSecondsAfterTheTouch() {
        let touch = now.addingTimeInterval(-9.9)
        let action = ForkReloadPolicy.decide(isOnScreen: true, lastTouch: touch, now: now)
        #expect(action == .showChip(autoReloadAt: touch.addingTimeInterval(10)))
        #expect(ForkReloadPolicy.decide(isOnScreen: true, lastTouch: touch, now: touch.addingTimeInterval(10)) == .reloadNow)
    }
}

struct ForkTimerClockTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test
    func pauseResumeAcrossATenMinuteGap() {
        var clock = ForkTimerClock(mode: .stopwatch)
        clock.start(now: t0)
        clock.pause(now: t0.addingTimeInterval(30))
        #expect(clock.elapsed(now: t0.addingTimeInterval(630)) == 30) // paused: the 10 min gap doesn't count
        clock.start(now: t0.addingTimeInterval(630))
        #expect(clock.elapsed(now: t0.addingTimeInterval(640)) == 40)
        // Running across a simulated 10 min backgrounding is wall-clock.
        #expect(clock.elapsed(now: t0.addingTimeInterval(1240)) == 640)
    }

    @Test
    func countdownClampsAtZero() {
        var clock = ForkTimerClock(mode: .countdown)
        clock.setTarget(60)
        clock.start(now: t0)
        #expect(clock.remaining(now: t0.addingTimeInterval(59)) == 1)
        #expect(clock.remaining(now: t0.addingTimeInterval(600)) == 0)
    }

    @Test
    func fireDateAccountsForAccumulated() throws {
        var clock = ForkTimerClock(mode: .countdown)
        clock.setTarget(180)
        clock.start(now: t0)
        clock.pause(now: t0.addingTimeInterval(60))
        clock.start(now: t0.addingTimeInterval(100))
        #expect(try #require(clock.fireDate) == t0.addingTimeInterval(220))
        clock.pause(now: t0.addingTimeInterval(110))
        #expect(clock.fireDate == nil)
    }

    @Test
    func pastFireDateAtActivationIsFinishedNoSound() throws {
        var clock = ForkTimerClock(mode: .countdown)
        clock.setTarget(60)
        clock.start(now: t0)
        let fire = try #require(clock.fireDate)
        let activation = t0.addingTimeInterval(3600)
        #expect(fire <= activation) // the model's reconcile path: finished, no sound flag
        clock.markFinished(at: fire)
        #expect(!clock.isRunning)
        #expect(clock.finishedAt == fire)
        #expect(clock.remaining(now: activation) == 0)
    }

    @Test
    func jsonRoundTrip() throws {
        var clock = ForkTimerClock(mode: .stopwatch)
        clock.start(now: t0)
        clock.lap(now: t0.addingTimeInterval(12.5))
        let decoded = try JSONDecoder().decode(ForkTimerClock.self, from: JSONEncoder().encode(clock))
        #expect(decoded == clock)
    }

    @Test
    func restartAfterFinishResets() {
        var clock = ForkTimerClock(mode: .countdown)
        clock.setTarget(5)
        clock.start(now: t0)
        clock.markFinished(at: t0.addingTimeInterval(5))
        clock.start(now: t0.addingTimeInterval(10))
        #expect(clock.remaining(now: t0.addingTimeInterval(11)) == 4)
        #expect(clock.finishedAt == nil)
    }

    @Test
    func formatting() {
        #expect(ForkTimerClock.format(192) == "03:12")
        #expect(ForkTimerClock.format(3725) == "1:02:05")
        #expect(ForkTimerClock.format(1.25, tenths: true) == "00:01.2")
    }
}

struct ForkDevLogSchemaTests {
    static let fullTicket: ForkJSON = .object([
        "v": .number(1), "id": .string("T-20261029-0623-artifacts"), "project": .string("element"),
        "title": .string("Artifacts space, Dev log, chat relay (hello world)"), "stage": .string("building"),
        "stages": .array(ForkDevLogTicket.defaultStages.map(ForkJSON.string)),
        "progress": .object(["done": .number(2), "total": .number(7), "label": .string("Three lanes building")]),
        "created_ts": .number(1_793_273_017_994), "updated_ts": .number(1_793_280_000_000),
        "request": .object(["room_id": .string("!Nbz2EXpsp3ChzfKAYHrAHuwu_zwZVOlQ46_D4CrrAv4"), "event_id": .string("$b_wu"),
                            "sender": .string("@turner:autopute.ai"), "ts": .number(1), "body": .string(" verbatim "),
                            "addenda": .array([.object(["event_id": .null, "via": .string("workshop chat"), "ts": .number(0), "body": .string("a1")])])]),
        "interpretations": .array([.object(["id": .string("D3"), "your_words": .string("w"), "reading": .string("r"), "alternative": .string("a")])]),
        "decisions_open": .array([.object(["id": .string("OD-2"), "question": .string("q"), "default": .string("No"), "owner": .string("operator")])]),
        "cost": .object(["basis": .string("API-rate equivalent"), "total_usd": .number(12.34), "total_is_estimate": .bool(true),
                         "coverage": .string("partial"), "coverage_note": .string("RELAY lane transcript not found"),
                         "runs": .array([.object(["kind": .string("steward"), "source": .string("transcript-usage")])])])
    ])

    @Test
    func fullTicketDecodesNewOptionalFields() throws {
        let ticket = try #require(ForkDevLogTicket.parse(content: Self.fullTicket))
        #expect(ticket.interpretations?.first?.id == "D3")
        #expect(ticket.decisionsOpen?.first?.defaultChoice == "No")
        #expect(ticket.cost?.isPartial == true)
        #expect(ticket.cost?.coverageNote == "RELAY lane transcript not found")
        #expect(ticket.cost?.runs?.first?.sourceChip == "transcript sum")
        #expect(ticket.request?.body == " verbatim ")
        #expect(ticket.request?.addenda?.first?.eventID == nil)
    }

    @Test
    func minimalTicketDecodesWithoutOptionalFields() throws {
        let ticket = try #require(ForkDevLogTicket.parse(content: .object(["v": .number(1), "id": .string("mx_1"), "title": .string("t"), "stage": .string("queued")])))
        #expect(ticket.interpretations == nil)
        #expect(ticket.decisionsOpen == nil)
        #expect(ticket.cost == nil)
        #expect(ticket.resolvedStages.count == 7)
    }

    @Test
    func notLiveWithoutRequiredFields() {
        #expect(ForkDevLogTicket.parse(content: .object(["v": .number(1), "id": .string("x"), "title": .string("t")])) == nil)
        #expect(ForkDevLogTicket.parse(content: .object(["v": .number(2), "id": .string("x"), "title": .string("t"), "stage": .string("queued")])) == nil)
    }

    @Test
    func a2BuildingIsIndexTwo() {
        let layout = ForkStageStepperLayout.layout(stage: "building", stages: ForkDevLogTicket.defaultStages, progressDone: 2)
        #expect(layout.index == 2)
        #expect(layout.states == [.done, .done, .current, .future, .future, .future, .future])
    }

    @Test
    func a2EscalatedIsAmberAtProgressDone() {
        let layout = ForkStageStepperLayout.layout(stage: "escalated", stages: ForkDevLogTicket.defaultStages, progressDone: 3)
        #expect(layout.index == 3)
        #expect(layout.states[3] == .escalated)
        #expect(layout.label == "Waiting on the steward")
    }

    @Test
    func a2FailedIsRedAtProgressDone() {
        let layout = ForkStageStepperLayout.layout(stage: "failed", stages: ForkDevLogTicket.defaultStages, progressDone: 4)
        #expect(layout.states[4] == .failed)
        #expect(layout.states[0...3].allSatisfy { $0 == .done })
    }

    @Test
    func a2UnknownStageRendersAsQueuedWithCaption() {
        let layout = ForkStageStepperLayout.layout(stage: "weird", stages: ForkDevLogTicket.defaultStages, progressDone: 5)
        #expect(layout.index == 0)
        #expect(layout.unknownCaption == "weird")
        #expect(layout.label == "Queued")
    }

    @Test
    func a2DeliveredIsHistory() throws {
        let delivered = try #require(ForkDevLogTicket.parse(content: .object(["v": .number(1), "id": .string("a"), "title": .string("t"), "stage": .string("delivered")])))
        let failed = try #require(ForkDevLogTicket.parse(content: .object(["v": .number(1), "id": .string("b"), "title": .string("t"), "stage": .string("failed")])))
        let building = try #require(ForkDevLogTicket.parse(content: .object(["v": .number(1), "id": .string("c"), "title": .string("t"), "stage": .string("building")])))
        #expect(!delivered.isInPipeline && !failed.isInPipeline && building.isInPipeline)
        let all = ForkStageStepperLayout.layout(stage: "delivered", stages: ForkDevLogTicket.defaultStages, progressDone: 7)
        #expect(all.states.allSatisfy { $0 == .done })
    }

    @Test
    func indexAppliesTrust() {
        let ticket = ForkArtifactFixtures.artifact(sender: ForkArtifactFixtures.bot, aid: "T-20261029-0623-artifacts", content: Self.fullTicket.object ?? [:], type: "ai.autopute.devlog.ticket")
        let rogue = ForkArtifactFixtures.artifact(sender: "@mallory:autopute.ai", aid: "rogue", content: Self.fullTicket.object ?? [:], type: "ai.autopute.devlog.ticket")
        var levels = ForkArtifactFixtures.powerLevels
        levels["events"] = .object(["ai.autopute.devlog.ticket": .number(50)])
        let tickets = ForkDevLogIndex.parse(stateEvents: ForkArtifactFixtures.room(powerLevels: levels, artifacts: [ticket, rogue]))
        #expect(tickets.count == 1)
    }
}

struct ForkArtifactSHATests {
    @Test
    func hexDigestOfAFixture() {
        #expect(ForkArtifactSHA.hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(ForkArtifactSHA.prefix16("abc") == "ba7816bf8f01cfea")
    }

    @Test
    func mismatchRejects() {
        let data = Data("<html></html>".utf8)
        #expect(ForkArtifactSHA.matches(data, expected: ForkArtifactSHA.hex(data)))
        #expect(ForkArtifactSHA.matches(data, expected: ForkArtifactSHA.hex(data).uppercased()))
        #expect(!ForkArtifactSHA.matches(data, expected: String(repeating: "0", count: 64)))
        #expect(!ForkArtifactSHA.matches(data, expected: nil))
    }

    /// G-A5 (b): a tampered cache file is refused and deleted.
    @Test
    func cacheTamperRefusesToRender() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "TJArtifactsSHATests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let cache = ForkArtifactCache(userID: "@a:b", roomID: "!r:b", base: base)
        let data = Data("<html>ok</html>".utf8)
        let sha = ForkArtifactSHA.hex(data)
        try cache.write(data, aid: "probe", version: 1, sha256: sha)
        #expect(cache.read(aid: "probe", version: 1, sha256: sha) == data)
        try Data("<html>evil</html>".utf8).write(to: cache.htmlURL(aid: "probe", version: 1, sha256: sha))
        #expect(cache.read(aid: "probe", version: 1, sha256: sha) == nil)
        #expect(!FileManager.default.fileExists(atPath: cache.htmlURL(aid: "probe", version: 1, sha256: sha).path()))
    }

    @Test
    func cacheKeepsTwoNewestVersions() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "TJArtifactsSHATests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let cache = ForkArtifactCache(userID: "@a:b", roomID: "!r:b", base: base)
        for version in 1...4 {
            let data = Data("v\(version)".utf8)
            try cache.write(data, aid: "a", version: version, sha256: ForkArtifactSHA.hex(data))
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: cache.root.appending(path: "a").path())
        #expect(Set(files.compactMap { $0.split(separator: "-").first.map(String.init) }) == ["3", "4"])
    }
}
