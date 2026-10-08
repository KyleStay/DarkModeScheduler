import SwiftUI
import CoreLocation
import AppKit

// =============================================================================
// PopoverView.swift — the MenuBarExtra popover UI. Every feature is reachable
// and wired here; all mutations go through AppModel setters so persistence and
// re-evaluation happen in one place.
//
// Layout is ordered by how often a user needs it, top → bottom:
//   Header (status) → Right now (pause + switch early) → Schedule → Location →
//   Preferences → Quit.
// =============================================================================

struct PopoverView: View {
    @EnvironmentObject var model: AppModel
    @State private var contentHeight: CGFloat = 0
    @State private var hostMaximumHeight: CGFloat = PopoverSizing.maximumHeight(visibleHeight: nil)
    // Only the offscreen verification lane supplies a synthetic display budget.
    var fixtureVisibleHeight: CGFloat? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                Divider()
                nowSection
                Divider()
                scheduleSection
                Divider()
                locationSection
                Divider()
                preferencesSection
                Divider()
                HStack {
                    Spacer()
                    Button("Quit") { NSApplication.shared.terminate(nil) }
                        .keyboardShortcut("q")
                }
            }
            .padding(16)
            .frame(minWidth: 300, idealWidth: 340, maxWidth: 380)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: PopoverContentHeightKey.self,
                        value: geometry.size.height
                    )
                }
            }
        }
        // ScrollView does not publish its content's ideal height to the
        // MenuBarExtra window. Measure it explicitly so the window opens tall
        // enough to show everything, while retaining scrolling on short screens.
        .frame(
            minHeight: fittedPopoverHeight,
            idealHeight: fittedPopoverHeight,
            maxHeight: fittedPopoverHeight ?? maxPopoverHeight
        )
        .background {
            if fixtureVisibleHeight == nil {
                PresentationHostReader { view, reason in
                    let maximum = PopoverSizing.maximumHeight(
                        visibleHeight: view.window?.screen?.visibleFrame.height)
                    if hostMaximumHeight != maximum { hostMaximumHeight = maximum }
                    MenuBarDiagnostics.shared?.recordHost(view, reason: "popover-" + reason)
                }
            }
        }
        .onPreferenceChange(PopoverContentHeightKey.self) { height in
            contentHeight = height
        }
    }

    private var fittedPopoverHeight: CGFloat? {
        PopoverSizing.fittedHeight(content: contentHeight, maximum: maxPopoverHeight)
    }

    private var maxPopoverHeight: CGFloat {
        fixtureVisibleHeight.map { PopoverSizing.maximumHeight(visibleHeight: $0) }
            ?? hostMaximumHeight
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: model.scheduledNight ? "moon.stars.fill" : "sun.max.fill")
                .font(.title2)
                .foregroundStyle(model.scheduledNight ? Color.indigo : Color.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Dark Mode Scheduler").font(.headline)
                Text(model.glanceSummary)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: "Right now" — selected effects + one contextual action

    private var nowSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Right now").font(.subheadline).bold()

            if let description = model.overrideDescription {
                Label(description, systemImage: model.isEarlySwitch ? "clock.arrow.circlepath" : "pause.circle.fill")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: model.scheduleMatches ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                        .foregroundStyle(model.scheduleMatches ? .green : .orange)
                    Text(scheduleStatus)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if model.isOverridden {
                Button { model.resumeNow() } label: {
                    Label("Resume schedule", systemImage: "calendar.badge.clock")
                }
                .controlSize(.small)
                .help("End the current override and return to the schedule")
            } else {
                Button { model.switchToNextModeEarly() } label: {
                    Label("Start \(model.earlySwitchTarget.label.lowercased()) now",
                          systemImage: model.earlySwitchTarget.isNight ? "moon.stars.fill" : "sun.max.fill")
                }
                .controlSize(.small)
                .disabled(!model.hasAvailableEffects)
                .help("Start the next scheduled mode now")
            }

            nighttimeEffects

            if let error = model.earlySwitchError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if model.permissionBlocked { permissionHint }
        }
    }

    private var scheduleStatus: String {
        if !model.hasAvailableEffects { return "Schedule active — no available effects selected" }
        return model.scheduleMatches
            ? "\(model.scheduledPhase.label) effects are in place"
            : "Adjusting \(model.scheduledPhase.label.lowercased()) effects…"
    }

    private var permissionHint: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("Automation permission needed", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).bold().foregroundStyle(.orange)
            Text("Allow \"Dark Mode Scheduler\" to control System Events in\nSystem Settings → Privacy & Security → Automation, then try again.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Schedule — mode, offsets / fixed times (features 2 & 3), sun times

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Schedule").font(.subheadline).bold()
            Picker("Mode", selection: Binding(
                get: { model.scheduleMode },
                set: { model.setScheduleMode($0) })) {
                Text("Sun-based").tag(ScheduleMode.sun)
                Text("Fixed times").tag(ScheduleMode.fixed)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if model.scheduleMode == .sun {
                offsetRow(label: "Nighttime offset",
                          minutes: model.nighttimeOffsetMinutes,
                          set: { model.setNighttimeOffset($0) },
                          anchor: "sunset")
                offsetRow(label: "Daytime offset",
                          minutes: model.daytimeOffsetMinutes,
                          set: { model.setDaytimeOffset($0) },
                          anchor: "sunrise")
                // The resulting sun times sit with the offsets that shift them.
                if model.location != nil {
                    row(label: "Sunrise", value: model.formatted(model.sunrise))
                    row(label: "Sunset", value: model.formatted(model.sunset))
                }
            } else {
                fixedTimeRow(label: "Nighttime starts", minutes: model.fixedNighttimeMinutes,
                             set: { model.setFixedNighttimeMinutes($0) })
                fixedTimeRow(label: "Daytime starts", minutes: model.fixedDaytimeMinutes,
                             set: { model.setFixedDaytimeMinutes($0) })
            }
        }
    }

    private var nighttimeEffects: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Nighttime effects")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack {
                Text("Dark appearance")
                Spacer()
                Toggle("", isOn: Binding(
                    get: { model.darkAppearanceEnabled },
                    set: { model.setDarkAppearanceEnabled($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .help("Switch between Dark appearance at night and Light appearance during the day")
                .accessibilityLabel("Dark appearance")
            }

            if model.supportsNightShift {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Night Shift")
                        if !model.nightShiftAvailable {
                            Text("Unavailable on this Mac")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let error = model.nightShiftError {
                            Text(error)
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { model.nightShiftEnabled },
                        set: { model.setNightShiftEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(!model.nightShiftAvailable)
                    .help(model.nightShiftAvailable
                          ? "Turn on Night Shift at night and off during the day"
                          : "Night Shift control is unavailable on this Mac")
                    .accessibilityLabel("Night Shift")
                }
            }
        }
        .font(.subheadline)
    }

    private func offsetRow(label: String, minutes: Int,
                           set: @escaping (Int) -> Void, anchor: String) -> some View {
        let range = SettingsStore.offsetRange
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.subheadline)
                Spacer()
                Text(offsetDescription(minutes, anchor: anchor))
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(minutes == 0 ? .secondary : .primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                if minutes != 0 {
                    Button { set(0) } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.caption)
                    }
                        .buttonStyle(.plain)
                        .help("Reset to \(anchor) (no offset)")
                        .accessibilityLabel("Reset \(label.lowercased())")
                }
            }
            // A continuous native track avoids macOS's step tick marks. The
            // binding still rounds to five-minute increments for useful values.
            Slider(value: Binding(get: { Double(minutes) },
                                  set: { set(Int(($0 / 5).rounded()) * 5) }),
                   in: Double(range.lowerBound)...Double(range.upperBound)) {
                Text(label)
            }
            .labelsHidden()
            .accessibilityValue(offsetDescription(minutes, anchor: anchor))
            .help("Drag left for before \(anchor), or right for after \(anchor)")
        }
    }

    private func offsetDescription(_ minutes: Int, anchor: String) -> String {
        if minutes == 0 { return "At \(anchor)" }
        let mag = abs(minutes)
        let duration: String
        if mag < 60 {
            duration = "\(mag) min"
        } else if mag.isMultiple(of: 60) {
            let hours = mag / 60
            duration = "\(hours) \(hours == 1 ? "hr" : "hrs")"
        } else {
            let hours = mag / 60
            duration = "\(hours) hr \(mag % 60) min"
        }
        return minutes < 0
            ? "\(duration) before \(anchor)"
            : "\(duration) after \(anchor)"
    }

    private func fixedTimeRow(label: String, minutes: Int,
                              set: @escaping (Int) -> Void) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text(label).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                timePicker(minutes: minutes, set: set)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.subheadline).foregroundStyle(.secondary)
                timePicker(minutes: minutes, set: set)
            }
        }
    }

    private func timePicker(minutes: Int, set: @escaping (Int) -> Void) -> some View {
        DatePicker("", selection: timeBinding(minutes: minutes, set: set),
                   displayedComponents: .hourAndMinute)
            .labelsHidden()
    }

    private func timeBinding(minutes: Int, set: @escaping (Int) -> Void) -> Binding<Date> {
        Binding(
            get: {
                var comps = DateComponents()
                comps.hour = minutes / 60
                comps.minute = minutes % 60
                return Calendar.current.date(from: comps) ?? Date()
            },
            set: { date in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
                set((comps.hour ?? 0) * 60 + (comps.minute ?? 0))
            })
    }

    // MARK: Location — source + postal / CoreLocation (features 4 & 5)

    private var locationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Location").font(.subheadline).bold()
            Picker("Source", selection: Binding(
                get: { model.locationSource },
                set: { model.setLocationSource($0) })) {
                Text("Postal code").tag(LocationSource.zip)
                Text("My Location").tag(LocationSource.coreLocation)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if model.locationSource == .zip {
                postalEntry
            } else {
                coreLocationEntry
            }

            if let location = model.location {
                row(label: "Place", value: location.displayName)
            }
        }
    }

    private var postalEntry: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("US", text: $model.countryInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 48)
                    .help("2-letter country code (e.g. US, GB, DE, CA)")
                TextField("e.g. 10001", text: $model.zipInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                    .onSubmit { model.saveLocation() }
                Button("Save") { model.saveLocation() }
                    .disabled(model.isResolving)
                if model.isResolving { ProgressView().controlSize(.small) }
            }
            if let error = model.geocodeError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var coreLocationEntry: some View {
        switch model.locationAuthStatus {
        case .notDetermined:
            VStack(alignment: .leading, spacing: 4) {
                Button("Use my location") { model.useMyLocation() }
                Text("Asks macOS for permission. Postal code stays available as a fallback.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        case .denied, .restricted:
            VStack(alignment: .leading, spacing: 4) {
                Label("Location access is off", systemImage: "location.slash.fill")
                    .font(.caption).foregroundStyle(.orange)
                Button("Open Location Settings") { model.openLocationSettings() }
                    .controlSize(.small)
            }
        default:  // any authorized variant
            VStack(alignment: .leading, spacing: 4) {
                if model.isLocating {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Finding your location…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Label("Location access granted", systemImage: "location.fill")
                        .font(.caption).foregroundStyle(.green)
                    Button("Refresh location") { model.useMyLocation() }
                        .controlSize(.small)
                }
            }
        }
        if let error = model.locationError {
            Text(error).font(.caption).foregroundStyle(.red)
        }
    }

    // MARK: Preferences — launch at login and notifications

    private var preferencesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preferences").font(.subheadline).bold()

            HStack {
                Text("Launch at Login").font(.subheadline)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel("Launch at Login")
            }
            if let error = model.launchAtLoginError {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Text("Notify on transition").font(.subheadline)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { model.notificationsEnabled },
                    set: { model.setNotificationsEnabled($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel("Notify on transition")
            }
        }
    }

    // MARK: Helpers

    private func row(label: String, value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text(label).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text(value).font(.subheadline).bold()
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.subheadline).foregroundStyle(.secondary)
                Text(value).font(.subheadline).bold()
            }
        }
    }
}

private struct PopoverContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
