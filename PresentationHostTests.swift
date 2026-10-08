import AppKit
import SwiftUI

@main
struct PresentationHostTests {
    @MainActor
    static func main() async {
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "✅" : "❌") \(label)")
            if !condition { failures += 1 }
        }
        func settle() async { try? await Task.sleep(nanoseconds: 30_000_000) }
        check(PopoverSizing.maximumHeight(visibleHeight: 300) == 276,
              "short host does not get a 320pt minimum exceeding its work area")
        check(PopoverSizing.fittedHeight(content: 900, maximum: 676) == 676,
              "tall content is capped to host height")
        check(PopoverSizing.fittedHeight(content: 400, maximum: 676) == 400,
              "short content keeps measured height")
        check(PopoverSizing.fittedHeight(content: 0, maximum: 676) == nil,
              "unmeasured content retains automatic fitting")

        // These windows are never ordered or activated. Notifications are local
        // synthetic events; posting them does not change the display or Space.
        _ = NSApplication.shared
        let a = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                         styleMask: .borderless, backing: .buffered, defer: true)
        let b = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                         styleMask: .borderless, backing: .buffered, defer: true)
        await settle()
        let probe = PresentationHostView()
        var callbacks: [String] = []
        probe.onChange = { _, reason in callbacks.append(reason) }
        for index in 0..<12 {
            let current = index.isMultiple(of: 2) ? a : b
            let former = index.isMultiple(of: 2) ? b : a
            current.contentView!.addSubview(probe)
            current.contentView!.layoutSubtreeIfNeeded()
            if index == 0 { try? await Task.sleep(nanoseconds: 300_000_000) }
            await settle()
            callbacks.removeAll()
            NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: former)
            await settle()
            check(callbacks.isEmpty, "migration \(index): old-host observer detached")
            NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: current)
            await settle()
            check(callbacks.count == 1, "migration \(index): new host observed once")
        }
        callbacks.removeAll()
        probe.viewDidChangeBackingProperties()
        probe.viewDidChangeEffectiveAppearance()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        await settle()
        check(callbacks.count == 1 && callbacks[0].contains("backing") &&
              callbacks[0].contains("appearance") && callbacks[0].contains("space"),
              "rapid environment changes coalesce without model evaluation")
        callbacks.removeAll()
        probe.removeFromSuperview()
        await settle()
        callbacks.removeAll()
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: a)
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: b)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        await settle()
        check(callbacks.isEmpty, "detached view releases host and Space observers")
        probe.schedule("pending")
        probe.stop()
        await settle()
        check(callbacks.isEmpty, "teardown cancels queued callback")
        print("Presentation host tests: \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
