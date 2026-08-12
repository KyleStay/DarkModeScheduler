import AppKit
import SwiftUI
import Foundation
import Dispatch

/// Inputs for one deterministic, offscreen UI fixture. The defaults suite and
/// all system adapters belong to the fixture process; nothing is read from or
/// written to the live user's settings.
struct BackgroundFixtureConfiguration {
    let defaults: UserDefaults
    let location: ResolvedLocation
    let timeZone: TimeZone
    let scheduleMode: ScheduleMode
    let fixedNighttimeMinutes: Int
    let fixedDaytimeMinutes: Int
    let scheduledPhase: SchedulePhase
    let currentMode: AppearanceMode
    let nextTransition: Transition
    let override: Override?
    let darkAppearanceEnabled: Bool
    let nightShiftEnabled: Bool
    let nightShiftAvailable: Bool
    let nightShiftActive: Bool
    let permissionBlocked: Bool
    let glanceText: String
}

private struct BackgroundArtifact: Codable {
    let name: String
    let relativePath: String
    let width: Int
    let height: Int
    let byteCount: Int
    let nonBackgroundSampleCount: Int
    let distinctSampleCount: Int
}

private struct BackgroundReport: Codable {
    let verification: String
    let fixtureVersion: Int
    let defaultsIsolation: String
    let adapters: [String]
    let artifacts: [BackgroundArtifact]
}

/// Packaged, nonactivating verification of the real popover view.
///
/// This type intentionally has no system menu-bar scene/status-item construction and no
/// live side-effecting calls. It renders `PopoverView` through NSHostingView,
/// which gives the default verification lane a real SwiftUI layout check while
/// keeping WindowServer focus and user state out of scope.
enum BackgroundVerification {
    private static let canvas = NSSize(width: 360, height: 1200)

    static func run(outputPath: String?) -> Never {
        Task { @MainActor in
            exit(Int32(runOnMainActor(outputPath: outputPath)))
        }
        dispatchMain()
    }

    @MainActor
    private static func runOnMainActor(outputPath: String?) -> Int {
        let outputDirectory = URL(fileURLWithPath: outputPath ?? ".build/background-verification",
                                  isDirectory: true)
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: outputDirectory,
                                            withIntermediateDirectories: true)
        } catch {
            print("[background] unable to create output directory: \(error)")
            return 1
        }

        let suiteName = "com.kyle.darkmodescheduler.background.\(ProcessInfo.processInfo.processIdentifier)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            print("[background] unable to create isolated defaults suite")
            return 1
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let timeZone = TimeZone(identifier: "America/New_York")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                hour: hour, minute: minute))!
        }

        let location = ResolvedLocation(zip: "10001", latitude: 40.7506,
                                        longitude: -73.9972, city: "Synthetic New York",
                                        state: "NY", country: "US")
        let activeNext = Transition(date: at(2099, 1, 11, 7, 0), phase: .day)
        let pausedUntil = at(2099, 1, 11, 7, 0)

        let fixtures: [(String, BackgroundFixtureConfiguration)] = [
            ("active-night", BackgroundFixtureConfiguration(
                defaults: defaults, location: location, timeZone: timeZone,
                scheduleMode: .fixed, fixedNighttimeMinutes: 20 * 60,
                fixedDaytimeMinutes: 7 * 60, scheduledPhase: .night,
                currentMode: .dark, nextTransition: activeNext, override: nil,
                darkAppearanceEnabled: true, nightShiftEnabled: true,
                nightShiftAvailable: true, nightShiftActive: true,
                permissionBlocked: false, glanceText: "Synthetic active-night fixture")),
            ("paused-day", BackgroundFixtureConfiguration(
                defaults: defaults, location: location, timeZone: timeZone,
                scheduleMode: .fixed, fixedNighttimeMinutes: 20 * 60,
                fixedDaytimeMinutes: 7 * 60, scheduledPhase: .day,
                currentMode: .dark,
                nextTransition: Transition(date: at(2099, 1, 11, 20, 0), phase: .night),
                override: Override(reason: .pausedUntilBoundary, until: pausedUntil),
                darkAppearanceEnabled: true, nightShiftEnabled: true,
                nightShiftAvailable: true, nightShiftActive: false,
                permissionBlocked: true, glanceText: "Synthetic paused-day fixture"))
        ]

        do {
            var artifacts: [BackgroundArtifact] = []
            for (name, fixture) in fixtures {
                let model = AppModel(backgroundFixture: fixture)
                let path = outputDirectory.appendingPathComponent("\(name).png")
                artifacts.append(try render(model: model, name: name, to: path))
            }

            let report = BackgroundReport(
                verification: "background-safe",
                fixtureVersion: 1,
                defaultsIsolation: "unique test suite: \(suiteName)",
                adapters: ["BackgroundAppearanceController", "BackgroundNightShiftController",
                           "LocationService(backgroundOnly: true)"],
                artifacts: artifacts)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let reportData = try encoder.encode(report)
            try reportData.write(to: outputDirectory.appendingPathComponent("report.json"),
                                 options: .atomic)
        } catch {
            print("[background] fixture failed: \(error)")
            return 1
        }

        print("✅ Background-safe fixture rendered to \(outputDirectory.path)")
        return 0
    }

    private static func render(model: AppModel, name: String, to path: URL) throws -> BackgroundArtifact {
        let root = AnyView(PopoverView().environmentObject(model))
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(origin: .zero, size: canvas)
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw NSError(domain: "BackgroundVerification", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "could not create bitmap context"])
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "BackgroundVerification", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "could not encode PNG"])
        }
        var nonBackgroundSampleCount = 0
        var distinctSamples = Set<UInt32>()
        for y in stride(from: 0, to: Int(canvas.height), by: 4) {
            for x in stride(from: 0, to: Int(canvas.width), by: 4) {
                var pixel = [Int](repeating: 0, count: 4)
                pixel.withUnsafeMutableBufferPointer { buffer in
                    bitmap.getPixel(buffer.baseAddress!, atX: x, y: y)
                }
                let sample = UInt32(pixel[0]) << 24 | UInt32(pixel[1]) << 16
                    | UInt32(pixel[2]) << 8 | UInt32(pixel[3])
                distinctSamples.insert(sample)
                if pixel[3] > 0 && (pixel[0] > 8 || pixel[1] > 8 || pixel[2] > 8) {
                    nonBackgroundSampleCount += 1
                }
            }
        }
        guard nonBackgroundSampleCount > 100, distinctSamples.count > 1 else {
            throw NSError(domain: "BackgroundVerification", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "rendered fixture has no visible UI content"])
        }
        try data.write(to: path, options: .atomic)
        return BackgroundArtifact(name: name, relativePath: path.lastPathComponent,
                                  width: Int(canvas.width), height: Int(canvas.height),
                                  byteCount: data.count,
                                  nonBackgroundSampleCount: nonBackgroundSampleCount,
                                  distinctSampleCount: distinctSamples.count)
    }
}
