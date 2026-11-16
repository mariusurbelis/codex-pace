import AppKit
import QuotaCore
import SwiftUI

/// A compact native utility: the quota is the fill, time is the marker.
@MainActor
struct TrackerView: View {
    @ObservedObject var model: TrackerModel
    @State private var isVisible = false
    @State private var showDetails: Bool

    init(model: TrackerModel, showDetails: Bool = false) {
        self.model = model
        _showDetails = State(initialValue: showDetails)
    }

    var body: some View {
        Group {
            if isVisible {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    content(at: context.date)
                }
            } else {
                content(at: .now)
            }
        }
        .frame(width: 360)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }

    private func content(at now: Date) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if let window = model.selectedWindow {
                quotaContent(window: window, now: now)
            } else {
                emptyContent
            }

            if let error = model.errorMessage {
                errorContent(error)
            }

            if let message = model.launchAtLoginMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            details(now: now)
        }
        .padding(18)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Codex Pace")
                .font(.headline)
            Spacer()
            if let window = model.selectedWindow {
                allowancePicker(window: window)
            }
            if model.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Refreshing usage")
            }
            settingsMenu
        }
    }

    private var settingsMenu: some View {
        Menu {
            Picker("Menu bar shows", selection: $model.menuBarDisplayMode) {
                ForEach(MenuBarDisplayMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)
            Divider()
            Toggle("Launch at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            Button("Choose Codex CLI…", action: model.chooseCLI)
            Divider()
            Button("Quit Codex Pace", action: model.quit)
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Settings")
        .accessibilityLabel("Settings")
    }

    private func quotaContent(window: QuotaWindow, now: Date) -> some View {
        let pace = PaceMetrics(window: window, at: now)
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(percent(window.remainingPercent, precision: 0))
                        .font(.system(size: 44, weight: .medium, design: .rounded))
                        .monospacedDigit()
                    Text("remaining")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if model.isStale(at: now) {
                        Label("Last reading", systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)

                paceDescription(pace)
            }

            PaceBar(
                remaining: window.remainingPercent,
                target: pace.targetRemainingPercent
            )

            VStack(alignment: .leading, spacing: 10) {
                if let reset = window.resetsAt {
                    VStack(alignment: .trailing, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Resets")
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 12)
                            Text(reset > now ? countdown(until: reset, now: now) : "Waiting for update")
                                .monospacedDigit()
                        }
                        Text(resetDate(reset))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } else {
                    Text("Reset time unavailable")
                        .foregroundStyle(.secondary)
                }

                if let daily = pace.dailyAllowancePercent, !pace.isExpired {
                    let isHourly = (window.windowDurationMins ?? 1_440) < 1_440
                    HStack(alignment: .firstTextBaseline) {
                        Text("To last until reset")
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        Text("\(percent(isHourly ? daily / 24 : daily, precision: 1)) / \(isHourly ? "hour" : "day")")
                            .fontWeight(.medium)
                            .monospacedDigit()
                            .help("Percentage points of this allowance per \(isHourly ? "hour" : "24 hours"). A planning estimate; task costs vary.")
                    }
                }
            }
            .font(.subheadline)
        }
    }

    @ViewBuilder
    private func allowancePicker(window: QuotaWindow) -> some View {
        if let snapshot = model.snapshot, snapshot.windows.count > 1 {
            Picker("Allowance", selection: $model.selectedWindowID) {
                ForEach(snapshot.windows) { option in
                    Text(windowLabel(option, includeBucket: true)).tag(option.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(maxWidth: 160)
        } else {
            Text(windowLabel(window, includeBucket: false))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func paceDescription(_ pace: PaceMetrics) -> some View {
        if pace.isExpired {
            Label(
                model.isRefreshing ? "Reset due. Checking the latest allowance." : "Reset due. Waiting for a fresh reading.",
                systemImage: "clock.arrow.circlepath"
            )
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else if let gap = pace.roundedGapPercentagePoints {
            if gap < 0 {
                Label("\(number(abs(gap), precision: 1)) points below pace", systemImage: "exclamationmark.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                    .accessibilityLabel("\(number(abs(gap), precision: 1)) percentage points below pace")
            } else if gap > 0 {
                Label("\(number(gap, precision: 1)) points above pace", systemImage: "checkmark.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PacePalette.surplus)
                    .accessibilityLabel("\(number(gap, precision: 1)) percentage points above pace")
            } else {
                Label("On pace for this window", systemImage: "checkmark.circle")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Pace is available when a reset time and window length are reported.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var emptyContent: some View {
        if model.isRefreshing {
            VStack(alignment: .leading, spacing: 8) {
                Text("Reading your allowance…")
                    .font(.title3.weight(.medium))
                Text("Using your existing Codex sign-in.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
        } else if model.snapshot != nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("No allowance reported")
                    .font(.title3.weight(.medium))
                Text("Open your usage dashboard to check the limits available on this account.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Usage dashboard", action: model.openUsageDashboard)
                    .controlSize(.small)
            }
        } else if model.errorMessage == nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your weekly pace, at a glance")
                    .font(.title3.weight(.medium))
                Text("Refresh to read the allowance on your signed-in Codex account.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                refreshButton
                    .controlSize(.small)
            }
        }
    }

    private func errorContent(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(model.snapshot == nil ? "Couldn’t read usage" : "Update failed · showing last reading", systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.orange)
            if model.snapshot == nil {
                errorMessage(message)
                HStack {
                    Button("Choose Codex CLI…", action: model.chooseCLI)
                    Spacer()
                    refreshButton
                }
                .controlSize(.small)
            }
        }
    }

    private func errorMessage(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func details(now: Date) -> some View {
        DisclosureGroup(isExpanded: $showDetails) {
            VStack(alignment: .leading, spacing: 14) {
                if let window = model.selectedWindow,
                   let target = PaceMetrics(window: window, at: now).targetRemainingPercent {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Even-use target")
                            Spacer()
                            Text(percent(target, precision: 1))
                                .monospacedDigit()
                        }
                        Text("Blue is the allowance up to the marker. Green is above pace. Gray is already used.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if model.menuBarDisplayMode == .paceBalance {
                            Text("A positive pace balance is extra allowance you can use before reaching the even-use pace. Points are a share of the full quota, not a prompt count.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.caption)
                }
                if let error = model.errorMessage, model.snapshot != nil {
                    errorMessage(error)
                }
                footer(now: now)
                if !model.changes.isEmpty {
                    Divider()
                    recentChanges
                }
            }
            .padding(.top, 10)
        } label: {
            Text("More details")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .font(.caption)
    }

    private var recentChanges: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent allowance changes")
                .font(.caption.weight(.medium))
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(model.changes.prefix(5).enumerated()), id: \.offset) { _, change in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(change.message)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(change.observedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func footer(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                if let fetchedAt = model.snapshot?.fetchedAt {
                    Text("Updated \(age(of: fetchedAt, now: now))")
                } else {
                    Text("Checks every 5 minutes")
                }
                Spacer()
                if let next = model.nextRefreshAt, !model.isRefreshing {
                    Text(next > now ? "Next \(countdown(until: next, now: now))" : "Check due")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Button("Usage dashboard", action: model.openUsageDashboard)
                    .buttonStyle(.link)
                Spacer()
                refreshButton
            }
            .controlSize(.small)
        }
    }

    private var refreshButton: some View {
        Button("Refresh now") {
            Task { await model.refresh() }
        }
        .keyboardShortcut("r")
        .disabled(model.isRefreshing)
    }

    private func windowLabel(_ window: QuotaWindow, includeBucket: Bool) -> String {
        guard includeBucket || window.bucketID != "codex" else { return window.displayName }
        let name = window.bucketName ?? (window.bucketID == "codex" ? "Codex" : window.bucketID)
        return "\(name) · \(window.displayName)"
    }

    private func number(_ value: Double, precision: Int) -> String {
        value.formatted(.number.precision(.fractionLength(precision)))
    }

    private func percent(_ value: Double, precision: Int) -> String {
        number(value, precision: precision) + "%"
    }

    private func resetDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateFormat = "EEE d MMM, HH:mm z"
        return formatter.string(from: date)
    }

    private func countdown(until date: Date, now: Date) -> String {
        let seconds = max(0, date.timeIntervalSince(now))
        if seconds < 60 { return "in less than a minute" }
        let totalMinutes = Int(ceil(seconds / 60))
        let days = totalMinutes / 1_440
        let hours = (totalMinutes % 1_440) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return "in \(days)d \(hours)h" }
        if hours > 0 { return "in \(hours)h \(minutes)m" }
        return "in \(minutes)m"
    }

    private func age(of date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3_600)h ago" }
        return "\(seconds / 86_400)d ago"
    }
}
