import Foundation

/// A single server-reported quota window. Usage is preserved as reported;
/// `remainingPercent` clamps only the value displayed to the user.
public struct QuotaWindow: Codable, Identifiable, Sendable, Equatable {
    public let bucketID: String
    public let bucketName: String?
    public let kind: String
    public let usedPercent: Double
    public let windowDurationMins: Int?
    public let resetsAt: Date?

    public init(
        bucketID: String,
        bucketName: String? = nil,
        kind: String,
        usedPercent: Double,
        windowDurationMins: Int?,
        resetsAt: Date?
    ) {
        self.bucketID = bucketID
        self.bucketName = bucketName
        self.kind = kind
        self.usedPercent = usedPercent
        self.windowDurationMins = windowDurationMins
        self.resetsAt = resetsAt
    }

    public var id: String { bucketID + "." + kind }

    public var remainingPercent: Double {
        guard usedPercent.isFinite else { return 0 }
        return min(100, max(0, 100 - usedPercent))
    }

    public var isWeekly: Bool { windowDurationMins == 10_080 }

    public var displayName: String {
        guard let minutes = windowDurationMins, minutes > 0 else {
            return kind == "secondary" ? "Secondary" : "Primary"
        }
        if isWeekly { return "Weekly" }
        if minutes.isMultiple(of: 1_440) { return "\(minutes / 1_440)-day" }
        if minutes.isMultiple(of: 60) { return "\(minutes / 60)-hour" }
        return "\(minutes)-minute"
    }
}

public struct UsageSnapshot: Codable, Sendable, Equatable {
    public let fetchedAt: Date
    public let windows: [QuotaWindow]
    public let availableResetCredits: Int?

    public init(fetchedAt: Date, windows: [QuotaWindow], availableResetCredits: Int? = nil) {
        self.fetchedAt = fetchedAt
        self.windows = windows
        self.availableResetCredits = availableResetCredits
    }

    /// Weekly windows win regardless of whether the service calls them primary
    /// or secondary. The standard Codex bucket wins within each duration class.
    public var preferredWindow: QuotaWindow? {
        windows.sorted { left, right in
            if left.isWeekly != right.isWeekly { return left.isWeekly }
            if (left.bucketID == "codex") != (right.bucketID == "codex") {
                return left.bucketID == "codex"
            }
            let leftDuration = left.windowDurationMins ?? 0
            let rightDuration = right.windowDurationMins ?? 0
            if leftDuration != rightDuration { return leftDuration > rightDuration }
            return left.id < right.id
        }.first
    }
}

public struct PaceMetrics: Codable, Sendable, Equatable {
    public let targetRemainingPercent: Double?
    public let gapPercentagePoints: Double?
    public let daysRemaining: Double?
    public let dailyAllowancePercent: Double?
    public let isExpired: Bool

    /// The shared display precision for the menu bar and popover pace status.
    public var roundedGapPercentagePoints: Double? {
        guard let gap = gapPercentagePoints, gap.isFinite else { return nil }
        let rounded = (gap * 10).rounded() / 10
        return rounded == 0 ? 0 : rounded
    }

    public init(window: QuotaWindow, at now: Date) {
        let remainingSeconds = window.resetsAt?.timeIntervalSince(now)
        isExpired = remainingSeconds.map { $0 <= 0 } ?? false
        if let remainingSeconds, remainingSeconds.isFinite {
            daysRemaining = max(0, remainingSeconds / 86_400)
        } else {
            daysRemaining = nil
        }

        guard
            let seconds = remainingSeconds,
            seconds.isFinite,
            seconds > 0,
            let minutes = window.windowDurationMins,
            minutes > 0,
            window.usedPercent.isFinite
        else {
            targetRemainingPercent = nil
            gapPercentagePoints = nil
            dailyAllowancePercent = nil
            return
        }

        let target = min(100, max(0, 100 * seconds / (Double(minutes) * 60)))
        targetRemainingPercent = target
        gapPercentagePoints = window.remainingPercent - target
        // The allowance becomes unhelpful in the final minute. Do not display
        // enormous per-day forecasts as the reset approaches.
        dailyAllowancePercent = seconds >= 60 ? window.remainingPercent / (seconds / 86_400) : nil
    }
}

public struct QuotaChange: Codable, Sendable, Equatable {
    public let windowID: String
    public let observedAt: Date
    public let message: String

    public init(windowID: String, observedAt: Date, message: String) {
        self.windowID = windowID
        self.observedAt = observedAt
        self.message = message
    }
}

public enum QuotaChangeDetector {
    /// Observes changes in authoritative reads. A local clock crossing the
    /// reset time is never sufficient evidence that quota has been restored.
    public static func changes(from previous: UsageSnapshot?, to current: UsageSnapshot) -> [QuotaChange] {
        guard let previous, current.fetchedAt >= previous.fetchedAt else { return [] }
        let oldWindows = Dictionary(previous.windows.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        return current.windows.compactMap { window in
            guard let old = oldWindows[window.id] else { return nil }
            let message: String
            if window.usedPercent < old.usedPercent - 0.000_001 {
                message = window.remainingPercent > old.remainingPercent
                    ? "\(window.displayName) quota restored"
                    : "\(window.displayName) usage adjusted"
            } else if window.resetsAt != old.resetsAt || window.windowDurationMins != old.windowDurationMins {
                message = "\(window.displayName) reset schedule updated"
            } else {
                return nil
            }
            return QuotaChange(windowID: window.id, observedAt: current.fetchedAt, message: message)
        }
    }
}
