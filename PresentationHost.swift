import AppKit
import SwiftUI

/// Observe the actual SwiftUI host, never the pointer's current screen. All
/// callbacks are coalesced onto the next main-actor turn after AppKit migration.
@MainActor
final class PresentationHostView: NSView {
    var onChange: ((PresentationHostView, String) -> Void)?
    private var windowObservers: [NSObjectProtocol] = []
    private var workspaceObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var pending: Task<Void, Never>?
    private var reasons = Set<String>()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers.removeAll()
        if let window {
            for name in [NSWindow.didChangeScreenNotification,
                         NSWindow.didChangeBackingPropertiesNotification,
                         NSWindow.didResizeNotification] {
                windowObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] notification in
                    MainActor.assumeIsolated { self?.schedule(notification.name.rawValue) }
                })
            }
            if workspaceObserver == nil {
                workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                    forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.schedule("space") }
                }
                screenObserver = NotificationCenter.default.addObserver(
                    forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.schedule("screens") }
                }
            }
        } else {
            detachEnvironmentObservers()
        }
        schedule("host")
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        schedule("backing")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        schedule("appearance")
    }

    func schedule(_ reason: String) {
        reasons.insert(reason)
        guard pending == nil else { return }
        pending = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            let reason = self.reasons.sorted().joined(separator: ",")
            self.reasons.removeAll()
            self.onChange?(self, reason)
        }
    }

    func stop() {
        pending?.cancel()
        pending = nil
        reasons.removeAll()
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers.removeAll()
        detachEnvironmentObservers()
        onChange = nil
    }

    private func detachEnvironmentObservers() {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        workspaceObserver = nil
        screenObserver = nil
    }

    deinit {
        pending?.cancel()
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }
}

struct PresentationHostReader: NSViewRepresentable {
    var onChange: (PresentationHostView, String) -> Void

    func makeNSView(context: Context) -> PresentationHostView {
        let view = PresentationHostView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: PresentationHostView, context: Context) {
        view.onChange = onChange
    }

    static func dismantleNSView(_ view: PresentationHostView, coordinator: ()) {
        view.stop()
    }
}

enum PopoverSizing {
    static func maximumHeight(visibleHeight: CGFloat?) -> CGFloat {
        // Do not force a 320pt minimum onto a smaller display/work area.
        max(1, (visibleHeight ?? 900) - 24)
    }

    static func fittedHeight(content: CGFloat, maximum: CGFloat) -> CGFloat? {
        content > 0 ? min(content, maximum) : nil
    }
}

/// Keep the production label shared with the synthetic reproduction scene and
/// offscreen glyph fixtures. No fixed tint, bitmap cache, or identity reset.
struct MenuBarGlyph: View {
    let night: Bool
    let summary: String

    var body: some View {
        Image(systemName: night ? "moon.stars" : "sun.max")
            .help(summary)
            .accessibilityLabel(summary)
    }
}
