import AppKit
import SwiftUI
import WebKit

extension NSImage {
    /// A porthole, no symbol being one: a thick frame with its rivets, and the glint on the glass.
    /// A template, like the symbols around it in a menu.
    static let porthole: NSImage = {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            let center = NSPoint(x: 8, y: 8)
            func disc(_ radius: CGFloat, at point: NSPoint) -> NSRect {
                NSRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            }
            let frame = NSBezierPath(ovalIn: disc(7.5, at: center))
            frame.append(NSBezierPath(ovalIn: disc(4.4, at: center)))
            for index in 0..<8 {
                let angle = CGFloat(index) * .pi / 4
                frame.append(NSBezierPath(ovalIn: disc(0.72, at: NSPoint(x: 8 + 5.95 * cos(angle), y: 8 + 5.95 * sin(angle)))))
            }
            frame.windingRule = .evenOdd
            NSColor.black.setFill()
            frame.fill()
            let glint = NSBezierPath()
            glint.appendArc(withCenter: center, radius: 2.5, startAngle: 105, endAngle: 165)
            glint.lineWidth = 1.2
            glint.lineCapStyle = .round
            NSColor.black.setStroke()
            glint.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

/// The Porthole (« Hublot » in French): a glance at a link without leaving the page. ⌥-click on a
/// link, or « Ouvrir dans un hublot » in its menu. It is a real tab that isn't in the bar yet: same
/// space, same sign-ins. Keeping it just moves it there, page and history included. Esc, or a click
/// beside it, lets it go.
extension BrowserModel {
    func openPorthole(_ url: URL, from tab: Tab?) {
        closePorthole()
        let glance = Tab(url: url, isPrivate: isPrivate)
        glance.space = tab?.space ?? currentSpace
        withAnimation(Theme.spring) { porthole = glance }
        glance.ensureWebView()
        commandBar = nil
    }

    func closePorthole() {
        guard let glance = porthole else { return }
        withAnimation(Theme.spring) { porthole = nil }
        glance.isClosed = true
        if glance.isInFloatingPlayer { FloatingPlayer.shared.close() }
        if glance.isInPiP, let wv = glance.webView { PiPController.shared.forceExit(wv) }
        glance.sleep(force: true)
    }

    /// The glance becomes a tab of the bar, next to the current one.
    func keepPorthole() {
        guard let glance = porthole, let space = glance.space else { return }
        porthole = nil
        withAnimation(Theme.spring) {
            if let current = selectedTab, let i = space.tabs.firstIndex(where: { $0 === current }) {
                space.tabs.insert(glance, at: i + 1)
            } else {
                space.tabs.append(glance)
            }
        }
        select(glance)
    }

    /// The glance goes next to the current page, in split view.
    func portholeToSplit() {
        guard let glance = porthole, let space = glance.space, let current = selectedTab else {
            keepPorthole()
            return
        }
        porthole = nil
        withAnimation(Theme.spring) {
            if let i = space.tabs.firstIndex(where: { $0 === current }) {
                space.tabs.insert(glance, at: i + 1)
            } else {
                space.tabs.append(glance)
            }
        }
        setNeedsSave()
        showInSplit(glance)
    }
}

struct PortholeOverlay: View {
    let tab: Tab
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.16)
                    .contentShape(Rectangle())
                    .onTapGesture { browser.closePorthole() }
                VStack(spacing: 0) {
                    header
                    ZStack {
                        PortholeWebHost(tab: tab)
                        if let page = tab.insecurePage { InsecurePageView(tab: tab, page: page) }
                    }
                }
                .frame(width: min(geometry.size.width - 48, max(520, geometry.size.width * 0.74)),
                       height: geometry.size.height * 0.88)
                .background(Theme.pageBackdrop)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.hairline))
                .shadow(color: Theme.shadow, radius: 24, y: 8)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: tab.hasOnlySecureContent ? "lock.fill" : "globe")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.faintText)
            Text(tab.url?.host()?.nuriNormalizedHost ?? tab.displayTitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
            Spacer()
            ChromeButton(symbol: "rectangle.split.2x1", help: L("Mettre en vue partagée", "Move to split view"), size: 26, iconSize: 12) { browser.portholeToSplit() }
            ChromeButton(symbol: "arrow.up.left.and.arrow.down.right", help: L("Garder dans un onglet", "Keep in a tab"), size: 26, iconSize: 12) { browser.keepPorthole() }
            ChromeButton(symbol: "xmark", help: L("Fermer (Échap)", "Close (Esc)"), size: 26, iconSize: 11) { browser.closePorthole() }
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: 36)
        .background(Theme.card)
    }
}

private struct PortholeWebHost: NSViewRepresentable {
    let tab: Tab

    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        let webView = tab.ensureWebView()
        webView.removeFromSuperview()
        webView.frame = host.bounds
        webView.autoresizingMask = [.width, .height]
        host.addSubview(webView)
        DispatchQueue.main.async { [weak webView] in webView?.window?.makeFirstResponder(webView) }
        return host
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
