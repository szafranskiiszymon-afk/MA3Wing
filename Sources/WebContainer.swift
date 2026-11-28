import SwiftUI
import WebKit

/// Connection settings, saved on the iPad.
struct LinkConfig: Codable {
    var mode: String = "direct"     // "direct" = OSC straight to MA, "bridge" = laptop bridge (WebSocket)
    var ip: String = ""
    var send: Int = 8000
    var recv: Int = 9000
    var prefix: String = "gma3"
    var bridge: String = ""

    static let key = "ma3wing.config"
    static func load() -> LinkConfig {
        if let d = UserDefaults.standard.data(forKey: key),
           let c = try? JSONDecoder().decode(LinkConfig.self, from: d) { return c }
        return LinkConfig()
    }
    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: LinkConfig.key) }
    }
    var json: String {
        (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? "{}"
    }
}

struct WebContainer: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(context.coordinator, name: "ma")
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.pinchGestureRecognizer?.isEnabled = false
        web.allowsLinkPreview = false
        context.coordinator.web = web
        context.coordinator.loadPage()
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKScriptMessageHandler {
        weak var web: WKWebView?
        private var config = LinkConfig.load()
        private let link = OSCLink()
        private var pending: [String] = []
        private var flushScheduled = false

        override init() {
            super.init()
            link.onMessage = { [weak self] m in self?.incoming(m) }
            link.onState = { [weak self] s in self?.toPage("fb\tSTATUS\t" + s) }
        }

        /// Page + settings; in direct mode the page's WebSocket is replaced by this native OSC link.
        func loadPage() {
            guard let web = web else { return }
            let uc = web.configuration.userContentController
            uc.removeAllUserScripts()
            var js = "window.MA3_CFG=\(config.json);"
            if config.mode != "bridge" {
                js += """
                (function(){
                  function NWS(url){var s=this;s.readyState=0;s.url=url;window.__nws=s;
                    setTimeout(function(){window.webkit.messageHandlers.ma.postMessage('!open');},0);}
                  NWS.prototype.send=function(m){window.webkit.messageHandlers.ma.postMessage(String(m));};
                  NWS.prototype.close=function(){};
                  window.__nwsOpen=function(){var s=window.__nws;if(s){s.readyState=1;if(s.onopen)s.onopen();}};
                  window.__nwsMsg=function(t){var s=window.__nws;if(s&&s.onmessage)s.onmessage({data:t});};
                  window.WebSocket=NWS;
                })();
                """
            }
            uc.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            if let url = Bundle.main.url(forResource: "index", withExtension: "html") {
                web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            }
        }

        // page -> app
        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? String else { return }
            if body.hasPrefix("!config\t") {
                let json = String(body.dropFirst(8))
                if let d = json.data(using: .utf8), let c = try? JSONDecoder().decode(LinkConfig.self, from: d) {
                    config = c
                    config.save()
                    link.stop()
                    loadPage()
                }
                return
            }
            if body == "!open" {
                if config.mode != "bridge" {
                    link.start(host: config.ip, sendPort: UInt16(clamping: config.send), recvPort: UInt16(clamping: config.recv))
                }
                web?.evaluateJavaScript("window.__nwsOpen&&window.__nwsOpen()")
                return
            }
            for line in body.split(separator: "\n") {
                if line.hasPrefix("!") { continue }            // keyboard / command-line mirror: only for the laptop bridge
                let p = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                guard p.count == 3 else { continue }
                let addr = config.prefix.isEmpty ? p[0] : "/" + config.prefix + p[0]
                link.send(address: addr, type: p[1], value: p[2])
            }
        }

        // MA -> page
        private func incoming(_ m: OSCMessage) {
            var a = m.address
            let pre = "/" + config.prefix + "/"
            if !config.prefix.isEmpty && a.hasPrefix(pre) { a = String(a.dropFirst(pre.count - 1)) }
            if a == "/ma3wing", let payload = m.args.first {
                // plugin in network mode: "KEY=VALUE%0AKEY=VALUE..." (%xx = special characters)
                let text = payload.removingPercentEncoding ?? payload
                for l in text.split(separator: "\n") {
                    guard let eq = l.firstIndex(of: "=") else { continue }
                    let k = String(l[..<eq]), v = String(l[l.index(after: eq)...])
                    if k == "HELLO" { continue }
                    toPage("fb\t\(k)\t\(v)")
                }
                return
            }
            if a.range(of: #"^/Page\d+/Fader\d+$"#, options: .regularExpression) != nil, let v = m.args.first {
                toPage("fb\t\(a)\t\(v)")
            }
        }

        /// Batches lines to the page (MA can send a lot at once).
        private func toPage(_ line: String) {
            DispatchQueue.main.async {
                self.pending.append(line)
                if self.flushScheduled { return }
                self.flushScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                    self.flushScheduled = false
                    let text = self.pending.joined(separator: "\n")
                    self.pending.removeAll()
                    guard let data = try? JSONSerialization.data(withJSONObject: [text]),
                          var arr = String(data: data, encoding: .utf8) else { return }
                    arr.removeFirst(); arr.removeLast()             // ["..."] -> "..."
                    self.web?.evaluateJavaScript("window.__nwsMsg&&window.__nwsMsg(\(arr))")
                }
            }
        }
    }
}
