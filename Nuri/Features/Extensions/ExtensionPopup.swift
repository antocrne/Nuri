import AppKit
import WebKit

/// Extension popups. WebKit lays them out at their content's own size, at most 800 × 600; a popup
/// made to fill the room it's given (Proton Pass) then stays at its minimum. Nuri gives them room: a
/// larger size to start with, a grip in the corner to resize them, remembered per extension
/// (double-click on the grip: back to the extension's own size).
@available(macOS 15.4, *)
@MainActor
enum ExtensionPopupSizing {
    static let minimum = NSSize(width: 280, height: 200)
    /// Popups wider than this are small apps (password managers…): they start larger. Not at exactly
    /// 480: Bitwarden's is laid out for that width and gets cut if given more.
    private static let appWidth: CGFloat = 480
    private static let appScale: CGFloat = 1.25

    /// Before the popover shows.
    static func prepare(_ popover: NSPopover, webView: WKWebView, extensionID: String, screen: NSScreen?) {
        let own = popover.contentViewController?.preferredContentSize ?? webView.intrinsicContentSize
        guard own.width >= minimum.width / 2, own.height >= minimum.height / 2,
              WebKitSPI.disableSizeToContent(webView) else { return }
        // WebKit's own limits on the popup (800 × 600).
        for constraint in webView.constraints where constraint.firstItem === webView && constraint.secondItem == nil
            && (constraint.firstAttribute == .width || constraint.firstAttribute == .height) {
            constraint.isActive = false
        }
        let maximum = maximumSize(on: screen)
        let saved = UserDefaults.standard.string(forKey: key(extensionID)).map(NSSizeFromString)
        let start = saved ?? (own.width > appWidth ? NSSize(width: own.width * appScale, height: own.height * appScale) : own)
        let size = clamp(start, to: maximum)

        // A new controller around web view + grip. WebKit's lets go of the web view first: a view
        // left pointing at its old controller would loop the responder chain.
        popover.contentViewController?.view = NSView()
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        webView.nextResponder = container
        let grip = ResizeGrip(popover: popover, extensionID: extensionID, ownSize: clamp(own, to: maximum), maximum: maximum)
        grip.frame = NSRect(x: container.bounds.maxX - ResizeGrip.side, y: 0, width: ResizeGrip.side, height: ResizeGrip.side)
        grip.autoresizingMask = [.minXMargin, .maxYMargin]
        container.addSubview(grip)

        let controller = NSViewController()
        controller.view = container
        controller.preferredContentSize = size
        popover.contentViewController = controller
        popover.contentSize = size
    }

    static func key(_ extensionID: String) -> String { "extensionPopupSize.\(extensionID)" }

    /// Within the screen, with room for the button and a margin.
    static func maximumSize(on screen: NSScreen?) -> NSSize {
        let visible = (screen ?? NSScreen.main)?.visibleFrame.size ?? NSSize(width: 1280, height: 800)
        return NSSize(width: max(minimum.width, visible.width - 80), height: max(minimum.height, visible.height - 120))
    }

    static func clamp(_ size: NSSize, to maximum: NSSize) -> NSSize {
        NSSize(width: min(maximum.width, max(minimum.width, size.width.rounded())),
               height: min(maximum.height, max(minimum.height, size.height.rounded())))
    }
}

/// The bottom corner away from the button: drag to resize the popup, double-click for its own size.
@available(macOS 15.4, *)
private final class ResizeGrip: NSView {
    static let side: CGFloat = 16

    private weak var popover: NSPopover?
    private let extensionID: String
    private let ownSize: NSSize
    private let maximum: NSSize
    private var dragStart: (mouse: NSPoint, size: NSSize)?

    @MainActor
    init(popover: NSPopover, extensionID: String, ownSize: NSSize, maximum: NSSize) {
        self.popover = popover
        self.extensionID = extensionID
        self.ownSize = ownSize
        self.maximum = maximum
        super.init(frame: .zero)
        toolTip = L("Glisser pour redimensionner · double-clic : taille d'origine", "Drag to resize · double-click: original size")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        // Three diagonal strokes, pointing at the corner.
        let path = NSBezierPath()
        for inset in [3.0, 7.0, 11.0] {
            path.move(to: NSPoint(x: inset, y: 1))
            path.line(to: NSPoint(x: bounds.maxX - 1, y: bounds.maxX - inset))
        }
        path.lineWidth = 1
        path.lineCapStyle = .round
        NSColor.secondaryLabelColor.withAlphaComponent(0.6).setStroke()
        path.stroke()
    }

    /// Resizes from the first click, even when the popup isn't the key window yet.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .frameResize(position: .bottomRight, directions: .all))
    }

    override func mouseDown(with event: NSEvent) {
        guard let popover else { return }
        if event.clickCount == 2 {
            UserDefaults.standard.removeObject(forKey: ExtensionPopupSizing.key(extensionID))
            MainActor.assumeIsolated { resize(to: ownSize, animated: true) }
            return
        }
        dragStart = (NSEvent.mouseLocation, popover.contentSize)
        popover.animates = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let mouse = NSEvent.mouseLocation
        let size = NSSize(width: start.size.width + mouse.x - start.mouse.x, height: start.size.height - (mouse.y - start.mouse.y))
        MainActor.assumeIsolated { resize(to: size, animated: false) }
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil, let popover else { return }
        dragStart = nil
        popover.animates = true
        UserDefaults.standard.set(NSStringFromSize(popover.contentSize), forKey: ExtensionPopupSizing.key(extensionID))
    }

    @MainActor
    private func resize(to size: NSSize, animated: Bool) {
        guard let popover else { return }
        let size = ExtensionPopupSizing.clamp(size, to: maximum)
        popover.animates = animated
        popover.contentViewController?.preferredContentSize = size
        popover.contentSize = size
        popover.animates = true
    }
}
