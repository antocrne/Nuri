import AppKit

// No storyboard, no SwiftUI App scene: windows are plain AppKit windows hosting SwiftUI, so their
// lifetime is exactly the window's (closing a private window destroys its model and its storage).
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    withExtendedLifetime(delegate) { NSApplication.shared.run() }
}
