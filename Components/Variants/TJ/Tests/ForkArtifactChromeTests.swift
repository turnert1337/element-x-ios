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
    func restIsTheBarTintAndOpenIsTheAccent() {
        #expect(ForkRailBadgeColors.artifacts(open: false, dark: false).icon == ForkRailBadgeColors.resolved(.label, dark: false))
        #expect(ForkRailBadgeColors.artifacts(open: false, dark: true).icon == ForkRailBadgeColors.resolved(.label, dark: true))
        #expect(ForkRailBadgeColors.artifacts(open: true, dark: false).icon == ForkRailBadgeColors.resolved(.tintColor, dark: false))
        // The digits are cut out of the capsule in the bar's background colour (white on black at rest in light mode).
        #expect(ForkRailBadgeColors.artifacts(open: false, dark: false).text == ForkRailBadgeColors.resolved(.systemBackground, dark: false))
    }

    @Test
    func everyBarDrawsTheBadgeIntoTheIcon() {
        // The system `.badge` is always red on iOS 26+ bars, so the Artifacts item never uses it (horizontal or vertical).
        #expect(!ForkRailBadgeColors.artifactsUsesSystemBadge)
    }
}
