import Foundation

@main
enum NightShiftAdapterTests {
    static func main() {
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print(condition ? "  ✅ \(label)" : "  ❌ \(label)")
            if !condition { failures += 1 }
        }

        check(MemoryLayout<CoreBrightnessNightShift.BlueLightStatus>.size == 33
                && MemoryLayout<CoreBrightnessNightShift.BlueLightStatus>.stride == 40,
              "status ABI payload is 33 bytes in a 40-byte stride")
        check(MemoryLayout<CoreBrightnessNightShift.BlueLightStatus>.offset(
            of: \CoreBrightnessNightShift.BlueLightStatus.active
        ) == 0, "service-active flag is at byte 0")
        check(MemoryLayout<CoreBrightnessNightShift.BlueLightStatus>.offset(
            of: \CoreBrightnessNightShift.BlueLightStatus.enabled
        ) == 1, "Night Shift enabled flag is at byte 1")
        check(MemoryLayout<CoreBrightnessNightShift.BlueLightStatus>.offset(
            of: \CoreBrightnessNightShift.BlueLightStatus.available
        ) == 32, "availability flag is at byte 32")

        var disabled = CoreBrightnessNightShift.BlueLightStatus()
        disabled.active = 1
        disabled.enabled = 0
        disabled.available = 1
        check(!disabled.isEnabled,
              "active service is not mistaken for enabled Night Shift")

        var enabled = disabled
        enabled.enabled = 1
        check(enabled.isEnabled, "enabled Night Shift is reported as enabled")
        if failures > 0 { exit(1) }
    }
}
