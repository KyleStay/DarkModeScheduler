import Foundation

@main
enum VariantContractTests {
    static func main() {
        #if APP_STORE
        precondition(DistributionChannel.current == .appStore)
        precondition(!DistributionChannel.current.supportsNightShift)
        print("✅ App Store capability contract")
        #else
        precondition(DistributionChannel.current == .full)
        precondition(DistributionChannel.current.supportsNightShift)
        print("✅ Full capability contract")
        #endif
    }
}
