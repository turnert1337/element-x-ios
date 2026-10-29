//
// TJ fork: the sandboxed HTML artifact renderer (iOS Workshop, Element card).
// Based on Element X iOS. SPDX-License-Identifier: AGPL-3.0-only
//
// Spec: WatchLab/Element/03_ARTIFACTS_SPEC.md rev 3, §5.4, D10, G-A5.
// - Bytes come only from the per-user cache after their sha256 matched the state event, through the `tjartifact://`
//   scheme handler, with a header CSP that an in-page <meta> can't loosen, plus `X-DNS-Prefetch-Control: off`.
// - A content rule list blocks every URL that isn't tjartifact/about/data/blob; a document-start user script stubs
//   WebRTC (CSP has no directive for ICE/STUN/TURN); no script message handlers (no JS bridge); non-persistent store.
// - The pool owns the WKWebViews (≤ 3 globally, LRU, the visible selection pinned), so push/split/full screen reparent
//   the same view and a fold never reloads a game (D10).
//

import OSLog
import SwiftUI
import WebKit

nonisolated enum ForkArtifactWebPolicy {
    static let contentSecurityPolicy = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; media-src data: blob:; font-src data:; connect-src 'none'; frame-src 'none'; worker-src blob:; form-action 'none'; base-uri 'none'"

    static let responseHeaders: [String: String] = [
        "Content-Type": "text/html; charset=utf-8",
        "Cache-Control": "no-store",
        "X-DNS-Prefetch-Control": "off",
        "Content-Security-Policy": contentSecurityPolicy
    ]

    static let ruleListIdentifier = "tj-artifacts-v1"

    /// §5.4's list, with the allow rule split per scheme: WebKit's content-blocker regex has no `|` alternation, so the
    /// frozen `^(tjartifact|about|data|blob):` would not compile. Same semantics.
    static let contentRules = """
    [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},\
    {"trigger":{"url-filter":"^tjartifact:"},"action":{"type":"ignore-previous-rules"}},\
    {"trigger":{"url-filter":"^about:"},"action":{"type":"ignore-previous-rules"}},\
    {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}},\
    {"trigger":{"url-filter":"^blob:"},"action":{"type":"ignore-previous-rules"}}]
    """

    static let webRTCStub = """
    (() => { const dead = function () { throw new DOMException('WebRTC disabled in TJ artifacts', 'NotSupportedError'); };
      for (const n of ['RTCPeerConnection','webkitRTCPeerConnection','RTCDataChannel','RTCSessionDescription','RTCIceCandidate'])
        Object.defineProperty(window, n, { value: dead, writable: false, configurable: false, enumerable: false });
      try { Object.defineProperty(Navigator.prototype, 'mediaDevices', { get: () => undefined, configurable: false }); } catch (_) {}
      try { Object.defineProperty(navigator, 'mediaDevices', { value: undefined, writable: false, configurable: false }); } catch (_) {}
    })();
    """

    static func url(aid: String, version: Int) -> URL? {
        URL(string: "\(ForkArtifactConstants.scheme)://\(aid)/v\(version)/index.html")
    }

    /// Only `tjartifact://<aid>/v<version>/index.html` is served; anything else is a 404.
    static func isServable(_ url: URL?, aid: String, version: Int) -> Bool {
        guard let url, url.scheme == ForkArtifactConstants.scheme, url.host() == aid else { return false }
        return url.path() == "/v\(version)/index.html" && url.query() == nil
    }
}

/// Serves exactly one verified payload per host.
final class TJArtifactSchemeHandler: NSObject, WKURLSchemeHandler {
    struct Payload {
        let aid: String
        let version: Int
        let data: Data
    }

    var payload: Payload?

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let url = urlSchemeTask.request.url
        guard let payload, let url, ForkArtifactWebPolicy.isServable(url, aid: payload.aid, version: payload.version),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ForkArtifactWebPolicy.responseHeaders) else {
            let fallback = url ?? URL(string: "tjartifact://invalid/")!
            let notFound = HTTPURLResponse(url: fallback, statusCode: 404, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "text/plain", "Cache-Control": "no-store", "X-DNS-Prefetch-Control": "off"])
            if let notFound { urlSchemeTask.didReceive(notFound) }
            urlSchemeTask.didReceive(Data())
            urlSchemeTask.didFinish()
            return
        }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(payload.data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) { }
}

/// One artifact's WKWebView + configuration. Owned by `ForkArtifactWebPool`.
final class ForkArtifactWebHost: NSObject, WKNavigationDelegate, WKUIDelegate {
    let key: String
    let aid: String
    let webView: WKWebView
    private let schemeHandler: TJArtifactSchemeHandler
    private(set) var loadedVersion: Int?
    private(set) var lastUsed = Date()
    var onTouch: (() -> Void)?

    init(key: String, aid: String, ruleList: WKContentRuleList?) {
        self.key = key
        self.aid = aid
        schemeHandler = TJArtifactSchemeHandler()

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: ForkArtifactConstants.scheme)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.dataDetectorTypes = []
        let controller = WKUserContentController()
        if let ruleList { controller.add(ruleList) }
        controller.addUserScript(WKUserScript(source: ForkArtifactWebPolicy.webRTCStub, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        configuration.userContentController = controller

        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.allowsLinkPreview = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.accessibilityIdentifier = "tj_artifact-webview_\(aid)"
        #if DEBUG
        webView.isInspectable = true
        #endif
    }

    func load(version: Int, data: Data) {
        guard let url = ForkArtifactWebPolicy.url(aid: aid, version: version) else { return }
        schemeHandler.payload = .init(aid: aid, version: version, data: data)
        loadedVersion = version
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
    }

    func markUsed() {
        lastUsed = Date()
    }

    func tearDown() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        schemeHandler.payload = nil
        onTouch = nil
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let isOwnPage = navigationAction.targetFrame?.isMainFrame == true
            && navigationAction.navigationType != .linkActivated
            && navigationAction.navigationType != .formSubmitted
            && loadedVersion.map { ForkArtifactWebPolicy.isServable(navigationAction.request.url, aid: aid, version: $0) } == true
        decisionHandler(isOwnPage ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let payload = schemeHandler.payload else { return }
        load(version: payload.version, data: payload.data)
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }
}

/// Pure LRU choice for the pool (unit-tested): which keys to evict so at most `capacity` stay, never the pinned ones.
nonisolated enum ForkLRUPolicy {
    /// `order` is least-recently-used first.
    static func evictions(order: [String], pinned: Set<String>, capacity: Int) -> [String] {
        var excess = order.count - capacity
        guard excess > 0 else { return [] }
        var evicted: [String] = []
        for key in order where excess > 0 && !pinned.contains(key) {
            evicted.append(key)
            excess -= 1
        }
        return evicted
    }
}

/// Global, per-process pool of artifact web views (≤ 3 live across all rooms).
final class ForkArtifactWebPool {
    static let shared = ForkArtifactWebPool()
    static let capacity = 3

    private(set) var hosts: [String: ForkArtifactWebHost] = [:]
    private var order: [String] = []
    private var pinned: Set<String> = []
    private var ruleList: WKContentRuleList?
    private var ruleListTask: Task<WKContentRuleList?, Never>?
    /// Called with the evicted keys so models drop their "loaded" marks.
    var onEvict: (([String]) -> Void)?

    /// Compiles (once) the content rule list. Hosts are never created without it.
    func prepareRuleList() async -> WKContentRuleList? {
        if let ruleList { return ruleList }
        if let ruleListTask { return await ruleListTask.value }
        let task = Task { @MainActor () -> WKContentRuleList? in
            do {
                return try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: ForkArtifactWebPolicy.ruleListIdentifier,
                                                                                        encodedContentRuleList: ForkArtifactWebPolicy.contentRules)
            } catch {
                MXLog.error("TJ artifacts: content rule list failed to compile: \(error)")
                return nil
            }
        }
        ruleListTask = task
        let list = await task.value
        ruleList = list
        return list
    }

    func host(forKey key: String) -> ForkArtifactWebHost? {
        hosts[key]
    }

    /// Returns the live host for `key`, creating it if needed (the rule list must be ready; else nil).
    func makeHost(key: String, aid: String) async -> ForkArtifactWebHost? {
        if let existing = hosts[key] {
            touch(key)
            return existing
        }
        guard let ruleList = await prepareRuleList() else { return nil }
        if let existing = hosts[key] { return existing }
        let host = ForkArtifactWebHost(key: key, aid: aid, ruleList: ruleList)
        hosts[key] = host
        touch(key)
        enforceCapacity()
        return host
    }

    func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
        hosts[key]?.markUsed()
    }

    func setPinned(_ keys: Set<String>) {
        pinned = keys
        enforceCapacity()
    }

    func remove(keys: [String]) {
        for key in keys {
            hosts.removeValue(forKey: key)?.tearDown()
            order.removeAll { $0 == key }
        }
    }

    func remove(prefix: String) {
        remove(keys: hosts.keys.filter { $0.hasPrefix(prefix) })
    }

    func removeAll() {
        remove(keys: Array(hosts.keys))
        pinned = []
    }

    private func enforceCapacity() {
        let evicted = ForkLRUPolicy.evictions(order: order, pinned: pinned, capacity: Self.capacity)
        guard !evicted.isEmpty else { return }
        remove(keys: evicted)
        onEvict?(evicted)
    }
}

/// Adopts the pooled WKWebView. Reparenting is safe across push / split / full screen: `dismantleUIView` only detaches
/// the web view if this container still owns it, so SwiftUI building the new container first is harmless.
struct ForkArtifactWebContainer: UIViewRepresentable {
    let host: ForkArtifactWebHost
    /// Only the surface that should show the artifact now (full screen while it's up, else the zone) adopts the web view.
    /// Without it, the zone's outgoing container got one last update after the overlay adopted the view, took it back, and
    /// then removed it when dismantled: a blank full screen (G-A2 run 2, TJWEB log in build/b3/fulldbg_tjweb.log).
    var isOwner = true
    let onTouch: () -> Void

    func makeUIView(context: Context) -> ForkWebContainerView {
        let view = ForkWebContainerView()
        view.onTouch = onTouch
        return view
    }

    func updateUIView(_ uiView: ForkWebContainerView, context: Context) {
        uiView.onTouch = onTouch
        if isOwner { uiView.adopt(host.webView) }
    }

    static func dismantleUIView(_ uiView: ForkWebContainerView, coordinator: ()) {
        uiView.releaseWebView()
    }
}

final class ForkWebContainerView: UIView, UIGestureRecognizerDelegate {
    #if DEBUG
    static let log = Logger(subsystem: "tj.artifacts", category: "web")

    override func didMoveToWindow() {
        super.didMoveToWindow()
        ForkWebContainerView.log.notice("TJWEB container=\(ObjectIdentifier(self).hashValue, privacy: .public) window=\(String(describing: self.window.map { type(of: $0) }), privacy: .public) frame=\(String(describing: self.bounds.size), privacy: .public) hasWeb=\(self.adopted?.superview === self, privacy: .public)")
    }
    #endif
    var onTouch: (() -> Void)?
    private weak var adopted: WKWebView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true
        // Passive touch sensing for D16 (never a JS bridge): taps and pans, simultaneous with the page's own handling.
        for recognizer in [UITapGestureRecognizer(target: self, action: #selector(touched)), UIPanGestureRecognizer(target: self, action: #selector(touched))] {
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func adopt(_ webView: WKWebView) {
        #if DEBUG
        ForkWebContainerView.log.notice("TJWEB adopt container=\(ObjectIdentifier(self).hashValue, privacy: .public) window=\(String(describing: self.window.map { type(of: $0) }), privacy: .public) already=\(webView.superview === self, privacy: .public) from=\(webView.superview.map { ObjectIdentifier($0).hashValue } ?? 0, privacy: .public)")
        #endif
        guard webView.superview !== self else { return }
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([webView.leadingAnchor.constraint(equalTo: leadingAnchor),
                                     webView.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     webView.topAnchor.constraint(equalTo: topAnchor),
                                     webView.bottomAnchor.constraint(equalTo: bottomAnchor)])
        adopted = webView
    }

    func releaseWebView() {
        #if DEBUG
        ForkWebContainerView.log.notice("TJWEB release container=\(ObjectIdentifier(self).hashValue, privacy: .public) owns=\(self.adopted?.superview === self, privacy: .public)")
        #endif
        if let adopted, adopted.superview === self {
            adopted.removeFromSuperview()
        }
        adopted = nil
    }

    @objc private func touched() {
        onTouch?()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}
