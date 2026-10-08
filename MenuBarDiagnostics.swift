import AppKit
import SwiftUI
import Combine
import Darwin

/// Opt-in only. Reads public state of this process's own presentation. SwiftUI
/// does not expose its NSStatusItem, so visibility/length are explicitly unknown;
/// button bounds and window placement are evidence, not proof of bar overflow.
@MainActor
final class MenuBarDiagnostics: ObservableObject {
    static weak var shared: MenuBarDiagnostics?
    var inserted = true {
        didSet { if oldValue != inserted { request("scene-insertion") } }
    }
    @Published var night = false
    let dayModel: AppModel
    let nightModel: AppModel
    private let defaults: UserDefaults
    private let suite: String
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var sampleSignal: DispatchSourceSignal?
    private var pending: Task<Void, Never>?
    private var reasons = Set<String>()
    private var previouslyFoundButton = false
    private var sequence = 0
    private let captureDirectory: URL?
    private var cycle: AnyCancellable?
    private var lifetime: Task<Void, Never>?

    var model: AppModel { night ? nightModel : dayModel }

    init() {
        suite = "com.kyle.darkmodescheduler.presentation.\(ProcessInfo.processInfo.processIdentifier)"
        defaults = UserDefaults(suiteName: suite)!
        let args = CommandLine.arguments
        night = args.contains("--night")
        if let i = args.firstIndex(of: "--capture-directory"), args.indices.contains(i + 1) {
            captureDirectory = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        } else { captureDirectory = nil }
        dayModel = AppModel(backgroundFixture: Self.fixture(defaults: defaults, night: false))
        nightModel = AppModel(backgroundFixture: Self.fixture(defaults: defaults, night: true))
        Self.shared = self
        let center = NotificationCenter.default
        for name in [NSApplication.didFinishLaunchingNotification,
                     NSApplication.didChangeScreenParametersNotification,
                     NSApplication.didBecomeActiveNotification,
                     NSApplication.didResignActiveNotification,
                     NSWindow.didChangeScreenNotification,
                     NSWindow.didChangeBackingPropertiesNotification,
                     NSWindow.didBecomeKeyNotification,
                     NSWindow.didResignKeyNotification] {
            observe(center, name)
        }
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification] {
            observe(NSWorkspace.shared.notificationCenter, name)
        }
        // An explicit sample remains available when the icon cannot be clicked.
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.request("manual-signal") }
        }
        source.resume()
        sampleSignal = source
        if args.contains("--cycle") {
            cycle = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect().sink { [weak self] _ in
                self?.toggle()
            }
        }
        lifetime = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.request("startup-settled")
            if let i = args.firstIndex(of: "--duration"), args.indices.contains(i + 1),
               let seconds = Double(args[i + 1]), seconds > 1, seconds < 3600 {
                try? await Task.sleep(nanoseconds: UInt64((seconds - 1) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.sample("diagnostic-complete")
                NSApp.terminate(nil)
            }
        }
        request("startup")
    }

    static func fixture(defaults: UserDefaults, night: Bool) -> BackgroundFixtureConfiguration {
        BackgroundFixtureConfiguration(
            defaults: defaults,
            location: ResolvedLocation(zip: "10001", latitude: 40.75, longitude: -74,
                                       city: "Synthetic", state: "NY", country: "US"),
            timeZone: TimeZone(identifier: "America/New_York")!, scheduleMode: .fixed,
            fixedNighttimeMinutes: 1200, fixedDaytimeMinutes: 420,
            scheduledPhase: night ? .night : .day, currentMode: night ? .dark : .light,
            nextTransition: Transition(date: Date(timeIntervalSince1970: 4070908800),
                                       phase: night ? .day : .night),
            override: nil, darkAppearanceEnabled: true, nightShiftEnabled: false,
            nightShiftAvailable: false, nightShiftActive: false, permissionBlocked: false,
            glanceText: night ? "Synthetic nighttime" : "Synthetic daytime")
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.request(name.rawValue) }
        }))
    }

    func toggle() {
        night.toggle()
        request("synthetic-phase")
    }

    func request(_ reason: String) {
        reasons.insert(reason)
        guard pending == nil else { return }
        pending = Task { @MainActor [weak self] in
            // Allow SwiftUI to commit the snapshot before inspecting its host.
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            let reason = self.reasons.sorted().joined(separator: ",")
            self.reasons.removeAll()
            self.sample(reason)
        }
    }

    func recordHost(_ view: NSView, reason: String) {
        emit(["event": reason, "host": host(view), "phase": night ? "night" : "day"])
        request(reason)
    }

    private func host(_ view: NSView) -> [String: Any] {
        let window = view.window
        let screen = window?.screen
        return ["windowNumber": window?.windowNumber ?? -1,
                "windowVisible": window?.isVisible ?? false,
                "screenID": screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber ?? -1,
                "backingScale": window?.backingScaleFactor ?? 0,
                "appearance": view.effectiveAppearance.name.rawValue,
                "bounds": NSStringFromRect(view.bounds),
                "visibleRect": NSStringFromRect(view.visibleRect)]
    }

    private func sample(_ reason: String) {
        func buttons(_ view: NSView) -> [NSStatusBarButton] {
            if let button = view as? NSStatusBarButton { return [button] }
            return view.subviews.flatMap(buttons)
        }
        let found = NSApp.windows.flatMap { $0.contentView.map(buttons) ?? [] }
        sequence += 1
        var entries: [[String: Any]] = []
        for (index, button) in found.enumerated() {
            var entry = host(button)
            let screenRect = button.window.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) } ?? .zero
            let intersectsScreen = NSScreen.screens.contains { $0.frame.intersects(screenRect) }
            entry["screenRect"] = NSStringFromRect(screenRect)
            entry["intersectsScreen"] = intersectsScreen
            entry["titlePresent"] = !button.title.isEmpty || !button.attributedTitle.string.isEmpty
            entry["actionPresent"] = button.action != nil
            entry["targetPresent"] = button.target != nil
            entry["accessibilityLabelPresent"] = !(button.accessibilityLabel() ?? "").isEmpty
            entry["highlighted"] = button.isHighlighted
            entry["backgroundStyle"] = button.cell?.backgroundStyle.rawValue ?? -1
            if let image = button.image {
                entry["image"] = ["size": NSStringFromSize(image.size), "template": image.isTemplate,
                                  "representations": image.representations.map {
                                      ["pixelsWide": $0.pixelsWide, "pixelsHigh": $0.pixelsHigh]
                                  }]
            } else { entry["image"] = NSNull() }
            entry["classification"] = !intersectsScreen ? "outside-screen-candidate" :
                (button.bounds.width <= 0 ? "zero-width" : "host-present-inspect-capture")
            if let directory = captureDirectory, button.bounds.width > 0, button.bounds.height > 0,
               let bitmap = button.bitmapImageRepForCachingDisplay(in: button.bounds) {
                // Only our own status button, never other applications or desktop pixels.
                button.cacheDisplay(in: button.bounds, to: bitmap)
                let filename = "button-\(sequence)-\(index).png"
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    try png.write(to: directory.appendingPathComponent(filename))
                    entry["capture"] = filename
                } catch { entry["captureError"] = String(describing: error) }
            }
            entries.append(entry)
        }
        emit(["event": reason, "sequence": sequence, "phase": night ? "night" : "day",
              "sceneInserted": inserted, "nativeButtonCount": found.count,
              "statusItemVisibility": "unavailable-through-public-SwiftUI-API",
              "statusItemLength": "unavailable-use-button-bounds",
              "classification": found.isEmpty ?
                (previouslyFoundButton ? "previous-native-button-missing" : "native-host-not-yet-observed") : "native-host-observed",
              "buttons": entries])
        previouslyFoundButton = previouslyFoundButton || !found.isEmpty
    }

    private func emit(_ fields: [String: Any]) {
        var record = fields
        record["pid"] = ProcessInfo.processInfo.processIdentifier
        record["timestamp"] = ISO8601DateFormatter().string(from: Date())
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
        }
    }

    deinit {
        pending?.cancel()
        cycle?.cancel()
        lifetime?.cancel()
        sampleSignal?.cancel()
        observers.forEach { $0.0.removeObserver($0.1) }
        defaults.removePersistentDomain(forName: suite)
    }
}

struct MenuBarDiagnosticApp: App {
    @StateObject private var diagnostics = MenuBarDiagnostics()
    @State private var inserted = true

    var body: some Scene {
        MenuBarExtra(isInserted: Binding(
            get: { inserted },
            set: { value in
                // SwiftUI can write back an unchanged insertion value. Publishing
                // it as model data would recursively invalidate the scene.
                if inserted != value { inserted = value }
                diagnostics.inserted = value
            }
        )) {
            VStack {
                HStack {
                    Text("Synthetic presentation diagnostic").font(.caption)
                    Button("Day / Night") { diagnostics.toggle() }
                    Button("Sample") { diagnostics.request("manual-button") }
                    Button("Quit") { NSApp.terminate(nil) }
                }
                .padding(8)
                PopoverView().environmentObject(diagnostics.model)
                    .disabled(true)
            }
        } label: {
            MenuBarGlyph(night: diagnostics.model.scheduledNight, summary: diagnostics.model.glanceSummary)
        }
        .menuBarExtraStyle(.window)
    }
}
