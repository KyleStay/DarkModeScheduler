import Foundation
import AppKit
import Combine
import CoreLocation
import UserNotifications
import ObjectiveC

// =============================================================================
// Services.swift — the app's side-effecting adapters:
//   • AppearanceController — reads/writes the live system appearance (AppleScript).
//   • GeocodeService       — postal code → lat/long (US default, intl support).
//   • LocationService      — optional CoreLocation auto-location.
//   • NotificationService  — opt-in switch notifications (UNUserNotificationCenter).
//   • NightShiftController  — opt-in Night Shift via the private CBBlueLightClient,
//                             isolated behind a protocol and fully guarded.
// =============================================================================

// MARK: - Appearance control

/// The result of one `enforce(...)` cycle, useful for logging, notifications,
/// and self-tests.
enum EnforceOutcome: Equatable {
    case unchanged(AppearanceMode)   // already correct → no AppleScript issued
    case applied(AppearanceMode)     // AppleScript issued, switch made
    case failedPermission            // Automation permission not granted
    case failed(Int)                 // other AppleScript error (osastatus code)
}

/// Reads the live system appearance and applies changes idempotently via
/// AppleScript to System Events (the only method that live-updates the UI).
struct AppearanceController {

    /// The current live appearance, read from the global-domain preference that
    /// macOS keeps in sync (`AppleInterfaceStyle` == "Dark" when Dark).
    func currentMode() -> AppearanceMode {
        if let style = UserDefaults.standard.string(forKey: "AppleInterfaceStyle"),
           style.lowercased() == "dark" {
            return .dark
        }
        return .light
    }

    /// Ensure the system appearance equals `desired`. Idempotent: if the live
    /// appearance already matches, **no AppleScript is issued** (no flicker).
    @discardableResult
    func enforce(desired: AppearanceMode) -> EnforceOutcome {
        let current = currentMode()
        guard current != desired else {
            Log.appearance.debug("enforce: already \(desired.label, privacy: .public); no AppleScript issued")
            return .unchanged(desired)
        }
        Log.appearance.info("enforce: \(current.label, privacy: .public) → \(desired.label, privacy: .public); issuing AppleScript")
        return apply(desired: desired)
    }

    /// Unconditionally apply `desired` via AppleScript. Prefer `enforce(desired:)`.
    @discardableResult
    func apply(desired: AppearanceMode) -> EnforceOutcome {
        let source = "tell application \"System Events\" to tell appearance preferences to set dark mode to \(desired.isDark)"
        guard let script = NSAppleScript(source: source) else {
            Log.appearance.error("Failed to construct NSAppleScript")
            return .failed(-1)
        }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "unknown error"
            // -1743 = errAEEventNotPermitted (Automation permission not granted).
            if code == -1743 {
                Log.appearance.error("AppleScript not permitted (-1743): Automation permission required")
                return .failedPermission
            }
            Log.appearance.error("AppleScript failed (\(code)): \(message, privacy: .public)")
            return .failed(code)
        }
        Log.appearance.info("Applied \(desired.label, privacy: .public)")
        return .applied(desired)
    }
}

// MARK: - Geocoding (the only outbound network use)

/// Resolves a postal code to latitude/longitude and place name via the free,
/// key-less Zippopotam API. US 5-digit zips are the default happy path; other
/// countries are supported by prefixing the ISO country code. Sun times are
/// always computed locally — this is the app's only network call.
struct GeocodeService {

    /// Shape of the api.zippopotam.us JSON response. Keys contain spaces, and
    /// non-US responses may omit the state abbreviation, so both are optional.
    private struct Response: Decodable {
        let places: [Place]
        struct Place: Decodable {
            let latitude: String
            let longitude: String
            let placeName: String
            let stateAbbreviation: String?
            let state: String?
            enum CodingKeys: String, CodingKey {
                case latitude, longitude, state
                case placeName = "place name"
                case stateAbbreviation = "state abbreviation"
            }
        }
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    static func isValidUSZip(_ zip: String) -> Bool {
        zip.count == 5 && zip.allSatisfy { $0.isNumber }
    }

    /// Loose validity for non-US postal codes: 2–10 chars of letters/digits/space/hyphen.
    static func isPlausiblePostal(_ code: String, country: String) -> Bool {
        if country.uppercased() == "US" { return isValidUSZip(code) }
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789- ")
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        return (2...10).contains(trimmed.count)
            && trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Resolve a postal code for a country (default "US"). Throws a
    /// `GeocodeError` on any failure — never crashes.
    func resolve(postal: String, country: String = "US") async throws -> ResolvedLocation {
        let cc = country.trimmingCharacters(in: .whitespaces).uppercased()
        let code = postal.trimmingCharacters(in: .whitespaces)

        guard Self.isPlausiblePostal(code, country: cc) else {
            throw cc == "US" ? GeocodeError.invalidZip : GeocodeError.invalidPostal
        }

        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "api.zippopotam.us"
        comps.path = "/\(cc.lowercased())/\(code)"
        guard let url = comps.url else {
            throw cc == "US" ? GeocodeError.invalidZip : GeocodeError.invalidPostal
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            Log.geocode.error("Network error for \(cc, privacy: .public)/\(code, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw GeocodeError.offline
        }

        guard let http = response as? HTTPURLResponse else { throw GeocodeError.badResponse }
        if http.statusCode == 404 { throw GeocodeError.notFound }
        guard http.statusCode == 200 else {
            Log.geocode.error("HTTP \(http.statusCode) for \(cc, privacy: .public)/\(code, privacy: .public)")
            throw GeocodeError.badResponse
        }

        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let place = decoded.places.first,
              let lat = Double(place.latitude),
              let lon = Double(place.longitude) else {
            throw GeocodeError.badResponse
        }

        // Prefer the abbreviation (US), fall back to full state name (intl), else empty.
        let region = place.stateAbbreviation?.isEmpty == false
            ? place.stateAbbreviation!
            : (place.state ?? "")

        let location = ResolvedLocation(zip: code, latitude: lat, longitude: lon,
                                        city: place.placeName, state: region,
                                        country: cc, source: .zip)
        Log.geocode.info("Resolved \(cc, privacy: .public)/\(code, privacy: .public) → \(location.displayName, privacy: .public) (\(lat), \(lon))")
        return location
    }
}

// MARK: - CoreLocation (optional auto-location)

/// Thin wrapper around CLLocationManager. Publishes the authorization status and
/// hands back a `ResolvedLocation` (reverse-geocoded for a friendly name) via
/// callbacks. Location Services is fully optional — the app works without it.
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {

    @Published private(set) var authorizationStatus: CLAuthorizationStatus

    /// Called on the main thread with a resolved fix / a human-readable error.
    var onResolved: ((ResolvedLocation) -> Void)?
    var onError: ((String) -> Void)?

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var wantsFixOnAuthorization = false

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// Any granted variant (Always / WhenInUse / the deprecated `.authorized`).
    /// Categorize by exclusion so we don't depend on which variants this SDK
    /// exposes on macOS.
    static func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        switch status {
        case .notDetermined, .denied, .restricted: return false
        default: return true
        }
    }

    var isAuthorized: Bool { Self.isAuthorized(authorizationStatus) }

    /// Ask for a location fix, driving the authorization flow as needed.
    func requestLocation() {
        switch authorizationStatus {
        case .notDetermined:
            wantsFixOnAuthorization = true
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            onError?("Location access is off. Enable it in System Settings → Privacy & Security → Location Services.")
        default:  // any authorized variant
            manager.requestLocation()
        }
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        DispatchQueue.main.async {
            self.authorizationStatus = status
            Log.location.info("Authorization changed: \(status.rawValue)")
            if self.wantsFixOnAuthorization, Self.isAuthorized(status) {
                self.wantsFixOnAuthorization = false
                manager.requestLocation()
            } else if status == .denied || status == .restricted {
                self.wantsFixOnAuthorization = false
                self.onError?("Location access was denied. You can still use a postal code.")
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Log.location.info("Got fix: \(loc.coordinate.latitude), \(loc.coordinate.longitude)")
        geocoder.reverseGeocodeLocation(loc) { [weak self] placemarks, error in
            guard let self else { return }
            // A newer reverse-geocode cancels this one; don't let the cancelled
            // callback overwrite the newer result with a generic placeholder.
            if let clError = error as? CLError, clError.code == .geocodeCanceled { return }
            let placemark = placemarks?.first
            let city = placemark?.locality ?? placemark?.name ?? "Current Location"
            let region = placemark?.administrativeArea ?? ""
            let country = placemark?.isoCountryCode ?? ""
            let postal = placemark?.postalCode ?? ""
            let resolved = ResolvedLocation(zip: postal.isEmpty ? "—" : postal,
                                            latitude: loc.coordinate.latitude,
                                            longitude: loc.coordinate.longitude,
                                            city: city, state: region,
                                            country: country.isEmpty ? "US" : country,
                                            source: .coreLocation)
            DispatchQueue.main.async { self.onResolved?(resolved) }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Log.location.error("Location error: \(error.localizedDescription, privacy: .public)")
        DispatchQueue.main.async {
            self.onError?("Couldn't get your location. Try again or use a postal code.")
        }
    }
}

// MARK: - Notifications (opt-in)

/// Wraps UNUserNotificationCenter. Authorization is requested only when the user
/// turns notifications on, and notices are posted only on real switches.
final class NotificationService {

    /// Request authorization; calls back with the granted flag on the main thread.
    func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
            if let error {
                Log.notify.error("Authorization error: \(error.localizedDescription, privacy: .public)")
            }
            DispatchQueue.main.async { completion(granted) }
        }
    }

    /// Post a "Switched to X" notice. Best-effort; silently no-ops if unauthorized.
    func postSwitch(to mode: AppearanceMode) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized ||
                  settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = "Switched to \(mode.label)"
            content.body = mode.isDark ? "Dark appearance is now on." : "Light appearance is now on."
            let request = UNNotificationRequest(identifier: UUID().uuidString,
                                                content: content, trigger: nil)
            center.add(request) { error in
                if let error {
                    Log.notify.error("Post failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}

// MARK: - Night Shift (opt-in; private API, fully guarded)

/// Abstract control over "warm color temperature" so the rest of the app never
/// touches the private API directly.
protocol NightShiftControlling {
    /// Whether the underlying mechanism is present on this macOS.
    var isAvailable: Bool { get }
    /// Turn warm mode on/off. Returns true iff the call was applied.
    @discardableResult func setActive(_ active: Bool) -> Bool
}

/// Night Shift has **no public API**. It lives behind the private
/// `CBBlueLightClient` class in the CoreBrightness framework. Rather than link
/// that private framework (fragile, can break at launch across OS versions), we
/// resolve the class and its methods entirely at runtime via the Objective-C
/// runtime, guard every step, and degrade to "unavailable" if anything is
/// missing — we never fake success. See README's Night Shift caveat.
final class CoreBrightnessNightShift: NightShiftControlling {

    private typealias SetEnabledIMP = @convention(c) (AnyObject, Selector, ObjCBool) -> ObjCBool

    private let client: NSObject?
    private let setEnabledSel = NSSelectorFromString("setEnabled:")

    init() {
        // The private CoreBrightness framework isn't linked, so its classes are
        // not registered until we load the image. dlopen it (lazily, read-only)
        // so NSClassFromString can find CBBlueLightClient. If the framework is
        // absent on this macOS, the feature simply stays unavailable.
        if dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
                  RTLD_LAZY) == nil {
            Log.nightshift.info("CoreBrightness dlopen failed; Night Shift unavailable")
            client = nil
            return
        }
        // Resolve the private class dynamically; absent → feature unavailable.
        guard let cls = NSClassFromString("CBBlueLightClient") as? NSObject.Type else {
            Log.nightshift.info("CBBlueLightClient not found; Night Shift unavailable")
            client = nil
            return
        }
        let instance = cls.init()
        guard instance.responds(to: setEnabledSel) else {
            Log.nightshift.info("CBBlueLightClient missing setEnabled:; Night Shift unavailable")
            client = nil
            return
        }
        client = instance
        Log.nightshift.info("CBBlueLightClient available; Night Shift enabled")
    }

    var isAvailable: Bool { client != nil }

    @discardableResult
    func setActive(_ active: Bool) -> Bool {
        guard let client else { return false }

        // Toggle Night Shift on/off only. We deliberately do NOT call
        // setStrength: — that would overwrite the warmth the user configured in
        // System Settings. Enabling applies their chosen strength.
        guard let method = class_getInstanceMethod(type(of: client), setEnabledSel) else {
            return false
        }
        let fn = unsafeBitCast(method_getImplementation(method), to: SetEnabledIMP.self)
        let ok = fn(client, setEnabledSel, ObjCBool(active))
        Log.nightshift.info("setEnabled(\(active)) → \(ok.boolValue)")
        return ok.boolValue
    }
}
