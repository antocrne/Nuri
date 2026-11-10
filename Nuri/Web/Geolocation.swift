import CoreLocation
import WebKit

/// Where navigator.geolocation's positions come from. On the Mac, WebKit asks its app for them
/// (Safari has its own provider) and has none of its own: without this, a page allowed to know where
/// you are waits forever, neither position nor error (leboncoin's « Autour de moi »). WebKit's C
/// API (WKGeolocationManager) takes the provider; it is looked up at run time, so a WebKit without it
/// leaves pages waiting, as before. The permission itself stays with the UI delegate
/// (`_webView:requestGeolocationPermissionForOrigin:…`): WebKit only asks here once a site may know.
@MainActor
final class Geolocation: NSObject, CLLocationManagerDelegate {
    static let shared = Geolocation()

    private typealias GetManager = @convention(c) (UnsafeRawPointer) -> UnsafeRawPointer?
    private typealias SetProvider = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> Void
    private typealias CreatePosition = @convention(c) (Double, Double, Double, Double, Bool, Double, Bool, Double, Bool, Double, Bool, Double) -> UnsafeRawPointer?
    private typealias Deliver = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> Void
    private typealias Fail = @convention(c) (UnsafeRawPointer) -> Void
    private typealias FailWithMessage = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> Void
    private typealias CreateString = @convention(c) (UnsafePointer<CChar>) -> UnsafeRawPointer?
    private typealias Release = @convention(c) (UnsafeRawPointer) -> Void
    private typealias Callback = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?) -> Void
    private typealias AccuracyCallback = @convention(c) (UnsafeRawPointer?, Bool, UnsafeRawPointer?) -> Void

    /// WKGeolocationProviderV1, laid out as WebKit reads it.
    private struct ProviderV1 {
        var version: Int32
        var clientInfo: UnsafeRawPointer?
        var startUpdating: Callback
        var stopUpdating: Callback
        var setEnableHighAccuracy: AccuracyCallback
    }

    private struct API {
        let getManager: GetManager
        let setProvider: SetProvider
        let createPosition: CreatePosition
        let deliver: Deliver
        let fail: Fail
        let failWithMessage: FailWithMessage?
        let createString: CreateString?
        let release: Release

        init?() {
            guard let webKit = dlopen("/System/Library/Frameworks/WebKit.framework/WebKit", RTLD_NOW) else { return nil }
            func symbol<T>(_ name: String, _ type: T.Type) -> T? { dlsym(webKit, name).map { unsafeBitCast($0, to: T.self) } }
            guard let getManager = symbol("WKContextGetGeolocationManager", GetManager.self),
                  let setProvider = symbol("WKGeolocationManagerSetProvider", SetProvider.self),
                  let createPosition = symbol("WKGeolocationPositionCreate_b", CreatePosition.self),
                  let deliver = symbol("WKGeolocationManagerProviderDidChangePosition", Deliver.self),
                  let fail = symbol("WKGeolocationManagerProviderDidFailToDeterminePosition", Fail.self),
                  let release = symbol("WKRelease", Release.self) else { return nil }
            self.getManager = getManager
            self.setProvider = setProvider
            self.createPosition = createPosition
            self.deliver = deliver
            self.fail = fail
            self.failWithMessage = symbol("WKGeolocationManagerProviderDidFailToDeterminePositionWithErrorMessage", FailWithMessage.self)
            self.createString = symbol("WKStringCreateWithUTF8CString", CreateString.self)
            self.release = release
        }
    }

    private let api = API()
    /// Kept for as long as Nuri runs: WebKit keeps the pointer.
    private let provider: UnsafeMutablePointer<ProviderV1>
    /// Each web view configuration has its own process pool, each with its own manager.
    private let pools = NSHashTable<WKProcessPool>.weakObjects()
    /// Managers of pages watching the position now.
    private var updating: [UnsafeRawPointer] = []
    private var highAccuracy: Set<UnsafeRawPointer> = []
    private lazy var locationManager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.delegate = self
        return manager
    }()
    /// Without a position by then, the page is told there is none (it would otherwise wait forever).
    private var timeout: Task<Void, Never>?
    private static let patience: Duration = .seconds(20)

    #if DEBUG
    /// Self-tests: positions given by the test, never by CoreLocation.
    var testPosition: CLLocation?
    #endif

    private override init() {
        provider = .allocate(capacity: 1)
        provider.initialize(to: ProviderV1(
            version: 1, clientInfo: nil,
            startUpdating: { manager, _ in
                guard let manager else { return }
                MainActor.assumeIsolated { Geolocation.shared.start(manager) }
            },
            stopUpdating: { manager, _ in
                guard let manager else { return }
                MainActor.assumeIsolated { Geolocation.shared.stop(manager) }
            },
            setEnableHighAccuracy: { manager, enabled, _ in
                guard let manager else { return }
                MainActor.assumeIsolated { Geolocation.shared.setHighAccuracy(enabled, for: manager) }
            }))
        super.init()
    }

    /// Gives the provider to the pool of this web view (once per pool).
    func attach(to webView: WKWebView) {
        let pool = webView.configuration.processPool
        guard let api, !pools.contains(pool) else { return }
        pools.add(pool)
        guard let manager = api.getManager(UnsafeRawPointer(Unmanaged.passUnretained(pool).toOpaque())) else { return }
        api.setProvider(manager, UnsafeRawPointer(provider))
    }

    // MARK: - WebKit's calls

    private func start(_ manager: UnsafeRawPointer) {
        if !updating.contains(manager) { updating.append(manager) }
        #if DEBUG
        if let testPosition { deliver(testPosition); return }
        #endif
        switch locationManager.authorizationStatus {
        case .denied, .restricted:
            fail(L("Nuri n'a pas accès à votre position.", "Nuri can't read your location."))
            return
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        default:
            break
        }
        updateAccuracy()
        locationManager.startUpdatingLocation()
        // A position of less than a minute ago answers at once; a better one follows.
        if let recent = locationManager.location, -recent.timestamp.timeIntervalSinceNow < 60 { deliver(recent) }
        waitForPosition()
    }

    private func stop(_ manager: UnsafeRawPointer) {
        updating.removeAll { $0 == manager }
        highAccuracy.remove(manager)
        guard updating.isEmpty else { updateAccuracy(); return }
        timeout?.cancel()
        timeout = nil
        locationManager.stopUpdatingLocation()
    }

    private func setHighAccuracy(_ enabled: Bool, for manager: UnsafeRawPointer) {
        if enabled { highAccuracy.insert(manager) } else { highAccuracy.remove(manager) }
        updateAccuracy()
    }

    private func updateAccuracy() {
        locationManager.desiredAccuracy = highAccuracy.isEmpty ? kCLLocationAccuracyHundredMeters : kCLLocationAccuracyBest
    }

    private func waitForPosition() {
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.patience)
            guard !Task.isCancelled, let self, !self.updating.isEmpty else { return }
            self.fail(L("Position introuvable.", "Location unavailable."))
        }
    }

    // MARK: - To the pages

    private func deliver(_ location: CLLocation) {
        guard let api, !updating.isEmpty, location.horizontalAccuracy >= 0 else { return }
        timeout?.cancel()
        timeout = nil
        let position = api.createPosition(
            location.timestamp.timeIntervalSince1970, location.coordinate.latitude, location.coordinate.longitude, location.horizontalAccuracy,
            location.verticalAccuracy >= 0, location.altitude, location.verticalAccuracy >= 0, location.verticalAccuracy,
            location.course >= 0, location.course, location.speed >= 0, location.speed)
        guard let position else { return }
        for manager in updating { api.deliver(manager, position) }
        api.release(position)
    }

    private func fail(_ message: String) {
        guard let api else { return }
        timeout?.cancel()
        timeout = nil
        let text = api.createString.flatMap { create in message.withCString { create($0) } }
        for manager in updating {
            if let text, let failWithMessage = api.failWithMessage { failWithMessage(manager, text) } else { api.fail(manager) }
        }
        if let text { api.release(text) }
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        MainActor.assumeIsolated { deliver(last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let code = (error as? CLError)?.code
        MainActor.assumeIsolated {
            switch code {
            // Not found yet: CoreLocation keeps looking, the page waits (up to `patience`).
            case .locationUnknown: break
            case .denied: fail(L("Nuri n'a pas accès à votre position.", "Nuri can't read your location."))
            default: fail(L("Position introuvable.", "Location unavailable."))
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            guard !updating.isEmpty else { return }
            switch status {
            case .denied, .restricted: fail(L("Nuri n'a pas accès à votre position.", "Nuri can't read your location."))
            case .authorizedAlways, .authorizedWhenInUse: locationManager.startUpdatingLocation()
            default: break
            }
        }
    }
}
