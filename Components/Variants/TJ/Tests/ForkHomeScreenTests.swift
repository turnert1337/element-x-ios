//
// TJ fork: Home Screen apps tests (iOS Workshop, Element card).
// Based on Element X iOS. SPDX-License-Identifier: AGPL-3.0-only
//
// Spec: WatchLab/Element/03_ARTIFACTS_SPEC.md rev 3.4, §13.1 (deep link), §13.3 (icon), §13.4 (profile plist), §13.5.
//

@testable import ElementX
import Foundation
import Testing
import UIKit

struct ForkHomeScreenTests {
    static let scheme = "com.turnertomlinson.element"
    static let devlogRoom = "!b1JRAyUWH8yWBFmKWeCkfBIdBsPRFk8D5Ny8VNjuh_s"

    // MARK: - §13.1 deep link

    @Test
    func deepLinkFormatsAndParsesBack() throws {
        let link = try #require(ForkArtifactDeepLink(roomID: Self.devlogRoom, aid: "lumen-drift"))
        let url = link.url(scheme: Self.scheme)
        #expect(url.absoluteString == "com.turnertomlinson.element://artifact?room=%21b1JRAyUWH8yWBFmKWeCkfBIdBsPRFk8D5Ny8VNjuh_s&a=lumen-drift")
        #expect(ForkArtifactDeepLink.parse(url, scheme: Self.scheme) == link)
    }

    @Test
    func roomIDWithAServerPartIsPercentEncoded() throws {
        let link = try #require(ForkArtifactDeepLink(roomID: "!Nbz2EXpsp3ChzfKAYHrAHuwu:autopute.ai", aid: "pipeline-map"))
        let url = link.url(scheme: Self.scheme)
        #expect(url.absoluteString.contains("room=%21Nbz2EXpsp3ChzfKAYHrAHuwu%3Aautopute.ai&a=pipeline-map"))
        #expect(ForkArtifactDeepLink.parse(url, scheme: Self.scheme) == link)
    }

    @Test
    func schemeMatchIsCaseInsensitive() throws {
        let url = try #require(URL(string: "COM.TurnerTomlinson.Element://artifact?room=%21abc&a=timer"))
        #expect(ForkArtifactDeepLink.parse(url, scheme: Self.scheme)?.aid == "timer")
    }

    @Test(arguments: ["https://artifact?room=%21abc&a=timer",                                   // other scheme
                      "com.turnertomlinson.element://share?room=%21abc&a=timer",                 // other host (upstream's)
                      "com.turnertomlinson.element://artifact?room=%21abc",                      // no aid
                      "com.turnertomlinson.element://artifact?a=timer",                          // no room
                      "com.turnertomlinson.element://artifact?room=abc&a=timer",                 // room without "!"
                      "com.turnertomlinson.element://artifact?room=%21abc&a=Bad_Aid",            // invalid aid
                      "com.turnertomlinson.element://artifact?room=%21abc&room=%21def&a=timer",  // duplicate room
                      "com.turnertomlinson.element://artifact/extra?room=%21abc&a=timer",        // extra path
                      "com.turnertomlinson.element://artifact?room=%21a%2Fb&a=timer",            // "/" in the room id
                      "matrix:roomid/abc"])
    func foreignOrMalformedLinksAreNotOurs(_ string: String) throws {
        let url = try #require(URL(string: string))
        #expect(ForkArtifactDeepLink.parse(url, scheme: Self.scheme) == nil)
    }

    @Test
    func entityIDRoundTrips() throws {
        let link = try #require(ForkArtifactDeepLink(roomID: Self.devlogRoom, aid: "timer"))
        #expect(ForkArtifactDeepLink(entityID: link.entityID) == link)
        #expect(ForkArtifactDeepLink(entityID: "no-separator") == nil)
    }

    @Test
    func stableUUIDIsDeterministicAndDistinct() throws {
        let a = ForkArtifactDeepLink.stableUUID("\(Self.devlogRoom)|timer")
        #expect(a == ForkArtifactDeepLink.stableUUID("\(Self.devlogRoom)|timer"))
        #expect(a != ForkArtifactDeepLink.stableUUID("\(Self.devlogRoom)|lumen-drift"))
        let uuid = try #require(UUID(uuidString: a))
        #expect(uuid.uuidString == a)
        #expect(Array(a)[14] == "5") // version nibble
    }

    // MARK: - §13.4 profile plist

    @Test
    func profilePlistCarriesTheWebClipPayload() throws {
        let link = try #require(ForkArtifactDeepLink(roomID: Self.devlogRoom, aid: "lumen-drift"))
        let icon = Data([0x89, 0x50, 0x4E, 0x47])
        let data = try ForkWebClipProfile.make(link: link, scheme: Self.scheme, baseIdentifier: "com.turnertomlinson.element",
                                               title: "Lumen Drift", label: "Lumen", iconPNG: icon)
        #expect(String(decoding: data.prefix(5), as: UTF8.self) == "<?xml")
        let root = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(root["PayloadType"] as? String == "Configuration")
        #expect(root["PayloadVersion"] as? Int == 1)
        #expect(root["PayloadOrganization"] as? String == "TJ Element")
        #expect(root["PayloadDisplayName"] as? String == "TJ Element: Lumen Drift")
        #expect(root["PayloadRemovalDisallowed"] as? Bool == false)
        #expect(root["PayloadIdentifier"] as? String == "com.turnertomlinson.element.tj.webclip.\(link.stableHash)")
        #expect(root["PayloadUUID"] as? String == ForkArtifactDeepLink.stableUUID(link.entityID))
        let content = try #require(root["PayloadContent"] as? [[String: Any]])
        #expect(content.count == 1)
        let clip = try #require(content.first)
        #expect(clip["PayloadType"] as? String == "com.apple.webClip.managed")
        #expect(clip["URL"] as? String == link.url(scheme: Self.scheme).absoluteString)
        #expect(clip["Label"] as? String == "Lumen")
        #expect(clip["Icon"] as? Data == icon)
        #expect(clip["Precomposed"] as? Bool == true)
        #expect(clip["FullScreen"] as? Bool == true)
        #expect(clip["IsRemovable"] as? Bool == true)
        #expect(clip["PayloadIdentifier"] as? String == "com.turnertomlinson.element.tj.webclip.\(link.stableHash).clip")
        #expect(clip["PayloadUUID"] as? String != root["PayloadUUID"] as? String)

        // Re-adding the same artifact yields the same identifiers (the installed icon is replaced, not duplicated).
        let again = try ForkWebClipProfile.make(link: link, scheme: Self.scheme, baseIdentifier: "com.turnertomlinson.element",
                                                title: "Lumen Drift", label: "Other", iconPNG: icon)
        let againRoot = try #require(try PropertyListSerialization.propertyList(from: again, format: nil) as? [String: Any])
        #expect(againRoot["PayloadUUID"] as? String == root["PayloadUUID"] as? String)
    }

    // MARK: - §13.3 icon

    @Test
    func iconRendersAt1024AndDownscalesTo400() throws {
        let spec = ForkHomeIconSpec(emoji: "✨", swatch: 3)
        let png = try #require(ForkHomeIconRenderer.png(spec: spec, generated: nil, side: 1024))
        let image = try #require(UIImage(data: png))
        #expect(image.size == CGSize(width: 1024, height: 1024))
        #expect(image.cgImage?.width == 1024)
        let small = ForkHomeIconRenderer.downscaledPNG(image, side: 400)
        let smallImage = try #require(UIImage(data: small))
        #expect(smallImage.cgImage?.width == 400)
        #expect(smallImage.cgImage?.height == 400)
        #expect(small.count < 1_000_000)
    }

    @Test
    func generatedImageIsDrawnIntoTheSquare() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let wide = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 200), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        }
        let image = try #require(ForkHomeIconRenderer.image(spec: ForkHomeIconSpec(emoji: "✨", swatch: 0), generated: wide, side: 1024))
        #expect(image.cgImage?.width == 1024)
        #expect(image.cgImage?.height == 1024)
    }

    @Test
    func iconDefaults() {
        #expect(ForkHomeIconSpec.defaultEmoji(symbol: "sparkles") == "✨")
        #expect(ForkHomeIconSpec.defaultEmoji(symbol: "timer") == "⏱️")
        #expect(ForkHomeIconSpec.defaultEmoji(symbol: "point.3.connected.trianglepath.dotted") == "🗺️")
        #expect(ForkHomeIconSpec.defaultEmoji(symbol: "square.dashed") == "🧩")
        let swatch = ForkHomeIconSpec.defaultSwatch(aid: "lumen-drift")
        #expect(swatch == ForkHomeIconSpec.defaultSwatch(aid: "lumen-drift"))
        #expect((0..<ForkHomeIconSpec.swatches.count).contains(swatch))
        #expect(ForkHomeIconSpec.normalizedEmoji("  🎮🎲") == "🎮")
        #expect(ForkHomeIconSpec.normalizedEmoji("   ") == nil)
        #expect(ForkHomeIconSpec.normalizedLabel("", title: "Artifact pipeline map, the long one") == "Artifact pipeline ma")
        #expect(ForkHomeIconSpec.normalizedLabel("  Map  ", title: "x") == "Map")
        #expect(ForkHomeIconSpec.normalizedLabel(String(repeating: "a", count: 40), title: "x").count == 20)
    }

    // MARK: - §13.5 entity list, §13.2 messages

    @Test
    func knownArtifactsReplaceARoomsRows() throws {
        let defaults = try #require(UserDefaults(suiteName: "tj.homescreen.tests.\(UUID().uuidString)"))
        ForkKnownArtifacts.record(roomID: "!a", entries: [("timer", "Timer", "timer"), ("lumen-drift", "Lumen Drift", "sparkles")], defaults: defaults)
        ForkKnownArtifacts.record(roomID: "!b", entries: [("pipeline-map", "Map", "map")], defaults: defaults)
        ForkKnownArtifacts.record(roomID: "!a", entries: [("timer", "Timer 2", "timer")], defaults: defaults)
        let rows = ForkKnownArtifacts.all(defaults: defaults)
        #expect(rows.map(\.aid) == ["timer", "pipeline-map"])
        #expect(rows.first?.title == "Timer 2")
    }

    @Test
    func homeAppProblemsAreSpecific() {
        let messages: [String] = [ForkHomeAppProblem.message(fetchFailure: .forbidden, hasEntries: false),
                                  ForkHomeAppProblem.message(fetchFailure: .notFound, hasEntries: false),
                                  ForkHomeAppProblem.message(fetchFailure: .noSession, hasEntries: false),
                                  ForkHomeAppProblem.message(fetchFailure: .sessionExpired, hasEntries: false),
                                  ForkHomeAppProblem.message(fetchFailure: .http(502), hasEntries: false),
                                  ForkHomeAppProblem.message(fetchFailure: nil, hasEntries: true),
                                  ForkHomeAppProblem.message(fetchFailure: nil, hasEntries: false)]
        #expect(Set(messages).count == messages.count)
    }
}

/// E6 H1 (Test Round 1, step h2): one guided path — make the icon, Add (Safari warns about the local address), one Open Settings
/// step with the exact path, then a check. The path text is Apple's (support.apple.com/102400, read 2026-10-30).
struct ForkHomeInstallFlowTests {
    @Test
    func stepsAdvanceInOrderAndCanStartOver() {
        var flow = ForkHomeInstallFlow()
        #expect(flow.state(of: .icon) == .active)
        #expect(flow.state(of: .add) == .active)
        #expect(flow.state(of: .settings) == .upcoming)
        #expect(flow.state(of: .check) == .upcoming)
        flow.profileServed()
        #expect(flow.state(of: .add) == .done)
        #expect(flow.state(of: .settings) == .active)
        // E6 review H1: someone who goes to Settings by themselves (not via our button) can still finish.
        #expect(flow.state(of: .check) == .active)
        flow.openedSettings()
        #expect(flow.state(of: .settings) == .done)
        #expect(flow.state(of: .check) == .active)
        flow.startOver()
        #expect(flow.state(of: .add) == .active)
        #expect(flow.state(of: .check) == .upcoming)
    }

    @Test
    func copyCarriesTheRealSettingsPath() {
        #expect(ForkHomeInstallFlow.safariLine.contains("not secure"))
        #expect(ForkHomeInstallFlow.safariLine.contains("Allow"))
        #expect(ForkHomeInstallFlow.settingsPath.contains("Profile Downloaded"))
        #expect(ForkHomeInstallFlow.settingsPath.contains("Install"))
        #expect(ForkHomeInstallFlow.fallbackPath.contains("General → VPN & Device Management"))
        // The public settings URL (no App-prefs: deep link), spelled as iOS defines it.
        #expect(ForkHomeInstallFlow.settingsURL?.absoluteString == "app-settings:")
    }

    @Test
    func copyMatchesWhatIOS27Shows() {
        // E2E b6 H1-a: the Safari view's dismiss control is a ✓ glyph at top left; there is no word "Done" on screen.
        #expect(ForkHomeInstallFlow.safariLine.hasSuffix("Tap Continue, then Allow, then Close, then tap ✓ (top left)."))
        #expect(!ForkHomeInstallFlow.safariLine.contains("then Done"))
        // E2E b6 H1-b: on the 27.0 sim Settings opened on its main list, not TJ Element's page: the copy must be right either way.
        #expect(ForkHomeInstallFlow.settingsLanding
            == "If Settings opens on TJ Element's page, tap back (top left) until you're on the main Settings list (your name at the top).")
    }
}
