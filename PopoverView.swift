import SwiftUI
import CoreLocation

// =============================================================================
// PopoverView.swift — the MenuBarExtra popover UI. Every v2 feature is reachable
// and wired here; all mutations go through AppModel setters so persistence and
// re-evaluation happen in one place.
// =============================================================================

struct PopoverView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                Divider()
                overrideSection
                Divider()
                modeSection
                Divider()
                locationSection
                Divider()
                integrationsSection
                Divider()
                HStack {
                    Spacer()
                    Button("Quit") { NSApplication.shared.terminate(nil) }
                        .keyboardShortcut("q")
                }
            }
            .padding(16)
            .frame(width: 320)
        }
        .frame(maxHeight: 640)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: model.scheduledDark ? "moon.stars.fill" : "sun.max.fill")
                .font(.title2)
                .foregroundStyle(model.scheduledDark ? Color.indigo : Color.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Dark Mode Scheduler").font(.headline)
                Text(model.glanceSummary)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Feature 1 — override / pause

    private var overrideSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let description = model.overrideDescription {
                Label(description, systemImage: "pause.circle.fill")
                    .font(.caption).foregroundStyle(.orange)
                Button("Resume schedule now") { model.resumeNow() }
                    .controlSize(.small)
            } else {
                Text("Enforcement").font(.subheadline).bold()
                HStack {
                    Button("Pause 1 hour") { model.pauseForOneHour() }
                        .controlSize(.small)
                    Button("Pause until next \(nextBoundaryWord)") { model.pauseUntilNextBoundary() }
                        .controlSize(.small)
                }
                HStack(spacing: 6) {
                    Image(systemName: model.scheduleMatches ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                        .foregroundStyle(model.scheduleMatches ? .green : .orange)
                    Text(model.scheduleMatches
                         ? "Matches schedule (\(model.currentMode.label))"
                         : "Adjusting to \(model.scheduledMode.label)…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.permissionBlocked { permissionHint }
        }
    }

    /// "sunrise"/"sunset" in sun mode, "transition" in fixed mode.
    private var nextBoundaryWord: String {
        guard model.scheduleMode == .sun, let next = model.nextTransition else { return "transition" }
        return next.mode.isDark ? "sunset" : "sunrise"
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

    // MARK: Features 2 & 3 — schedule mode, offsets / fixed times

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                offsetRow(label: "Dark offset",
                          minutes: model.darkOffsetMinutes,
                          set: { model.setDarkOffset($0) },
                          anchor: "sunset")
                offsetRow(label: "Light offset",
                          minutes: model.lightOffsetMinutes,
                          set: { model.setLightOffset($0) },
                          anchor: "sunrise")
            } else {
                fixedTimeRow(label: "Dark at", minutes: model.fixedDarkMinutes,
                             set: { model.setFixedDarkMinutes($0) })
                fixedTimeRow(label: "Light at", minutes: model.fixedLightMinutes,
                             set: { model.setFixedLightMinutes($0) })
            }
        }
    }

    private func offsetRow(label: String, minutes: Int,
                           set: @escaping (Int) -> Void, anchor: String) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Stepper(value: Binding(get: { minutes }, set: { set($0) }),
                    in: SettingsStore.offsetRange, step: 5) {
                Text(offsetDescription(minutes, anchor: anchor))
                    .font(.caption).monospacedDigit()
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private func offsetDescription(_ minutes: Int, anchor: String) -> String {
        if minutes == 0 { return "at \(anchor)" }
        let mag = abs(minutes)
        return minutes < 0 ? "\(mag)m before \(anchor)" : "\(mag)m after \(anchor)"
    }

    private func fixedTimeRow(label: String, minutes: Int,
                              set: @escaping (Int) -> Void) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            DatePicker("", selection: timeBinding(minutes: minutes, set: set),
                       displayedComponents: .hourAndMinute)
                .labelsHidden()
        }
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

    // MARK: Features 4 & 5 — location source, postal / CoreLocation

    private var locationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                resolvedLocationRows(location)
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

    private func resolvedLocationRows(_ location: ResolvedLocation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            row(label: "Place", value: location.displayName)
            if model.scheduleMode == .sun {
                row(label: "Sunrise", value: model.formatted(model.sunrise))
                row(label: "Sunset", value: model.formatted(model.sunset))
            }
            row(label: "Current mode", value: model.currentMode.label)
        }
    }

    // MARK: Features 6 & 8 — notifications, Night Shift; launch at login

    private var integrationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                Text("Notify on switch").font(.subheadline)
            }
            .toggleStyle(.switch)

            Toggle(isOn: Binding(
                get: { model.nightShiftEnabled },
                set: { model.setNightShiftEnabled($0) })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Night Shift with schedule").font(.subheadline)
                    if !model.nightShiftAvailable {
                        Text("Unavailable on this Mac").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.switch)
            .disabled(!model.nightShiftAvailable)
        }
    }

    // MARK: Helpers

    private func row(label: String, value: String) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.subheadline).bold()
        }
    }
}
