import AppKit
import SwiftUI

/// Everything inside a browser window, in the "window" coordinate space (top-left origin).
struct BrowserRootView: View {
    let browser: BrowserModel

    var body: some View {
        BrowserWindowContent()
            .environment(browser)
            .environment(AppSettings.shared)
            .environment(\.chromeForeground, browser.isPrivate ? Theme.privateText : Theme.secondaryText)
    }
}

private struct BrowserWindowContent: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(AppSettings.self) private var settings

    var body: some View {
        ZStack(alignment: .top) {
            FrameBackground()
            VStack(spacing: 0) {
                if showsFixedBar { TopBar() }
                if Updater.shared.showsBar { UpdateBar() }
                HStack(spacing: Metrics.pageInset) {
                    if settings.sidePanelOnLeft { sidePanel }
                    PageArea()
                    if !settings.sidePanelOnLeft { sidePanel }
                }
                .animation(Theme.spring, value: browser.sidePanel?.id)
                .padding(.horizontal, Metrics.pageInset)
                .padding(.bottom, Metrics.pageInset)
                .padding(.top, showsFixedBar ? 0 : Metrics.pageInset)
            }
            if !showsFixedBar, browser.topBarRevealed || browser.carry != nil {
                // Its look is behind it, not around it: clipping or shadowing the bar itself would
                // wrap its AppKit views in a container that keeps the clicks from reaching the tabs.
                TopBar()
                    .background {
                        RoundedRectangle(cornerRadius: Metrics.pageRadius, style: .continuous)
                            .fill(.regularMaterial)
                            .shadow(color: Theme.shadow, radius: 12, y: 4)
                    }
                    .transition(.opacity)
            }
            TabPreviewCard()
            CommandBarVeil()
            if let request = browser.commandBar {
                CommandBarOverlay(request: request).id(request.id)
            }
            if browser.carry != nil { TabCarryGhost() }
            if browser.onboardingStep != nil { OnboardingOverlay() }
        }
        .coordinateSpace(.named(WindowSpace.name))
        .ignoresSafeArea()
        .onChange(of: showsFixedBar || browser.topBarRevealed || browser.carry != nil) { _, shown in
            setTrafficLights(visible: shown)
        }
        .onAppear { setTrafficLights(visible: showsFixedBar || browser.topBarRevealed) }
    }

    @ViewBuilder
    private var sidePanel: some View {
        if let panel = browser.sidePanel, !browser.isPrivate {
            ExtensionSidePanelCard(panel: panel)
                .id(panel.id)
                .transition(.move(edge: settings.sidePanelOnLeft ? .leading : .trailing).combined(with: .opacity))
        }
    }

    /// In full screen, the bar stays: the pointer there brings up the system's menu bar instead.
    private var showsFixedBar: Bool { !settings.autoHideTopBar || browser.isFullScreen }

    private func setTrafficLights(visible: Bool) {
        guard let window = browser.window else { return }
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.isHidden = !visible
        }
    }
}

enum WindowSpace { static let name = "window" }

/// The window's frame: a warm veil over the blurred desktop and, optionally, two soft glows of the
/// space's color. Drawn once, not animated: it costs nothing once on screen.
struct FrameBackground: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            Rectangle().fill(Color(nsColor: browser.isPrivate ? Theme.privateFrameNS : Theme.frameNS))
                .opacity(veilOpacity)
            if settings.softGlows, !browser.isPrivate { ChromeGlow(tint: browser.currentSpace.tint.color) }
        }
    }

    /// 0 (solid) → 1 (most see-through). Never below a veil that keeps the text readable.
    private var veilOpacity: Double {
        if reduceTransparency { return 1 }
        return 1 - settings.transparency * 0.9
    }
}

/// Two soft glows, top left and bottom right. A nod to Firn's window, and all of it is here: this
/// view and `softGlows` are what to remove if it doesn't stay.
struct ChromeGlow: View {
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            let side = max(geometry.size.width, geometry.size.height)
            ZStack {
                RadialGradient(colors: [tint.opacity(0.3), tint.opacity(0)], center: .center, startRadius: 0, endRadius: side * 0.42)
                    .frame(width: side, height: side)
                    .position(x: geometry.size.width * 0.14, y: geometry.size.height * 0.04)
                RadialGradient(colors: [tint.opacity(0.18), tint.opacity(0)], center: .center, startRadius: 0, endRadius: side * 0.5)
                    .frame(width: side, height: side)
                    .position(x: geometry.size.width * 0.92, y: geometry.size.height * 0.96)
            }
        }
        .allowsHitTesting(false)
        .clipped()
    }
}

/// A new version is available, above the page.
private struct UpdateBar: View {
    var body: some View {
        let updater = Updater.shared
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(Theme.accent)
            switch updater.phase {
            case .available(let release):
                Text(L("Nuri \(release.version) est disponible", "Nuri \(release.version) is available"))
                Spacer()
                Button(L("Installer", "Install")) { updater.install() }
                Button(L("Plus tard", "Later")) { updater.dismiss() }
            case .downloading(_, let progress):
                Text(L("Téléchargement de la mise à jour…", "Downloading the update…"))
                ProgressView(value: progress).frame(width: 120)
                Spacer()
            case .ready(let release):
                Text(L("Nuri \(release.version) est prête", "Nuri \(release.version) is ready"))
                Spacer()
                Button(L("Relancer", "Relaunch")) { updater.relaunch() }
                Button(L("Plus tard", "Later")) { updater.dismiss() }
            case .failed(_, let message):
                Text(message)
                Spacer()
                Button(L("Réessayer", "Try Again")) { updater.retry() }
                Button(L("Plus tard", "Later")) { updater.dismiss() }
            case .idle, .checking:
                EmptyView()
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.text)
        .controlSize(.small)
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .frame(height: 30)
    }
}
