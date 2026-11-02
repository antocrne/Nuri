import WebKit

/// Receives every message posted by Nuri's scripts and dispatches it to the owning tab.
/// Handlers are registered once on the shared content controller, so the tab is found
/// from `message.webView` (popups inherit the opener's controller).
final class ScriptMessageRouter: NSObject, WKScriptMessageHandler {
    static let shared = ScriptMessageRouter()
    static let names = ["nuriMedia", "nuriContext", "nuriActivity"]

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let webView = message.webView as? NuriWebView, let tab = webView.tab,
                  let body = message.body as? [String: Any] else { return }
            switch message.name {
            case "nuriMedia":
                PiPController.shared.handleReport(body, frame: message.frameInfo, tab: tab)
            case "nuriActivity":
                if body["type"] as? String == "input" {
                    tab.hasUserInput = true
                    tab.typedFrame = message.frameInfo
                } else if body["type"] as? String == "notification" {
                    WebNotifications.shared.show(body, from: message.frameInfo, tab: tab)
                }
            case "nuriContext":
                webView.contextLinkURL = (body["href"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
            default:
                break
            }
        }
    }
}
