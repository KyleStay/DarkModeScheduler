import Foundation

/// The product has one shared source tree and two distribution channels.
///
/// `APP_STORE` is supplied only by the App Store build. Keep channel policy
/// centralized here so feature work does not grow scattered conditional code.
enum DistributionChannel: String {
    case full
    case appStore

    static let current: DistributionChannel = {
        #if APP_STORE
        return .appStore
        #else
        return .full
        #endif
    }()

    /// Night Shift has no public API and must never be present in an App Store
    /// binary. The Full build retains the guarded CoreBrightness implementation.
    var supportsNightShift: Bool { self == .full }

    var label: String {
        switch self {
        case .full: return "Full"
        case .appStore: return "App Store"
        }
    }
}
