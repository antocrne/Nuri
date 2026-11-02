import AppKit
import SwiftUI

/// The pastel colors Nuri offers: for its accent, and for each space. Warm first; never intense.
enum Pastel: String, CaseIterable, Identifiable, Codable {
    case peach, apricot, rose, honey, sage, sky, lavender, clay
    var id: String { rawValue }

    @MainActor var label: String {
        switch self {
        case .peach: L("Pêche", "Peach")
        case .apricot: L("Abricot", "Apricot")
        case .rose: L("Rose poudré", "Dusty rose")
        case .honey: L("Miel", "Honey")
        case .sage: L("Sauge", "Sage")
        case .sky: L("Ciel", "Sky")
        case .lavender: L("Lavande", "Lavender")
        case .clay: L("Argile", "Clay")
        }
    }

    /// (light appearance, dark appearance): a touch deeper on light frames so it stays visible.
    private var rgb: (light: UInt32, dark: UInt32) {
        switch self {
        case .peach: (0xE9A488, 0xF2B9A0)
        case .apricot: (0xEBB073, 0xF3C48F)
        case .rose: (0xDF9DA6, 0xEDB5BC)
        case .honey: (0xDDB65F, 0xEBCD84)
        case .sage: (0x9DB58C, 0xB4CBA4)
        case .sky: (0x8FB3CF, 0xA9C8E0)
        case .lavender: (0xABA2D3, 0xC0B8E3)
        case .clay: (0xC49A83, 0xD6B19C)
        }
    }

    var nsColor: NSColor {
        let (l, d) = rgb
        return .nuriDynamic(light: NSColor(hex: l), dark: NSColor(hex: d))
    }
    var color: Color { Color(nsColor: nsColor) }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// A color that follows the light or dark appearance it is drawn in.
    static func nuriDynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }

    var cssHex: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}

/// Every color and motion of the chrome: warm paper in light, warm cocoa in dark.
enum Theme {
    static let spring = Animation.spring(response: 0.3, dampingFraction: 0.86)
    static let quick = Animation.easeOut(duration: 0.14)
    /// Tabs making room for the one being carried: fast enough to keep up with the pointer.
    static let slide = Animation.spring(response: 0.22, dampingFraction: 0.9)
    /// A veil coming over the window or leaving it.
    static let veil = Animation.easeOut(duration: 0.2)

    private static func dynamic(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: .nuriDynamic(light: NSColor(hex: light, alpha: lightAlpha), dark: NSColor(hex: dark, alpha: darkAlpha)))
    }

    /// Text and icons of the chrome, a warm brown rather than black.
    static let text = dynamic(0x43362C, 0xF3E9DF)
    static let secondaryText = dynamic(0x7A6A5C, 0xBFB0A2)
    static let faintText = dynamic(0x7A6A5C, 0xBFB0A2, lightAlpha: 0.6, darkAlpha: 0.6)

    /// The warm veil over the blurred desktop.
    static let frameNS = NSColor.nuriDynamic(light: NSColor(hex: 0xF7EDE1), dark: NSColor(hex: 0x2B2420))
    /// Private windows: the same glass, cooler and darker, so there is no mistaking them.
    static let privateFrameNS = NSColor.nuriDynamic(light: NSColor(hex: 0x6A6072), dark: NSColor(hex: 0x262230))
    static let privateText = Color(nsColor: NSColor(hex: 0xF1ECF5))

    /// What sits on the frame: tabs, buttons, fields.
    static let control = dynamic(0xFFFFFF, 0xFFFFFF, lightAlpha: 0.42, darkAlpha: 0.08)
    static let controlHover = dynamic(0xFFFFFF, 0xFFFFFF, lightAlpha: 0.32, darkAlpha: 0.07)
    static let selected = dynamic(0xFFFFFF, 0xFFFFFF, lightAlpha: 0.78, darkAlpha: 0.17)
    static let hairline = dynamic(0x6B5848, 0xFFFFFF, lightAlpha: 0.14, darkAlpha: 0.1)
    static let shadow = dynamic(0x5A4634, 0x000000, lightAlpha: 0.22, darkAlpha: 0.5)

    /// Floating cards: command bar, panels, Porthole header.
    static let card = dynamic(0xFBF5ED, 0x352C27, lightAlpha: 0.97, darkAlpha: 0.97)
    /// The command bar's card: solid, so the page's text doesn't show through what is being typed.
    static let commandBarCard = dynamic(0xFBF5ED, 0x352C27)
    /// Over the window behind the command bar. Stronger in dark, where a dark page barely darkens.
    static let commandBarVeil = dynamic(0x2A1D14, 0x000000, lightAlpha: 0.14, darkAlpha: 0.25)
    /// Behind a page while it loads: never a white flash on a dark frame.
    static let pageBackdrop = dynamic(0xFFFBF6, 0x241E1B)
    static let danger = dynamic(0xBC5B4E, 0xE9968A)

    /// Text on an accent-colored background: always dark, the pastels are all light.
    static let onAccentNS = NSColor(hex: 0x3B2C22)
    static let onAccent = Color(nsColor: onAccentNS)

    static var accent: Color { MainActor.assumeIsolated { AppSettings.shared.accent.color } }

    static let videoBackgroundNS = NSColor.black
    static let videoControlNS = NSColor.white.withAlphaComponent(0.85)
}

/// The window's corners inside: the page's card.
enum Metrics {
    static let topBarHeight: CGFloat = 46
    static let pageInset: CGFloat = 7
    static let pageRadius: CGFloat = 11
    static let controlRadius: CGFloat = 9
    static let tabHeight: CGFloat = 30
}

/// A plain button of the chrome: an icon in a soft rounded square.
struct ChromeButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 28
    var iconSize: CGFloat = 13
    var isOn = false
    var isEnabled = true
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.chromeForeground) private var foreground

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(isOn ? Theme.accent : foreground)
                .opacity(isEnabled ? 1 : 0.35)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                    .fill(hovering && isEnabled ? Theme.controlHover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
        .animation(Theme.quick, value: hovering)
    }
}

/// A choice of a right-click menu, with its icon.
struct IconMenuItem: View {
    let title: String
    let symbol: String
    var role: ButtonRole? = nil
    let action: () -> Void

    init(_ title: String, _ symbol: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) { Label(title, systemImage: symbol).labelStyle(.titleAndIcon) }
    }
}

/// Nuri's name: the system's serif taken as outlines, so it scales like a drawing with no font to
/// ship, and the i's dot apart, in the color of the theme or the space.
struct NuriWordmark: View {
    var height: CGFloat = 44
    var color: Color = Theme.text
    var dot: Color = Theme.accent

    var body: some View {
        let scale = height / Self.outlines.box.height
        Canvas { context, _ in
            context.scaleBy(x: scale, y: scale)
            context.fill(Self.outlines.letters, with: .color(color))
            context.fill(Self.outlines.dot, with: .color(dot))
        }
        .frame(width: Self.outlines.box.width * scale, height: height)
        .accessibilityLabel("Nuri")
    }

    /// In a box with a margin: nothing touches its edges, where a Canvas would clip the antialiasing.
    private static let outlines: (letters: Path, dot: Path, box: CGSize) = {
        let size: CGFloat = 200
        let font = NSFont(descriptor: NSFont.systemFont(ofSize: size, weight: .medium).fontDescriptor.withDesign(.serif)!, size: size)! as CTFont
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "nuri", attributes: [.font: font, .kern: 2]))
        let letters = CGMutablePath()
        var dot = CGRect.zero
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var origins = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(), &glyphs)
            CTRunGetPositions(run, CFRange(), &origins)
            for index in 0..<count {
                guard let glyph = CTFontCreatePathForGlyph(font, glyphs[index], nil) else { continue }
                let move = CGAffineTransform(translationX: origins[index].x, y: origins[index].y)
                // The last letter's highest part is the i's dot.
                let parts = glyph.componentsSeparated().sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
                if index == count - 1, parts.count > 1 {
                    dot = parts[0].boundingBox.applying(move)
                    parts.dropFirst().forEach { letters.addPath($0, transform: move) }
                } else {
                    letters.addPath(glyph, transform: move)
                }
            }
        }
        // A little larger than the font's: a pale color needs it to be seen.
        dot = dot.insetBy(dx: -dot.width * 0.08, dy: -dot.height * 0.08)
        let margin: CGFloat = 3
        let bounds = letters.boundingBoxOfPath.union(dot)
        let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: margin - bounds.minX, ty: margin + bounds.maxY)
        return (Path(letters).applying(flip), Path(ellipseIn: dot.applying(flip)),
                CGSize(width: bounds.width + 2 * margin, height: bounds.height + 2 * margin))
    }()
}

/// Lays its views out in rows, going to the next row when the width runs out.
struct WrappingRow: Layout {
    var spacing: CGFloat = 6
    var centered = false

    private func rows(_ subviews: Subviews, width: CGFloat) -> [[(view: LayoutSubview, size: CGSize)]] {
        var rows: [[(view: LayoutSubview, size: CGSize)]] = [[]]
        var used: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if used + size.width > width, !rows[rows.count - 1].isEmpty {
                rows.append([])
                used = 0
            }
            rows[rows.count - 1].append((view, size))
            used += size.width + spacing
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = rows(subviews, width: width)
        let widest = rows.map { $0.reduce(0) { $0 + $1.size.width + spacing } - spacing }.max() ?? 0
        let height = rows.reduce(0) { $0 + ($1.map(\.size.height).max() ?? 0) + spacing } - spacing
        return CGSize(width: proposal.width ?? widest, height: max(0, height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            let used = row.reduce(0) { $0 + $1.size.width + spacing } - spacing
            var x = centered ? bounds.midX - used / 2 : bounds.minX
            for item in row {
                item.view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += (row.map(\.size.height).max() ?? 0) + spacing
        }
    }
}

private struct ChromeForegroundKey: EnvironmentKey {
    static let defaultValue = Theme.secondaryText
}

extension EnvironmentValues {
    /// Icons of the chrome: lighter over a private window's dark frame.
    var chromeForeground: Color {
        get { self[ChromeForegroundKey.self] }
        set { self[ChromeForegroundKey.self] = newValue }
    }
}
