import AppKit
import SwiftUI

/// The downloads button and its panel: an arrow that becomes a ring filling up while files come in,
/// with the speed beside it, and a popover listing them — the history or, in a private window, only
/// that window's downloads.
struct DownloadsButton: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(\.chromeForeground) private var foreground
    @State private var hovering = false

    var body: some View {
        @Bindable var browser = browser
        let progress = DownloadManager.shared.progress(for: browser)
        let speed = DownloadManager.shared.speedText(for: browser)
        let label = DownloadManager.shared.speedLabel(for: browser)
        Button {
            browser.showingDownloads.toggle()
        } label: {
            HStack(spacing: 5) {
                if let progress {
                    DownloadProgressIcon(progress: progress)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(foreground)
                }
                if let label {
                    // A fixed width: the tabs beside it don't move each time the speed changes.
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(foreground)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(width: 56, alignment: .leading)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, label == nil ? 0 : 6)
            .frame(minWidth: 28, minHeight: 28)
            .background(RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                .fill(hovering || browser.showingDownloads ? Theme.controlHover : label == nil ? .clear : Theme.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(speed.map { L("Téléchargements (⌥⌘L) · \($0)", "Downloads (⌥⌘L) · \($0)") } ?? L("Téléchargements (⌥⌘L)", "Downloads (⌥⌘L)"))
        .onHover { hovering = $0 }
        .animation(Theme.quick, value: hovering)
        .animation(Theme.quick, value: label == nil)
        .popover(isPresented: $browser.showingDownloads, arrowEdge: .bottom) {
            DownloadsPopover(browser: browser)
        }
    }
}

/// The arrow inside a thin ring that fills up as the downloads progress; a short arc turns while
/// no size is known. Grey while everything is paused.
struct DownloadProgressIcon: View {
    let progress: DownloadManager.Progress
    @Environment(\.chromeForeground) private var foreground
    @State private var spinning = false

    private static let diameter: CGFloat = 18
    private static let line: CGFloat = 2.25

    var body: some View {
        let tint = progress.paused ? foreground : Theme.accent
        ZStack {
            Circle().stroke(foreground.opacity(0.22), lineWidth: Self.line)
            if let fraction = progress.fraction {
                Circle()
                    .trim(from: 0, to: max(0.03, fraction))
                    .stroke(tint, style: StrokeStyle(lineWidth: Self.line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    // WebKit's progress comes twice a second: the ring glides between reports.
                    .animation(.linear(duration: 0.5), value: fraction)
            } else {
                Circle()
                    .trim(from: 0, to: 0.22)
                    .stroke(tint, style: StrokeStyle(lineWidth: Self.line, lineCap: .round))
                    .rotationEffect(.degrees(spinning ? 270 : -90))
                    .animation(progress.paused ? .default : .linear(duration: 1.1).repeatForever(autoreverses: false), value: spinning)
                    .onAppear { spinning = !progress.paused }
                    .onChange(of: progress.paused) { spinning = !progress.paused }
            }
            // The pastels are too pale for so small a glyph: it takes the bar's color.
            Image(systemName: progress.paused ? "pause.fill" : "arrow.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(foreground)
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .accessibilityElement()
        .accessibilityLabel(L("Téléchargements", "Downloads"))
        .accessibilityValue(progress.fraction.map { $0.formatted(.percent.precision(.fractionLength(0))) }
                            ?? (progress.paused ? L("En pause", "Paused") : L("En cours", "In progress")))
    }
}

/// One download's progress in the theme's color (the system's bar turns grey out of a key window):
/// it glides between WebKit's reports and a light passes along it while bytes come in. A short piece
/// goes back and forth while no size is known.
struct DownloadBar: View {
    let fraction: Double?
    let moving: Bool
    @State private var phase = false

    private static let height: CGFloat = 5
    private static let sheenWidth: CGFloat = 70

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let tint = moving ? Theme.accent : Theme.secondaryText.opacity(0.5)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.secondaryText.opacity(0.16))
                if let fraction {
                    Capsule().fill(tint)
                        .overlay(alignment: .leading) {
                            if moving {
                                LinearGradient(colors: [.white.opacity(0), .white.opacity(0.65), .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: Self.sheenWidth)
                                    .offset(x: phase ? width : -Self.sheenWidth)
                                    .animation(.linear(duration: 1.5).repeatForever(autoreverses: false), value: phase)
                            }
                        }
                        .clipShape(Capsule())
                        .frame(width: max(Self.height, width * min(1, fraction)))
                        .animation(.linear(duration: 0.5), value: fraction)
                } else {
                    Capsule().fill(tint)
                        .frame(width: width * 0.25)
                        .offset(x: phase ? width * 0.75 : 0)
                        .animation(moving ? .easeInOut(duration: 0.9).repeatForever() : .default, value: phase)
                }
            }
        }
        .frame(height: Self.height)
        .onAppear { phase = moving }
        .onChange(of: moving) { phase = moving }
    }
}

struct DownloadsPopover: View {
    let browser: BrowserModel

    var body: some View {
        let manager = DownloadManager.shared
        let items = browser.isPrivate ? manager.items(of: browser) : manager.history
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(browser.isPrivate ? L("Téléchargements de cette fenêtre", "This window's downloads") : L("Téléchargements", "Downloads"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                if !browser.isPrivate {
                    Button(L("Effacer", "Clear")) { manager.clearFinished() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .disabled(!items.contains { $0.state != .running && $0.state != .paused })
                }
            }
            .padding([.horizontal, .top], 14)
            .padding(.bottom, 8)
            if items.isEmpty {
                Text(L("Aucun téléchargement.", "No downloads."))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(items) { DownloadRow(item: $0) }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider().padding(.top, 8)
            if browser.isPrivate {
                Text(L("Non ajoutés à l'historique des téléchargements. Les fichiers restent dans le dossier de téléchargement.",
                       "Not added to the downloads history. The files stay in the download folder."))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
            } else {
                Button(L("Ouvrir le dossier", "Open Folder")) { NSWorkspace.shared.open(AppSettings.shared.downloadFolder) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        }
        .frame(width: 340)
    }
}

struct DownloadRow: View {
    let item: DownloadItem

    var body: some View {
        let manager = DownloadManager.shared
        HStack(spacing: 10) {
            Image(systemName: "doc").foregroundStyle(Theme.secondaryText)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.filename).font(.system(size: 12.5)).foregroundStyle(Theme.text).lineLimit(1)
                switch item.state {
                case .running, .paused:
                    DownloadBar(fraction: item.totalBytes > 0 ? item.progress : nil, moving: item.state == .running)
                    caption(item.state == .paused ? item.pausedText : item.statusText).monospacedDigit()
                case .finished: caption(item.finishedText)
                case .cancelled: caption(L("Annulé", "Cancelled"))
                case .failed(let reason):
                    Text(item.canResume ? L("Interrompu · \(reason)", "Interrupted · \(reason)") : reason)
                        .font(.system(size: 11)).foregroundStyle(Theme.danger).lineLimit(2)
                }
            }
            Spacer()
            actions(manager)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { manager.open(item) }
        .contextMenu { menu(manager) }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
    }

    @ViewBuilder
    private func actions(_ manager: DownloadManager) -> some View {
        switch item.state {
        case .running, .paused:
            if item.state == .paused {
                rowButton("play.circle", L("Reprendre", "Resume")) { manager.resume(item) }.disabled(!item.canResume)
            } else if item.canPause {
                rowButton("pause.circle", L("Mettre en pause", "Pause")) { manager.pause(item) }
            }
            rowButton("xmark.circle", L("Annuler", "Cancel")) { manager.cancel(item) }
        default:
            if item.canResume {
                rowButton("play.circle", L("Reprendre", "Resume")) { manager.resume(item) }
            } else if item.canRetry {
                rowButton("arrow.clockwise.circle", L("Réessayer", "Try Again")) { manager.retry(item) }
            } else if item.state == .finished, item.destination != nil {
                rowButton("magnifyingglass.circle", L("Afficher dans le Finder", "Show in Finder")) { manager.reveal(item) }
            }
        }
    }

    private func rowButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(Theme.secondaryText)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder
    private func menu(_ manager: DownloadManager) -> some View {
        switch item.state {
        case .running, .paused:
            if item.state == .paused {
                IconMenuItem(L("Reprendre", "Resume"), "play") { manager.resume(item) }.disabled(!item.canResume)
            } else if item.canPause {
                IconMenuItem(L("Mettre en pause", "Pause"), "pause") { manager.pause(item) }
            }
            IconMenuItem(L("Annuler", "Cancel"), "xmark") { manager.cancel(item) }
        case .finished:
            IconMenuItem(L("Ouvrir", "Open"), "arrow.up.right.square") { manager.open(item) }
            IconMenuItem(L("Afficher dans le Finder", "Show in Finder"), "folder") { manager.reveal(item) }
            IconMenuItem(L("Déplacer vers…", "Move To…"), "arrow.right.doc.on.clipboard") { manager.move(item) }
        default:
            if item.canResume { IconMenuItem(L("Reprendre", "Resume"), "play") { manager.resume(item) } }
            if item.canRetry { IconMenuItem(item.canResume ? L("Recommencer depuis le début", "Start Over") : L("Réessayer", "Try Again"), "arrow.clockwise") { manager.retry(item) } }
        }
        if let source = item.sourceURL, ["http", "https"].contains(source.scheme?.lowercased() ?? "") {
            Divider()
            IconMenuItem(L("Copier l'adresse du fichier", "Copy File Address"), "link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(source.absoluteString, forType: .string)
            }
        }
    }
}
