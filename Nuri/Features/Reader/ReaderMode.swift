import SwiftUI
import WebKit

struct ReaderArticle: Equatable {
    var title: String
    var byline: String
    var site: String
    var html: String
    var words: Int
    var url: URL
}

/// Reader mode (⌘⇧R): extracts the article with reader.js and shows it in a
/// JavaScript-disabled web view with Nuri's typography.
@MainActor
enum ReaderMode {
    static func toggle(_ tab: Tab) {
        if tab.reader != nil {
            withAnimation(Theme.spring) { tab.reader = nil }
            return
        }
        guard let webView = tab.webView else { return }
        Task {
            guard let dict = await webView.nuriCall("return (\n\(Scripts.reader)\n);") as? [String: Any],
                  let html = dict["html"] as? String,
                  let url = URL(string: dict["url"] as? String ?? "") ?? webView.url else {
                tab.browser?.showToast("doc.text.magnifyingglass", L("Pas d'article détecté sur cette page", "No article found on this page"))
                return
            }
            let article = ReaderArticle(title: dict["title"] as? String ?? "",
                                        byline: dict["byline"] as? String ?? "",
                                        site: dict["site"] as? String ?? "",
                                        html: html,
                                        words: dict["words"] as? Int ?? 0,
                                        url: url)
            withAnimation(Theme.spring) { tab.reader = article }
        }
    }

    static func document(for article: ReaderArticle, fontScale: Double) -> String {
        let accent = AppSettings.shared.accent.nsColor.cssHex
        let minutes = max(1, article.words / 230)
        let meta = [article.site, article.byline, L("\(minutes) min de lecture", "\(minutes) min read")].filter { !$0.isEmpty }.map(escape).joined(separator: " · ")
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: http: data:; style-src 'unsafe-inline'">
        <meta name="color-scheme" content="dark light">
        <style>
        :root { color-scheme: dark light; --bg:#FBF5EC; --fg:#3F3329; --muted:#8A7969; --rule:rgba(107,88,72,.16); --accent:#B9694A; }
        @media (prefers-color-scheme: dark) { :root { --bg:#241E1B; --fg:#EFE5DB; --muted:#A99A8C; --rule:rgba(255,255,255,.12); --accent:\(accent); } }
        html { background: var(--bg); }
        body { margin: 0; padding: 72px 24px 120px; color: var(--fg); font: \(Int(19 * fontScale))px/1.65 ui-serif, "New York", Georgia, serif; -webkit-font-smoothing: antialiased; }
        main { max-width: 680px; margin: 0 auto; }
        header { margin-bottom: 40px; padding-bottom: 28px; border-bottom: 1px solid var(--rule); }
        .meta { font: 500 13px/1.4 -apple-system, system-ui, sans-serif; color: var(--muted); letter-spacing: .01em; }
        h1.title { font: 700 \(Int(36 * fontScale))px/1.15 -apple-system, system-ui, sans-serif; letter-spacing: -.02em; margin: 12px 0 0; }
        h1, h2, h3, h4 { font-family: -apple-system, system-ui, sans-serif; line-height: 1.25; letter-spacing: -.01em; margin: 1.8em 0 .6em; }
        p { margin: 0 0 1.1em; }
        a { color: var(--accent); text-decoration: none; }
        img { max-width: 100%; height: auto; border-radius: 8px; display: block; margin: 1.6em auto; }
        figure { margin: 1.6em 0; } figcaption { font: 13px/1.4 -apple-system, system-ui, sans-serif; color: var(--muted); text-align: center; }
        blockquote { margin: 1.4em 0; padding-left: 1.1em; border-left: 3px solid var(--accent); color: var(--muted); }
        pre, code { font: 14px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; }
        pre { background: var(--rule); padding: 14px 16px; border-radius: 8px; overflow-x: auto; }
        table { border-collapse: collapse; width: 100%; font-size: .9em; } td, th { border-bottom: 1px solid var(--rule); padding: 6px 8px; text-align: left; }
        hr { border: none; border-top: 1px solid var(--rule); margin: 2em 0; }
        </style></head><body><main>
        <header><div class="meta">\(meta)</div><h1 class="title">\(escape(article.title))</h1></header>
        <article>\(article.html)</article>
        </main></body></html>
        """
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// The reader overlay shown above the page.
struct ReaderView: View {
    let article: ReaderArticle
    let onClose: () -> Void
    @Environment(BrowserModel.self) private var browser
    @State private var fontScale: Double = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ReaderWebView(article: article, fontScale: fontScale, browser: browser)
            HStack(spacing: 2) {
                ChromeButton(symbol: "textformat.size.smaller", help: L("Réduire le texte", "Smaller text")) { fontScale = max(0.8, fontScale - 0.1) }
                ChromeButton(symbol: "textformat.size.larger", help: L("Agrandir le texte", "Larger text")) { fontScale = min(1.6, fontScale + 0.1) }
                ChromeButton(symbol: "xmark", help: L("Quitter le mode lecture (⌘⇧R)", "Leave reader mode (⌘⇧R)"), action: onClose)
            }
            .padding(4)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(14)
        }
        .onExitCommand(perform: onClose)
    }
}

private struct ReaderWebView: NSViewRepresentable {
    let article: ReaderArticle
    let fontScale: Double
    let browser: BrowserModel

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        // Its images come from the site: through the VPN too.
        ExtensionProxy.shared.attach(to: config.websiteDataStore)
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        // The article's images come from the page: its tracking pixels stay blocked here too.
        if let list = ContentRules.shared.installedAdBlockList { config.userContentController.add(list) }
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.underPageBackgroundColor = .clear
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.browser = browser
        let key = "\(article.url.absoluteString)|\(fontScale)"
        guard context.coordinator.loadedKey != key else { return }
        context.coordinator.loadedKey = key
        webView.loadHTMLString(ReaderMode.document(for: article, fontScale: fontScale), baseURL: article.url)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedKey = ""
        weak var browser: BrowserModel?
        // Links open in a new tab; the reader itself never navigates.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                await MainActor.run { _ = browser?.openTab(url: url, background: true) }
                return .cancel
            }
            return .allow
        }
    }
}
