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
        }
        // Size to content, but never taller than the screen it opens on — so the
        // popover only scrolls if the content genuinely can't fit the display
        // (e.g. very large system text), instead of at an arbitrary fixed height.
        .frame(maxHeight: maxPopoverHeight)
    }

    /// The usable height of the screen the menu bar lives on, minus a small
    /// margin. Falls back to a generous constant if no screen is reported.
    private var maxPopoverHeight: CGFloat {
        let visible = NSScreen.main?.visibleFrame.height ?? 900
        return max(320, visible - 24)
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

    // MARK: "Right now" — pause / resume (feature 1) + on-demand preview
    //
    // Both temporarily override the schedule, so they share one section: the
    // status/banner up top, then whichever controls apply, then the preview
    // (test) buttons that are always available.

    private var nowSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Right now").font(.subheadline).bold()

            if let description = model.overrideDescription {
                Label(description, systemImage: model.isEarlySwitch ? "clock.arrow.circlepath" : "pause.circle.fill")
                    .font(.caption).foregroundStyle(.orange)
                Button("Back to schedule") { model.resumeNow() }
                    .controlSize(.small)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: model.scheduleMatches ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                        .foregroundStyle(model.scheduleMatches ? .green : .orange)
                    Text(scheduleStatus)
                        .font(.caption).foregroundStyle(.secondary)
                }
                ViewThatFits(in: .horizontal) {
                    pauseButtons(axis: .horizontal)
                    pauseButtons(axis: .vertical)
                }
                // Bring the next scheduled change forward: switch to the upcoming
                // mode now (also confirms switching works) instead of waiting for
                // the boundary. Holds until then, then rejoins the schedule.
                Button { model.switchToNextModeEarly() } label: {
                    Label("Start \(model.earlySwitchTarget.label.lowercased()) effects now",
                          systemImage: model.earlySwitchTarget.isNight ? "moon.stars.fill" : "sun.max.fill")
                }
                .controlSize(.small)
                .disabled(!model.hasAvailableEffects)
                .help("Bring the next phase's selected effects forward to now")
            }

            if let error = model.earlySwitchError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if model.permissionBlocked { permissionHint }
        }
    }

    private func pauseButtons(axis: Axis) -> some View {
        Group {
            if axis == .horizontal {
                HStack {
                    Button("Pause 1 hour") { model.pauseForOneHour() }
                    Button("Pause until next \(nextBoundaryWord)") { model.pauseUntilNextBoundary() }
                }
            } else {
                VStack(alignment: .leading) {
                    Button("Pause 1 hour") { model.pauseForOneHour() }
                    Button("Pause until next \(nextBoundaryWord)") { model.pauseUntilNextBoundary() }
                }
            }
        }
        .controlSize(.small)
    }

    private var scheduleStatus: String {
        if !model.hasAvailableEffects { return "Schedule active — no available effects selected" }
        return model.scheduleMatches
            ? "\(model.scheduledPhase.label) effects are in place"
            : "Adjusting \(model.scheduledPhase.label.lowercased()) effects…"
    }

    /// "sunrise"/"sunset" in sun mode, "transition" in fixed mode.
    private var nextBoundaryWord: String {
        guard model.scheduleMode == .sun, let next = model.nextTransition else { return "transition" }
        return next.phase.isNight ? "sunset" : "sunrise"
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

            nighttimeEffects

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
        GroupBox("Nighttime effects") {
            VStack(alignment: .leading, spacing: 5) {
                Toggle("Dark appearance", isOn: Binding(
                    get: { model.darkAppearanceEnabled },
                    set: { model.setDarkAppearanceEnabled($0) }
                ))
                .toggleStyle(.switch)
                .help("Switch between Dark appearance at night and Light appearance during the day")
                .accessibilityLabel("Dark appearance")

                Toggle(isOn: Binding(
                    get: { model.nightShiftEnabled },
                    set: { model.setNightShiftEnabled($0) }
                )) {
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
                }
                .toggleStyle(.switch)
                .disabled(!model.nightShiftAvailable)
                .help(model.nightShiftAvailable
                      ? "Turn on Night Shift at night and off during the day"
                      : "Night Shift control is unavailable on this Mac")
                .accessibilityLabel("Night Shift")
            }
            .font(.subheadline)
        }
    }

    private func offsetRow(label: String, minutes: Int,
                           set: @escaping (Int) -> Void, anchor: String) -> some View {
        let range = SettingsStore.offsetRange
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                // Live magnitude as you drag, e.g. "30m before sunset".
                Text(offsetDescription(minutes, anchor: anchor))
                    .font(.caption).monospacedDigit()
                // Reset to the exact sun event; only shown when there's an offset.
                if minutes != 0 {
                    Button("Reset") { set(0) }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                        .help("Reset to \(anchor) (no offset)")
                }
            }
            // Slider gives a visual sense of how large the offset is (±3h) while
            // setting it; snaps to 5-minute steps like the old stepper.
            Slider(value: Binding(get: { Double(minutes) },
                                  set: { set(Int($0.rounded())) }),
                   in: Double(range.lowerBound)...Double(range.upperBound),
                   step: 5) {
                Text(label)
            } minimumValueLabel: {
                Text("−3h").font(.caption2).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text("+3h").font(.caption2).foregroundStyle(.secondary)
            }
            .labelsHidden()
        }
    }

    private func offsetDescription(_ minutes: Int, anchor: String) -> String {
        if minutes == 0 { return "at \(anchor)" }
        let mag = abs(minutes)
        return minutes < 0 ? "\(mag)m before \(anchor)" : "\(mag)m after \(anchor)"
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
                Label("Location access granted", systemImage: "location.fill")
                    .font(.caption).foregroundStyle(.green)
                Button("Refresh location") { model.useMyLocation() }
                    .controlSize(.small)
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

            Toggle(isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) })) {
                Text("Launch at Login").font(.subheadline)
            }
            .toggleStyle(.switch)
            if let error = model.launchAtLoginError {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            Toggle(isOn: Binding(
                get: { model.notificationsEnabled },
                set: { model.setNotificationsEnabled($0) })) {
                Text("Notify on transition").font(.subheadline)
            }
            .toggleStyle(.switch)
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
