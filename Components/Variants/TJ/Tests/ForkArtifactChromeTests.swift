//
// TJ fork: room chrome, per-user store, web pool and scheme handler tests (iOS Workshop, Element card).
// Based on Element X iOS. SPDX-License-Identifier: AGPL-3.0-only
//
// Spec: WatchLab/Element/03_ARTIFACTS_SPEC.md rev 3, §5.9 ForkRoomChromeTests + ForkArtifactsStoreTests, G-A5
// (scheme response carries X-DNS-Prefetch-Control: off and the frozen CSP; only the artifact's own URL is served).
//

@testable import ElementX
import Foundation
import SwiftUI
import Testing
import WebKit

final class ForkStubCoordinator: CoordinatorProtocol {
    var startCount = 0
    var stopCount = 0

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
    func toPresentable() -> AnyView { AnyView(Text("inner")) }
}

struct ForkRoomChromeTests {
    @Test
    func wrapIsInertUnderUnitTests() throws {
        #expect(ProcessInfo.isRunningUnitTests)
        let inner = ForkStubCoordinator()
        // Mirrors what RoomFlowCoordinator does with the real coordinator: under unit tests the same instance comes back.
        let wrapped = ForkRoomChrome.wrap(inner,
                                          roomProxy: JoinedRoomProxyMock(.init()),
                                          stack: NavigationStackCoordinator(),
                                          flowParameters: Self.flowParameters(),
                                          flow: nil)
        #expect(wrapped === inner)
    }

    private static func flowParameters() -> CommonFlowParameters {
        let userSession = UserSessionMock(.init(clientProxy: ClientProxyMock(.init())))
        return CommonFlowParameters(userSession: userSession,
                                    availableSessionsPublisher: .init([.init(userSession: userSession)]),
                                    bugReportService: BugReportServiceMock(.init()),
                                    elementCallService: ElementCallServiceMock(.init()),
                                    timelineControllerFactory: TimelineControllerFactoryMock(.init()),
                                    emojiProvider: EmojiProvider(userSettings: userSession.userSettings),
                                    linkMetadataProvider: LinkMetadataProvider(),
                                    appMediator: AppMediatorMock(.init()),
                                    analytics: AnalyticsServiceMock(.init()),
                                    userIndicatorController: UserIndicatorControllerMock(),
                                    stateMachineFactory: PublishedStateMachineFactory())
    }

    @Test
    func directConstructionForwardsStartStopAndExposesInner() {
        let inner = ForkStubCoordinator()
        let chrome = ForkRoomChromeCoordinator(inner: inner)
        chrome.start()
        #expect(inner.startCount == 1)
        chrome.stop()
        #expect(inner.stopCount == 1)
        _ = chrome.innerPresentable
        _ = chrome.toPresentable()
        #expect(chrome.inner === inner)
        #expect(chrome.model.layoutMode == .chatOnly)
        #expect(!chrome.model.isOpen)
    }

    /// Build 5 E2E F1: in iPhone portrait (compact, horizontal bar) the 5th trailing item pushed upstream's room-name header
    /// off the bar. Artifacts + Schedule stay top level (the operator's "just like an artifact button"); New chat joins Dev log
    /// under More, so the bar holds as many items as build 4, where the room name showed.
    @Test
    func compactHorizontalBarKeepsArtifactsAndScheduleAndFoldsNewChatIntoMore() {
        let layout = ForkRoomBarLayout(isCompact: true, hasVerticalBar: false)
        #expect(layout.topLevel == [.artifacts, .schedule])
        #expect(layout.more == [.newChat, .devLog])
    }

    @Test
    func verticalBarAndRegularWidthShowEveryItemTopLevel() {
        for layout in [ForkRoomBarLayout(isCompact: true, hasVerticalBar: true),
                       ForkRoomBarLayout(isCompact: false, hasVerticalBar: false),
                       ForkRoomBarLayout(isCompact: false, hasVerticalBar: true)] {
            #expect(layout.topLevel == [.artifacts, .schedule, .newChat, .devLog])
            #expect(layout.more.isEmpty)
        }
    }
}

struct ForkArtifactsStoreTests {
    @Test
    func activatingAnotherUserTearsDownTheFirstUsersModels() {
        let store = ForkArtifactsStore()
        let modelA = makeModel(user: "@a:x", room: "!r:x")
        store.install(modelA)
        #expect(store.activeUserID == "@a:x")
        #expect(store.modelCount == 1)
        store.activate(userID: "@b:x", purge: false)
        #expect(modelA.isTornDown)
        #expect(store.modelCount == 0)
        #expect(store.activeUserID == "@b:x")
    }

    @Test
    func reactivatingTheSameUserKeepsModels() {
        let store = ForkArtifactsStore()
        let model = makeModel(user: "@a:x", room: "!r:x")
        store.install(model)
        store.activate(userID: "@a:x", purge: false)
        #expect(!model.isTornDown)
        #expect(store.existingModel(roomID: "!r:x") === model)
    }

    @Test
    func cachePathsAndTimerKeysDifferPerUser() {
        let base = URL(filePath: "/tmp/base")
        let a = ForkArtifactCache(userID: "@a:x", roomID: "!r:x", base: base)
        let b = ForkArtifactCache(userID: "@b:x", roomID: "!r:x", base: base)
        #expect(a.root != b.root)
        #expect(a.root.path().contains(ForkArtifactSHA.prefix16("@a:x")))
        #expect(a.root.path().contains(ForkArtifactSHA.prefix16("!r:x")))
        #expect(ForkTimerStorage.key(userID: "@a:x", roomID: "!r:x") != ForkTimerStorage.key(userID: "@b:x", roomID: "!r:x"))
        #expect(ForkTimerStorage.key(userID: "@a:x", roomID: "!r:x") == "tj.artifact.timer.\(ForkArtifactSHA.prefix16("@a:x")).\(ForkArtifactSHA.prefix16("!r:x"))")
    }

    @Test
    func purgeDropsSignedOutUsers() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "TJArtifactsPurge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let defaults = try #require(UserDefaults(suiteName: "tj.purge.\(UUID().uuidString)"))
        for user in ["@keep:x", "@gone:x"] {
            try FileManager.default.createDirectory(at: ForkArtifactCache(userID: user, roomID: "!r:x", base: base).root, withIntermediateDirectories: true)
            defaults.set(Data(), forKey: ForkTimerStorage.key(userID: user, roomID: "!r:x"))
        }
        ForkArtifactCache.purge(keepingUserIDs: ["@keep:x"], base: base, defaults: defaults)
        let folders = try FileManager.default.contentsOfDirectory(atPath: base.path())
        #expect(folders == [ForkArtifactSHA.prefix16("@keep:x")])
        #expect(defaults.data(forKey: ForkTimerStorage.key(userID: "@keep:x", roomID: "!r:x")) != nil)
        #expect(defaults.data(forKey: ForkTimerStorage.key(userID: "@gone:x", roomID: "!r:x")) == nil)
    }

    @Test
    func poolPolicyNeverExceedsThreeAndNeverEvictsThePinnedHost() {
        #expect(ForkLRUPolicy.evictions(order: ["a", "b", "c"], pinned: [], capacity: 3).isEmpty)
        #expect(ForkLRUPolicy.evictions(order: ["a", "b", "c", "d"], pinned: [], capacity: 3) == ["a"])
        #expect(ForkLRUPolicy.evictions(order: ["a", "b", "c", "d"], pinned: ["a"], capacity: 3) == ["b"])
        #expect(ForkLRUPolicy.evictions(order: ["a", "b", "c", "d", "e"], pinned: ["a", "c"], capacity: 3) == ["b", "d"])
        // Walk a long access sequence: the live set never exceeds 3 and always holds the pinned key.
        var order: [String] = []
        for step in 0..<40 {
            let key = "k\(step % 7)"
            order.removeAll { $0 == key }
            order.append(key)
            let evicted = ForkLRUPolicy.evictions(order: order, pinned: ["k0"], capacity: 3)
            #expect(!evicted.contains("k0"))
            order.removeAll { evicted.contains($0) }
            #expect(order.count <= 3)
        }
    }

    @Test
    func realPoolHonoursCapacityAndPin() async {
        let pool = ForkArtifactWebPool()
        _ = await pool.makeHost(key: "u/r/a", aid: "a")
        pool.setPinned(["u/r/a"])
        for aid in ["b", "c", "d", "e"] {
            _ = await pool.makeHost(key: "u/r/\(aid)", aid: aid)
            #expect(pool.hosts.count <= ForkArtifactWebPool.capacity)
            #expect(pool.hosts["u/r/a"] != nil)
        }
        pool.removeAll()
        #expect(pool.hosts.isEmpty)
    }

    private func makeModel(user: String, room: String) -> ForkArtifactsModel {
        ForkArtifactsModel(userID: user, roomID: room, rest: ForkMatrixREST(userID: user) { _ in nil },
                           cacheBase: FileManager.default.temporaryDirectory.appending(path: "TJArtifactsStoreTests"))
    }
}

struct ForkArtifactSchemeHandlerTests {
    @Test
    func servesTheVerifiedPayloadWithTheFrozenHeaders() throws {
        let handler = TJArtifactSchemeHandler()
        handler.payload = .init(aid: "probe", version: 3, data: Data("<html></html>".utf8))
        let task = ForkFakeSchemeTask(url: URL(string: "tjartifact://probe/v3/index.html")!)
        handler.webView(WKWebView(), start: task)
        let response = try #require(task.response as? HTTPURLResponse)
        #expect(response.statusCode == 200)
        #expect(response.value(forHTTPHeaderField: "X-DNS-Prefetch-Control") == "off")
        #expect(response.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(response.value(forHTTPHeaderField: "Content-Security-Policy") == "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; media-src data: blob:; font-src data:; connect-src 'none'; frame-src 'none'; worker-src blob:; form-action 'none'; base-uri 'none'")
        #expect(task.body == Data("<html></html>".utf8))
        #expect(task.finished)
    }

    @Test(arguments: ["tjartifact://probe/v2/index.html", "tjartifact://other/v3/index.html", "tjartifact://probe/v3/secret.js", "tjartifact://probe/v3/index.html?x=1"])
    func anythingElseIs404(_ raw: String) throws {
        let handler = TJArtifactSchemeHandler()
        handler.payload = .init(aid: "probe", version: 3, data: Data("<html></html>".utf8))
        let task = ForkFakeSchemeTask(url: URL(string: raw)!)
        handler.webView(WKWebView(), start: task)
        let response = try #require(task.response as? HTTPURLResponse)
        #expect(response.statusCode == 404)
        #expect(task.body.isEmpty)
    }

    @Test
    func contentRuleListCompiles() async throws {
        let list = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "tj-artifacts-test", encodedContentRuleList: ForkArtifactWebPolicy.contentRules)
        #expect(list != nil)
    }
}

final class ForkFakeSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    var response: URLResponse?
    var body = Data()
    var finished = false

    init(url: URL) {
        request = URLRequest(url: url)
    }

    func didReceive(_ response: URLResponse) { self.response = response }
    func didReceive(_ data: Data) { body.append(data) }
    func didFinish() { finished = true }
    func didFailWithError(_ error: any Error) { finished = true }
}

/// E6 B1 (Test Round 1, step a1): the Artifacts count badge takes the button's own colour, never red.
struct ForkRailBadgeColorTests {
    @Test
    func badgeMatchesTheButtonInEveryState() {
        for dark in [false, true] {
            for open in [false, true] {
                let look = ForkRailBadgeColors.artifacts(open: open, dark: dark)
                #expect(look.fill == look.icon, "open \(open) dark \(dark)")
                #expect(look.fill != ForkRailBadgeColors.resolved(.systemRed, dark: dark), "open \(open) dark \(dark)")
                #expect(look.text != look.fill)
            }
        }
    }

    @Test
    func restIsTheBarTintAndOpenIsBlue() {
        // Rest: UIKit's label (black/white). Open: blue (operator, Test Round 1 a1) — blue-dominant in both modes, never red.
        #expect(Self.rgb(ForkRailBadgeColors.artifacts(open: false, dark: false).icon) == [0, 0, 0])
        #expect(Self.rgb(ForkRailBadgeColors.artifacts(open: false, dark: true).icon) == [255, 255, 255])
        for dark in [false, true] {
            let open = Self.rgb(ForkRailBadgeColors.artifacts(open: true, dark: dark).icon)
            #expect(open[2] >= 200 && open[2] > open[0] + 100 && open[2] > open[1], "open is blue, dark \(dark): \(open)")
        }
        // The digits are cut out of the capsule in the bar's background colour (white on black at rest in light mode).
        #expect(Self.rgb(ForkRailBadgeColors.artifacts(open: false, dark: false).text) == [255, 255, 255])
        #expect(Self.rgb(ForkRailBadgeColors.artifacts(open: false, dark: true).text) == [0, 0, 0])
    }

    @Test
    func everyBarDrawsTheBadgeIntoTheIcon() throws {
        // The system `.badge` is always red on iOS 26+ bars, so the count is drawn into the icon image: a capsule in the icon's colour
        // with digits in the background colour, and no red anywhere.
        for dark in [false, true] {
            for open in [false, true] {
                let image = try #require(ForkRailBadgeColors.artifactsIcon(open: open, badge: "3", dark: dark))
                let plain = try #require(ForkRailBadgeColors.artifactsIcon(open: true, badge: nil, dark: dark))
                #expect(image.size.width > plain.size.width, "open \(open) dark \(dark)") // room for the capsule
                let colours = Self.opaqueColours(image)
                let look = ForkRailBadgeColors.artifacts(open: open, dark: dark)
                #expect(colours.contains { Self.near($0, Self.rgb(look.icon)) }, "open \(open) dark \(dark)")
                #expect(colours.contains { Self.near($0, Self.rgb(look.text)) }, "open \(open) dark \(dark)")
                #expect(!colours.contains { $0[0] > 200 && $0[1] < 90 && $0[2] < 90 }, "red in open \(open) dark \(dark)")
            }
        }
        // At rest with no count the bar's own template symbol is used (it follows the bar's tint).
        #expect(ForkRailBadgeColors.artifactsIcon(open: false, badge: nil, dark: false) == nil)
    }

    @Test
    func openColourIsTheSameWithAndWithoutABadge() throws {
        // E6 review B1: badged and plain open icons must be the same colour; operator rule: blue while open, never red.
        for dark in [false, true] {
            let accent = Self.rgb(UIColor.systemBlue.resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light)))
            #expect(accent[2] > accent[0] + 100, "open tint is blue, dark \(dark)") // operator: blue when open
            let badged = Self.opaqueColours(try #require(ForkRailBadgeColors.artifactsIcon(open: true, badge: "3", dark: dark)))
            let plain = Self.opaqueColours(try #require(ForkRailBadgeColors.artifactsIcon(open: true, badge: nil, dark: dark)))
            #expect(!plain.isEmpty && plain.allSatisfy { Self.near($0, accent) }, "dark \(dark): \(plain)")
            #expect(badged.contains { Self.near($0, accent) }, "dark \(dark)")
            #expect(!badged.contains { $0[0] > $0[2] + 60 }, "red in dark \(dark)") // never attention red
            #expect(Self.rgb(ForkRailBadgeColors.artifacts(open: true, dark: dark).fill) == accent)
            #expect(Self.rgb(ForkRailBadgeColors.openTint.resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))) == accent)
        }
    }

    // MARK: - Pixel helpers

    /// Within one step per channel (8-bit rounding).
    static func near(_ lhs: [Int], _ rhs: [Int]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { abs($0 - $1) <= 1 }
    }

    static func rgb(_ color: UIColor) -> [Int] {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue].map { Int(($0 * 255).rounded()) }
    }

    /// The colours of the fully opaque pixels, drawn into an 8-bit sRGB bitmap.
    static func opaqueColours(_ image: UIImage) -> Set<[Int]> {
        let width = Int(image.size.width * image.scale), height = Int(image.size.height * image.scale)
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return []
        }
        UIGraphicsPushContext(context)
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: image.scale, y: -image.scale)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        UIGraphicsPopContext()
        guard let data = context.data else { return [] }
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var colours = Set<[Int]>()
        for index in stride(from: 0, to: width * height * 4, by: 4) where bytes[index + 3] == 255 {
            colours.insert([Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2])])
        }
        return colours
    }
}
