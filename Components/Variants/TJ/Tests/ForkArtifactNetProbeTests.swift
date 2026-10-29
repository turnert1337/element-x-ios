//
// TJ fork: G-A5 (a) network probe through the real artifact renderer (iOS Workshop, Element card).
// Based on Element X iOS. SPDX-License-Identifier: AGPL-3.0-only
//
// Spec: WatchLab/Element/03_ARTIFACTS_SPEC.md rev 3, §5.4 + G-A5. The test-only fixture `netProbeHTML` (never published)
// is served by the real `TJArtifactSchemeHandler` into a real `ForkArtifactWebHost` (CSP header, content rules, WebRTC stub,
// navigation delegate) and tries 11 ways out. The host the probes aim at comes from `TJPROBE_HOST` (pass
// `TEST_RUNNER_TJPROBE_HOST=<dev-Mac LAN IP>`), where the gate runs an HTTP logger on :8765 and a UDP (STUN) logger on :3478;
// those server-side logs are the second half of the proof (expected: 0 requests, 0 packets).
//

@testable import ElementX
import Foundation
import Testing
import UIKit
import WebKit

struct ForkArtifactNetProbeTests {
    @Test
    func elevenProbesAllBlocked() async throws {
        let host = ProcessInfo.processInfo.environment["TJPROBE_HOST"] ?? "127.0.0.1"
        let pool = ForkArtifactWebPool()
        let ruleList = try #require(await pool.prepareRuleList(), "content rule list must compile")
        let webHost = ForkArtifactWebHost(key: "test/net-probe", aid: "net-probe", ruleList: ruleList)
        #expect(!webHost.webView.allowsLinkPreview)

        // A window, so timers and layout behave as in the app.
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.rootViewController = UIViewController()
        webHost.webView.frame = window.bounds
        window.rootViewController?.view.addSubview(webHost.webView)
        window.isHidden = false
        defer {
            window.isHidden = true
            webHost.tearDown()
        }

        webHost.load(version: 1, data: Data(Self.netProbeHTML.replacingOccurrences(of: "__HOST__", with: host).utf8))

        var report: String?
        for _ in 0..<120 {
            try await Task.sleep(for: .milliseconds(250))
            if let value = try? await webHost.webView.evaluateJavaScript("window.__probeDone ? JSON.stringify(window.__probe) : ''") as? String, !value.isEmpty {
                report = value
                break
            }
        }
        let json = try #require(report, "probe never finished (or a navigation left the page: a probe reached out)")
        let probe = try ForkJSON.decode(Data(json.utf8))
        let results = try #require(probe["results"]?.object)
        print("TJ-NET-PROBE \(json)")
        #expect(results.count == 11)
        for (name, value) in results.sorted(by: { $0.key < $1.key }) {
            #expect(value == .string("blocked"), "\(name) reached out")
        }
        #expect(probe["reached"]?.int == 0)
        #expect(probe["summary"] == .string("0/11 reached"))
        // WebRTC stub presence (G-A5 (i)).
        #expect(probe["rtc_throws"] == .string("NotSupportedError"))
        #expect(probe["rtc_configurable"] == .bool(false))
        #expect(probe["media_devices"] == .string("undefined"))
        // Still on the artifact's own page: no navigation got through.
        #expect(webHost.webView.url?.absoluteString == "tjartifact://net-probe/v1/index.html")
    }

    /// Test-only fixture (G-A5): never published to a room or the NAS.
    static let netProbeHTML = #"""
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>net-probe</title></head><body><p id="out">running</p>
    <a id="link" href="http://__HOST__:8765/link">link</a>
    <form id="form" method="POST" action="http://__HOST__:8765/form"><input name="x" value="1"></form>
    <script>
    const H = "__HOST__"; const results = {}; let reached = 0;
    function mark(name, ok) { if (results[name]) return; results[name] = ok ? "reached" : "blocked"; if (ok) reached++; }
    const wait = (ms) => new Promise(r => setTimeout(r, ms));
    function loadEl(tag, name, url) { return new Promise(r => { try { const e = document.createElement(tag); e.onload = () => { mark(name, true); r(); };
      e.onerror = () => { mark(name, false); r(); }; e.src = url; document.body.appendChild(e); setTimeout(() => { mark(name, false); r(); }, 3000); } catch (_) { mark(name, false); r(); } }); }
    window.addEventListener("message", (e) => { if (e.data === "reached-iframe") mark("iframe", true); });
    async function run() {
      try { await fetch(`http://${H}:8765/fetch`); mark("fetch", true); } catch (_) { mark("fetch", false); }
      await new Promise(r => { try { const x = new XMLHttpRequest(); x.open("GET", `http://${H}:8765/xhr`); x.onload = () => { mark("xhr", true); r(); };
        x.onerror = () => { mark("xhr", false); r(); }; x.send(); setTimeout(() => { mark("xhr", false); r(); }, 3000); } catch (_) { mark("xhr", false); r(); } });
      await new Promise(r => { try { const w = new WebSocket(`ws://${H}:8765/ws`); w.onopen = () => { mark("websocket", true); r(); };
        w.onerror = () => { mark("websocket", false); r(); }; setTimeout(() => { mark("websocket", false); r(); }, 3000); } catch (_) { mark("websocket", false); r(); } });
      await loadEl("img", "img", `http://${H}:8765/img.png`);
      await loadEl("script", "script", `http://${H}:8765/s.js`);
      try { const f = document.createElement("iframe"); f.src = `http://${H}:8765/iframe`; document.body.appendChild(f); } catch (_) {}
      await wait(2500); mark("iframe", false);
      try { const w = window.open(`http://${H}:8765/open`); mark("window_open", !!w); } catch (_) { mark("window_open", false); }
      // WebRTC (stub presence + an actual attempt at the gate's STUN listener).
      let rtcThrows = "none";
      try { const pc = new RTCPeerConnection({ iceServers: [{ urls: `stun:${H}:3478` }] }); pc.createDataChannel("x");
        const offer = await pc.createOffer(); await pc.setLocalDescription(offer); await wait(2000); mark("webrtc", true);
      } catch (e) { rtcThrows = e.name; mark("webrtc", false); }
      const d = Object.getOwnPropertyDescriptor(window, "RTCPeerConnection");
      window.__probe = { rtc_throws: rtcThrows, rtc_configurable: d ? d.configurable : null, media_devices: String(navigator.mediaDevices) };
      // Main-frame navigations last: if one got through, this page (and its report) would be gone.
      document.getElementById("link").click(); await wait(1500); mark("link_click", false);
      document.getElementById("form").submit(); await wait(1500); mark("form_post", false);
      location.href = `http://${H}:8765/location`; await wait(1500); mark("location", false);
      Object.assign(window.__probe, { results, reached, summary: `${reached}/11 reached` });
      document.getElementById("out").textContent = window.__probe.summary;
      window.__probeDone = true;
    }
    run();
    </script></body></html>
    """#
}
