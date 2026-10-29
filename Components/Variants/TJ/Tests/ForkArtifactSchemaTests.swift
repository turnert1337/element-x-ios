//
// TJ fork: artifact state contract tests (iOS Workshop, Element card).
// Based on Element X iOS. SPDX-License-Identifier: AGPL-3.0-only
//
// Spec: WatchLab/Element/03_ARTIFACTS_SPEC.md rev 3, §3.2 + Appendix A.1 (#1–#11, #16, sort).
//

@testable import ElementX
import Foundation
import Testing

struct ForkArtifactSchemaTests {
    // MARK: - A.1 vectors

    @Test
    func vector1HTMLFromTheBotIsLive() throws {
        let entries = ForkArtifactIndex.parse(stateEvents: ForkArtifactFixtures.room(artifacts: [ForkArtifactFixtures.artifact(sender: ForkArtifactFixtures.bot, aid: "lumen-drift", content: ForkArtifactFixtures.html)]))
        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(entry.source == .html(mxc: "mxc://autopute.ai/AbCdEfGh"))
        #expect(entry.pipe == .nas)
        #expect(entry.title == "Lumen Drift")
        #expect(entry.version == 1)
        #expect(entry.sha256 == ForkArtifactFixtures.sha256)
    }

    @Test
    func vector2NativeTimerIsLive() throws {
        let entries = ForkArtifactIndex.parse(stateEvents: ForkArtifactFixtures.room(artifacts: [ForkArtifactFixtures.artifact(sender: ForkArtifactFixtures.bot, aid: "timer", content: ForkArtifactFixtures.native)]))
        let entry = try #require(entries.first)
        #expect(entry.source == .native(id: "timer"))
        #expect(entry.pipe == .xcode)
        #expect(entry.minBuild == 202_610_290_827)
    }

    @Test
    func vector3EmptyContentIsRemoved() {
        let entries = ForkArtifactIndex.parse(stateEvents: ForkArtifactFixtures.room(artifacts: [ForkArtifactFixtures.artifact(sender: ForkArtifactFixtures.bot, aid: "lumen-drift", content: [:])]))
        #expect(entries.isEmpty)
    }

    @Test
    func vector4UntrustedSenderIsHidden() {
        let entries = ForkArtifactIndex.parse(stateEvents: ForkArtifactFixtures.room(artifacts: [ForkArtifactFixtures.artifact(sender: "@mallory:autopute.ai", aid: "lumen-drift", content: ForkArtifactFixtures.html)]))
        #expect(entries.isEmpty)
    }

    @Test
    func vector5NonMXCURLIsUnsupported() throws {
        var content = ForkArtifactFixtures.html
        content["url"] = .string("https://evil.example/x.html")
        let entry = try #require(ForkArtifactIndex.parse(stateEvents: ForkArtifactFixtures.room(artifacts: [ForkArtifactFixtures.artifact(sender: ForkArtifactFixtures.bot, aid: "x", content: content)])).first)
        #expect(entry.source == .unsupported)
    }

    @Test
    func vector6UnknownNativeIsLiveAndGetsTheCard() throws {
        var content = ForkArtifactFixtures.native
        content["native_id"] = .string("chess")
        let entry = try #require(ForkArtifactIndex.parse(stateEvents: ForkArtifactFixtures.room(artifacts: [ForkArtifactFixtures.artifact(sender: ForkArtifactFixtures.bot, aid: "chess", content: content)])).first)
        #expect(entry.source == .native(id: "chess"))
        #expect(ForkNativeGate.decide(nativeID: "chess", minBuild: entry.minBuild, bundleVersion: "1", registry: ["timer"]) == .arrivesInUpdate(needsBuild: 202_610_290_827))
    }

    @Test
    func vector7OperatorAtPL100IsLive() {
        let entries = ForkArtifactIndex.parse(stateEvents: ForkArtifactFixtures.room(artifacts: [ForkArtifactFixtures.artifact(sender: ForkArtifactFixtures.turner, aid: "lumen-drift", content: ForkArtifactFixtures.html)]))
        #expect(entries.count == 1)
    }

    @Test
    func vector8UnknownVersionIsHidden() {
        let entries = ForkArtifactIndex.parse(stateEvents: ForkArtifactFixtures.room(artifacts: [ForkArtifactFixtures.artifact(sender: ForkArtifactFixtures.bot, aid: "x", content: ["v": .number(2), "title": .string("X")])]))
        #expect(entries.isEmpty)
    }

    @Test
    func vector9UsersDefaultFiftyMakesCarolTrusted() {
        var powerLevels = ForkArtifactFixtures.powerLevels
        powerLevels["users_default"] = .number(50)
        let entries = ForkArtifactIndex.parse(stateEvents: ForkArtifactFixtures.room(powerLevels: powerLevels,
                                                                         artifacts: [ForkArtifactFixtures.artifact(sender: "@carol:autopute.ai", aid: "lumen-drift", content: ForkArtifactFixtures.html)]))
        #expect(entries.count == 1)
    }

    @Test
    func vector10UsersDefaultZeroHidesCarol() {
        var powerLevels = ForkArtifactFixtures.powerLevels
        powerLevels["users_default"] = .number(0)
        let entries = ForkArtifactIndex.parse(stateEvents: ForkArtifactFixtures.room(powerLevels: powerLevels,
                                                                         artifacts: [ForkArtifactFixtures.artifact(sender: "@carol:autopute.ai", aid: "lumen-drift", content: ForkArtifactFixtures.html)]))
        #expect(entries.isEmpty)
    }

    @Test
    func vector11AdditionalCreatorIsInfinite() {
        var powerLevels = ForkArtifactFixtures.powerLevels
        powerLevels["events"] = .object(["ai.autopute.artifact": .number(100)])
        let entries = ForkArtifactIndex.parse(stateEvents: ForkArtifactFixtures.room(powerLevels: powerLevels,
                                                                         additionalCreators: ["@dave:autopute.ai"],
                                                                         artifacts: [ForkArtifactFixtures.artifact(sender: "@dave:autopute.ai", aid: "lumen-drift", content: ForkArtifactFixtures.html)]))
        #expect(entries.count == 1)
    }

    @Test
    func vector16MissingPipeIsDerivedFromKind() throws {
        var content = ForkArtifactFixtures.html
        content.removeValue(forKey: "pipe")
        let entry = try #require(ForkArtifactIndex.parse(stateEvents: ForkArtifactFixtures.room(artifacts: [ForkArtifactFixtures.artifact(sender: ForkArtifactFixtures.bot, aid: "x", content: content)])).first)
        #expect(entry.pipe == .nas)
        #expect(entry.pipe.badge == "NAS")
    }

    // MARK: - Trust edge cases

    @Test
    func roomCreatorIsInfiniteInV12() {
        var powerLevels = ForkArtifactFixtures.powerLevels
        powerLevels["events"] = .object(["ai.autopute.artifact": .number(100)])
        let entries = ForkArtifactIndex.parse(stateEvents: ForkArtifactFixtures.room(powerLevels: powerLevels,
                                                                         artifacts: [ForkArtifactFixtures.artifact(sender: ForkArtifactFixtures.bot, aid: "x", content: ForkArtifactFixtures.html)]))
        #expect(entries.count == 1)
    }

    @Test
    func creatorIsNotInfiniteBeforeV12() {
        var powerLevels = ForkArtifactFixtures.powerLevels
        powerLevels["events"] = .object(["ai.autopute.artifact": .number(100)])
        let entries = ForkArtifactIndex.parse(stateEvents: ForkArtifactFixtures.room(powerLevels: powerLevels, roomVersion: "11",
                                                                         artifacts: [ForkArtifactFixtures.artifact(sender: ForkArtifactFixtures.bot, aid: "x", content: ForkArtifactFixtures.html)]))
        #expect(entries.isEmpty)
    }

    @Test
    func noPowerLevelsMeansCreatorsOnlyAtFifty() {
        let events = ForkArtifactFixtures.room(powerLevels: nil, artifacts: [ForkArtifactFixtures.artifact(sender: ForkArtifactFixtures.bot, aid: "a", content: ForkArtifactFixtures.html),
                                                                  ForkArtifactFixtures.artifact(sender: ForkArtifactFixtures.turner, aid: "b", content: ForkArtifactFixtures.html)])
        let entries = ForkArtifactIndex.parse(stateEvents: events)
        #expect(entries.map(\.aid) == ["a"])
        #expect(ForkPowerLevels(content: nil, creators: []).requiredLevel(forStateType: "ai.autopute.artifact") == 50)
    }

    @Test
    func stateDefaultIsUsedWhenEventsLacksTheType() {
        let levels = ForkPowerLevels(content: .object(["state_default": .number(75), "users": .object(["@x:y": .number(70)])]), creators: [])
        #expect(levels.requiredLevel(forStateType: "ai.autopute.artifact") == 75)
        #expect(!levels.isTrusted(sender: "@x:y", stateType: "ai.autopute.artifact"))
    }

    @Test
    func invalidStateKeyIsIgnored() {
        let entries = ForkArtifactIndex.parse(stateEvents: ForkArtifactFixtures.room(artifacts: [ForkArtifactFixtures.artifact(sender: ForkArtifactFixtures.bot, aid: "Bad_Aid", content: ForkArtifactFixtures.html)]))
        #expect(entries.isEmpty)
    }

    @Test
    func unknownFieldsAreIgnoredAndMinBuildNonIntegerIsNull() throws {
        var content = ForkArtifactFixtures.native
        content["min_build"] = .string("soon")
        content["future_field"] = .object(["x": .number(1)])
        let entry = try #require(ForkArtifactIndex.parse(stateEvents: ForkArtifactFixtures.room(artifacts: [ForkArtifactFixtures.artifact(sender: ForkArtifactFixtures.bot, aid: "timer", content: content)])).first)
        #expect(entry.minBuild == nil)
    }

    // MARK: - Sort

    @Test
    func sortIsOrderThenUpdatedDescending() {
        var first = ForkArtifactFixtures.html
        first["order"] = .number(10)
        first["updated_ts"] = .number(1)
        var second = ForkArtifactFixtures.native
        second["order"] = .number(20)
        second["updated_ts"] = .number(1)
        var seventh = ForkArtifactFixtures.html
        seventh["order"] = .number(10)
        seventh["updated_ts"] = .number(2)
        let entries = ForkArtifactIndex.parse(stateEvents: ForkArtifactFixtures.room(artifacts: [ForkArtifactFixtures.artifact(sender: ForkArtifactFixtures.bot, aid: "one", content: first),
                                                                                    ForkArtifactFixtures.artifact(sender: ForkArtifactFixtures.bot, aid: "two", content: second),
                                                                                    ForkArtifactFixtures.artifact(sender: ForkArtifactFixtures.turner, aid: "seven", content: seventh)]))
        #expect(entries.map(\.aid) == ["seven", "one", "two"])
    }

    @Test
    func unknownSymbolFallsBack() throws {
        var content = ForkArtifactFixtures.html
        content["icon"] = .string("definitely.not.a.symbol")
        let entry = try #require(ForkArtifactIndex.parse(stateEvents: ForkArtifactFixtures.room(artifacts: [ForkArtifactFixtures.artifact(sender: ForkArtifactFixtures.bot, aid: "x", content: content)])).first)
        #expect(entry.symbolName == "square.dashed")
    }
}

// MARK: - ForkArtifactFixtures (A.1)

enum ForkArtifactFixtures {
    static let bot = "@tjtest:autopute.ai"
    static let turner = "@turner:autopute.ai"
    static let sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    static let powerLevels: [String: ForkJSON] = ["state_default": .number(50),
                                                  "events": .object(["ai.autopute.artifact": .number(50)]),
                                                  "users": .object([turner: .number(100)])]

    static let html: [String: ForkJSON] = ["v": .number(1), "title": .string("Lumen Drift"), "icon": .string("sparkles"), "pipe": .string("nas"),
                                           "kind": .string("html"), "url": .string("mxc://autopute.ai/AbCdEfGh"), "mimetype": .string("text/html"),
                                           "size": .number(61234), "sha256": .string(sha256), "version": .number(1), "order": .number(10),
                                           "updated_ts": .number(1_793_274_000_000), "summary": .string("One-tap flyer through a dusk marsh. Original game."),
                                           "request_event_id": .string("$b_wuAJQCG-rVSUkG-jwXkv8iTV9KHhAZ_aOg2CrWoKQ"), "change_note": .string("Motes 20% bigger.")]

    static let native: [String: ForkJSON] = ["v": .number(1), "title": .string("Timer"), "icon": .string("timer"), "pipe": .string("xcode"),
                                             "kind": .string("native"), "native_id": .string("timer"), "min_build": .number(202_610_290_827),
                                             "version": .number(1), "order": .number(20), "updated_ts": .number(1_793_274_000_000),
                                             "summary": .string("Countdown + stopwatch, wall-clock based.")]

    static func artifact(sender: String, aid: String, content: [String: ForkJSON], type: String = "ai.autopute.artifact") -> ForkJSON {
        .object(["type": .string(type), "state_key": .string(aid), "sender": .string(sender), "content": .object(content)])
    }

    static func room(powerLevels: [String: ForkJSON]? = ForkArtifactFixtures.powerLevels,
                     roomVersion: String = "12",
                     additionalCreators: [String] = [],
                     artifacts: [ForkJSON]) -> [ForkJSON] {
        var createContent: [String: ForkJSON] = ["room_version": .string(roomVersion)]
        if !additionalCreators.isEmpty { createContent["additional_creators"] = .array(additionalCreators.map(ForkJSON.string)) }
        var events: [ForkJSON] = [.object(["type": .string("m.room.create"), "state_key": .string(""), "sender": .string(bot), "content": .object(createContent)])]
        if let powerLevels {
            events.append(.object(["type": .string("m.room.power_levels"), "state_key": .string(""), "sender": .string(bot), "content": .object(powerLevels)]))
        }
        return events + artifacts
    }
}
