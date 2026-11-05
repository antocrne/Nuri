import AVFoundation
import CoreLocation
import WebKit

/// Camera and microphone for a site (video calls: kMeet, Jitsi, Meet, Teams…), and its location
/// (Google Maps, store finders…). WebKit asks the UI delegate; a page whose request gets no answer
/// waits forever ("Configuring devices…").
/// Asked once per site and device, and only over a tab on screen. The answer is kept for the site
/// (Settings → Confidentialité lists it and takes it back); a private window keeps its own until it
/// closes, where a refusal lasts a minute, so that a page asking in a loop doesn't bring the
/// question back at once.
@MainActor
enum MediaPermission {
    /// What is asked for, each with its own lists.
    enum Device: String, CaseIterable {
        case camera, microphone, location

        var allowedSites: SiteList { SiteList(key: "\(rawValue)AllowedHosts") }
        var refusedSites: SiteList { SiteList(key: "\(rawValue)RefusedHosts") }

        @MainActor var allowedTitle: String {
            switch self {
            case .camera: L("Caméra autorisée", "Camera allowed")
            case .microphone: L("Micro autorisé", "Microphone allowed")
            case .location: L("Position autorisée", "Location allowed")
            }
        }

        @MainActor var refusedTitle: String {
            switch self {
            case .camera: L("Caméra refusée", "Camera denied")
            case .microphone: L("Micro refusé", "Microphone denied")
            case .location: L("Position refusée", "Location denied")
            }
        }
    }

    /// Settings → Confidentialité: every list, with its title.
    static var lists: [(title: String, list: SiteList)] {
        Device.allCases.flatMap { [($0.allowedTitle, $0.allowedSites), ($0.refusedTitle, $0.refusedSites)] }
    }

    /// Under the question: how long the answer lasts.
    static func scope(in browser: BrowserModel) -> String {
        browser.isPrivate ? L("Jusqu'à la fermeture de cette fenêtre privée.", "Until this private window closes.")
                          : L("Nuri s'en souviendra pour ce site : Réglages → Confidentialité pour changer d'avis.", "Nuri will remember it for this site: Settings → Privacy to change your mind.")
    }

    /// Private windows' answers, by window.
    private static var allowed: Set<String> = []
    private static var refused: [String: Date] = [:]
    /// Questions on screen: a second request meanwhile (camera then micro) waits for the answer.
    private static var asking: [String: Task<Bool, Never>] = [:]

    /// "la caméra", "le micro", "la caméra et le micro".
    static func devices(_ type: WKMediaCaptureType) -> String {
        switch type {
        case .camera: L("la caméra", "the camera")
        case .microphone: L("le micro", "the microphone")
        default: L("la caméra et le micro", "the camera and microphone")
        }
    }

    #if DEBUG
    /// Requests that reached Nuri (self-test: WebKit refuses on its own when its delegate isn't found).
    private(set) static var requests = 0
    #endif

    /// `ask` shows the question ("Autoriser … ?") and returns the answer.
    static func decide(host: String, type: WKMediaCaptureType, in browser: BrowserModel,
                       ask: @escaping @MainActor () async -> Bool) async -> WKPermissionDecision {
        #if DEBUG
        requests += 1
        #endif
        #if DEBUG
        // Self-tests never open the camera, but the page gets its answer.
        if SelfTestRunner.isRequested { return .deny }
        #endif
        guard await siteAllows(host, devices(of: type), in: browser, ask: ask) else { return .deny }
        // The system's own permission for Nuri, asked the first time.
        for media in mediaTypes(type) where await !systemAllows(media) {
            browser.showToast("video.slash", systemRefusal(media))
            return .deny
        }
        return .grant
    }

    /// The location (navigator.geolocation). macOS asks for its own permission the first time
    /// WebKit reads the position; once refused there, the site isn't asked in vain.
    static func decideLocation(host: String, in browser: BrowserModel,
                               ask: @escaping @MainActor () async -> Bool) async -> WKPermissionDecision {
        #if DEBUG
        requests += 1
        #endif
        #if DEBUG
        if SelfTestRunner.isRequested { return .deny }
        #endif
        switch CLLocationManager().authorizationStatus {
        case .denied, .restricted:
            browser.showToast("location.slash", L("Nuri n'a pas accès à votre position : Réglages Système → Confidentialité et sécurité → Service de localisation", "Nuri can't read your location: System Settings → Privacy & Security → Location Services"))
            return .deny
        default:
            return await siteAllows(host, [.location], in: browser, ask: ask) ? .grant : .deny
        }
    }

    static func devices(of type: WKMediaCaptureType) -> [Device] {
        switch type {
        case .camera: [.camera]
        case .microphone: [.microphone]
        default: [.camera, .microphone]
        }
    }

    /// The site's answer for `devices`: remembered, or asked. Camera and microphone asked together
    /// are allowed if both are; refused if either is.
    static func siteAllows(_ host: String, _ devices: [Device], in browser: BrowserModel,
                           ask: @escaping @MainActor () async -> Bool) async -> Bool {
        let what = devices.map(\.rawValue).joined(separator: "+")
        let key = (browser.isPrivate ? "\(ObjectIdentifier(browser).hashValue)|" : "") + "\(host)|\(what)"
        if browser.isPrivate {
            if allowed.contains(key) { return true }
            if let date = refused[key], Date().timeIntervalSince(date) < 60 { return false }
        } else {
            if devices.contains(where: { $0.refusedSites.contains(host) }) { return false }
            if devices.allSatisfy({ $0.allowedSites.contains(host) }) { return true }
        }
        let task = asking[key] ?? Task { @MainActor in await ask() }
        asking[key] = task
        let answer = await task.value
        asking[key] = nil
        if browser.isPrivate {
            if answer { allowed.insert(key) } else { refused[key] = Date() }
        } else {
            for device in devices {
                (answer ? device.refusedSites : device.allowedSites).remove(host)
                (answer ? device.allowedSites : device.refusedSites).add(host)
            }
        }
        return answer
    }

    private static func mediaTypes(_ type: WKMediaCaptureType) -> [AVMediaType] {
        switch type {
        case .camera: [.video]
        case .microphone: [.audio]
        default: [.video, .audio]
        }
    }

    private static func systemAllows(_ media: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: media)
        default: false
        }
    }

    private static func systemRefusal(_ media: AVMediaType) -> String {
        media == .video ? L("Nuri n'a pas accès à la caméra : Réglages Système → Confidentialité et sécurité", "Nuri can't use the camera: System Settings → Privacy & Security")
                        : L("Nuri n'a pas accès au micro : Réglages Système → Confidentialité et sécurité", "Nuri can't use the microphone: System Settings → Privacy & Security")
    }
}
